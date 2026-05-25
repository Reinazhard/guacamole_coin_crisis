# SPDX-License-Identifier: GPL-3.0
#
# Stage: Download & Extract sources

verify_checksum() {
  local file="sources/$1"
  local expected_sha256="$2"

  if [[ -z "${expected_sha256:-}" ]]; then
    warn "No SHA256 defined for $1. Skipping verification."
    return 0
  fi

  if [[ "${SKIP_CHECKSUM:-false}" == "true" ]]; then
    log "Skipping checksum verification for $1 (SKIP_CHECKSUM=true)"
    return 0
  fi

  log "Verifying checksum for $1..."
  echo "${expected_sha256}  ${file}" | sha256sum --check --status || \
    die "Checksum verification failed for ${file}!"
  ok "Checksum for $1 matches."
}

fetch() {
  local url="$1"
  local file="${url##*/}"
  local expected_sha256="${2:-}"

  if [[ -f "sources/${file}" ]]; then
    if [[ -n "${expected_sha256}" ]] && ! echo "${expected_sha256}  sources/${file}" | sha256sum --check --status 2>/dev/null; then
      warn "Existing sources/${file} failed checksum verification! Deleting and redownloading..."
      rm -f "sources/${file}"
    else
      ok "Cached sources/${file} (verified)"
      return 0
    fi
  fi

  log "Downloading ${file}..."
  if ! $DRY_RUN; then
    curl -fL --retry 5 --retry-delay 3 -o "sources/${file}.tmp" "${url}"
    mv "sources/${file}.tmp" "sources/${file}"
    verify_checksum "${file}" "${expected_sha256}"
  else
    log "[DRY-RUN] curl -fL ... -o sources/${file}.tmp ${url} && mv sources/${file}.tmp sources/${file}"
  fi
}

download_resources() {
  header "DOWNLOADING & CLONING SOURCES"
  mkdir -p sources

  # Git Sources
  if [[ ! -d "gcc-src" ]]; then
    log "Cloning GCC from ${GCC_BRANCH}..."
    if $DRY_RUN; then
      log "[DRY-RUN] git clone --branch=${GCC_BRANCH} ..."
    elif [[ -n "${GCC_COMMIT}" ]]; then
      log "Pinning GCC to commit: ${GCC_COMMIT}"
      git clone --shallow-since="${SHALLOW_SINCE}" --branch="${GCC_BRANCH}" https://gnu.googlesource.com/gcc gcc-src
      git -C gcc-src checkout "${GCC_COMMIT}"
    else
      git clone --depth=1 --branch="${GCC_BRANCH}" https://gnu.googlesource.com/gcc gcc-src
    fi
  fi

  if [[ ! -d "binutils-src" ]]; then
    log "Cloning Binutils from ${BINUTILS_BRANCH}..."
    if $DRY_RUN; then
      log "[DRY-RUN] git clone --branch=${BINUTILS_BRANCH} ..."
    elif [[ -n "${BINUTILS_COMMIT}" ]]; then
      log "Pinning Binutils to commit: ${BINUTILS_COMMIT}"
      git clone --shallow-since="${SHALLOW_SINCE}" --branch="${BINUTILS_BRANCH}" https://gnu.googlesource.com/binutils-gdb binutils-src
      git -C binutils-src checkout "${BINUTILS_COMMIT}"
    else
      git clone --depth=1 --branch="${BINUTILS_BRANCH}" https://gnu.googlesource.com/binutils-gdb binutils-src
    fi
  fi

  # Tarball sources
  fetch "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz" "${GLIBC_SHA256:-}" &
  fetch "https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VER%%.*}.x/linux-${LINUX_VER}.tar.xz" "${LINUX_SHA256:-}" &
  fetch "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" "${GMP_SHA256:-}" &
  fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz" "${MPFR_SHA256:-}" &
  fetch "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.xz" "${MPC_SHA256:-}" &
  fetch "https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz" "${ISL_SHA256:-}" &
  wait

  header "EXTRACTING SOURCES"

  for pkg in \
    "glibc-${GLIBC_VER}" \
    "linux-${LINUX_VER}" \
    "gmp-${GMP_VER}" \
    "mpfr-${MPFR_VER}" \
    "mpc-${MPC_VER}" \
    "isl-${ISL_VER}"
  do
    if [[ ! -d "${pkg}" ]]; then
      log "Extracting ${pkg}..."
      if $DRY_RUN; then
        log "[DRY-RUN] tar xf sources/${pkg}.tar.*"
      else
        tar xf "sources/${pkg}.tar."* &
      fi
    fi
  done
  wait

  # Integrate prerequisites as in-tree symlinks for both GCC and Binutils.
  if ! $DRY_RUN; then
    log "Linking prerequisites in-tree..."
    for dep_dir in "gmp-${GMP_VER}" "mpfr-${MPFR_VER}" "mpc-${MPC_VER}" "isl-${ISL_VER}"; do
      dep_name="${dep_dir%%-*}"
      ln -sfn "../${dep_dir}" "gcc-src/${dep_name}"
      ln -sfn "../${dep_dir}" "binutils-src/${dep_name}"
    done
  fi
  ok "All sources ready  [$(elapsed)]"
}
