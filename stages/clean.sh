# SPDX-License-Identifier: GPL-3.0
#
# Stage: Clean build environment

clean() {
  require_context WORK_DIR
  header "CLEAN"

  log "Removing builds directory..."
  rm -rf "${WORK_DIR:?}/builds"
  rm -rf "${WORK_DIR:?}/pgo-profiles"
  rm -rf "${WORK_DIR:?}/mold-bin"

  if [[ "${CLEAN_SOURCES:-false}" == "true" ]]; then
    warn "CLEAN_SOURCES=true: removing source trees and downloads..."
    rm -rf "${WORK_DIR}/sources" \
           "${WORK_DIR}/gcc-src" \
           "${WORK_DIR}/binutils-src" \
           "${WORK_DIR}/mold-src" \
           "${WORK_DIR}/glibc-${GLIBC_VER}" \
           "${WORK_DIR}/linux-${LINUX_VER}" \
           "${WORK_DIR}/gmp-${GMP_VER}" \
           "${WORK_DIR}/mpfr-${MPFR_VER}" \
           "${WORK_DIR}/mpc-${MPC_VER}" \
           "${WORK_DIR}/isl-${ISL_VER}"
  fi
  ok "Clean done  [$(elapsed)]"
}
register_stage "clean" "Clean build environment"
