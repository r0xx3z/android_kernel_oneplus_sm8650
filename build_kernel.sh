#!/usr/bin/env bash
# Build script for android_kernel_oneplus_sm8650
# Target: Snapdragon 8 Gen 3 ("pineapple"), Linux 6.1 GKI, built with Clang/LLVM.
#
# Usage: ./build_kernel.sh [all|deps|fetch|toolchain|config|menuconfig|build|clean]
# Every variable in the "Configuration" block can be overridden from the
# environment, e.g.: JOBS=8 DISABLE_LTO=1 ./build_kernel.sh all

set -Eeuo pipefail
trap 'echo "[x] Failed at line $LINENO" >&2' ERR

# ---------- Configuration ----------
REPO_URL="${REPO_URL:-https://github.com/DroidKitchen/android_kernel_oneplus_sm8650}"
BRANCH="${BRANCH:-17.0}"

WORKDIR="${WORKDIR:-$HOME/sm8650-build}"
SRC_DIR="${SRC_DIR:-$WORKDIR/kernel}"
OUT_DIR="${OUT_DIR:-$WORKDIR/out}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$WORKDIR/artifacts}"

# AOSP Clang used by Android 14 6.1 kernels (clang 17.0.2).
# Point TOOLCHAIN_DIR to your own Clang (>= 15) to skip the download.
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$WORKDIR/clang}"
CLANG_REV="${CLANG_REV:-clang-r487747c}"
CLANG_BRANCH="${CLANG_BRANCH:-android14-release}"

JOBS="${JOBS:-$(nproc --all)}"

# Qualcomm/GKI convention: base GKI defconfig + SoC vendor fragment
BASE_DEFCONFIG="${BASE_DEFCONFIG:-gki_defconfig}"
VENDOR_FRAGMENT="${VENDOR_FRAGMENT:-vendor/pineapple_GKI.config}"

# 1 = turn ThinLTO off (far less RAM, much faster builds, slightly bigger Image)
DISABLE_LTO="${DISABLE_LTO:-0}"
# 1 = keep CONFIG_TRIM_UNUSED_KSYMS (needs the ABI symbol list that Kleaf/Bazel provides)
KEEP_KSYMS_TRIM="${KEEP_KSYMS_TRIM:-0}"
# 1 = git fetch + reset the source tree to the latest remote commit
UPDATE="${UPDATE:-0}"

export ARCH=arm64
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-Llorens}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-MKernel}"

# ---------- Helpers ----------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

kmake() {
    make -C "$SRC_DIR" -j"$JOBS" O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 "$@"
}

use_toolchain() {
    [[ -x "$TOOLCHAIN_DIR/bin/clang" ]] || die "Clang not found in $TOOLCHAIN_DIR (run: $0 toolchain)"
    export PATH="$TOOLCHAIN_DIR/bin:$PATH"
}

