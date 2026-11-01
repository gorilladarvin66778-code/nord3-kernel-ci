#!/usr/bin/env bash
# Nord 3 (vitamin) RTL8821AU build. Stages: deps toolchain source config kernel driver check
set -euo pipefail

WORK="${WORK:-$HOME/nord3-build}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/nord3_running_kernel.config}"
# With .scmversion present, the tree's localversion "-o" is dropped, so LV must carry it.
LV="-android12-9-o"

EXPECT_REL="5.10.209-android12-9-o-gb0bb096ffb03"
EXPECT_VERMAGIC="${EXPECT_REL} SMP preempt mod_unload modversions aarch64"
EXPECT_SHA="b0bb096ffb03"

KREPO="https://github.com/lineageos-on-vitamin/android_kernel_oneplus_mt6983"
KBRANCH="lineage-22.2"

VND_REPO="https://github.com/lineageos-on-vitamin/android_kernel_modules_oneplus_mt6983"
VND_BRANCH="lineage-22.2"
VND_SHA="2bfce4788931"

CLANG_REPO="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
CLANG_BRANCH="android12-release"
CLANG_NAME="clang-r416183b"
DRV_REPO="https://github.com/morrownr/8821au-20210708"

SRC="${WORK}/kernel"
VND="${WORK}/vendor/oplus"
OUT="${WORK}/out"
DRV="${WORK}/8821au"
DIST="${WORK}/dist"
CLANG="${WORK}/clang-repo/${CLANG_NAME}"
KCF_FILE="${WORK}/kcflags.txt"
mkdir -p "${WORK}" "${DIST}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

need_clang() {
  [ -x "${CLANG}/bin/clang" ] || fail "toolchain missing - run: $0 toolchain"
  export PATH="${CLANG}/bin:${PATH}"
}

kmake() {
  KCF=""
  if [ -f "${KCF_FILE}" ]; then KCF="$(cat "${KCF_FILE}")"; fi
  make -C "${SRC}" O="${OUT}" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
    HOSTCC=gcc HOSTCXX=g++ HOSTLD=ld LOCALVERSION="${LV}" \
    KCFLAGS="${KCF}" "$@"
}

st_deps() {
  sudo apt-get update
  sudo apt-get install -y git curl build-essential bc bison flex libssl-dev libelf-dev \
    libncurses-dev python3 cpio rsync lz4 xz-utils zip unzip dwarves kmod \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  echo "--- resources:"
  nproc
  free -g | head -2
  df -h "${WORK}" | tail -1
  pass "deps installed"
}

st_toolchain() {
  if [ ! -d "${WORK}/clang-repo/.git" ]; then
    git clone --depth 1 --filter=blob:none --sparse -b "${CLANG_BRANCH}" "${CLANG_REPO}" "${WORK}/clang-repo"
  fi
  git -C "${WORK}/clang-repo" sparse-checkout set "${CLANG_NAME}"
  [ -x "${CLANG}/bin/clang" ] || fail "${CLANG_NAME} not found on branch ${CLANG_BRANCH}"
  V="$("${CLANG}/bin/clang" --version | head -1)"
  echo "${V}"
  echo "${V}" | grep -q "12.0.5" || fail "compiler is not clang 12.0.5"
  pass "toolchain ${CLANG_NAME}"
}

