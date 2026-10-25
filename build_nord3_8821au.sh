#!/usr/bin/env bash
# Nord 3 (vitamin) RTL8821AU build. Stages: deps toolchain source config kernel driver check
set -euo pipefail

WORK="${WORK:-$HOME/nord3-build}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/nord3_running_kernel.config}"
# Kernel tree's localversion file already adds "-o". Only "-android12-9" is needed here.
LV="-android12-9"

EXPECT_REL="5.10.209-android12-9-o-gb0bb096ffb03"
EXPECT_VERMAGIC="$EXPECT_REL SMP preempt mod_unload modversions aarch64"
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

SRC="$WORK/kernel"
VND="$WORK/vendor/oplus"
OUT="$WORK/out"
DRV="$WORK/8821au"
DIST="$WORK/dist"
CLANG="$WORK/clang-repo/$CLANG_NAME"
mkdir -p "$WORK" "$DIST"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

need_clang() {
  [ -x "$CLANG/bin/clang" ] || fail "toolchain missing - run: $0 toolchain"
  export PATH="$CLANG/bin:$PATH"
}

kmake() {
  make -C "$SRC" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
    HOSTCC=gcc HOSTCXX=g++ HOSTLD=ld LOCALVERSION="$LV" "$@"
}

st_deps() {
  sudo apt-get update
  sudo apt-get install -y git curl build-essential bc bison flex libssl-dev libelf-dev \
    libncurses-dev python3 cpio rsync lz4 xz-utils zip unzip dwarves kmod \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  echo "--- resources:"; nproc; free -g | head -2; df -h "$WORK" | tail -1
  pass "deps installed"
}

st_toolchain() {
  [ -d "$WORK/clang-repo/.git" ] || \
    git clone --depth 1 --filter=blob:none --sparse -b "$CLANG_BRANCH" "$CLANG_REPO" "$WORK/clang-repo"
  git -C "$WORK/clang-repo" sparse-checkout set "$CLANG_NAME"
  [ -x "$CLANG/bin/clang" ] || fail "$CLANG_NAME not found on branch $CLANG_BRANCH"
  V="$("$CLANG/bin/clang" --version | head -1)"; echo "$V"
  echo "$V" | grep -q "12.0.5" || fail "compiler is not clang 12.0.5"
  pass "toolchain $CLANG_NAME"
}

