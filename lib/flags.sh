# SPDX-License-Identifier: GPL-3.0
#
# Flags and optimizations philosophy.
# Sourced by build.sh.

# Sanitize environment
unset CFLAGS CXXFLAGS LDFLAGS

# Check for mold linker availability
MOLD_FLAG=""
if command -v mold &>/dev/null; then
  MOLD_FLAG="-fuse-ld=mold"
else
  warn "mold linker not found, falling back to default linker."
fi

BUILD_CFLAGS="-O3 -pipe -march=x86-64-v3 -fomit-frame-pointer"
BUILD_CXXFLAGS="-O3 -pipe -march=x86-64-v3 -fomit-frame-pointer"

HOST_CFLAGS="-O3 -pipe -march=x86-64-v3 -fno-semantic-interposition -flto=auto -fno-fat-lto-objects -fipa-pta -fno-plt -falign-functions=32 -fomit-frame-pointer"
HOST_CXXFLAGS="-O3 -pipe -march=x86-64-v3 -fno-semantic-interposition -flto=auto -fno-fat-lto-objects -fipa-pta -fno-plt -falign-functions=32 -fomit-frame-pointer"
HOST_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--sort-common -Wl,-z,relro -Wl,-z,now ${MOLD_FLAG} -flto=auto"

TARGET_CFLAGS="-O3 -pipe -fgraphite-identity -floop-nest-optimize -fno-semantic-interposition -fipa-pta -fstack-protector-strong -fstack-clash-protection -Wp,-D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections -fomit-frame-pointer"
TARGET_CXXFLAGS="-O3 -pipe -fgraphite-identity -floop-nest-optimize -fno-semantic-interposition -fipa-pta -fstack-protector-strong -fstack-clash-protection -Wp,-D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections -fomit-frame-pointer"
TARGET_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--sort-common -Wl,--enable-new-dtags"
