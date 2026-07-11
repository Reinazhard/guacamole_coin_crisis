# SPDX-License-Identifier: GPL-3.0
#
# Stage 3: GCC Pass 1

# Source the GCC common helper
source "${SCRIPT_DIR}/stages/_gcc_common.sh"

build_gcc_pass1() {
  require_build_context
  header "STAGE 3: GCC PASS 1 (BOOTSTRAP C COMPILER)"
  safe_cd "${BUILD_DIR}"
  mkdir -p build-gcc-pass1 && safe_cd build-gcc-pass1

  _configure_gcc "${WORK_DIR}/gcc-src" "pass1" \
      --without-headers \
      --with-newlib \
      --disable-shared \
      --disable-threads \
      --disable-libatomic \
      --disable-libquadmath \
      --disable-libvtv \
      --disable-libstdcxx \
      --disable-libffi \
      CFLAGS="${HOST_CFLAGS}" \
      CXXFLAGS="${HOST_CXXFLAGS}" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS}"

  run_log "gcc-pass1-make-gcc" make all-gcc
  run_log "gcc-pass1-install-gcc" make install-gcc
  run_log "gcc-pass1-make-libgcc" make all-target-libgcc
  run_log "gcc-pass1-install-libgcc" make install-target-libgcc

  safe_cd "${WORK_DIR}"
  ok "GCC Pass 1 done  [$(elapsed)]"
}
register_stage "build_gcc_pass1" "Build GCC Pass 1 (C/C++ only)"
