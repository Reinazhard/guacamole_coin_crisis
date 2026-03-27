#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
# Optimized cross-compiler build script
# For Google Pixel 6 series
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
#  ARCHITECTURE TUNING
#  Primary tune target is specified per-architecture
# ─────────────────────────────────────────────────────────────────

# ── Colour helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GREEN}${BOLD}[DONE]${RESET}  $*"; }
warn() { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $*"; }
die()  { echo -e "${RED}${BOLD}[FAIL]${RESET}  $*" >&2; exit 1; }

header() {
  local len=${#1}
  local padding=""
  for ((i=0; i<len; i++)); do padding="${padding}="; done
  echo
  echo -e "${YELLOW}${BOLD}====${padding}===="
  echo -e "==  ${1}  =="
  echo -e "====${padding}====${RESET}"
  echo
}

# ── Elapsed-time tracker ──────────────────────────────────────────
START_TIME=$(date +%s)
elapsed() {
  local s=$(( $(date +%s) - START_TIME ))
  printf "%02d:%02d:%02d" $(( s/3600 )) $(( s%3600/60 )) $(( s%60 ))
}

# ── Banner ────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      Bleeding-Edge GCC — Optimized Cross-Compiler       ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Argument parsing ──────────────────────────────────────────────
ENABLE_PGO=false

# Consistent deterministic versions for reproducibility and caching
BINUTILS_VER="2.46.0"
GCC_VER="15.2.0"
GLIBC_VER="2.43"
LINUX_VER="6.19"
GMP_VER="6.3.0"
MPFR_VER="4.2.2"
MPC_VER="1.4.0"
ISL_VER="0.26"

usage() {
  echo "Usage: $0 -a <arch> [-p]"
  echo "  -a  Target arch: arm | arm64 | x86"
  echo "  -p  Enable PGO (Profile-Guided Optimisation) for the compiler itself"
  exit 1
}

while getopts "a:p" flag; do
  case "${flag}" in
    a) arch="${OPTARG}" ;;
    p) ENABLE_PGO=true ;;
    *) usage ;;
  esac
done

[[ -z "${arch:-}" ]] && usage

# ── Target resolution ─────────────────────────────────────────────
case "${arch}" in
  "arm")
    TARGET="arm-linux-gnueabihf"
    KERNEL_ARCH="arm"
    EXTRA_GCC_FLAGS="--with-fpu=neon-fp-armv8 --with-float=hard"
    TARGET_ARCH="armv8.2-a"
    TARGET_TUNE="cortex-a55"
    ;;
  "arm64")
    TARGET="aarch64-linux-gnu"
    KERNEL_ARCH="arm64"
    EXTRA_GCC_FLAGS="--with-abi=lp64 --enable-fix-cortex-a53-835769 --enable-fix-cortex-a53-843419"
    TARGET_ARCH="armv8.2-a+crypto+dotprod+fp16+rcpc+ssbs+sb"
    TARGET_TUNE="cortex-a76.cortex-a55"
    ;;
  "x86")
    TARGET="x86_64-linux-gnu"
    KERNEL_ARCH="x86"
    EXTRA_GCC_FLAGS=""
    TARGET_ARCH="x86-64-v3"
    TARGET_TUNE="skylake"
    ;;
  *)
    die "Unknown arch '${arch}'. Valid: arm | arm64 | x86"
    ;;
esac

# ── Paths ─────────────────────────────────────────────────────────
export WORK_DIR="$PWD"
export PREFIX="$WORK_DIR/gcc-${arch}"
export SYSROOT="$PREFIX/$TARGET/sysroot"
export PATH="$PREFIX/bin:/usr/bin/core_perl:$PATH"

# ── Parallelism ───────────────────────────────────────────────────
JOBS=$(nproc --all)
export MAKEFLAGS="-j${JOBS}"
log "Detected ${JOBS} logical CPUs → using ${JOBS} parallel jobs"

# ── Host compiler optimisation flags ─────────────────────────────
HOST_OPT_FLAGS=(
  "-g0"
  "-O3"
  "-march=native"
  "-mtune=native"
  "-pipe"
  "-fomit-frame-pointer"
  "-fstack-protector-strong"
  "-ffunction-sections"
  "-fdata-sections"
  "-flto=auto"
  "-ffat-lto-objects"
  "-flto-compression-level=6"
  "-fuse-linker-plugin"
)
OPT_FLAGS="${HOST_OPT_FLAGS[*]}"
export OPT_FLAGS

# ─────────────────────────────────────────────────────────────────
log "Work dir : ${WORK_DIR}"
log "Prefix   : ${PREFIX}"
log "Sysroot  : ${SYSROOT}"
log "Target   : ${TARGET}"
log "Arch     : ${TARGET_ARCH}  tune=${TARGET_TUNE}"
log "PGO      : ${ENABLE_PGO}"
echo ""

