# SPDX-License-Identifier: GPL-3.0
#
# Common helper to configure GCC passes.
# Sourced by stages/gcc_pass1.sh and stages/gcc_pass2.sh.

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
      CFLAGS_FOR_TARGET="${TARGET_CFLAGS}" \
      CXXFLAGS_FOR_TARGET="${TARGET_CXXFLAGS}" \
      CFLAGS_FOR_BUILD="${BUILD_CFLAGS}" \
      CXXFLAGS_FOR_BUILD="${BUILD_CXXFLAGS}" \
      LDFLAGS_FOR_TARGET="${TARGET_LDFLAGS}" \
      "$@"
}