st_source() {
  # kernel source, pinned to the running kernel's commit
  if [ ! -d "${SRC}/.git" ]; then
    git clone --depth 1 -b "${KBRANCH}" "${KREPO}" "${SRC}"
  fi
  H="$(git -C "${SRC}" rev-parse --short=12 HEAD)"
  [ "${H}" = "${EXPECT_SHA}" ] || fail "kernel HEAD=${H} expected ${EXPECT_SHA}"
  pass "kernel HEAD ${H}"

  # modules repo, pinned commit. Its tree is: <clone>/vendor/oplus/kernel/...
  if [ ! -d "${VND}/.git" ]; then
    mkdir -p "${WORK}/vendor"
    git clone -b "${VND_BRANCH}" "${VND_REPO}" "${VND}"
  fi
  git -C "${VND}" checkout -q "${VND_SHA}" || fail "cannot checkout ${VND_SHA}"
  VH="$(git -C "${VND}" rev-parse --short=12 HEAD)"
  [ "${VH}" = "${VND_SHA}" ] || fail "vendor commit ${VH} expected ${VND_SHA}"
  pass "vendor commit ${VH}"

  # relink every tracked symlink in the kernel tree that points into vendor/oplus
  BAD=0
  while read -r mode _ _ path; do
    [ "${mode}" = "120000" ] || continue
    t="$(readlink "${SRC}/${path}" 2>/dev/null || true)"
    case "${t}" in
      *vendor/oplus/*)
        rest="${t#*vendor/oplus/}"
        tgt="${VND}/vendor/oplus/${rest}"
        rm -f "${SRC}/${path}"
        ln -s "${tgt}" "${SRC}/${path}"
        if [ -e "${SRC}/${path}" ]; then
          echo "relinked ${path}"
        else
          echo "MISSING target for ${path} -> ${tgt}"
          BAD=1
        fi
        ;;
    esac
  done < <(git -C "${SRC}" ls-files -s)
  [ "${BAD}" = 0 ] || fail "some oplus links have no target in the modules clone (see MISSING)"

  # oplus code includes ../../../../vendor/oplus/... from drivers/gpu/drm/mediatek/mediatek_v2/,
  # which resolves to drivers/vendor/oplus/...
  if [ -e "${SRC}/drivers/vendor" ] && [ ! -L "${SRC}/drivers/vendor" ]; then
    fail "kernel repo has a real drivers/vendor directory, refusing to replace it"
  fi
  rm -f "${SRC}/drivers/vendor"
  ln -s "${VND}/vendor" "${SRC}/drivers/vendor"

  # oplus code includes ../../../../kernel-5.10/... from two depths, so both links are needed:
  #  - from drivers/power/oplus/v1/charger_ic/ the target is drivers/kernel-5.10
  #  - from drivers/power/oplus/test-kit/../charger_ic/ the target is <root>/kernel-5.10
  rm -f "${SRC}/drivers/kernel-5.10"
  ln -s ../ "${SRC}/drivers/kernel-5.10"
  rm -f "${SRC}/kernel-5.10"
  ln -s . "${SRC}/kernel-5.10"
  [ -f "${SRC}/drivers/kernel-5.10/drivers/power/supply/charger_class.h" ] || fail "drivers/kernel-5.10 link broken"
  [ -f "${SRC}/kernel-5.10/drivers/power/supply/charger_class.h" ] || fail "root kernel-5.10 link broken"
  pass "kernel-5.10 links ok (drivers/ and root)"

  TP="${SRC}/drivers/vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2/touchpanel_notify/touchpanel_event_notify.h"
  [ -f "${TP}" ] || fail "drivers/vendor link broken, touchpanel header not reachable"
  pass "path links ok"

  # Include path for touch_pen_core.c: ONLY the oplus_touchscreen_v2 folder (the one whose
  # touchpanel_common.h has pen_msg_list), plus the touchpanel_notify folder.
  # Do NOT add oplus_touchscreen/ (v1): its struct touchpanel_data has no pen_msg_list.
  V2="${VND}/vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2"
  [ -f "${V2}/touchpanel_common.h" ] || fail "v2 touchpanel_common.h not found at ${V2}"
  grep -q "pen_msg_list" "${V2}/touchpanel_common.h" || fail "v2 touchpanel_common.h has no pen_msg_list"
  EVT="$(find "${V2}" -name touchpanel_event_notify.h | head -1 || true)"
  [ -n "${EVT}" ] || fail "touchpanel_event_notify.h not found under v2"
  EVT_DIR="$(dirname "${EVT}")"
  echo "DIAG v2 folder : ${V2}"
  echo "DIAG notify dir: ${EVT_DIR}"
  echo "-I${V2} -I${EVT_DIR}" > "${KCF_FILE}"
  echo "KCFLAGS: $(cat "${KCF_FILE}")"
  pass "include flags written"

  # link edits make the git tree dirty (adds -dirty). .scmversion gives a fixed -g<sha> instead.
  echo "-g${H}" > "${SRC}/.scmversion"
  SV="$(cat "${SRC}/.scmversion")"
  pass "scmversion=${SV}"
}

st_config() {
  need_clang
  [ -f "${CONFIG_SRC}" ] || fail "missing ${CONFIG_SRC}"
  mkdir -p "${OUT}"
  rm -f "${OUT}/.config"
  cp "${CONFIG_SRC}" "${OUT}/.config"
  kmake olddefconfig > "${WORK}/config.log" 2>&1 || { tail -20 "${WORK}/config.log"; fail "olddefconfig"; }

  bad=0
  for s in KASAN_HW_TAGS LTO_CLANG_THIN CFI_CLANG SHADOW_CALL_STACK MODVERSIONS CFG80211 MAC80211 MODULE_SIG; do
    a="$(grep -E "^CONFIG_${s}=" "${CONFIG_SRC}" || echo "unset:${s}")"
    b="$(grep -E "^CONFIG_${s}=" "${OUT}/.config" || echo "unset:${s}")"
    if [ "${a}" = "${b}" ]; then
      echo "  same: ${a}"
    else
      echo "  DIFF: phone[${a}] generated[${b}]"
      bad=1
    fi
  done
  [ "${bad}" = 0 ] || fail "critical config drift vs running kernel"

  kmake -j"$(nproc)" modules_prepare > "${WORK}/prepare.log" 2>&1 || { tail -20 "${WORK}/prepare.log"; fail "modules_prepare"; }
  REL="$(cat "${OUT}/include/config/kernel.release")"
  if [ "${REL}" = "${EXPECT_REL}" ]; then
    pass "kernel.release ${REL}"
  else
    fail "release ${REL}, expected ${EXPECT_REL}"
  fi
}

st_kernel() {
  need_clang
  [ -f "${OUT}/.config" ] || fail "run config first"
  echo "Heavy step. Progress: tail -f ${WORK}/kernel-build.log"
  if ! kmake -j"$(nproc)" Image modules > "${WORK}/kernel-build.log" 2>&1; then
    echo "--- real errors:"
    grep -nE "fatal error|error:|undefined reference|Killed|No space" "${WORK}/kernel-build.log" | head -40 || echo "  none matched"
    echo "--- last 40 lines:"
    tail -40 "${WORK}/kernel-build.log"
    fail "kernel build"
  fi
  [ -f "${OUT}/Module.symvers" ] || fail "Module.symvers not produced"
  REL="$(cat "${OUT}/include/config/kernel.release")"
  [ "${REL}" = "${EXPECT_REL}" ] || fail "release ${REL}"
  N="$(wc -l < "${OUT}/Module.symvers")"
  pass "built ${REL}, Module.symvers has ${N} lines"
}

patch_tasklets() {
  # Kernel 5.10 tasklet_init() calls the callback as void(unsigned long). The driver declares its
  # callbacks as void(void *) and casts them, which does not change the target's type. CFI checks
  # the target's type at the call, so it traps. Fix: make the callbacks take unsigned long and
  # cast back to void * inside. Also remove the function-pointer casts at tasklet_init call sites.
  python3 - "$1" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
names = ["usb_recv_tasklet", "rtl8812au_xmit_tasklet", "mpath_tx_tasklet_hdl"]
defs_found = {n: 0 for n in names}
files_changed = 0
for p in root.rglob("*"):
    if not p.is_file() or p.suffix not in (".c", ".h"):
        continue
    s = p.read_text(errors="ignore")
    o = s
    for n in names:
        def_pat = r"void\s+%s\s*\(\s*void\s*\*\s*priv\s*\)\s*\n(\s*)\{" % n
        def_count = len(re.findall(def_pat, s))
        defs_found[n] += def_count
        s = re.sub(def_pat,
                   lambda m, n=n: "void %s(unsigned long _priv)\n%s{\n%s\tvoid *priv = (void *)_priv;"
                                  % (n, m.group(1), m.group(1)), s)
        s = re.sub(r"void\s+%s\s*\(\s*void\s*\*\s*priv\s*\)\s*;" % n,
                   "void %s(unsigned long _priv);" % n, s)
        s = re.sub(r"\(\s*void\s*\(\s*\*\s*\)\s*(\(\s*unsigned long\s*\)\s*)?\)\s*%s\b" % n, n, s)
        s = re.sub(r"\(\s*void\s*\*\s*\)\s*%s\b" % n, n, s)
    if s != o:
        p.write_text(s)
        files_changed += 1
        print("patched", p)
print("files changed:", files_changed)
missing = [n for n, c in defs_found.items() if c == 0]
for n, c in defs_found.items():
    print("definitions patched for %s: %d" % (n, c))
if missing:
    print("ERROR: no definition found for:", missing)
    sys.exit(1)
PY
  [ $? -eq 0 ] || fail "tasklet patch failed"
  # verify no old-style definitions remain for these names
  if grep -rnE "void +(usb_recv_tasklet|rtl8812au_xmit_tasklet|mpath_tx_tasklet_hdl) *\(void *\* *priv\)" "$1" --include=*.c --include=*.h 2>/dev/null | head -5 | grep -q .; then
    fail "old void*-style tasklet callbacks still present"
  fi
  pass "tasklet callbacks patched to
