# SPDX-License-Identifier: GPL-3.0
#
# Stage 6: Install Mold linker

install_mold() {
  require_context WORK_DIR PREFIX MOLD_BRANCH TARGET JOBS
  header "STAGE 6: MOLD LINKER"
  command -v cmake &>/dev/null || die "cmake required for mold stage"

  # Clone or update mold source
  if [[ ! -d "mold-src" ]]; then
    log "Cloning mold (branch: ${MOLD_BRANCH})..."
    if $DRY_RUN; then
      log "[DRY-RUN] git clone --depth=1 --branch=${MOLD_BRANCH} ..."
    else
      git clone --depth=1 --branch="${MOLD_BRANCH}" --single-branch --no-tags \
        https://github.com/rui314/mold.git mold-src
    fi
  fi

  safe_cd "${BUILD_DIR}"
  
  if [[ -x "${WORK_DIR}/mold-bin/mold" ]]; then
    log "Cached mold binary found. Skipping build."
  else
    [[ -d build-mold ]] && rm -rf build-mold
    run_log "mold-cmake" cmake -B build-mold -S "${WORK_DIR}/mold-src" \
      -DCMAKE_BUILD_TYPE=Release \
      -DMOLD_MOSTLY_STATIC=ON

    run_log "mold-build" cmake --build build-mold -j${JOBS}
    
    # Save the compiled binary to a cacheable location
    mkdir -p "${WORK_DIR}/mold-bin"
    cp build-mold/mold "${WORK_DIR}/mold-bin/"
  fi

  # Install the binary from the cache
  mkdir -p "${PREFIX}/bin"
  cp "${WORK_DIR}/mold-bin/mold" "${PREFIX}/bin/"

  # Create symlinks for GCC -fuse-ld=mold lookup
  if ! $DRY_RUN; then
    ln -sfn mold "${PREFIX}/bin/ld.mold"
    ln -sfn ld.mold "${PREFIX}/bin/${TARGET}-ld.mold"
  fi

  safe_cd "${WORK_DIR}"
  ok "Mold linker installed  [$(elapsed)]"
}
register_stage "install_mold" "Build and install Mold linker"
