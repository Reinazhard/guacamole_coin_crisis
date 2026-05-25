# SPDX-License-Identifier: GPL-3.0
#
# Stage 2: Install Linux headers

build_linux_headers() {
  header "STAGE 2: LINUX KERNEL HEADERS"
  safe_cd "${WORK_DIR}/linux-${LINUX_VER}"

  run_log "linux-headers" make ARCH="${KERNEL_ARCH}" \
       INSTALL_HDR_PATH="${SYSROOT}/usr" \
       headers_install

  safe_cd "${WORK_DIR}"
  ok "Linux headers done  [$(elapsed)]"
}
