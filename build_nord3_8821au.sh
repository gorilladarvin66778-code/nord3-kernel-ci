#!/usr/bin/env bash
# Nord 3 (vitamin) RTL8821AU build. Stages: deps toolchain source config kernel driver check
set -euo pipefail

WORK="${WORK:-$HOME/nord3-build}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/nord3_running_kernel.config}"
# With .scmversion present, the tree's localversion "-o" is dropped, so LV must carry it.
LV="-android12-9-o"

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

  # kernel/../vendor must exist: oplus code includes ../../../../vendor/oplus/... from drivers/gpu/drm/mediatek/mediatek_v2/
  if [ -d "$SRC/vendor" ] && [ ! -L "$SRC/vendor" ]; then
    fail "kernel repo has a real vendor/ directory; refusing to replace it"
  fi
  rm -f "$SRC/vendor"
  ln -s "$WORK/vendor" "$SRC/vendor"
  [ -f "$SRC/vendor/oplus/kernel/touchpanel/oplus_touchscreen_v2/touchpanel_notify/touchpanel_event_notify.h" ] \
    || fail "vendor/oplus link
