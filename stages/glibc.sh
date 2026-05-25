# SPDX-License-Identifier: GPL-3.0
#
# Stage 4: Build Glibc

build_glibc() {
  header "STAGE 4: GLIBC"
  safe_cd "${WORK_DIR}"
  mkdir -p build-glibc && safe_cd build-glibc

  # glibc cannot be compiled with external _FORTIFY_SOURCE as it implements it
  local glibc_cflags="${TARGET_CFLAGS//-Wp,-D_FORTIFY_SOURCE=3/}"
  local glibc_cxxflags="${TARGET_CXXFLAGS//-Wp,-D_FORTIFY_SOURCE=3/}"

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
      CFLAGS="${glibc_cflags}" \
      CXXFLAGS="${glibc_cxxflags}"

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

  safe_cd "${WORK_DIR}"
  ok "Glibc done  [$(elapsed)]"
}
