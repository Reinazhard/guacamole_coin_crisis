# SPDX-License-Identifier: GPL-3.0
#
# Stage 1: Build Binutils

build_binutils() {
  require_build_context
  header "STAGE 1: BINUTILS"
  safe_cd "${BUILD_DIR}"
  mkdir -p build-binutils && safe_cd build-binutils

  run_log "binutils-configure" "${WORK_DIR}/binutils-src/configure" \
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
      --disable-source-highlight \
      --disable-docs \
      CFLAGS="${HOST_CFLAGS}" \
      CXXFLAGS="${HOST_CXXFLAGS}" \
      LDFLAGS="-static-libstdc++ -static-libgcc ${HOST_LDFLAGS}"

  run_log "binutils-make" make
  run_log "binutils-install" make install

  safe_cd "${WORK_DIR}"
  ok "Binutils done  [$(elapsed)]"
}
register_stage "build_binutils" "Build binutils"
