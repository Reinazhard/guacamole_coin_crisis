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
A64O="${CUR_DIR}/bin/aarch64-linux-gnu-objcopy"
A32O="${CUR_DIR}/bin/arm-linux-gnueabihf-objcopy"

# Target specific debug sections to remove, but explicitly spare .debug_frame
# to ensure basic stack unwinding remains functional.
SECTION_FLAGS=(
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

STRIP_FLAGS=(
    --strip-unneeded
    "${SECTION_FLAGS[@]}"
)

# Strip host tools and shared objects by ELF machine.
strip_elf_files() {
    local tool="$1"
    local machine_pattern="$2"
    local jobs; jobs=$(nproc 2>/dev/null || echo 4)

    log "Stripping ELF binaries (Machine: ${machine_pattern}) with ${tool}..."

    find "${CUR_DIR}" -type f \( -executable -o -name "*.so" -o -name "*.so.*" \) \
        -print0 | xargs -0 -P "${jobs}" -n1 bash -c '
        file="$1"; tool="$2"; pattern="$3"; shift 3; flags=("$@")
        if readelf -h "$file" 2>/dev/null | grep -iq "Machine:.*$pattern"; then
            "$tool" "${flags[@]}" "$file" 2>/dev/null || true
        fi
    ' _ {} "${tool}" "${machine_pattern}" "${STRIP_FLAGS[@]}" || true
}

# Strip target static libraries and object files in sysroot.
strip_target_runtime_artifacts() {
    local objcopy_tool="$1"
    local target="$2"
    local jobs; jobs=$(nproc 2>/dev/null || echo 4)
    local sysroot_dir="${CUR_DIR}/${target}/sysroot"

    if [[ ! -d "${sysroot_dir}" ]]; then
        warn "Sysroot not found for ${target}. Skipping runtime library stripping."
        return 0
    fi

    log "Stripping target runtime artifacts in ${sysroot_dir} with ${objcopy_tool}..."
    find "${sysroot_dir}" -type f \( -name "*.a" -o -name "*.o" \) -print0 | \
        xargs -0 -P "${jobs}" -n1 bash -c '
            file="$1"; objcopy="$2"; shift 2; flags=("$@")
            "$objcopy" "${flags[@]}" "$file" 2>/dev/null || true
        ' _ {} "${objcopy_tool}" "${SECTION_FLAGS[@]}" || true
}

if [[ -n "${X86S}" && -x "${X86S}" ]]; then
    strip_elf_files "${X86S}" "X86-64"
else
    warn "Stripper for x86 not found. Skipping."
fi

if [[ -n "${A64S}" && -x "${A64S}" ]]; then
    strip_elf_files "${A64S}" "AArch64"
    if [[ -x "${A64O}" ]]; then
        strip_target_runtime_artifacts "${A64O}" "aarch64-linux-gnu"
    else
        warn "Objcopy for aarch64 not found. Skipping target archive/object stripping."
    fi
else
    warn "Stripper for aarch64 not found. Skipping."
fi

if [[ -n "${A32S}" && -x "${A32S}" ]]; then
    strip_elf_files "${A32S}" "ARM"
    if [[ -x "${A32O}" ]]; then
        strip_target_runtime_artifacts "${A32O}" "arm-linux-gnueabihf"
    else
        warn "Objcopy for arm32 not found. Skipping target archive/object stripping."
    fi
else
    warn "Stripper for arm32 not found. Skipping."
fi

ok "Stripping process completed."
