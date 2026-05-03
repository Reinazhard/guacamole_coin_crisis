#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────
CYAN='\033[0;36m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
ok()   { echo -e "${GREEN}[DONE]${RESET}  $*"; }

CUR_DIR="${1:-$(pwd)}"
log "Target directory: ${CUR_DIR}"

# Use the cross-compiler's own strip utilities from the toolchain we just built.
X86S=$(command -v strip || true)
A64S="${CUR_DIR}/bin/aarch64-linux-gnu-strip"
A32S="${CUR_DIR}/bin/arm-linux-gnueabihf-strip"

# Target specific debug sections to remove, but explicitly spare .debug_frame
# to ensure basic stack unwinding remains functional.
STRIP_FLAGS=(
    --strip-unneeded
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

# Helper to check ELF machine type using readelf
# Machine codes: 62 = x86-64, 183 = AArch64, 40 = ARM
get_elf_machine() {
    local file="$1"
    readelf -h "${file}" 2>/dev/null | awk '/Machine:/ {print $2}' || echo "unknown"
}

# Safely strip binaries in parallel
strip_files() {
    local tool="$1"
    local machine_code="$2"
    local jobs; jobs=$(nproc)

    log "Searching for binaries (Machine: ${machine_code}) using ${tool}..."
    
    find "${CUR_DIR}" -type f -executable -print0 | xargs -0 -P "${jobs}" -I {} bash -c "
        if [[ \"\$(readelf -h '{}' 2>/dev/null | awk '/Machine:/ {print \$NF}')\" == \"${machine_code}\" ]]; then
            \"${tool}\" ${STRIP_FLAGS[*]} '{}' 2>/dev/null
        fi
    "
}

if [[ -n "${X86S}" && -x "${X86S}" ]]; then
    # Machine code for x86-64 is Advanced Micro Devices X86-64 (or similar)
    # We check for X86-64
    strip_files "${X86S}" "X86-64"
else
    warn "Stripper for x86 not found. Skipping."
fi

if [[ -n "${A64S}" && -x "${A64S}" ]]; then
    # Machine code for AArch64 is AArch64
    strip_files "${A64S}" "AArch64"
else
    warn "Stripper for aarch64 not found. Skipping."
fi

if [[ -n "${A32S}" && -x "${A32S}" ]]; then
    # Machine code for ARM is ARM
    strip_files "${A32S}" "ARM"
else
    warn "Stripper for arm32 not found. Skipping."
fi

ok "Stripping process completed."
