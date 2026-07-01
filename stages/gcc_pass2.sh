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
  log "Phase 1/5: Building instrumented compiler..."
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
  log "Phase 2/5: Training on kernel compilation..."
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
  log "Phase 3/5: Rebuilding compiler with PGO profile data..."
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
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS} -fprofile-use=${PROFILE_DIR} -Wl,--emit-relocs"

  run_log "gcc-pgo-final-make" make all
  run_log "gcc-pgo-final-install" make install

  safe_cd "${WORK_DIR}"
  ok "Phase 3 complete: PGO-optimized compiler installed  [$(elapsed)]"

  # ── Phase 4: BOLT instrumentation & training run ────────────────
  log "Phase 4/5: Instrumenting with BOLT and second training run..."
  local BOLT_DATA_DIR="${WORK_DIR}/bolt-profiles"
  
  if ! $DRY_RUN; then
    rm -rf "${BOLT_DATA_DIR}"
    mkdir -p "${BOLT_DATA_DIR}"
    
    local cc1_path cc1plus_path lto1_path
    cc1_path=$(find "${PREFIX}/libexec/gcc/${TARGET}" -name "cc1" -type f | head -n 1)
    cc1plus_path=$(find "${PREFIX}/libexec/gcc/${TARGET}" -name "cc1plus" -type f | head -n 1)
    lto1_path=$(find "${PREFIX}/libexec/gcc/${TARGET}" -name "lto1" -type f | head -n 1)

    for bin_path in "${cc1_path}" "${cc1plus_path}" "${lto1_path}"; do
      if [[ -n "${bin_path}" ]] && [[ -f "${bin_path}" ]]; then
        log "Instrumenting ${bin_path}..."
        mv "${bin_path}" "${bin_path}.orig"
        llvm-bolt "${bin_path}.orig" -instrument -instrumentation-file-append-pid \
          -instrumentation-file="${BOLT_DATA_DIR}/prof" -o "${bin_path}"
      fi
    done
  fi

  safe_cd "${WORK_DIR}/linux-${LINUX_VER}"
  run_log "bolt-kernel-mrproper" make ARCH="${KERNEL_ARCH}" mrproper
  run_log "bolt-kernel-defconfig" make ARCH="${KERNEL_ARCH}" CROSS_COMPILE="${TARGET}-" defconfig
  log "Compiling kernel for BOLT training..."
  run_log "bolt-kernel-make" make ARCH="${KERNEL_ARCH}" CROSS_COMPILE="${TARGET}-" -j${JOBS} all || true
  run_log "bolt-kernel-clean" make ARCH="${KERNEL_ARCH}" mrproper
  ok "Phase 4 complete: BOLT profile data collected  [$(elapsed)]"

  # ── Phase 5: BOLT Optimization ────────────────────────────────
  log "Phase 5/5: Optimizing compiler with BOLT..."
  if ! $DRY_RUN; then
    local prof_count=$(find "${BOLT_DATA_DIR}" -name "prof*" 2>/dev/null | wc -l)
    if (( prof_count > 0 )); then
      merge-fdata "${BOLT_DATA_DIR}/prof"* > "${BOLT_DATA_DIR}/merged.fdata"
      for bin_path in "${cc1_path}" "${cc1plus_path}" "${lto1_path}"; do
        if [[ -n "${bin_path}" ]] && [[ -f "${bin_path}.orig" ]]; then
          log "Optimizing ${bin_path}..."
          llvm-bolt "${bin_path}.orig" -data "${BOLT_DATA_DIR}/merged.fdata" -o "${bin_path}.bolt" \
            -reorder-blocks=ext-tsp -reorder-functions=hfsort+ -split-functions -split-all-cold -split-eh -dyno-stats
          mv "${bin_path}.bolt" "${bin_path}"
          rm -f "${bin_path}.orig"
        fi
      done
    else
      warn "No BOLT profile data found, skipping optimization."
    fi
  fi
  ok "Phase 5 complete: BOLT optimization applied  [$(elapsed)]"
}
