# SPDX-License-Identifier: GPL-3.0
#
# Target resolution and configuration loading.
# Sourced by build.sh.

CONF_FILE="${SCRIPT_DIR}/targets/${ARCH}.conf"
if [[ ! -f "${CONF_FILE}" ]]; then
  die "Unknown arch '${ARCH}'. Missing configuration file: ${CONF_FILE}"
fi

# Load target configuration
# shellcheck source=/dev/null
source "${CONF_FILE}"

# Validation
if [[ -z "${TARGET:-}" || -z "${KERNEL_ARCH:-}" ]]; then
  die "Target configuration ${CONF_FILE} must define TARGET and KERNEL_ARCH."
fi
