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
GCC_BRANCH="releases/gcc-15"
BINUTILS_BRANCH="binutils-2_46-branch"

GCC_COMMIT="f495ebba36784a13057fd8a2005dd314fe3ca47d"
BINUTILS_COMMIT="915e4288408594416fb032df4c8dc768f52d5280"
# For shallow cloning
SHALLOW_SINCE="2026-03-30"

GLIBC_VER="2.43"
LINUX_VER="6.19"
GMP_VER="6.3.0"
MPFR_VER="4.2.2"
MPC_VER="1.4.0"
ISL_VER="0.26"

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
BUILD_CFLAGS="-O3 -pipe -march=x86-64-v3 -fomit-frame-pointer"
BUILD_CXXFLAGS="-O3 -pipe -march=x86-64-v3 -fomit-frame-pointer"

HOST_CFLAGS="-O3 -pipe -march=x86-64-v3 -fno-semantic-interposition -flto=auto -fno-fat-lto-objects -fipa-pta -fomit-frame-pointer"
HOST_CXXFLAGS="-O3 -pipe -march=x86-64-v3 -fno-semantic-interposition -flto=auto -fno-fat-lto-objects -fipa-pta -fomit-frame-pointer"
HOST_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--sort-common -fuse-ld=mold -flto=auto"

TARGET_CFLAGS="-O3 -pipe -fgraphite-identity -floop-nest-optimize -fno-semantic-interposition -fipa-pta -fstack-protector-strong -ffunction-sections -fdata-sections -fomit-frame-pointer"
TARGET_CXXFLAGS="-O3 -pipe -fgraphite-identity -floop-nest-optimize -fno-semantic-interposition -fipa-pta -fstack-protector-strong -ffunction-sections -fdata-sections -fomit-frame-pointer"
TARGET_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--sort-common"

# ─────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────
ENABLE_PGO=false

usage() {
  echo "Usage: $0 -a <arch> [-p] [stage...]"
  echo "  -a  Target architecture: arm64 | arm"
  echo "  -p  Enable PGO (Profile-Guided Optimisation) for the compiler host binary"
  echo "  stage... Optional specific stages to run (e.g., build_binutils)"
  exit 1
}

while getopts "a:p" flag; do
  case "${flag}" in
    a) ARCH="${OPTARG}" ;;
    p) ENABLE_PGO=true ;;
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
if [[ "${STAGES[*]}" != "print_summary" ]]; then
  log "Build machine : ${BUILD_TRIPLE}"
  log "Host machine  : ${BUILD_TRIPLE}  (same — standard cross-build)"
  log "Target triple : ${TARGET}"
  log "Prefix        : ${PREFIX}"
  log "Sysroot       : ${SYSROOT}"
  log "Parallel jobs : ${JOBS}"
  log "PGO           : ${ENABLE_PGO}"
  echo
fi

# ─────────────────────────────────────────────────────────────────
# DEPENDENCY CHECK
# ─────────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in gcc g++ make bison flex makeinfo gawk curl tar xz git zstd mold; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || \
    die "Missing host tools: ${missing[*]}\nInstall with: pacman -S ${missing[*]}"
}

