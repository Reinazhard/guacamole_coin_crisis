# SPDX-License-Identifier: GPL-3.0
#
# Stage: Print Summary

print_summary() {
  local gcc_hash_full; gcc_hash_full=$(git -C gcc-src rev-parse HEAD 2>/dev/null || echo "unknown")
  local gcc_hash_short; gcc_hash_short=$(git -C gcc-src rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local binutils_hash_full; binutils_hash_full=$(git -C binutils-src rev-parse HEAD 2>/dev/null || echo "unknown")
  local binutils_hash_short; binutils_hash_short=$(git -C binutils-src rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local mold_hash_short; mold_hash_short=$(git -C mold-src rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local pgo_status="enabled"

  # Helper to truncate values for narrow box (max 34 chars)
  _fmt() {
    local val="$1"
    if (( ${#val} > 34 )); then
      echo "...${val: -31}"
    else
      echo "$val"
    fi
  }

  echo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗"
  echo -e "║                    Toolchain Summary                     ║"
  echo -e "╠══════════════════════════════════════════════════════════╣${RESET}"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Target triple:"    "$(_fmt "${TARGET}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Installed to:"     "$(_fmt "${PREFIX}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Sysroot:"          "$(_fmt "${SYSROOT}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "GCC branch:"       "$(_fmt "${GCC_BRANCH}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "GCC commit:"       "$(_fmt "${gcc_hash_short} (${gcc_hash_full:0:16}...)")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Binutils branch:"  "$(_fmt "${BINUTILS_BRANCH}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Binutils commit:"  "$(_fmt "${binutils_hash_short} (${binutils_hash_full:0:16}...)")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Glibc version:"    "$(_fmt "${GLIBC_VER}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Linux headers:"    "$(_fmt "${LINUX_VER}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Mold commit:"      "$(_fmt "${mold_hash_short}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "PGO training:"     "$(_fmt "${pgo_status}")"
  printf "${BOLD}║${RESET}  %-20s %-34s ${BOLD}║${RESET}\n" "Total build time:" "$(_fmt "$(elapsed)")"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo
  log "Verifying installed components..."
  for tool in gcc ld as; do
    local bin="${PREFIX}/bin/${TARGET}-${tool}"
    if [[ -x "${bin}" ]]; then
      log "  ${tool}: $(${bin} --version | head -n1)"
    fi
  done
  if [[ -x "${PREFIX}/bin/mold" ]]; then
    log "  mold: $(${PREFIX}/bin/mold --version | head -n1)"
  fi
  echo
}
