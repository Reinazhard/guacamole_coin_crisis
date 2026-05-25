# SPDX-License-Identifier: GPL-3.0
#
# Stage: Clean build environment

clean() {
  header "CLEAN"
  local dirs=(
    build-binutils build-gcc-pass1 build-glibc
    build-gcc-pgo-instr build-gcc-pgo-final build-mold
    pgo-profiles
  )
  for d in "${dirs[@]}"; do
    if [[ -d "${WORK_DIR}/${d}" ]]; then
      log "Removing ${d}..."
      rm -rf "${WORK_DIR:?}/${d}"
    fi
  done

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
