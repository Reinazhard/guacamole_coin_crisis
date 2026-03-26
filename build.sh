#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
# Enhanced for Google Tensor G1 (Cortex-X1 / A76 / A55) Android targets
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
#  TENSOR G1 CORE TOPOLOGY
#  2x Cortex-X1  @ 2.80 GHz  — ARMv8.2-A + SVE + DotProd + FP16
#  2x Cortex-A76 @ 2.25 GHz  — ARMv8.2-A
#  4x Cortex-A55 @ 1.80 GHz  — ARMv8.2-A (in-order)
#  Primary tune target: cortex-x1 (performance-critical code path)
# ─────────────────────────────────────────────────────────────────

# ── Colour helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GREEN}${BOLD}[DONE]${RESET}  $*"; }
warn() { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $*"; }
die()  { echo -e "${RED}${BOLD}[FAIL]${RESET}  $*" >&2; exit 1; }

# ── Elapsed-time tracker ──────────────────────────────────────────
START_TIME=$(date +%s)
elapsed() {
  local s=$(( $(date +%s) - START_TIME ))
  printf "%02d:%02d:%02d" $(( s/3600 )) $(( s%3600/60 )) $(( s%60 ))
}

# ── Banner ────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Bleeding-Edge GCC — Tensor G1 Performance Build     ║"
echo "║        Cortex-X1 · Cortex-A76 · Cortex-A55 (A64)       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Argument parsing ──────────────────────────────────────────────
ENABLE_PGO=false
BINUTILS_BRANCH="binutils-2_46"
GCC_BRANCH="releases/gcc-15"

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
    TARGET="arm-linux-gnueabi"
    EXTRA_GCC_FLAGS="--with-fpu=crypto-neon-fp-armv8"
    TENSOR_ARCH="armv8.2-a+crypto+dotprod+fp16+rcpc+ssbs+sb"
    TENSOR_TUNE="cortex-x1"
    ;;
  "arm64")
    TARGET="aarch64-linux-gnu"
    EXTRA_GCC_FLAGS="--with-abi=lp64 --enable-fix-cortex-a53-835769 --enable-fix-cortex-a53-843419"
    TENSOR_ARCH="armv8.2-a+crypto+dotprod+fp16+rcpc+ssbs+sb"
    TENSOR_TUNE="cortex-x1"
    ;;
  "x86")
    TARGET="x86_64-linux-gnu"
    EXTRA_GCC_FLAGS=""
    TENSOR_ARCH="x86-64-v3"
    TENSOR_TUNE="skylake"
    ;;
  *)
    die "Unknown arch '${arch}'. Valid: arm | arm64 | x86"
    ;;
esac

# ── Paths ─────────────────────────────────────────────────────────
export WORK_DIR="$PWD"
export PREFIX="$WORK_DIR/gcc-${arch}"
export PATH="$PREFIX/bin:/usr/bin/core_perl:$PATH"

export CC="clang"
export CXX="clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export STRIP="llvm-strip"
export RANLIB="llvm-ranlib"

# ── Parallelism ───────────────────────────────────────────────────
# Leave 1 logical CPU free so the desktop stays responsive.
RAW_JOBS=$(nproc --all)
JOBS=$(( RAW_JOBS > 1 ? RAW_JOBS - 1 : RAW_JOBS ))
log "Detected ${RAW_JOBS} logical CPUs → using ${JOBS} parallel jobs"

# ── Host compiler optimisation flags ─────────────────────────────
# These flags build the compiler itself as fast as possible on the
# host machine.  march=native lets the host CPU (your PC) use every
# instruction it supports while compiling GCC.
HOST_OPT_FLAGS=(
  "-O3"
  "-march=native"               # exploit every host CPU feature
  "-mtune=native"
  "-pipe"                       # avoid temp files between compiler passes
  "-fomit-frame-pointer"        # free one register on x86-64
  "-ffunction-sections"         # allow linker to GC unused text sections
  "-fdata-sections"             # same for data
  "-flto"                       # "Fat" (full) LTO for aggressive cross-module optimizations
  "-fuse-ld=lld"                # immensely faster than bfd/gold linker
)
OPT_FLAGS="${HOST_OPT_FLAGS[*]}"
export OPT_FLAGS