# ── Dependency check ──────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in gcc g++ make bison flex makeinfo gawk curl tar xz; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing host tools: ${missing[*]}\nInstall with: sudo apt install ${missing[*]}"
  fi
}

# ── Fetch helper ──────────────────────────────────────────────────
fetch() {
  local url="$1"
  local file="${url##*/}"
  if [[ ! -f "sources/$file" ]]; then
    log "Downloading $file..."
    curl -L --retry 3 -o "sources/$file" "$url"
  else
    ok "Cached $file"
  fi
}

# ── Download and extract ──────────────────────────────────────────
download_resources() {
  if [[ -f "${WORK_DIR}/.stamp_downloaded" ]]; then
    return 0
  fi
  header "DOWNLOADING AND EXTRACTING RESOURCES"
  mkdir -p sources
  fetch "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
  fetch "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
  fetch "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz"
  fetch "https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VER%%.*}.x/linux-${LINUX_VER}.tar.xz"

  # GCC dependencies
  fetch "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz"
  fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz"
  fetch "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.xz"
  fetch "https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz"

  for pkg in binutils-${BINUTILS_VER} gcc-${GCC_VER} glibc-${GLIBC_VER} linux-${LINUX_VER}; do
    if [[ ! -d "$pkg" ]]; then
      log "Extracting $pkg..."
      tar xf "sources/${pkg}.tar."*
    fi
  done

  # Extract GCC prerequisites (GMP, MPFR, MPC, ISL) in root for native integration
  for dep in gmp mpfr mpc isl; do
    local dep_ver_var="${dep^^}_VER"
    local dep_ver="${!dep_ver_var}"
    if [[ ! -d "${dep}-${dep_ver}" ]]; then
      log "Extracting native dep: $dep..."
      tar xf "sources/${dep}-${dep_ver}.tar."*
    fi
  done

  # Integrate dependencies natively into GCC
  cd "gcc-${GCC_VER}"
  for dep in gmp mpfr mpc isl; do
    local dep_ver_var="${dep^^}_VER"
    local dep_ver="${!dep_ver_var}"
    [[ ! -L "$dep" ]] && ln -s -f "../${dep}-${dep_ver}" "$dep"
  done
  cd "${WORK_DIR}"

  # Integrate dependencies natively into Binutils
  cd "binutils-${BINUTILS_VER}"
  for dep in gmp mpfr mpc isl; do
    local dep_ver_var="${dep^^}_VER"
    local dep_ver="${!dep_ver_var}"
    [[ ! -L "$dep" ]] && ln -s -f "../${dep}-${dep_ver}" "$dep"
  done
  cd "${WORK_DIR}"
  
  touch "${WORK_DIR}/.stamp_downloaded"
  ok "All sources natively linked and ready"
}

# ── Binutils ──────────────────────────────────────────────────────
build_binutils() {
  if [[ -f "${WORK_DIR}/.stamp_binutils" ]]; then
    ok "Binutils already built [cached]"
    return 0
  fi
  header "BUILDING BINUTILS"
  cd "${WORK_DIR}"
  log "Configuring binutils..."
  mkdir -p build-binutils && cd build-binutils

  ../binutils-${BINUTILS_VER}/configure \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-sysroot="$SYSROOT" \
      --with-arch="${TARGET_ARCH}" \
      --with-tune="${TARGET_TUNE}" \
      --enable-static \
      --disable-shared \
      --enable-gold \
      --enable-plugins \
      --enable-relro \
      --enable-threads \
      --enable-lto \
      --enable-deterministic-archives \
      --disable-docs \
      --disable-gdb \
      --disable-gprof \
      --disable-gprofng \
      --disable-gdbserver \
      --disable-libdecnumber \
      --disable-readline \
      --disable-nls \
      --disable-sim \
      --disable-werror \
      CFLAGS="$OPT_FLAGS" \
      CXXFLAGS="$OPT_FLAGS" \
      LDFLAGS="-static" \
      2>&1 | tee "${WORK_DIR}/configure-binutils.log"

  log "Building binutils..."
  make
  make install
  touch "${WORK_DIR}/.stamp_binutils"
  cd "${WORK_DIR}"
  ok "Binutils built and installed  [$(elapsed)]"
}

# ── Linux Headers ─────────────────────────────────────────────────
build_linux_headers() {
  if [[ -f "${WORK_DIR}/.stamp_linux_headers" ]]; then
    ok "Linux headers already installed [cached]"
    return 0
  fi
  header "MAKING LINUX HEADERS"
  cd "${WORK_DIR}/linux-${LINUX_VER}"
  log "Installing Linux headers..."
  make ARCH="${KERNEL_ARCH}" INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install
  touch "${WORK_DIR}/.stamp_linux_headers"
  cd "${WORK_DIR}"
  ok "Linux headers installed  [$(elapsed)]"
}

