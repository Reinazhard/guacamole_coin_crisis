#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
#
# Copyright (C) 2026 M. "Harumajati" Alfarozi
#
# Cross-compiler build script
# Produces a redistributable GNU cross-toolchain for building Linux kernels.
#
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}${BOLD}[DONE]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $*"; }
die()    { echo -e "${RED}${BOLD}[FAIL]${RESET}  $*" >&2; exit 1; }

# ── Error Handling & Logging ──────────────────────────────────────
DRY_RUN=false
LOG_FILE=""

# Trap signals for clean exit and error reporting
cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ] && [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    echo -e "\n${RED}${BOLD}!!! Build failed. Last 20 lines of ${LOG_FILE}:${RESET}"
    tail -n 20 "${LOG_FILE}"
  fi
  exit $exit_code
}
trap cleanup EXIT ERR INT TERM

safe_cd() {
  if [ ! -d "$1" ]; then
    if $DRY_RUN; then
      log "[DRY-RUN] cd $1"
      return 0
    else
      die "Directory $1 does not exist."
    fi
  fi
  cd "$1"
}

run_log() {
  local stage_name="$1"
  shift
  LOG_FILE="${WORK_DIR}/build-${stage_name}.log"
  
  if $DRY_RUN; then
    log "[DRY-RUN] $*"
    return 0
  fi

  log "Running stage: ${stage_name} (log: build-${stage_name}.log)..."
  "$@" > "${LOG_FILE}" 2>&1
}

header() {
  local title="$1"
  local bar; bar=$(printf '═%.0s' $(seq 1 ${#title}))
  echo
  echo -e "${YELLOW}${BOLD}╔══${bar}══╗"
  echo -e "║  ${title}  ║"
  echo -e "╚══${bar}══╝${RESET}"
  echo
}

# ── Elapsed-time tracker ──────────────────────────────────────────
START_TIME=$(date +%s)
elapsed() {
  local s=$(( $(date +%s) - START_TIME ))
  printf "%02d:%02d:%02d" $(( s/3600 )) $(( s%3600/60 )) $(( s%60 ))
}

# ─────────────────────────────────────────────────────────────────
# VERSION PINS & SOURCE REPOSITORIES
# ─────────────────────────────────────────────────────────────────
# Source version pins from dedicated file for cache invalidation
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.version-pins"

# ─────────────────────────────────────────────────────────────────
# FLAG PHILOSOPHY
#
# BUILD_CFLAGS  — flags for tools that run on the build machine during
#                 the build process (e.g. genscripts, fixincludes).
#
# HOST_CFLAGS   — flags used to compile the cross-compiler itself.
#
# TARGET_CFLAGS — flags used when compiling libraries that run on the
#                 TARGET (libgcc, libstdc++, glibc).
# ─────────────────────────────────────────────────────────────────
# Sanitize environment
unset CFLAGS CXXFLAGS LDFLAGS

# Check for mold linker availability
MOLD_FLAG=""
if command -v mold &>/dev/null; then
  MOLD_FLAG="-fuse-ld=mold"
else
  warn "mold linker not found, falling back to default linker."
fi

BUILD_CFLAGS="-O3 -pipe -march=x86-64-v3 -fomit-frame-pointer"
BUILD_CXXFLAGS="-O3 -pipe -march=x86-64-v3 -fomit-frame-pointer"

HOST_CFLAGS="-O3 -pipe -march=x86-64-v3 -fno-semantic-interposition -flto=auto -fno-fat-lto-objects -fipa-pta -fno-plt -falign-functions=32 -fomit-frame-pointer"
HOST_CXXFLAGS="-O3 -pipe -march=x86-64-v3 -fno-semantic-interposition -flto=auto -fno-fat-lto-objects -fipa-pta -fno-plt -falign-functions=32 -fomit-frame-pointer"
HOST_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--sort-common -Wl,-z,relro -Wl,-z,now ${MOLD_FLAG} -flto=auto"

TARGET_CFLAGS="-O3 -pipe -fgraphite-identity -floop-nest-optimize -fno-semantic-interposition -fipa-pta -fstack-protector-strong -fstack-clash-protection -Wp,-D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections -fomit-frame-pointer"
TARGET_CXXFLAGS="-O3 -pipe -fgraphite-identity -floop-nest-optimize -fno-semantic-interposition -fipa-pta -fstack-protector-strong -fstack-clash-protection -Wp,-D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections -fomit-frame-pointer"
TARGET_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--sort-common -Wl,--enable-new-dtags"

# ─────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────
ENABLE_PGO=true

usage() {
  echo "Usage: $0 -a <arch> [-n] [-d] [stage...]"
  echo "  -a  Target architecture: arm64 | arm"
  echo "  -n  Disable PGO (Profile-Guided Optimisation) — build without training"
  echo "  -d  Dry-run mode (print commands instead of executing them)"
  echo "  stage... Optional specific stages to run (e.g., build_binutils)"
  exit 1
}

while getopts "a:nd" flag; do
  case "${flag}" in
    a) ARCH="${OPTARG}" ;;
    n) ENABLE_PGO=false ;;
    d) DRY_RUN=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