# ── Tensor G1 — target-code default flags (baked into the toolchain)
# These become the *default* -march/-mtune the produced GCC will use
# when compiling Android source unless overridden by the caller.
#
#   armv8.2-a   — baseline for all three cores (X1, A76, A55)
#   +crypto     — AES / PMULL / SHA{1,2,512} hardware acceleration
#   +dotprod    — UDOT/SDOT used heavily by ML kernels (NNAPI, tflite)
#   +fp16       — half-precision FP (camera / ML pipelines)
#   +rcpc       — Release-Consistent Processor Consistent load (atomics)
#   +ssbs       — Speculative Store Bypass Safe (Spectre-v4 mitigation)
#   +sb         — Speculation Barrier
#
# Tune = cortex-x1: schedules for the wide, out-of-order prime core.
# Code that lands on A76/A55 still runs correctly; the schedule is just
# biased toward the highest-throughput core (peak perf path).
# Note: Variables are now set per-architecture in the parsing block above.

# ─────────────────────────────────────────────────────────────────
log "Work dir : ${WORK_DIR}"
log "Prefix   : ${PREFIX}"
log "Target   : ${TARGET}"
log "Arch     : ${TENSOR_ARCH}  tune=${TENSOR_TUNE}"
log "PGO      : ${ENABLE_PGO}"
echo ""

# ── Dependency check ──────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in git make clang clang++ llvm-ar llvm-nm lld bison flex makeinfo gawk; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing host tools: ${missing[*]}\nInstall with: sudo apt install ${missing[*]}"
  fi
}

# ── Clean previous artefacts ──────────────────────────────────────
clean_previous() {
  log "Removing previous build directories..."
  rm -rf "$WORK_DIR"/{binutils,build-binutils,build-gcc,gcc}
}

# ── Download ──────────────────────────────────────────────────────
download_resources() {
  log "Cloning binutils (branch: ${BINUTILS_BRANCH})..."
  git clone https://sourceware.org/git/binutils-gdb.git \
    -b "${BINUTILS_BRANCH}" binutils \
    --depth=1 --single-branch --no-tags
  # Mark as release (not a development snapshot) to avoid assert()-heavy paths
  sed -i '/^development=/s/true/false/' binutils/bfd/development.sh
  ok "Cloned binutils"

  log "Cloning GCC (branch: ${GCC_BRANCH})..."
  git clone https://gcc.gnu.org/git/gcc.git \
    -b "${GCC_BRANCH}" gcc \
    --depth=1 --single-branch --no-tags
  ok "Cloned GCC"

  cd "${WORK_DIR}"
  ok "All sources ready"
}

# ── Binutils ──────────────────────────────────────────────────────
build_binutils() {
  cd "${WORK_DIR}"
  log "Configuring binutils..."
  mkdir -p build-binutils && cd build-binutils

  env CFLAGS="$OPT_FLAGS" CXXFLAGS="$OPT_FLAGS" LDFLAGS="-static" \
    ../binutils/configure \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-sysroot \
      --with-arch="${TENSOR_ARCH}" \
      --with-tune="${TENSOR_TUNE}" \
      --enable-static \
      --disable-shared \
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
      2>&1 | tee "${WORK_DIR}/configure-binutils.log"

  log "Building binutils (${JOBS} jobs)..."
  make -j"$JOBS" 2>&1 | tee "${WORK_DIR}/build-binutils.log"
  make install -j"$JOBS"
  cd "${WORK_DIR}"
  ok "Binutils built and installed  [$(elapsed)]"
}