# ─────────────────────────────────────────────────────────────────
# FETCH HELPER
# ─────────────────────────────────────────────────────────────────
fetch() {
  local url="$1"
  local file="${url##*/}"
  if [[ ! -f "sources/${file}" ]]; then
    log "Downloading ${file}..."
    curl -fL --retry 5 --retry-delay 3 -o "sources/${file}" "${url}"
  else
    ok "Cached ${file}"
  fi
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
    if [[ -n "${GCC_COMMIT}" ]]; then
      log "Pinning GCC to commit: ${GCC_COMMIT}"
      git clone --shallow-since="${SHALLOW_SINCE}" --branch="${GCC_BRANCH}" https://gnu.googlesource.com/gcc gcc-src
      git -C gcc-src checkout "${GCC_COMMIT}"
    else
      git clone --depth=1 --branch="${GCC_BRANCH}" https://gnu.googlesource.com/gcc gcc-src
    fi
  fi

  if [[ ! -d "binutils-src" ]]; then
    log "Cloning Binutils from ${BINUTILS_BRANCH}..."
    if [[ -n "${BINUTILS_COMMIT}" ]]; then
      log "Pinning Binutils to commit: ${BINUTILS_COMMIT}"
      git clone --shallow-since="${SHALLOW_SINCE}" --branch="${BINUTILS_BRANCH}" https://gnu.googlesource.com/binutils-gdb binutils-src
      git -C binutils-src checkout "${BINUTILS_COMMIT}"
    else
      git clone --depth=1 --branch="${BINUTILS_BRANCH}" https://gnu.googlesource.com/binutils-gdb binutils-src
    fi
  fi

  # Tarball sources
  fetch "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz" &
  fetch "https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VER%%.*}.x/linux-${LINUX_VER}.tar.xz" &
  fetch "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" &
  fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz" &
  fetch "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.xz" &
  fetch "https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz" &
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
      tar xf "sources/${pkg}.tar."* &
    fi
  done
  wait

  # Integrate GCC prerequisites as in-tree symlinks.
  # GCC's configure will prefer these over any system-installed versions,
  # ensuring a fully deterministic and reproducible build.
  log "Linking GCC prerequisites in-tree..."
  for dep_dir in "gmp-${GMP_VER}" "mpfr-${MPFR_VER}" "mpc-${MPC_VER}" "isl-${ISL_VER}"; do
    local dep_name="${dep_dir%%-*}"
    ln -sfn "../${dep_dir}" "gcc-src/${dep_name}"
  done

  # Symlink prerequisites to Binutils
  log "Linking Binutils prerequisites in-tree..."
  for dep_dir in "gmp-${GMP_VER}" "mpfr-${MPFR_VER}" "mpc-${MPC_VER}" "isl-${ISL_VER}"; do
    local dep_name="${dep_dir%%-*}"
    ln -sfn "../${dep_dir}" "binutils-src/${dep_name}"
  done

  touch "${WORK_DIR}/.stamp_downloaded"
  ok "All sources ready  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 1: BINUTILS
#
# Builds the cross-assembler, cross-linker, and binary utilities.
# These run on HOST, operate on TARGET binaries.
#
# Flag notes:
#   --with-arch is acceptable here: it sets the default linker emulation
#   for the BFD linker. Unlike GCC's --with-arch, this does not affect
#   code generation — there is no code generation in the linker.
#
#   The linker (-static-libstdc++ -static-libgcc) creates a highly portable
#   binary relying only on the host's libc, which is usually safe.
#   A fully -static binutils kills dynamic dlopen() support preventing
#   liblto_plugin.so from loading. This is the hybrid compromise.
# ─────────────────────────────────────────────────────────────────
build_binutils() {
  [[ -f "${WORK_DIR}/.stamp_binutils" ]] && { ok "Binutils already built [cached]"; return 0; }

  header "STAGE 1: BINUTILS"
  cd "${WORK_DIR}"
  mkdir -p build-binutils && cd build-binutils

  ../binutils-src/configure \
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
      --enable-deterministic-archives \
      --disable-nls \
      --disable-werror \
      --enable-kernel="${LINUX_VER}" \
      --disable-docs \
      CFLAGS="${HOST_CFLAGS}" \
      CXXFLAGS="${HOST_CXXFLAGS}" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS}" \
      2>&1 | tee "${WORK_DIR}/log-binutils-configure.txt"

  make
  make install

  touch "${WORK_DIR}/.stamp_binutils"
  cd "${WORK_DIR}"
  ok "Binutils done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 2: LINUX KERNEL HEADERS
#
# Installs the kernel UAPI headers into the sysroot.
# These are required by glibc — glibc's syscall wrappers are
# generated from kernel header definitions.
# ─────────────────────────────────────────────────────────────────
build_linux_headers() {
  [[ -f "${WORK_DIR}/.stamp_linux_headers" ]] && { ok "Linux headers already installed [cached]"; return 0; }

  header "STAGE 2: LINUX KERNEL HEADERS"
  cd "${WORK_DIR}/linux-${LINUX_VER}"

  make ARCH="${KERNEL_ARCH}" \
       INSTALL_HDR_PATH="${SYSROOT}/usr" \
       headers_install

  touch "${WORK_DIR}/.stamp_linux_headers"
  cd "${WORK_DIR}"
  ok "Linux headers done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 3: GCC PASS 1 (Bootstrap / C-only)
#
# A minimal C-only compiler sufficient to compile glibc.
# This compiler has no libc (--without-headers, --with-newlib)
# and produces a temporary libgcc_eh stub.
#
# ─────────────────────────────────────────────────────────────────
_configure_gcc() {
  local src_dir="$1"; shift

  "../${src_dir}/configure" \
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
      --enable-kernel="${LINUX_VER}" \
      --disable-docs \
      CFLAGS="${HOST_CFLAGS}" \
      CXXFLAGS="${HOST_CXXFLAGS}" \
      CFLAGS_FOR_TARGET="${TARGET_CFLAGS}" \
      CXXFLAGS_FOR_TARGET="${TARGET_CXXFLAGS}" \
      CFLAGS_FOR_BUILD="${BUILD_CFLAGS}" \
      CXXFLAGS_FOR_BUILD="${BUILD_CXXFLAGS}" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS}" \
      LDFLAGS_FOR_TARGET="${TARGET_LDFLAGS}" \
      "$@" \
      2>&1 | tee "${WORK_DIR}/log-gcc-${2}-configure.txt"
}

build_gcc_pass1() {
  [[ -f "${WORK_DIR}/.stamp_gcc_pass1" ]] && { ok "GCC Pass 1 already built [cached]"; return 0; }

  header "STAGE 3: GCC PASS 1 (BOOTSTRAP C COMPILER)"
  cd "${WORK_DIR}"
  mkdir -p build-gcc-pass1 && cd build-gcc-pass1

  _configure_gcc "gcc-src" "pass1" \
      --without-headers \
      --with-newlib \
      --disable-shared \
      --disable-threads \
      --disable-libatomic \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libvtv \
      --disable-libstdcxx \
      --disable-gcov \
      --disable-libffi

  make all-gcc
  make install-gcc
  make all-target-libgcc
  make install-target-libgcc

  touch "${WORK_DIR}/.stamp_gcc_pass1"
  cd "${WORK_DIR}"
  ok "GCC Pass 1 done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 4: GLIBC
#
# Builds and installs glibc into the sysroot using the pass-1 compiler.
#
# The two-phase install (headers first, then full build) is the
# canonical glibc cross-compilation procedure.
#
# ─────────────────────────────────────────────────────────────────
build_glibc() {
  [[ -f "${WORK_DIR}/.stamp_glibc" ]] && { ok "Glibc already built [cached]"; return 0; }

  header "STAGE 4: GLIBC"
  cd "${WORK_DIR}"
  mkdir -p build-glibc && cd build-glibc

  ../glibc-${GLIBC_VER}/configure \
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
      CXXFLAGS="${TARGET_CXXFLAGS}" \
      2>&1 | tee "${WORK_DIR}/log-glibc-configure.txt"

  # Install headers and minimal bootstrap stubs first.
  # This satisfies the circular dependency: gcc needs glibc headers to
  # build libgcc; glibc needs gcc to build itself.
  mkdir -p "${SYSROOT}/usr/lib" "${SYSROOT}/usr/include/gnu"

  make install_root="${SYSROOT}" install-bootstrap-headers=yes install-headers
  make csu/subdir_lib

  # Install CRT objects and create a dummy libc.so stub.
  # This is enough for the pass-1 libgcc to link against.
  install -m 644 csu/crt1.o csu/crti.o csu/crtn.o "${SYSROOT}/usr/lib/"
  "${TARGET}-gcc" -nostdlib -nostartfiles -shared -x c /dev/null \
      -o "${SYSROOT}/usr/lib/libc.so"
  touch "${SYSROOT}/usr/include/gnu/stubs.h"

  # Full glibc build and install.
  make
  make install_root="${SYSROOT}" install

  touch "${WORK_DIR}/.stamp_glibc"
  cd "${WORK_DIR}"
  ok "Glibc done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# STAGE 5: GCC PASS 2 (Final Compiler)
# ─────────────────────────────────────────────────────────────────
build_gcc_pass2() {
  [[ -f "${WORK_DIR}/.stamp_gcc_pass2" ]] && { ok "GCC Pass 2 already built [cached]"; return 0; }

  if $ENABLE_PGO; then
    _build_gcc_pass2_pgo
  else
    _build_gcc_pass2_standard
  fi

  touch "${WORK_DIR}/.stamp_gcc_pass2"
}

_build_gcc_pass2_standard() {
  header "STAGE 5: GCC PASS 2 (FINAL COMPILER)"
  cd "${WORK_DIR}"
  mkdir -p build-gcc-pass2 && cd build-gcc-pass2

  _configure_gcc "gcc-src" "pass2" \
      --enable-shared \
      --enable-threads=posix \
      --enable-linker-build-id \
      --enable-default-ssp \
      --enable-default-pie \
      --disable-libstdcxx-pch \
      --disable-gcov

  make all
  make install

  cd "${WORK_DIR}"
  ok "GCC Pass 2 done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# GCC PASS 2 (PGO VARIANT)
#
# Uses GCC's built-in profiledbootstrap target, which is the
# canonical, supported way to build a PGO-optimised GCC.
#
# The profiledbootstrap target performs:
#   stage1: build an instrumented GCC
#   stage2: use stage1 to compile GCC itself (training run — the
#           act of compiling GCC is the profiling workload)
#   stage3: rebuild GCC using the collected profiles
#
# This is correct and avoids the fragile manual sed/prefix tricks
# in the previous implementation.
#
# Reference: https://gcc.gnu.org/install/build.html#TOC4
# ─────────────────────────────────────────────────────────────────
_build_gcc_pass2_pgo() {
  header "STAGE 5: GCC PASS 2 (PGO BOOTSTRAP)"
  cd "${WORK_DIR}"
  mkdir -p build-gcc-pgo && cd build-gcc-pgo

  _configure_gcc "gcc-src" "pass2-pgo" \
      --enable-shared \
      --enable-threads=posix \
      --enable-linker-build-id \
      --enable-default-ssp \
      --enable-default-pie \
      --disable-libstdcxx-pch \
      --disable-gcov

  # profiledbootstrap is GCC's own three-stage PGO build.
  # It is self-contained and does not require external intervention.
  make profiledbootstrap
  make install

  cd "${WORK_DIR}"
  ok "GCC PGO Pass 2 done  [$(elapsed)]"
}

# ─────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────
print_summary() {
  local gcc_hash_full=$(git -C gcc-src rev-parse HEAD)
  local gcc_hash_short=$(git -C gcc-src rev-parse --short HEAD)

  local binutils_hash_full=$(git -C binutils-src rev-parse HEAD)
  local binutils_hash_short=$(git -C binutils-src rev-parse --short HEAD)

  echo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗"
  echo -e "║                    Toolchain Summary                     ║"
  echo -e "╠══════════════════════════════════════════════════════════╣${RESET}"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Target triple:"  "${TARGET}"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Installed to:"   "${PREFIX}"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Sysroot:"        "${SYSROOT}"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "GCC branch:"     "${GCC_BRANCH}"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "GCC commit:"     "${gcc_hash_short} (${gcc_hash_full:0:16}...)"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Binutils branch:" "${BINUTILS_BRANCH}"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Binutils commit:" "${binutils_hash_short} (${binutils_hash_full:0:16}...)"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "PGO:"            "${ENABLE_PGO}"
  printf "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Total time:"     "$(elapsed)"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo
  if [[ -x "${PREFIX}/bin/${TARGET}-gcc" ]]; then
    log "Verify the toolchain:"
    "${PREFIX}/bin/${TARGET}-gcc" --version | head -n 1
  fi
  echo
}

# ─────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────
STAGES=("${@:-all}")

if [[ "${STAGES[0]}" == "all" ]]; then
  check_deps
  download_resources
  build_binutils
  build_linux_headers
  build_gcc_pass1
  build_glibc
  build_gcc_pass2
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