[[ -z "${ARCH:-}" ]] && usage

# ─────────────────────────────────────────────────────────────────
# TARGET RESOLUTION
#
# This block sets only:
#   TARGET       — the GNU target triple for this compiler
#   KERNEL_ARCH  — the Linux kernel ARCH= value
#   EXTRA_GCC_FLAGS — configure flags that describe the ABI and
#                     correct known silicon errata. These are
#                     compiler-identity flags, not tuning flags.
#
# ─────────────────────────────────────────────────────────────────
case "${ARCH}" in
  "arm64")
    # Canonical GNU triple for 64-bit ARM Linux cross-compiler.
    # "none" vendor field is the GNU/ARM standard for bare cross-toolchains.
    TARGET="aarch64-linux-gnu"
    KERNEL_ARCH="arm64"

    # ABI flag: lp64 is the only valid 64-bit ABI for aarch64-linux. This
    # is a compiler identity declaration, not a tuning flag — it affects
    # the psABI used for calling conventions and structure layout.
    #
    # Errata flags: these enable linker workarounds for two widely-deployed
    # Cortex-A53 hardware bugs. They cost nothing in performance and are
    # correctness fixes, not optimisation. See:
    #   835769: incorrect result from certain multiply-accumulate instructions
    #   843419: ADRP instruction may produce wrong result in rare sequences
    EXTRA_GCC_FLAGS=(
      "--with-abi=lp64"
      "--enable-fix-cortex-a53-835769"
      "--enable-fix-cortex-a53-843419"
    )
    ;;
  "arm")
    # Hard-float ARMv7-A cross-compiler.
    # gnueabihf = GNU EABI, hard-float — this is an ABI declaration,
    # not a tuning flag. It sets the calling convention for floating-point.
    TARGET="arm-linux-gnueabihf"
    KERNEL_ARCH="arm"

    # --with-float=hard and --with-fpu are ABI declarations here:
    # they tell GCC which ABI the sysroot was built against so it
    # can link correctly. The specific FPU model is NOT specified
    # (which would be tuning); we only declare the ABI class.
    EXTRA_GCC_FLAGS=(
      "--with-float=hard"
      "--with-fpu=vfpv3-d16"
    )
    ;;
  *)
    die "Unknown arch '${ARCH}'. Valid: arm64 | arm"
    ;;
esac

# ── Paths ─────────────────────────────────────────────────────────
export WORK_DIR="$PWD"
export PREFIX="${WORK_DIR}/gcc-${ARCH}"
export SYSROOT="${PREFIX}/${TARGET}/sysroot"
export PATH="${PREFIX}/bin:/usr/bin/core_perl:${PATH}"

# ── Build machine triple & Parallelism ─────────────────────────────────
BUILD_TRIPLE="$(cc -dumpmachine)"
JOBS=$(nproc --all)
export MAKEFLAGS="-j${JOBS}"

