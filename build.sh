#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
#
# Copyright (C) 2026 M. "Harumajati" Alfarozi
#
# Thin dispatcher entry point for the cross-compiler build system.

set -euo pipefail

# 1. Resolve SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. Source lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Source version pins
source "${SCRIPT_DIR}/.version-pins"

# 3. Parse -a ARCH and -d flags
ARCH=""
usage() {
  echo "Usage: $0 -a <arch> [-d] [stage...]"
  echo "  -a  Target architecture: arm64 | arm"
  echo "  -d  Dry-run mode (print commands instead of executing them)"
  echo "  stage... Optional specific stages to run (e.g., build_binutils)"
  exit 1
}

while getopts "a:d" flag; do
  case "${flag}" in
    a) ARCH="${OPTARG}" ;;
    d) DRY_RUN=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

[[ -z "${ARCH:-}" ]] && usage

# 4. Source lib/flags.sh
source "${SCRIPT_DIR}/lib/flags.sh"

# 5. Source lib/targets.sh
source "${SCRIPT_DIR}/lib/targets.sh"

# 6. Set variables and environment
export WORK_DIR="$PWD"
export PREFIX="${WORK_DIR}/gcc-${ARCH}"
export SYSROOT="${PREFIX}/${TARGET}/sysroot"
export PATH="${PREFIX}/bin:/usr/bin/core_perl:${PATH}"

BUILD_TRIPLE="$(cc -dumpmachine)"
JOBS=$(nproc --all)
export MAKEFLAGS="-j${JOBS}"

# 7. Source all stages/*.sh files
# Sourcing all stages including helper files to allow direct invocation
for stage_file in "${SCRIPT_DIR}"/stages/*.sh; do
  # shellcheck source=/dev/null
  source "${stage_file}"
done

# 8. Parse remaining positional args as STAGES
STAGES=("${@:-all}")

# Elapsed-time tracking persistence across separate stage invocations
if [[ "${STAGES[0]}" == "all" ]] || [[ " ${STAGES[*]} " == *" download_resources "* ]]; then
  START_TIME=$(date +%s)
  echo "${START_TIME}" > "${WORK_DIR}/.build_start_time_${ARCH}"
elif [[ -f "${WORK_DIR}/.build_start_time_${ARCH}" ]]; then
  START_TIME=$(cat "${WORK_DIR}/.build_start_time_${ARCH}")
else
  echo "${START_TIME}" > "${WORK_DIR}/.build_start_time_${ARCH}"
fi

# Helper to check if we should print startup info
_should_print_startup_info() {
  [[ "${STAGES[*]}" != "print_summary" ]]
}

# Print startup info
_print_startup_info() {
  log "Build machine : ${BUILD_TRIPLE}"
  log "Host machine  : ${BUILD_TRIPLE}  (same — standard cross-build)"
  log "Target triple : ${TARGET}"
  log "Prefix        : ${PREFIX}"
  log "Sysroot       : ${SYSROOT}"
  log "Parallel jobs : ${JOBS}"
  log "PGO           : enabled"
  echo
}

# 9. check_deps() — inline, short, references JOBS, DRY_RUN
check_deps() {
  local missing=()
  for cmd in gcc g++ make bison flex makeinfo gawk curl tar xz git zstd mold; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  
  if (( ${#missing[@]} > 0 )); then
    warn "Missing host tools: ${missing[*]}"
    if ! $DRY_RUN; then
      die "Install missing tools with: pacman -S ${missing[*]}"
    else
      warn "[DRY-RUN] Proceeding anyway..."
    fi
  fi
}

# 10. Startup info
_should_print_startup_info && _print_startup_info

# 11. Dispatch
if [[ "${STAGES[0]}" == "all" ]]; then
  check_deps
  download_resources
  install_mold
  build_binutils
  build_linux_headers
  build_gcc_pass1
  build_glibc
  build_gcc_pass2
  strip_binaries
  validate_elf
  print_summary
else
  for stage in "${STAGES[@]}"; do
    if declare -f "$stage" > /dev/null; then
      $stage
    else
      die "Unknown stage: $stage"
    fi
  done
fi
