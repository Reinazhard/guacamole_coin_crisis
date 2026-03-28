#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0

set -euo pipefail

log()  { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
ok()   { echo -e "\033[0;32m[DONE]\033[0m  $*"; }

CUR_DIR="${1:-$(pwd)}"
log "Target directory: $CUR_DIR"

# Try to use llvm-strip, fall back to binutils strip
LLVMS=$(command -v llvm-strip || true)
X86S=${LLVMS:-$(command -v strip || true)}
A64S=${LLVMS:-$(command -v aarch64-linux-gnu-strip || true)}
A32S=${LLVMS:-$(command -v arm-linux-gnueabi-strip || command -v arm-linux-gnu-strip || true)}

# Use a safely handled temporary file
IDX=$(mktemp)
trap 'rm -f "$IDX"' EXIT

log "Indexing binaries (this is much faster now)..."
# Use '+' to batch file arguments, eliminating massive process overhead
find "$CUR_DIR" -type f -exec file {} + > "$IDX" || true

# Target specific debug sections to remove, but explicitly spare .debug_frame
# to ensure basic stack unwinding (kernel panics, exceptions) remains functional.
STRIP_FLAGS="-R .comment -R .note -R .debug_info -R .debug_aranges -R .debug_pubnames -R .debug_pubtypes -R .debug_abbrev -R .debug_line -R .debug_str -R .debug_ranges -R .debug_loc -R .debug_rnglists -R .debug_loclists"

# Safely extract filenames and strip them.
# `sed` cleanly captures everything before the first colon and space `: `,
# avoiding issues with spaces in directory paths unlike `awk`.
process_lines() {
        local tool="$1"
        sed 's/:[[:space:]].*//' | while IFS= read -r filepath; do
                "$tool" $STRIP_FLAGS "$filepath" 2>/dev/null || true
        done
}

if [[ -n "$X86S" && -x "$X86S" ]]; then
        log "Stripping x86 binaries using ${X86S}..."
        grep "x86" "$IDX" | grep "not strip" | grep -v "relocatable" | process_lines "$X86S" || true
else
        warn "Stripper for x86 not found. Skipping."
fi

if [[ -n "$A64S" && -x "$A64S" ]]; then
        log "Stripping aarch64 binaries using ${A64S}..."
        grep "ARM" "$IDX" | grep "aarch64" | grep "not strip" | grep -v "relocatable" | process_lines "$A64S" || true
else
        warn "Stripper for aarch64 not found. Skipping."
fi

if [[ -n "$A32S" && -x "$A32S" ]]; then
        log "Stripping arm32 binaries using ${A32S}..."
        grep "ARM" "$IDX" | grep -E "32[-.]bit" | grep "not strip" | grep -v "relocatable" | process_lines "$A32S" || true
else
        warn "Stripper for arm32 not found. Skipping."
fi

ok "Stripping process completed."