# ── GCC (standard or PGO) ─────────────────────────────────────────
_configure_gcc() {
  # $1 = --prefix override (used during PGO bootstrap)
  local prefix="${1:-$PREFIX}"

  env CFLAGS="$OPT_FLAGS" CXXFLAGS="$OPT_FLAGS" LDFLAGS="-static" \
    ../gcc/configure \
      --target="$TARGET" \
      --prefix="$prefix" \
      \
      `# ── Tensor G1 target defaults ─────────────────────────` \
      --with-arch="${TENSOR_ARCH}" \
      --with-tune="${TENSOR_TUNE}" \
      ${EXTRA_GCC_FLAGS} \
      \
      `# ── Language & runtime ────────────────────────────────` \
      --enable-languages=c,c++ \
      --enable-threads=posix \
      --enable-default-ssp \
      --enable-default-pie \
      --enable-linker-build-id \
      \
      `# ── LTO & optimiser plugins ───────────────────────────` \
      --enable-lto \
      --enable-plugins \
      \
      `# ── Linker integration ────────────────────────────────` \
      --with-gnu-as \
      --with-gnu-ld \
      --with-linker-hash-style=gnu \
      \
      `# ── Sysroot / runtime ─────────────────────────────────` \
      --with-headers="/usr/include" \
      --with-newlib \
      --with-sysroot \
      \
      `# ── Disabled features (keep the toolchain lean) ───────` \
      --disable-decimal-float \
      --disable-docs \
      --disable-gcov \
      --disable-libffi \
      --disable-libgomp \
      --disable-libmudflap \
      --disable-libquadmath \
      --disable-libsanitizer \
      --disable-libstdcxx-pch \
      --disable-multilib \
      --disable-nls \
      --disable-shared \
      --disable-werror \
      2>&1 | tee "${WORK_DIR}/configure-gcc.log"
}

build_gcc() {
  cd "${WORK_DIR}"
  log "Preparing GCC sources..."
  cd gcc
  ./contrib/download_prerequisites
  cd "${WORK_DIR}"

  if $ENABLE_PGO; then
    _build_gcc_pgo
  else
    _build_gcc_standard
  fi
}

_build_gcc_standard() {
  log "Building GCC (standard, ${JOBS} jobs)..."
  mkdir -p build-gcc && cd build-gcc
  _configure_gcc "$PREFIX"

  make all-gcc             -j"$JOBS"
  make all-target-libgcc   -j"$JOBS"
  make install-gcc         -j"$JOBS"
  make install-target-libgcc -j"$JOBS"
  cd "${WORK_DIR}"
  ok "GCC built and installed  [$(elapsed)]"
}

