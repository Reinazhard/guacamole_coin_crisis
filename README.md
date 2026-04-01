# GNU Cross-Compiler Toolchain

## Overview

Personal build scripts for producing redistributable GNU cross-toolchains for ARM Linux targets, primarily used for cross-compiling Linux kernels from an `x86-64-v3` host. Builds a complete, self-contained sysroot-based toolchain from source across five stages (Binutils → Linux headers → GCC bootstrap → glibc → GCC final), pinned to specific upstream commits for reproducibility. Pre-built tarballs are published automatically to GitHub Releases on every push via CI.

## Prebuilt Binaries

Pre-built toolchain tarballs are available on the [Releases page](https://github.com/Reinazhard/guacamole_coin_crisis/releases).

## Package Contents

Each release tarball contains a complete cross-toolchain installed under `gcc-<arch>/`:

- **Binutils** — cross-assembler, linker, and binary utilities (`as`, `ld`, `objdump`, `nm`, etc.)
- **GCC** — C and C++ cross-compiler (`gcc`, `g++`)
- **libgcc / libstdc++** — GCC runtime and C++ standard library built for the target
- **glibc** — C library and sysroot headers for the target

## Supported Configurations

| Architecture | Target Triple | ABI | Kernel | GCC | Binutils | glibc |
|---|---|---|---|---|---|---|
| `arm64` | `aarch64-linux-gnu` | LP64, hard-float | 6.19 | 15 (`releases/gcc-15`) | 2.46 | 2.43 |
| `arm` | `arm-linux-gnueabihf` | EABI hard-float, VFPv3-D16 | 6.19 | 15 (`releases/gcc-15`) | 2.46 | 2.43 |

The `arm64` build includes Cortex-A53 errata workarounds (835769, 843419). Both targets are built with LTO, Graphite loop optimisations, and PIE/SSP enabled by default.

## Credits

Inspired by and referenced against the following projects:

- [GNU Devtools for Arm](https://gitlab.arm.com/tooling/gnu-devtools-for-arm) — Arm Ltd.'s canonical reference implementation for GNU toolchain builds targeting Arm platforms.
- [mvaisakh/gcc-build](https://github.com/mvaisakh/gcc-build) — Stripping script.
- [USBhost/build-tools-gcc](https://github.com/USBhost/build-tools-gcc) — GNU cross-toolchain build scripts for Android/Linux kernel development.

## License

GPL-3.0 — see [LICENSE](LICENSE).