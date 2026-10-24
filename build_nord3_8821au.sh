#!/usr/bin/env bash
# Nord 3 (vitamin) - build the RTL8821AU out-of-tree module against the EXACT running kernel.
# Runs on the Ubuntu VM. Nothing here touches the phone: no flashing, no adb writes.
# Run ONE stage at a time and check PASS/FAIL before the next:
#   ./build_nord3_8821au.sh deps | toolchain | source | config | kernel | driver | check
set -euo pipefail

WORK="${WORK:-$HOME/nord3-build}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/nord3_running_kernel.config}"   # copy it from phone: /sdcard/nord3_running_kernel.config

EXPECT_REL="5.10.209-android12-9-o-gb0bb096ffb03"
EXPECT_VERMAGIC="$EXPECT_REL SMP preempt mod_unload modversions aarch64"
EXPECT_SHA="b0bb096ffb03"

KREPO="https://github.com/lineageos-on-vitamin/android_kernel_oneplus_mt6983"
KBRANCH="lineage-22.2"
CLANG_REPO="${CLANG_REPO:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
CLANG_BRANCH="${CLANG_BRANCH:-android12-release}"
CLANG_NAME="clang-r416183b"
DRV_REPO="${DRV_REPO:-https://github.com/morrownr/8821au-20210708}"

SRC="$WORK/kernel"; OUT="$WORK/out"; DRV="$WORK/8821au"; DIST="$WORK/dist"
CLANG="$WORK/clang-repo/$CLANG_NAME"
LV="${LV:-$(cat "$WORK/lv" 2>/dev/null || true)}"
mkdir -p "$WORK" "$DIST"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

need_clang() {
  [ -x "$CLANG/bin/clang" ] || fail "toolchain missing - run: $0 toolchain"
  export PATH="$CLANG/bin:$PATH"
}

# Same toolchain/flags family the ROM kernel was built with (clang r416183b, LLD, ThinLTO+CFI+SCS come from .config)
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
  echo "--- resources (ThinLTO kernel build wants ~16GB RAM incl. swap, ~40GB disk, several cores)"
  free -g | head -2; df -h "$WORK" | tail -1; nproc
  pass "deps installed"
}

st_toolchain() {
  cd "$WORK"
  [ -d clang-repo/.git ] || git clone --depth 1 --filter=blob:none --sparse -b "$CLANG_BRANCH" "$CLANG_REPO" clang-repo
  cd clang-repo
  if ! git ls-tree --name-only HEAD | grep -qx "$CLANG_NAME"; then
    echo "Available on branch $CLANG_BRANCH:"; git ls-tree --name-only HEAD | grep '^clang-r' || true
    fail "$CLANG_NAME not on branch $CLANG_BRANCH (try CLANG_BRANCH=<other android12 branch>)"
  fi
  git sparse-checkout set "$CLANG_NAME"
  V="$("$CLANG/bin/clang" --version | head -1)"; echo "$V"
  echo "$V" | grep -q "12.0.5" && echo "$V" | grep -q "r416183b" && pass "toolchain = clang 12.0.5 r416183b" \
    || fail "toolchain version differs from the ROM's (Android clang 12.0.5 r416183b)"
}

st_source() {
  [ -d "$SRC/.git" ] || git clone --depth 1 -b "$KBRANCH" "$KREPO" "$SRC"
  H="$(git -C "$SRC" rev-parse --short=12 HEAD)"
  [ "$H" = "$EXPECT_SHA" ] && pass "kernel source HEAD = $H" || fail "HEAD=$H, expected $EXPECT_SHA"
}

