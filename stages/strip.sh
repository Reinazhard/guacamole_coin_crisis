# SPDX-License-Identifier: GPL-3.0
#
# Stage 7: Strip Binaries

strip_binaries() {
  header "STAGE 7: STRIPPING BINARIES"

  local CUR_DIR="${PREFIX}"
  log "Target directory for stripping: ${CUR_DIR}"

  # Target specific debug sections to remove, but explicitly spare .debug_frame
  # to ensure basic stack unwinding remains functional.
  local SECTION_FLAGS=(
      --remove-section=.comment
      --remove-section=.note
      --remove-section=.debug_info
      --remove-section=.debug_aranges
      --remove-section=.debug_pubnames
      --remove-section=.debug_pubtypes
      --remove-section=.debug_abbrev
      --remove-section=.debug_line
      --remove-section=.debug_str
      --remove-section=.debug_ranges
      --remove-section=.debug_loc
      --remove-section=.debug_rnglists
      --remove-section=.debug_loclists
  )

  local STRIP_FLAGS=(
      --strip-unneeded
      "${SECTION_FLAGS[@]}"
  )

  # Strip host tools and shared objects by ELF machine.
  strip_elf_files() {
      local tool="$1"
      local machine_pattern="$2"

      if $DRY_RUN; then
        log "[DRY-RUN] strip ELF files (Machine: ${machine_pattern})"
        return 0
      fi

      log "Stripping ELF binaries (Machine: ${machine_pattern}) with ${tool}..."

      find "${CUR_DIR}" -type f \( -executable -o -name "*.so" -o -name "*.so.*" \) \
          -print0 | xargs -0 -P "${JOBS}" -n1 bash -c '
          file="$1"; tool="$2"; pattern="$3"; shift 3; flags=("$@")
          if readelf -h "$file" 2>/dev/null | grep -iq "Machine:.*$pattern"; then
              "$tool" "${flags[@]}" "$file" 2>/dev/null || true
          fi
      ' _ {} "${tool}" "${machine_pattern}" "${STRIP_FLAGS[@]}" || true
  }

  # Strip target static libraries and object files in sysroot.
  strip_target_runtime_artifacts() {
      local objcopy_tool="$1"
      local target_triple="$2"
      local sysroot_dir="${CUR_DIR}/${target_triple}/sysroot"

      if $DRY_RUN; then
        log "[DRY-RUN] strip target runtime artifacts in ${sysroot_dir}"
        return 0
      fi

      if [[ ! -d "${sysroot_dir}" ]]; then
          warn "Sysroot not found for ${target_triple}. Skipping runtime library stripping."
          return 0
      fi

      log "Stripping target runtime artifacts in ${sysroot_dir} with ${objcopy_tool}..."
      find "${sysroot_dir}" -type f \( -name "*.a" -o -name "*.o" \) -print0 | \
          xargs -0 -P "${JOBS}" -n1 bash -c '
              file="$1"; objcopy="$2"; shift 2; flags=("$@")
              "$objcopy" "${flags[@]}" "$file" 2>/dev/null || true
          ' _ {} "${objcopy_tool}" "${SECTION_FLAGS[@]}" || true
  }

  # Strip an architecture target toolchain and sysroot.
  strip_arch_target() {
      local arch_name="$1"      # e.g., "aarch64" or "arm32"
      local machine_pat="$2"    # e.g., "AArch64" or "ARM"
      local target_triple="$3"  # e.g., "aarch64-linux-gnu" or "arm-linux-gnueabihf"
      local strip_bin="${CUR_DIR}/bin/${target_triple}-strip"
      local objcopy_bin="${CUR_DIR}/bin/${target_triple}-objcopy"

      if [[ -x "${strip_bin}" ]]; then
          strip_elf_files "${strip_bin}" "${machine_pat}"
          if [[ -x "${objcopy_bin}" ]]; then
              strip_target_runtime_artifacts "${objcopy_bin}" "${target_triple}"
          else
              warn "Objcopy for ${arch_name} not found. Skipping target archive/object stripping."
          fi
      else
          warn "Stripper for ${arch_name} not found. Skipping."
      fi
  }

  local X86S
  X86S=$(command -v strip || true)
  if [[ -n "${X86S}" && -x "${X86S}" ]]; then
      strip_elf_files "${X86S}" "X86-64"
  else
      warn "Stripper for x86 not found. Skipping."
  fi

  if [[ "${ARCH}" == "arm64" ]]; then
      strip_arch_target "aarch64" "AArch64" "aarch64-linux-gnu"
  elif [[ "${ARCH}" == "arm" ]]; then
      strip_arch_target "arm32" "ARM" "arm-linux-gnueabihf"
  fi

  ok "Stripping process completed."
}
