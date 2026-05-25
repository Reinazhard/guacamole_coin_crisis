# SPDX-License-Identifier: GPL-3.0
#
# Stage 5: GCC Pass 2 (with PGO)

# Source the GCC common helper
source "${SCRIPT_DIR}/stages/_gcc_common.sh"

GCC_PASS2_FLAGS=(
  --enable-shared
  --enable-threads=posix
  --enable-linker-build-id
  --enable-default-ssp
  --enable-default-pie
  --disable-libstdcxx-pch
)

build_gcc_pass2() {
  header "STAGE 5: GCC PASS 2 (PGO COMPILER)"

  local PROFILE_DIR="${WORK_DIR}/pgo-profiles"
  local profile_count=0

  if ! $DRY_RUN; then
    rm -rf "${PROFILE_DIR}"
    mkdir -p "${PROFILE_DIR}"
  fi

  # ── Phase 1: Build instrumented compiler ──────────────────────
  log "Phase 1/3: Building instrumented compiler..."
  safe_cd "${WORK_DIR}"
  [[ -d build-gcc-pgo-instr ]] && rm -rf build-gcc-pgo-instr
  mkdir -p build-gcc-pgo-instr && safe_cd build-gcc-pgo-instr

  _configure_gcc "gcc-src" "pass2-pgo-instr" "${GCC_PASS2_FLAGS[@]}" \
      CFLAGS="${HOST_CFLAGS} -fprofile-generate=${PROFILE_DIR}" \
      CXXFLAGS="${HOST_CXXFLAGS} -fprofile-generate=${PROFILE_DIR}" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS} -fprofile-generate=${PROFILE_DIR}"

  run_log "gcc-pgo-instr-make" make all
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
    die "No profile data found! PGO training failed."
  fi
  log "Collected ${profile_count} profile files"

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

  _configure_gcc "gcc-src" "pass2-pgo-final" "${GCC_PASS2_FLAGS[@]}" \
      CFLAGS="${HOST_CFLAGS} -fprofile-use=${PROFILE_DIR} -fprofile-correction -Wno-missing-profile" \
      CXXFLAGS="${HOST_CXXFLAGS} -fprofile-use=${PROFILE_DIR} -fprofile-correction -Wno-missing-profile" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS} -fprofile-use=${PROFILE_DIR}"

  run_log "gcc-pgo-final-make" make all
  run_log "gcc-pgo-final-install" make install

  safe_cd "${WORK_DIR}"
  ok "Phase 3 complete: PGO-optimised compiler installed  [$(elapsed)]"
}
