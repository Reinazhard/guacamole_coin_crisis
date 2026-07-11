# SPDX-License-Identifier: GPL-3.0
#
# Stage 8: ELF Validation

validate_elf() {
  header "STAGE 8: ELF VALIDATION"

  log "Validating host compiler binaries (should be X86-64)..."
  local host_bins=("gcc" "ld" "as" "mold")
  for tool in "${host_bins[@]}"; do
    local bin_path
    if [[ "${tool}" == "mold" ]]; then
      bin_path="${PREFIX}/bin/mold"
    else
      bin_path="${PREFIX}/bin/${TARGET}-${tool}"
    fi

    if [[ -f "${bin_path}" ]]; then
      log "Checking ${bin_path}..."
      local info
      info=$(readelf -h "${bin_path}" 2>/dev/null | grep -i "Machine:") || true
      if [[ "${info}" =~ "X86-64" ]]; then
        ok "  ${tool} is valid X86-64 ELF"
      else
        die "  ${tool} is NOT valid X86-64: ${info}"
      fi
    else
      warn "  ${tool} not found at ${bin_path}"
    fi
  done

  log "Validating target libraries (should be correct target arch)..."
  local expected_pattern=""
  if [[ "${ARCH}" == "arm64" ]]; then
    expected_pattern="AArch64"
  elif [[ "${ARCH}" == "arm" ]]; then
    expected_pattern="ARM"
  fi

  local actual_lib
  actual_lib=$(find "${SYSROOT}/usr/lib" -name "libc.so.*" -o -name "libc-*.so" | head -n1)
  if [[ -z "${actual_lib}" ]]; then
    actual_lib=$(find "${SYSROOT}/usr/lib" -name "crt1.o" | head -n1)
  fi

  if [[ -n "${actual_lib}" && -f "${actual_lib}" ]]; then
    log "Checking target library ${actual_lib}..."
    local info
    info=$(readelf -h "${actual_lib}" 2>/dev/null | grep -i "Machine:") || true
    if [[ "${info}" =~ "${expected_pattern}" ]]; then
      ok "  ${actual_lib} is valid ${expected_pattern} ELF"
    else
      die "  ${actual_lib} is NOT valid ${expected_pattern}: ${info}"
    fi
  else
    die "Target runtime libraries not found in sysroot"
  fi

  ok "ELF validation successful."
}
register_stage "validate_elf" "Validate ELF binaries"