st_config() {
  need_clang
  [ -f "$CONFIG_SRC" ] || fail "copy nord3_running_kernel.config to $CONFIG_SRC (or set CONFIG_SRC=...)"
  mkdir -p "$OUT"; cp "$CONFIG_SRC" "$OUT/.config"
  kmake olddefconfig
  diff <(grep -E '^(CONFIG_|# CONFIG_)' "$CONFIG_SRC" | sort) \
       <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT/.config" | sort) > "$WORK/config.diff" || true
  echo "config drift vs running kernel: $(grep -c '^[<>]' "$WORK/config.diff") lines (see $WORK/config.diff)"
  kmake -j"$(nproc)" modules_prepare
  REL="$(cat "$OUT/include/config/kernel.release")"; echo "kernel.release = $REL"
  if [ "$REL" != "$EXPECT_REL" ]; then
    LV="-${EXPECT_REL#*-}"; LV="${LV%-g*}"      # -> -android12-9-o
    echo "release differs, retrying with LOCALVERSION=$LV"
    echo "$LV" > "$WORK/lv"
    kmake -j"$(nproc)" modules_prepare
    REL="$(cat "$OUT/include/config/kernel.release")"; echo "kernel.release = $REL"
  fi
  [ "$REL" = "$EXPECT_REL" ] && pass "kernel.release matches running kernel" || fail "release mismatch: $REL vs $EXPECT_REL"
}

st_kernel() {
  need_clang
  [ -f "$OUT/.config" ] || fail "run config first"
  echo "Heavy step (1-3h). Progress: tail -f $WORK/kernel-build.log"
  kmake -j"$(nproc)" Image modules > "$WORK/kernel-build.log" 2>&1 || { tail -40 "$WORK/kernel-build.log"; fail "kernel build"; }
  [ -f "$OUT/Module.symvers" ] || fail "Module.symvers not produced"
  REL="$(cat "$OUT/include/config/kernel.release")"
  [ "$REL" = "$EXPECT_REL" ] && pass "built $REL, Module.symvers present ($(wc -l < "$OUT/Module.symvers") symbols)" || fail "release $REL"
  echo "Image size: $(stat -c%s "$OUT/arch/arm64/boot/Image") bytes (stock boot header said 16,790,280 for its kernel blob)"
}

st_driver() {
  need_clang
  [ -f "$OUT/Module.symvers" ] || fail "run kernel first (needs Module.symvers)"
  [ -d "$DRV/.git" ] || git clone --depth 1 "$DRV_REPO" "$DRV"
  # generic little-endian arm64 platform instead of x86 PC
  sed -i 's/^CONFIG_PLATFORM_I386_PC *= *y/CONFIG_PLATFORM_I386_PC = n/; s/^CONFIG_PLATFORM_ARM64_RPI *= *n/CONFIG_PLATFORM_ARM64_RPI = y/' "$DRV/Makefile"
  grep -nE '^CONFIG_PLATFORM_(I386_PC|ARM64_RPI)' "$DRV/Makefile" || true
  kmake -j"$(nproc)" M="$DRV" modules > "$WORK/driver-build.log" 2>&1 || { tail -40 "$WORK/driver-build.log"; fail "driver build"; }
  KO="$(find "$DRV" -name '8821au.ko' | head -1)"; [ -n "$KO" ] || fail "8821au.ko not produced"
  cp "$KO" "$DIST/8821au.ko"; sha256sum "$DIST/8821au.ko"
  pass "built $DIST/8821au.ko"
}

st_check() {
  need_clang
  KO="$DIST/8821au.ko"; [ -f "$KO" ] || fail "run driver first"
  VM="$(modinfo -F vermagic "$KO")"
  echo "module : $VM"; echo "running: $EXPECT_VERMAGIC"
  [ "$VM" = "$EXPECT_VERMAGIC" ] && pass "vermagic matches" || fail "vermagic differs - DO NOT load this module"
  llvm-nm "$KO" 2>/dev/null | grep -q __cfi_check && pass "CFI check function present" || echo "WARN: no __cfi_check in module"
  echo "modversion entries: $(modprobe --dump-modversions "$KO" | wc -l)"
  echo "depends: $(modinfo -F depends "$KO")"
  sha256sum "$KO"
  echo "Next: copy $KO to the phone and test-load (separate step, I will give the commands)."
}

case "${1:-}" in
  deps) st_deps ;; toolchain) st_toolchain ;; source) st_source ;; config) st_config ;;
  kernel) st_kernel ;; driver) st_driver ;; check) st_check ;;
  *) echo "usage: $0 deps|toolchain|source|config|kernel|driver|check"; exit 1 ;;
esac