st_source() {
  # kernel source, pinned to the running kernel's commit
  [ -d "$SRC/.git" ] || git clone --depth 1 -b "$KBRANCH" "$KREPO" "$SRC"
  H="$(git -C "$SRC" rev-parse --short=12 HEAD)"
  [ "$H" = "$EXPECT_SHA" ] || fail "kernel HEAD=$H expected $EXPECT_SHA"
  pass "kernel HEAD $H"

  # modules repo, pinned commit. Its tree contains vendor/oplus/...
  [ -d "$VND/.git" ] || { mkdir -p "$WORK/vendor"; git clone -b "$VND_BRANCH" "$VND_REPO" "$VND"; }
  git -C "$VND" checkout -q "$VND_SHA" || fail "cannot checkout $VND_SHA"
  VH="$(git -C "$VND" rev-parse --short=12 HEAD)"
  [ "$VH" = "$VND_SHA" ] || fail "vendor commit $VH expected $VND_SHA"
  pass "vendor commit $VH"

  # relink every tracked symlink in the kernel tree that points into vendor/oplus
  BAD=0
  while read -r mode _ _ path; do
    [ "$mode" = "120000" ] || continue
    t="$(readlink "$SRC/$path" 2>/dev/null || true)"
    case "$t" in
      *vendor/oplus/*)
        rest="${t#*vendor/oplus/}"
        tgt="$VND/vendor/oplus/$rest"
        rm -f "$SRC/$path"
        ln -s "$tgt" "$SRC/$path"
        if [ -e "$SRC/$path" ]; then
          echo "relinked $path -> $tgt"
        else
          echo "MISSING target for $path -> $tgt"; BAD=1
        fi
        ;;
    esac
  done < <(git -C "$SRC" ls-files -s)
  [ "$BAD" = 0 ] || fail "some oplus links have no target in the modules clone (see MISSING)"

  # oplus code includes ../../../../kernel-5.10/... so this must resolve to the kernel root
  rm -f "$SRC/drivers/kernel-5.10"
  ln -s ../ "$SRC/drivers/kernel-5.10"
  [ -f "$SRC/drivers/kernel-5.10/drivers/power/supply/charger_class.h" ] || fail "kernel-5.10 link broken"

  # our link edits make the git tree 'dirty', which adds -dirty to the release string.
  # .scmversion (untracked) makes scripts/setlocalversion use this fixed -g<sha> instead of git.
  echo "-g$H" > "$SRC/.scmversion"
  pass "path links ok, .scmversion=$(cat "$SRC/.scmversion")"
}

st_config() {
  need_clang
  [ -f "$CONFIG_SRC" ] || fail "missing $CONFIG_SRC"
  mkdir -p "$OUT"; rm -f "$OUT/.config"; cp "$CONFIG_SRC" "$OUT/.config"
  kmake olddefconfig > "$WORK/config.log" 2>&1 || { tail -20 "$WORK/config.log"; fail "olddefconfig"; }

  bad=0
  for s in KASAN_HW_TAGS LTO_CLANG_THIN CFI_CLANG SHADOW_CALL_STACK MODVERSIONS CFG80211 MAC80211 MODULE_SIG; do
    a="$(grep -E "^CONFIG_${s}=" "$CONFIG_SRC" || echo "unset:$s")"
    b="$(grep -E "^CONFIG_${s}=" "$OUT/.config" || echo "unset:$s")"
    if [ "$a" = "$b" ]; then echo "  same: $a"; else echo "  DIFF: phone[$a] generated[$b]"; bad=1; fi
  done
  [ "$bad" = 0 ] || fail "critical config drift vs running kernel"

  kmake -j"$(nproc)" modules_prepare > "$WORK/prepare.log" 2>&1 || { tail -20 "$WORK/prepare.log"; fail "modules_prepare"; }
  REL="$(cat "$OUT/include/config/kernel.release")"
  [ "$REL" = "$EXPECT_REL" ] && pass "kernel.release $REL" || fail "release $REL, expected $EXPECT_REL"
}

st_kernel() {
  need_clang
  [ -f "$OUT/.config" ] || fail "run config first"
  echo "Heavy step. Progress: tail -f $WORK/kernel-build.log"
  kmake -j"$(nproc)" Image modules > "$WORK/kernel-build.log" 2>&1 || { tail -40 "$WORK/kernel-build.log"; fail "kernel build"; }
  [ -f "$OUT/Module.symvers" ] || fail "Module.symvers not produced"
  REL="$(cat "$OUT/include/config/kernel.release")"
  [ "$REL" = "$EXPECT_REL" ] || fail "release $REL"
  pass "built $REL, Module.symvers has $(wc -l < "$OUT/Module.symvers") lines"
}

st_driver() {
  need_clang
  [ -f "$OUT/Module.symvers" ] || fail "run kernel first"
  [ -d "$DRV/.git" ] || git clone --depth 1 "$DRV_REPO" "$DRV"
  echo "--- platform options in driver Makefile (not changed by this script):"
  grep -nE '^CONFIG_PLATFORM_' "$DRV/Makefile" || echo "  none found"
  kmake -j"$(nproc)" M="$DRV" modules > "$WORK/driver-build.log" 2>&1 || { tail -40 "$WORK/driver-build.log"; fail "driver build"; }
  KO="$(find "$DRV" -name '8821au.ko' | head -1)"
  [ -n "$KO" ] || fail "8821au.ko not produced"
  cp "$KO" "$DIST/8821au.ko"; sha256sum "$DIST/8821au.ko"
  pass "built $DIST/8821au.ko"
}

st_check() {
  KO="$DIST/8821au.ko"; [ -f "$KO" ] || fail "run driver first"

  VM="$(strings "$KO" | grep -m1 '^vermagic=' | sed 's/^vermagic=//' || true)"
  echo "module : $VM"; echo "running: $EXPECT_VERMAGIC"
  [ "$VM" = "$EXPECT_VERMAGIC" ] && pass "vermagic matches" || fail "vermagic differs - do NOT load"

  rm -f "$WORK/missing-syms.txt"; MISS=0
  for s in $(aarch64-linux-gnu-nm -u "$KO" | awk '{print $2}' | sort -u); do
    if ! awk -v s="$s" '$2==s{f=1} END{exit !f}' "$OUT/Module.symvers"; then
      MISS=$((MISS+1)); echo "$s" >> "$WORK/missing-syms.txt"
    fi
  done
  echo "undefined symbols not in Module.symvers: $MISS (list: $WORK/missing-syms.txt)"
  echo "NOTE: some symbols come from vmlinux, not Module.symvers. Review this list before any insmod."
  sha256sum "$KO"
  pass "check finished - no phone load done"
}

case "${1:-}" in
  deps) st_deps ;;
  toolchain) st_toolchain ;;
  source) st_source ;;
  config) st_config ;;
  kernel) st_kernel ;;
  driver) st_driver ;;
  check) st_check ;;
  *) echo "usage: $0 deps|toolchain|source|config|kernel|driver|check"; exit 1 ;;
esac