# ─────────────────────────────────────────────────────────────────
# STAGES is parsed at the end of the script; define a helper to check
# if we should print startup info (i.e., not when only running print_summary).
_should_print_startup_info() {
  # Called from entry point after STAGES is set
  [[ "${STAGES[*]}" != "print_summary" ]]
}

# Startup info is printed from the entry point after STAGES is defined.
_print_startup_info() {
  log "Build machine : ${BUILD_TRIPLE}"
  log "Host machine  : ${BUILD_TRIPLE}  (same — standard cross-build)"
  log "Target triple : ${TARGET}"
  log "Prefix        : ${PREFIX}"
  log "Sysroot       : ${SYSROOT}"
  log "Parallel jobs : ${JOBS}"
  log "PGO           : ${ENABLE_PGO}"
  echo
}

# ─────────────────────────────────────────────────────────────────
# DEPENDENCY CHECK
# ─────────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in gcc g++ make bison flex makeinfo gawk curl tar xz git zstd mold cmake; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  
  if (( ${#missing[@]} > 0 )); then
    warn "Missing host tools: ${missing[*]}"
    if ! $DRY_RUN; then
      die "Install missing tools with: pacman -S ${missing[*]}"
    else
      warn "[DRY-RUN] Proceeding anyway..."
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────
# FETCH & VERIFY HELPERS
# ─────────────────────────────────────────────────────────────────
verify_checksum() {
  local file="sources/$1"
  local expected_sha256="$2"

  if [[ -z "${expected_sha256:-}" ]]; then
    warn "No SHA256 defined for $1. Skipping verification."
    return 0
  fi

  if [[ "${SKIP_CHECKSUM:-false}" == "true" ]]; then
    log "Skipping checksum verification for $1 (SKIP_CHECKSUM=true)"
    return 0
  fi

  log "Verifying checksum for $1..."
  echo "${expected_sha256}  ${file}" | sha256sum --check --status || \
    die "Checksum verification failed for ${file}!"
  ok "Checksum for $1 matches."
}

fetch() {
  local url="$1"
  local file="${url##*/}"
  local expected_sha256="${2:-}"

  if [[ ! -f "sources/${file}" ]]; then
    log "Downloading ${file}..."
    if ! $DRY_RUN; then
      curl -fL --retry 5 --retry-delay 3 -o "sources/${file}.tmp" "${url}"
      mv "sources/${file}.tmp" "sources/${file}"
    else
      log "[DRY-RUN] curl -fL ... -o sources/${file}.tmp ${url} && mv sources/${file}.tmp sources/${file}"
    fi
  else
    ok "Cached ${file}"
  fi

  verify_checksum "${file}" "${expected_sha256}"
}

# ─────────────────────────────────────────────────────────────────
# DOWNLOAD & EXTRACT
# ─────────────────────────────────────────────────────────────────
download_resources() {
  [[ -f "${WORK_DIR}/.stamp_downloaded" ]] && return 0

  header "DOWNLOADING & CLONING SOURCES"
  mkdir -p sources

  # Git Sources
  if [[ ! -d "gcc-src" ]]; then
    log "Cloning GCC from ${GCC_BRANCH}..."
    if $DRY_RUN; then
      log "[DRY-RUN] git clone --branch=${GCC_BRANCH} ..."
    elif [[ -n "${GCC_COMMIT}" ]]; then
      log "Pinning GCC to commit: ${GCC_COMMIT}"
      git clone --shallow-since="${SHALLOW_SINCE}" --branch="${GCC_BRANCH}" https://gnu.googlesource.com/gcc gcc-src
      git -C gcc-src checkout "${GCC_COMMIT}"
    else
      git clone --depth=1 --branch="${GCC_BRANCH}" https://gnu.googlesource.com/gcc gcc-src
    fi
  fi

  if [[ ! -d "binutils-src" ]]; then
    log "Cloning Binutils from ${BINUTILS_BRANCH}..."
    if $DRY_RUN; then
      log "[DRY-RUN] git clone --branch=${BINUTILS_BRANCH} ..."
    elif [[ -n "${BINUTILS_COMMIT}" ]]; then
      log "Pinning Binutils to commit: ${BINUTILS_COMMIT}"
      git clone --shallow-since="${SHALLOW_SINCE}" --branch="${BINUTILS_BRANCH}" https://gnu.googlesource.com/binutils-gdb binutils-src
      git -C binutils-src checkout "${BINUTILS_COMMIT}"
    else
      git clone --depth=1 --branch="${BINUTILS_BRANCH}" https://gnu.googlesource.com/binutils-gdb binutils-src
    fi
  fi

  # Tarball sources
  fetch "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz" "${GLIBC_SHA256:-}" &
  fetch "https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VER%%.*}.x/linux-${LINUX_VER}.tar.xz" "${LINUX_SHA256:-}" &
  fetch "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" "${GMP_SHA256:-}" &
  fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz" "${MPFR_SHA256:-}" &
  fetch "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.xz" "${MPC_SHA256:-}" &
  fetch "https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz" "${ISL_SHA256:-}" &
  wait

  header "EXTRACTING SOURCES"

  for pkg in \
    "glibc-${GLIBC_VER}" \
    "linux-${LINUX_VER}" \
    "gmp-${GMP_VER}" \
    "mpfr-${MPFR_VER}" \
    "mpc-${MPC_VER}" \
    "isl-${ISL_VER}"
  do
    if [[ ! -d "${pkg}" ]]; then
      log "Extracting ${pkg}..."
      if $DRY_RUN; then
        log "[DRY-RUN] tar xf sources/${pkg}.tar.*"
      else
        tar xf "sources/${pkg}.tar."* &
      fi
    fi
  done
  wait

  # Integrate prerequisites as in-tree symlinks for both GCC and Binutils.
  if ! $DRY_RUN; then
    log "Linking prerequisites in-tree..."
    for dep_dir in "gmp-${GMP_VER}" "mpfr-${MPFR_VER}" "mpc-${MPC_VER}" "isl-${ISL_VER}"; do
      dep_name="${dep_dir%%-*}"
      ln -sfn "../${dep_dir}" "gcc-src/${dep_name}"
      ln -sfn "../${dep_dir}" "binutils-src/${dep_name}"
    done
    touch "${WORK_DIR}/.stamp_downloaded"
  fi
  ok "All sources ready  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 1: BINUTILS
# ─────────────────────────────────────────────────────────────────
build_binutils() {
  [[ -f "${WORK_DIR}/.stamp_binutils" ]] && { ok "Binutils already built [cached]"; return 0; }

  header "STAGE 1: BINUTILS"
  safe_cd "${WORK_DIR}"
  mkdir -p build-binutils && safe_cd build-binutils

  run_log "binutils-configure" ../binutils-src/configure \
      --target="${TARGET}" \
      --prefix="${PREFIX}" \
      --with-sysroot="${SYSROOT}" \
      --build="${BUILD_TRIPLE}" \
      --host="${BUILD_TRIPLE}" \
      --enable-static \
      --disable-shared \
      --enable-plugins \
      --enable-relro \
      --enable-threads \
      --enable-lto \
      --with-zstd \
      --with-system-zlib \
      --enable-deterministic-archives \
      --disable-nls \
      --disable-werror \
      --disable-gprofng \
      --disable-docs \
      CFLAGS="${HOST_CFLAGS}" \
      CXXFLAGS="${HOST_CXXFLAGS}" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS}"

  run_log "binutils-make" make
  run_log "binutils-install" make install

  if ! $DRY_RUN; then
    touch "${WORK_DIR}/.stamp_binutils"
  fi
  safe_cd "${WORK_DIR}"
  ok "Binutils done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 2: LINUX KERNEL HEADERS
# ─────────────────────────────────────────────────────────────────
build_linux_headers() {
  [[ -f "${WORK_DIR}/.stamp_linux_headers" ]] && { ok "Linux headers already installed [cached]"; return 0; }

  header "STAGE 2: LINUX KERNEL HEADERS"
  safe_cd "${WORK_DIR}/linux-${LINUX_VER}"

  run_log "linux-headers" make ARCH="${KERNEL_ARCH}" \
       INSTALL_HDR_PATH="${SYSROOT}/usr" \
       headers_install

  if ! $DRY_RUN; then
    touch "${WORK_DIR}/.stamp_linux_headers"
  fi
  safe_cd "${WORK_DIR}"
  ok "Linux headers done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 3: GCC PASS 1 (Bootstrap / C-only)
# ─────────────────────────────────────────────────────────────────
_configure_gcc() {
  local src_dir="$1"
  local pass_name="$2"
  shift 2

  run_log "gcc-${pass_name}-configure" "../${src_dir}/configure" \
      --target="${TARGET}" \
      --prefix="${PREFIX}" \
      --with-sysroot="${SYSROOT}" \
      --with-build-sysroot="${SYSROOT}" \
      --build="${BUILD_TRIPLE}" \
      --host="${BUILD_TRIPLE}" \
      --with-native-system-header-dir="/usr/include" \
      --with-glibc-version="${GLIBC_VER}" \
      "${EXTRA_GCC_FLAGS[@]}" \
      --enable-languages=c,c++ \
      --enable-checking=release \
      --enable-gnu-indirect-function \
      --enable-__cxa_atexit \
      --enable-plugin \
      --enable-lto \
      --with-zstd \
      --with-system-zlib \
      --with-gnu-as \
      --with-gnu-ld \
      --with-linker-hash-style=gnu \
      --disable-decimal-float \
      --disable-libmudflap \
      --disable-libsanitizer \
      --disable-libssp \
      --disable-libgomp \
      --disable-libitm \
      --disable-vtable-verify \
      --disable-multilib \
      --disable-nls \
      --disable-werror \
      --disable-docs \
      CFLAGS="${HOST_CFLAGS}" \
      CXXFLAGS="${HOST_CXXFLAGS}" \
      CFLAGS_FOR_TARGET="${TARGET_CFLAGS}" \
      CXXFLAGS_FOR_TARGET="${TARGET_CXXFLAGS}" \
      CFLAGS_FOR_BUILD="${BUILD_CFLAGS}" \
      CXXFLAGS_FOR_BUILD="${BUILD_CXXFLAGS}" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS}" \
      LDFLAGS_FOR_TARGET="${TARGET_LDFLAGS}" \
      "$@"
}

build_gcc_pass1() {
  [[ -f "${WORK_DIR}/.stamp_gcc_pass1" ]] && { ok "GCC Pass 1 already built [cached]"; return 0; }

  header "STAGE 3: GCC PASS 1 (BOOTSTRAP C COMPILER)"
  safe_cd "${WORK_DIR}"
  mkdir -p build-gcc-pass1 && safe_cd build-gcc-pass1

  _configure_gcc "gcc-src" "pass1" \
      --without-headers \
      --with-newlib \
      --disable-shared \
      --disable-threads \
      --disable-libatomic \
      --disable-libquadmath \
      --disable-libvtv \
      --disable-libstdcxx \
      --disable-libffi

  run_log "gcc-pass1-make-gcc" make all-gcc
  run_log "gcc-pass1-install-gcc" make install-gcc
  run_log "gcc-pass1-make-libgcc" make all-target-libgcc
  run_log "gcc-pass1-install-libgcc" make install-target-libgcc

  if ! $DRY_RUN; then
    touch "${WORK_DIR}/.stamp_gcc_pass1"
  fi
  safe_cd "${WORK_DIR}"
  ok "GCC Pass 1 done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 4: GLIBC
# ─────────────────────────────────────────────────────────────────
build_glibc() {
  [[ -f "${WORK_DIR}/.stamp_glibc" ]] && { ok "Glibc already built [cached]"; return 0; }

  header "STAGE 4: GLIBC"
  safe_cd "${WORK_DIR}"
  mkdir -p build-glibc && safe_cd build-glibc

  run_log "glibc-configure" ../glibc-${GLIBC_VER}/configure \
      --host="${TARGET}" \
      --build="${BUILD_TRIPLE}" \
      --prefix="/usr" \
      --with-headers="${SYSROOT}/usr/include" \
      --disable-multilib \
      --disable-werror \
      --enable-kernel="${LINUX_VER}" \
      libc_cv_forced_unwind=yes \
      --disable-selinux \
      CC="${TARGET}-gcc" \
      CXX="${TARGET}-g++" \
      CFLAGS="${TARGET_CFLAGS}" \
      CXXFLAGS="${TARGET_CXXFLAGS}"

  # Install headers and minimal bootstrap stubs first.
  if ! $DRY_RUN; then
    mkdir -p "${SYSROOT}/usr/lib" "${SYSROOT}/usr/include/gnu"
    run_log "glibc-install-headers" make install_root="${SYSROOT}" install-bootstrap-headers=yes install-headers
    run_log "glibc-make-csu" make csu/subdir_lib

    install -m 644 csu/crt1.o csu/crti.o csu/crtn.o "${SYSROOT}/usr/lib/"
    "${TARGET}-gcc" -nostdlib -nostartfiles -shared -x c /dev/null \
        -o "${SYSROOT}/usr/lib/libc.so"
    touch "${SYSROOT}/usr/include/gnu/stubs.h"
  fi

  # Full glibc build and install.
  run_log "glibc-make" make
  run_log "glibc-install" make install_root="${SYSROOT}" install

  if ! $DRY_RUN; then
    touch "${WORK_DIR}/.stamp_glibc"
  fi
  safe_cd "${WORK_DIR}"
  ok "Glibc done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 5: GCC PASS 2 (Final Compiler)
# ─────────────────────────────────────────────────────────────────

# Common configure flags for all GCC pass2 variants
GCC_PASS2_FLAGS=(
  --enable-shared
  --enable-threads=posix
  --enable-linker-build-id
  --enable-default-ssp
  --enable-default-pie
  --disable-libstdcxx-pch
)

build_gcc_pass2() {
  [[ -f "${WORK_DIR}/.stamp_gcc_pass2" ]] && { ok "GCC Pass 2 already built [cached]"; return 0; }

  if $ENABLE_PGO; then
    _build_gcc_pass2_pgo
  else
    _build_gcc_pass2_standard
  fi

  if ! $DRY_RUN; then
    touch "${WORK_DIR}/.stamp_gcc_pass2"
  fi
}

_build_gcc_pass2_standard() {
  header "STAGE 5: GCC PASS 2 (FINAL COMPILER)"
  safe_cd "${WORK_DIR}"
  mkdir -p build-gcc-pass2 && safe_cd build-gcc-pass2

  _configure_gcc "gcc-src" "pass2" "${GCC_PASS2_FLAGS[@]}"

  run_log "gcc-pass2-make" make all
  run_log "gcc-pass2-install" make install

  safe_cd "${WORK_DIR}"
  ok "GCC Pass 2 done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# GCC PASS 2 (PGO VARIANT)
# ─────────────────────────────────────────────────────────────────
_build_gcc_pass2_pgo() {
  header "STAGE 5: GCC PASS 2 (KERNEL-OPTIMISED PGO)"

  local PROFILE_DIR="${WORK_DIR}/pgo-profiles"
  local profile_count=0

  # Check for cached profiles
  if [[ -d "${PROFILE_DIR}" ]]; then
    profile_count=$(find "${PROFILE_DIR}" -name "*.gcda" 2>/dev/null | wc -l)
  fi

  if (( profile_count > 0 )); then
    log "Found ${profile_count} cached PGO profiles — skipping training"
    log "To retrain: rm -rf pgo-profiles/"
  else
    if ! $DRY_RUN; then
      mkdir -p "${PROFILE_DIR}"
    fi

    # ── Phase 1: Build instrumented compiler ──────────────────────
    log "Phase 1/3: Building instrumented compiler..."
    safe_cd "${WORK_DIR}"
    [[ -d build-gcc-pgo-instr ]] && rm -rf build-gcc-pgo-instr
    mkdir -p build-gcc-pgo-instr && safe_cd build-gcc-pgo-instr

    _configure_gcc "gcc-src" "pass2-pgo-instr" "${GCC_PASS2_FLAGS[@]}"

    run_log "gcc-pgo-instr-make" make BOOT_CFLAGS="-O2 -g0 -fprofile-generate=${PROFILE_DIR}" \
         BOOT_LDFLAGS="-fprofile-generate=${PROFILE_DIR}" \
         all

    run_log "gcc-pgo-instr-install" make install

    ok "Phase 1 complete: instrumented compiler installed  [$(elapsed)]"

    # ── Phase 2: Training run — compile a kernel ──────────────────
    log "Phase 2/3: Training on kernel compilation..."
    safe_cd "${WORK_DIR}/linux-${LINUX_VER}"

    run_log "pgo-kernel-mrproper" make ARCH="${KERNEL_ARCH}" mrproper
    run_log "pgo-kernel-defconfig" make ARCH="${KERNEL_ARCH}" CROSS_COMPILE="${TARGET}-" defconfig

    log "Compiling kernel for PGO training (this takes a while)..."
    # Allow failure during training as partial profiles are still useful
    run_log "pgo-kernel-make" make ARCH="${KERNEL_ARCH}" CROSS_COMPILE="${TARGET}-" -j${JOBS} all || true

    run_log "pgo-kernel-clean" make ARCH="${KERNEL_ARCH}" mrproper

    ok "Phase 2 complete: profile data collected  [$(elapsed)]"

    # Verify profiles were generated
    profile_count=$(find "${PROFILE_DIR}" -name "*.gcda" 2>/dev/null | wc -l)
    if (( profile_count == 0 )) && ! $DRY_RUN; then
      warn "No profile data found! Falling back to standard build."
      _build_gcc_pass2_standard
      return
    fi
    log "Collected ${profile_count} profile files"
  fi

  # ── Phase 3: Rebuild with collected profiles ──────────────────
  log "Phase 3/3: Rebuilding compiler with profile data..."
  safe_cd "${WORK_DIR}"

  if ! $DRY_RUN; then
    rm -rf "${PREFIX:?}/lib/gcc" "${PREFIX}/libexec" \
           "${PREFIX}/include/c++" "${PREFIX}/share"
    local prefix_bin="${PREFIX}/bin"
    if [[ -d "${prefix_bin}" ]]; then
      find "${prefix_bin}" -type f \( \
        -name "${TARGET}-gcc*" -o \
        -name "${TARGET}-g++*" -o \
        -name "${TARGET}-c++*" -o \
        -name "${TARGET}-cpp*" -o \
        -name "${TARGET}-gcov*" -o \
        -name "${TARGET}-lto*" \
      \) -delete 2>/dev/null || true
    fi
  fi

  [[ -d build-gcc-pgo-final ]] && rm -rf build-gcc-pgo-final
  mkdir -p build-gcc-pgo-final && safe_cd build-gcc-pgo-final

  _configure_gcc "gcc-src" "pass2-pgo-final" "${GCC_PASS2_FLAGS[@]}"

  run_log "gcc-pgo-final-make" make BOOT_CFLAGS="-O2 -g0 -fprofile-use=${PROFILE_DIR} -fprofile-correction -Wno-missing-profile" \
       BOOT_LDFLAGS="-fprofile-use=${PROFILE_DIR}" \
       all

  run_log "gcc-pgo-final-install" make install

  safe_cd "${WORK_DIR}"
  ok "Phase 3 complete: PGO-optimised compiler installed  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 6: MOLD LINKER
# ─────────────────────────────────────────────────────────────────
install_mold() {
  [[ -f "${WORK_DIR}/.stamp_mold" ]] && { ok "Mold already installed [cached]"; return 0; }

  header "STAGE 6: MOLD LINKER"

  # Clone or update mold source
  if [[ ! -d "mold-src" ]]; then
    log "Cloning mold (branch: ${MOLD_BRANCH})..."
    if $DRY_RUN; then
      log "[DRY-RUN] git clone --depth=1 --branch=${MOLD_BRANCH} ..."
    else
      git clone --depth=1 --branch="${MOLD_BRANCH}" \
        https://github.com/rui314/mold.git mold-src
    fi
  fi

  safe_cd "${WORK_DIR}"
  [[ -d build-mold ]] && rm -rf build-mold

  run_log "mold-cmake" cmake -B build-mold -S mold-src \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DMOLD_MOSTLY_STATIC=ON

  run_log "mold-build" cmake --build build-mold -j${JOBS}
  run_log "mold-install" cmake --install build-mold

  # Create symlinks for GCC -fuse-ld=mold lookup
  if ! $DRY_RUN; then
    ln -sfn mold "${PREFIX}/bin/ld.mold"
    ln -sfn ld.mold "${PREFIX}/bin/${TARGET}-ld.mold"
    touch "${WORK_DIR}/.stamp_mold"
  fi

  safe_cd "${WORK_DIR}"
  ok "Mold linker installed  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────
print_summary() {
  local gcc_hash_full; gcc_hash_full=$(git -C gcc-src rev-parse HEAD 2>/dev/null || echo "unknown")
  local gcc_hash_short; gcc_hash_short=$(git -C gcc-src rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local binutils_hash_full; binutils_hash_full=$(git -C binutils-src rev-parse HEAD 2>/dev/null || echo "unknown")
  local binutils_hash_short; binutils_hash_short=$(git -C binutils-src rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local mold_hash_short; mold_hash_short=$(git -C mold-src rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local pgo_status="disabled"
  [[ "${ENABLE_PGO}" == "true" ]] && pgo_status="enabled"

  # Helper to truncate values for narrow box (max 34 chars)
  _fmt() {
    local val="$1"
    if (( ${#val} > 34 )); then
      echo "...${val: -31}"
    else
      echo "$val"
    fi
  }

  echo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗"
  echo -e "║                    Toolchain Summary                     ║"
  echo -e "╠══════════════════════════════════════════════════════════╣${RESET}"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Target triple:"    "$(_fmt "${TARGET}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Installed to:"     "$(_fmt "${PREFIX}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Sysroot:"          "$(_fmt "${SYSROOT}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "GCC branch:"       "$(_fmt "${GCC_BRANCH}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "GCC commit:"       "$(_fmt "${gcc_hash_short} (${gcc_hash_full:0:16}...)")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Binutils branch:"  "$(_fmt "${BINUTILS_BRANCH}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Binutils commit:"  "$(_fmt "${binutils_hash_short} (${binutils_hash_full:0:16}...)")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Glibc version:"    "$(_fmt "${GLIBC_VER}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Linux headers:"    "$(_fmt "${LINUX_VER}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Mold commit:"      "$(_fmt "${mold_hash_short}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "PGO training:"     "$(_fmt "${pgo_status}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Total build time:" "$(_fmt "$(elapsed)")"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo
  log "Verifying installed components..."
  for tool in gcc ld as; do
    local bin="${PREFIX}/bin/${TARGET}-${tool}"
    if [[ -x "${bin}" ]]; then
      log "  ${tool}: $(${bin} --version | head -n1)"
    fi
  done
  if [[ -x "${PREFIX}/bin/mold" ]]; then
    log "  mold: $(${PREFIX}/bin/mold --version | head -n1)"
  fi
  echo
}

# ─────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────
STAGES=("${@:-all}")

# Print startup info now that STAGES is defined
_should_print_startup_info && _print_startup_info

if [[ "${STAGES[0]}" == "all" ]]; then
  check_deps
  download_resources
  build_binutils
  build_linux_headers
  build_gcc_pass1
  build_glibc
  build_gcc_pass2
  install_mold
  print_summary
else
  for stage in "${STAGES[@]}"; do
    if declare -f "$stage" > /dev/null; then
      $stage
    else
      die "Unknown stage: $stage"
    fi
  done
fi