# ---------- Steps ----------
check_deps() {
    local missing=() c
    for c in git make curl tar bc bison flex python3 cpio lz4 xz rsync; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if ((${#missing[@]})); then
        warn "Missing tools: ${missing[*]}"
        warn "Debian/Ubuntu: sudo apt install git make curl tar bc bison flex python3 cpio lz4 xz-utils rsync libssl-dev libelf-dev dwarves"
        warn "Arch:          sudo pacman -S git make curl tar bc bison flex python cpio lz4 xz rsync openssl libelf pahole"
        die "Install the missing dependencies and run again"
    fi
    command -v pahole >/dev/null 2>&1 || warn "pahole not found (package: dwarves / pahole); BTF generation may fail"
    log "Dependencies OK"
}

fetch_source() {
    mkdir -p "$WORKDIR"
    if [[ -d "$SRC_DIR/.git" ]]; then
        if [[ "$UPDATE" == "1" ]]; then
            log "Updating source tree"
            git -C "$SRC_DIR" fetch --depth=1 origin "$BRANCH"
            git -C "$SRC_DIR" reset --hard FETCH_HEAD
        else
            log "Source already present in $SRC_DIR (UPDATE=1 to refresh)"
        fi
    else
        log "Cloning $REPO_URL ($BRANCH, shallow; the full history is ~1.2M commits)"
        git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
    fi
    # KernelSU-Next is a git submodule
    git -C "$SRC_DIR" submodule update --init --recursive --depth=1
}

fetch_toolchain() {
    if [[ -x "$TOOLCHAIN_DIR/bin/clang" ]]; then
        log "Toolchain already present: $("$TOOLCHAIN_DIR/bin/clang" --version | head -n1)"
        return
    fi
    local url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/${CLANG_BRANCH}/${CLANG_REV}.tar.gz"
    log "Downloading ${CLANG_REV} from AOSP"
    mkdir -p "$TOOLCHAIN_DIR"
    if ! curl -fL --retry 3 "$url" | tar -xz -C "$TOOLCHAIN_DIR"; then
        rm -rf "$TOOLCHAIN_DIR"
        die "Toolchain download failed. Set TOOLCHAIN_DIR to an existing Clang (>= 15) and retry"
    fi
    log "Toolchain ready: $("$TOOLCHAIN_DIR/bin/clang" --version | head -n1)"
}

configure() {
    use_toolchain
    [[ -d "$SRC_DIR" ]] || die "Source not found (run: $0 fetch)"
    [[ -f "$SRC_DIR/arch/arm64/configs/$BASE_DEFCONFIG" ]] \
        || die "Missing arch/arm64/configs/$BASE_DEFCONFIG"
    [[ -f "$SRC_DIR/arch/arm64/configs/$VENDOR_FRAGMENT" ]] \
        || die "Missing arch/arm64/configs/$VENDOR_FRAGMENT (check: ls $SRC_DIR/arch/arm64/configs/vendor | grep -i pineapple)"

    mkdir -p "$OUT_DIR"
    log "Applying $BASE_DEFCONFIG + $VENDOR_FRAGMENT"
    kmake "$BASE_DEFCONFIG"
    kmake "$VENDOR_FRAGMENT"

    local cfg="$SRC_DIR/scripts/config --file $OUT_DIR/.config"
    if [[ "$KEEP_KSYMS_TRIM" != "1" ]]; then
        # Without the Kleaf ABI symbol list, trimming exports breaks the build / module loading
        $cfg -d TRIM_UNUSED_KSYMS
    fi
    if [[ "$DISABLE_LTO" == "1" ]]; then
        $cfg -d LTO_CLANG_THIN -d LTO_CLANG_FULL -e LTO_NONE
    fi
    kmake olddefconfig
}

build() {
    use_toolchain
    [[ -f "$OUT_DIR/.config" ]] || configure
    log "Building with $JOBS jobs ($(clang --version | head -n1))"

    local t0=$SECONDS
    kmake Image modules
    kmake modules_install INSTALL_MOD_PATH="$OUT_DIR/modules_staging" INSTALL_MOD_STRIP=1

    # DTBs may live in a separate devicetrees repo; do not fail the whole build for that
    kmake dtbs || warn "dtbs target failed or is not provided by this tree"

    collect_artifacts
    log "Done in $((SECONDS - t0))s -> $ARTIFACTS_DIR"
}

collect_artifacts() {
    rm -rf "$ARTIFACTS_DIR"
    mkdir -p "$ARTIFACTS_DIR/dtbs"
    cp "$OUT_DIR/arch/arm64/boot/Image" "$ARTIFACTS_DIR/"
    cp "$OUT_DIR/.config" "$ARTIFACTS_DIR/config"
    [[ -d "$OUT_DIR/modules_staging" ]] && cp -r "$OUT_DIR/modules_staging" "$ARTIFACTS_DIR/modules"
    find "$OUT_DIR/arch/arm64/boot/dts" -name '*.dtb' -exec cp {} "$ARTIFACTS_DIR/dtbs/" \; 2>/dev/null || true
    ls -lh "$ARTIFACTS_DIR/Image"
}

# ---------- Entry point ----------
case "${1:-all}" in
    deps)       check_deps ;;
    fetch)      fetch_source ;;
    toolchain)  fetch_toolchain ;;
    config)     configure ;;
    menuconfig) use_toolchain; kmake menuconfig ;;
    build)      build ;;
    clean)      log "Removing $OUT_DIR"; rm -rf "$OUT_DIR" ;;
    all)        check_deps; fetch_source; fetch_toolchain; configure; build ;;
    *)          die "Unknown step '$1'. Usage: $0 [all|deps|fetch|toolchain|config|menuconfig|build|clean]" ;;
esac
