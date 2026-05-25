# SPDX-License-Identifier: GPL-3.0
#
# Target resolution and configuration loading.
# Sourced by build.sh.

case "${ARCH}" in
  "arm64")
    # Canonical GNU triple for 64-bit ARM Linux cross-compiler.
    # "none" vendor field is the GNU/ARM standard for bare cross-toolchains.
    TARGET="aarch64-linux-gnu"
    KERNEL_ARCH="arm64"

    # ABI flag: lp64 is the only valid 64-bit ABI for aarch64-linux. This
    # is a compiler identity declaration, not a tuning flag — it affects
    # the psABI used for calling conventions and structure layout.
    #
    # Errata flags: these enable linker workarounds for two widely-deployed
    # Cortex-A53 hardware bugs. They cost nothing in performance and are
    # correctness fixes, not optimisation. See:
    #   835769: incorrect result from certain multiply-accumulate instructions
    #   843419: ADRP instruction may produce wrong result in rare sequences
    EXTRA_GCC_FLAGS=(
      "--with-abi=lp64"
      "--enable-fix-cortex-a53-835769"
      "--enable-fix-cortex-a53-843419"
    )
    ;;
  "arm")
    # Hard-float ARMv7-A cross-compiler.
    # gnueabihf = GNU EABI, hard-float — this is an ABI declaration,
    # not a tuning flag. It sets the calling convention for floating-point.
    TARGET="arm-linux-gnueabihf"
    KERNEL_ARCH="arm"

    # --with-float=hard and --with-fpu are ABI declarations here:
    # they tell GCC which ABI the sysroot was built against so it
    # can link correctly. The specific FPU model is NOT specified
    # (which would be tuning); we only declare the ABI class.
    EXTRA_GCC_FLAGS=(
      "--with-float=hard"
      "--with-fpu=vfpv3-d16"
    )
    ;;
  *)
    die "Unknown arch '${ARCH}'. Valid: arm64 | arm"
    ;;
esac

CONF_FILE="${SCRIPT_DIR}/targets/${TARGET}.conf"
if [[ -f "${CONF_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONF_FILE}"
fi