# ── GCC Pass 1 (Initial / Core) ───────────────────────────────────
_configure_gcc_pass1() {
  local build_dir="$1"
  local extra_opts="${2:-}"

  cd "${WORK_DIR}"
  mkdir -p "${build_dir}" && cd "${build_dir}"

  ../gcc-${GCC_VER}/configure \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-sysroot="$SYSROOT" \
      --with-build-sysroot="$SYSROOT" \
      --with-native-system-header-dir="/usr/include" \
      --with-arch="${TARGET_ARCH}" \
      --with-tune="${TARGET_TUNE}" \
      --with-pkgversion="Bleeding-Edge GCC" \
      ${EXTRA_GCC_FLAGS} \
      --with-glibc-version="${GLIBC_VER}" \
      --enable-languages=c,c++ \
      --without-headers \
      --with-newlib \
      --disable-shared \
      --disable-threads \
      --disable-libatomic \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libssp \
      --disable-libvtv \
      --disable-libstdcxx \
      --disable-decimal-float \
      --disable-docs \
      --disable-gcov \
      --disable-libffi \
      --disable-libmudflap \
      --disable-libsanitizer \
      --disable-multilib \
      --disable-nls \
      --disable-werror \
      CFLAGS="${OPT_FLAGS}" \
      CXXFLAGS="${OPT_FLAGS}" \
      CFLAGS_FOR_TARGET="-O2 -g " \
      CXXFLAGS_FOR_TARGET="-O2 -g " \
      LDFLAGS="-static" \
      ${extra_opts} \
      2>&1 | tee "${WORK_DIR}/configure-gcc-pass1.log"
}

build_gcc_pass1() {
  if [[ -f "${WORK_DIR}/.stamp_gcc_pass1" ]]; then
    ok "GCC Pass 1 already built [cached]"
    return 0
  fi
  header "BUILDING GCC PASS 1 (CORE BOOTSTRAP)"
  _configure_gcc_pass1 "build-gcc-pass1"

  make all-gcc
  make install-gcc

  make all-target-libgcc
  make install-target-libgcc

  touch "${WORK_DIR}/.stamp_gcc_pass1"
  cd "${WORK_DIR}"
  ok "GCC Pass 1 built and installed  [$(elapsed)]"
}

# ── Glibc ─────────────────────────────────────────────────────────
build_glibc() {
  if [[ -f "${WORK_DIR}/.stamp_glibc" ]]; then
    ok "Glibc already built [cached]"
    return 0
  fi
  header "BUILDING GLIBC"
  cd "${WORK_DIR}"
  log "Configuring glibc..."
  mkdir -p build-glibc && cd build-glibc

  ../glibc-${GLIBC_VER}/configure \
      --host="$TARGET" \
      --build="$MACHTYPE" \
      --prefix="/usr" \
      --with-headers="${SYSROOT}/usr/include" \
      --disable-multilib \
      --disable-werror \
      libc_cv_forced_unwind=yes \
      with_selinux=no \
      CC="${TARGET}-gcc" \
      CXX="${TARGET}-g++" \
      CFLAGS="-g0 -O3 -fstack-protector-strong -ffunction-sections -fdata-sections" \
      CXXFLAGS="-g0 -O3 -fstack-protector-strong -ffunction-sections -fdata-sections" \
      2>&1 | tee "${WORK_DIR}/configure-glibc.log"

  log "Building glibc bootstrap headers & dummy libc..."
  mkdir -p elf
  make install-bootstrap-headers=yes install-headers
  make csu/subdir_lib

  mkdir -p "${SYSROOT}/usr/lib" "${SYSROOT}/usr/include/gnu"
  install csu/crt1.o csu/crti.o csu/crtn.o "${SYSROOT}/usr/lib"
  ${TARGET}-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o "${SYSROOT}/usr/lib/libc.so"
  touch "${SYSROOT}/usr/include/gnu/stubs.h"

  log "Building glibc final..."
  make
  make install_root="${SYSROOT}" install

  touch "${WORK_DIR}/.stamp_glibc"
  cd "${WORK_DIR}"
  ok "Glibc built and installed  [$(elapsed)]"
}

