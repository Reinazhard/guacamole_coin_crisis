# SPDX-License-Identifier: GPL-3.0
#
# Context validation and loading for build stages.

# Ensures that all required environment variables for a stage are present.
# Usage: require_context "VAR1" "VAR2"
require_context() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    die "Missing required context variables: ${missing[*]}. Are you running this stage through build.sh?"
  fi
}

# Ensure the build directory exists
# The standard build context required by most compilation stages
require_build_context() {
  require_context \
    WORK_DIR \
    PREFIX \
    SYSROOT \
    TARGET \
    ARCH \
    HOST_CFLAGS \
    HOST_CXXFLAGS \
    HOST_LDFLAGS \
    TARGET_CFLAGS \
    TARGET_CXXFLAGS \
    TARGET_LDFLAGS

  export BUILD_DIR="${WORK_DIR}/builds"
  mkdir -p "${BUILD_DIR}"
}

# --- Stage Registration ---

declare -A REGISTERED_STAGES=()

# Register a function as an invokable stage
register_stage() {
  local stage_name="$1"
  local description="${2:-}"
  REGISTERED_STAGES["${stage_name}"]="${description}"
}

# Check if a stage is registered
is_stage_registered() {
  local stage_name="$1"
  [[ -n "${REGISTERED_STAGES[${stage_name}]+isset}" ]]
}