# ── PGO bootstrap ─────────────────────────────────────────────────
# Stage 1: build an instrumented GCC
# Stage 2: compile a real workload through it to gather profiles
# Stage 3: rebuild GCC using those profiles — the result is 5-15 %
#           faster at compile time than a vanilla -O3 build.
_build_gcc_pgo() {
  log "PGO bootstrap — Stage 1: instrumented build..."
  local STAGE1_PREFIX="${WORK_DIR}/gcc-pgo-stage1"
  mkdir -p build-gcc && cd build-gcc

  # Override OPT_FLAGS temporarily: add profiling instrumentation
  env CFLAGS="${OPT_FLAGS} -fprofile-generate=${WORK_DIR}/pgo-profiles" \
      CXXFLAGS="${OPT_FLAGS} -fprofile-generate=${WORK_DIR}/pgo-profiles" \
      LDFLAGS="-static" \
    ../gcc/configure \
      --target="$TARGET" \
      --prefix="${STAGE1_PREFIX}" \
      --with-arch="${TENSOR_ARCH}" \
      --with-tune="${TENSOR_TUNE}" \
      ${EXTRA_GCC_FLAGS} \
      --enable-languages=c,c++ \
      --enable-threads=posix \
      --enable-lto \
      --with-newlib \
      --with-sysroot \
      --with-gnu-as \
      --with-gnu-ld \
      --with-linker-hash-style=gnu \
      --disable-docs \
      --disable-nls \
      --disable-shared \
      --disable-multilib \
      --disable-werror \
      2>&1 | tee "${WORK_DIR}/configure-gcc-pgo1.log"

  make all-gcc -j"$JOBS"
  make install-gcc -j"$JOBS"
  ok "Stage 1 done  [$(elapsed)]"

  # ── Stage 2: training run ──────────────────────────────────────
  log "PGO bootstrap — Stage 2: training run (compiling GCC itself)..."
  mkdir -p "${WORK_DIR}/pgo-profiles"
  # Re-compile the GCC source tree with the instrumented compiler to
  # exercise realistic code paths (parsing, RTL, scheduling, RA, LTO).
  make -C "${WORK_DIR}/build-gcc" \
    CC="${STAGE1_PREFIX}/bin/${TARGET}-gcc" \
    CXX="${STAGE1_PREFIX}/bin/${TARGET}-g++" \
    all-gcc -j"$JOBS" 2>/dev/null || true   # failures OK — we just want profiles
  ok "Training run complete  [$(elapsed)]"

  # ── Stage 3: optimised build ───────────────────────────────────
  log "PGO bootstrap — Stage 3: final optimised build..."
  cd "${WORK_DIR}"
  rm -rf build-gcc && mkdir build-gcc && cd build-gcc

  env CFLAGS="${OPT_FLAGS} -fprofile-use=${WORK_DIR}/pgo-profiles -fprofile-correction" \
      CXXFLAGS="${OPT_FLAGS} -fprofile-use=${WORK_DIR}/pgo-profiles -fprofile-correction" \
      LDFLAGS="-static" \
    ../gcc/configure \
      --target="$TARGET" \
      --prefix="$PREFIX" \
      --with-arch="${TENSOR_ARCH}" \
      --with-tune="${TENSOR_TUNE}" \
      ${EXTRA_GCC_FLAGS} \
      --enable-languages=c,c++ \
      --enable-threads=posix \
      --enable-default-ssp \
      --enable-default-pie \
      --enable-linker-build-id \
      --enable-lto \
      --enable-plugins \
      --with-gnu-as \
      --with-gnu-ld \
      --with-linker-hash-style=gnu \
      --with-headers="/usr/include" \
      --with-newlib \
      --with-sysroot \
      --disable-decimal-float \
      --disable-docs \
      --disable-gcov \
      --disable-libffi \
      --disable-libgomp \
      --disable-libmudflap \
      --disable-libquadmath \
      --disable-libsanitizer \
      --disable-libstdcxx-pch \
      --disable-multilib \
      --disable-nls \
      --disable-shared \
      --disable-werror \
      2>&1 | tee "${WORK_DIR}/configure-gcc-pgo3.log"

  make all-gcc             -j"$JOBS"
  make all-target-libgcc   -j"$JOBS"
  make install-gcc         -j"$JOBS"
  make install-target-libgcc -j"$JOBS"
  cd "${WORK_DIR}"
  ok "PGO GCC built and installed  [$(elapsed)]"
}

# ── Summary ───────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║                     Build Summary                       ║${RESET}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${RESET}"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Target triple:"  "$TARGET"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Architecture:"   "$TENSOR_ARCH"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Tune for:"       "$TENSOR_TUNE (Cortex-X1 prime core)"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Extra Flags:"            "${EXTRA_GCC_FLAGS}"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "PGO:"            "$ENABLE_PGO"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Installed to:"   "$PREFIX"
  printf  "${BOLD}║${RESET}  %-20s %-35s ${BOLD}║${RESET}\n" "Total time:"     "$(elapsed)"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  log "Add the toolchain to your PATH:"
  echo "    export PATH=\"${PREFIX}/bin:\$PATH\""
  echo ""
  log "Verify installation:"
  echo "    ${PREFIX}/bin/${TARGET}-gcc --version"
  echo "    ${PREFIX}/bin/${TARGET}-gcc -Q --help=target | grep march"
}

# ── Entry point ───────────────────────────────────────────────────
check_deps
clean_previous
download_resources
build_binutils
build_gcc
print_summary