# ── GCC Pass 2 (Final) ────────────────────────────────────────────
_configure_gcc_pass2() {
  local build_dir="$1"
  local extra_cflags="${2:-}"

  cd "${WORK_DIR}"
  mkdir -p "${build_dir}" && cd "${build_dir}"

  ../gcc-${GCC_VER}/configure \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-sysroot="$SYSROOT" \
      --with-build-sysroot="$SYSROOT" \
      --with-native-system-header-dir="/usr/include" \
      --with-arch="${TARGET_ARCH}" \
      --with-tune="${TARGET_TUNE}" \
      --with-pkgversion="Bleeding-Edge GCC" \
      ${EXTRA_GCC_FLAGS} \
      --with-glibc-version="${GLIBC_VER}" \
      --enable-languages=c,c++ \
      --enable-threads=posix \
      --enable-default-ssp \
      --enable-default-pie \
      --enable-linker-build-id \
      --enable-lto \
      --enable-plugins \
      --enable-shared \
      --enable-__cxa_atexit \
      --with-gnu-as \
      --with-gnu-ld \
      --with-linker-hash-style=gnu \
      --disable-decimal-float \
      --disable-docs \
      --disable-gcov \
      --disable-libffi \
      --disable-libmudflap \
      --disable-libsanitizer \
      --disable-libstdcxx-pch \
      --disable-multilib \
      --disable-nls \
      --disable-werror \
      CFLAGS="${OPT_FLAGS} ${extra_cflags}" \
      CXXFLAGS="${OPT_FLAGS} ${extra_cflags}" \
      CFLAGS_FOR_TARGET="-g0 -O3 -fstack-protector-strong" \
      CXXFLAGS_FOR_TARGET="-g0 -O3 -fstack-protector-strong" \
      LDFLAGS="-static" \
      2>&1 | tee "${WORK_DIR}/configure-gcc-pass2.log"
}

build_gcc_pass2() {
  if [[ -f "${WORK_DIR}/.stamp_gcc_pass2" ]]; then
    ok "GCC Pass 2 already built [cached]"
    return 0
  fi
  if $ENABLE_PGO; then
    _build_gcc_pgo
  else
    _build_gcc_standard_pass2
  fi
  touch "${WORK_DIR}/.stamp_gcc_pass2"
}

_build_gcc_standard_pass2() {
  header "BUILDING GCC PASS 2 (FINAL)"
  _configure_gcc_pass2 "build-gcc-pass2"

  make all
  make install

  cd "${WORK_DIR}"
  ok "GCC Pass 2 built and installed  [$(elapsed)]"
}

# ── PGO bootstrap ─────────────────────────────────────────────────
_build_gcc_pgo() {
  header "PGO BOOTSTRAP - STAGE 1: INSTRUMENTED BUILD"
  local STAGE1_PREFIX="${WORK_DIR}/gcc-pgo-stage1"

  _configure_gcc_pass2 "build-gcc-pgo1" "-fprofile-generate=${WORK_DIR}/pgo-profiles"

  sed -i "s|^prefix =.*|prefix = ${STAGE1_PREFIX}|g" Makefile

  make all-gcc > "${WORK_DIR}/build-gcc-pgo1.log"
  make install-gcc
  ok "Stage 1 done  [$(elapsed)]"

  header "PGO BOOTSTRAP - STAGE 2: TRAINING RUN"
  mkdir -p "${WORK_DIR}/pgo-profiles"
  make -C "${WORK_DIR}/build-gcc-pgo1"     CC="${STAGE1_PREFIX}/bin/${TARGET}-gcc"     CXX="${STAGE1_PREFIX}/bin/${TARGET}-g++"     all-gcc > "${WORK_DIR}/build-gcc-pgo-train.log" 2>&1 || true
  ok "Training run complete  [$(elapsed)]"

  header "PGO BOOTSTRAP - STAGE 3: FINAL OPTIMISED BUILD"
  _configure_gcc_pass2 "build-gcc-pgo3" "-fprofile-use=${WORK_DIR}/pgo-profiles -fprofile-correction"

  make all > "${WORK_DIR}/build-gcc-pgo3.log"
  make install
  cd "${WORK_DIR}"
  ok "PGO GCC built and installed  [$(elapsed)]"
}

# ── Summary ───────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                     Build Summary                       ║${RESET}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${RESET}"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "Target triple:"  "$TARGET"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "Architecture:"   "$TARGET_ARCH"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "Tune for:"       "$TARGET_TUNE "
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "Extra Flags:"            "${EXTRA_GCC_FLAGS}"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "PGO:"            "$ENABLE_PGO"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "Installed to:"   "$PREFIX"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "Sysroot:"        "$SYSROOT"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}
" "Total time:"     "$(elapsed)"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  log "Add the toolchain to your PATH:"
  echo "    export PATH="${PREFIX}/bin:\$PATH""
  echo ""
  log "Verify installation:"
  echo "    ${PREFIX}/bin/${TARGET}-gcc --version"
  echo "    ${PREFIX}/bin/${TARGET}-gcc -Q --help=target | grep march"
}

# ── Entry point ───────────────────────────────────────────────────
check_deps
download_resources
build_binutils
build_linux_headers
build_gcc_pass1
build_glibc
build_gcc_pass2
print_summary
