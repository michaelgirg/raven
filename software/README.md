# Embedded software

Nahjay leads the RISC-V firmware/runtime. These are future implementation directories, not available APIs or executables.

| Directory | Intended contents |
|---|---|
| `apps/` | Self-test, single-operation examples, and model-demo entry points |
| `runtime/` | Model-blob validation, layer execution, tiling, scheduling, and CPU fallback kernels |
| `drivers/` | NPU, AXI DMA, stream-adapter, and interrupt drivers |
| `hal/` | Core/board-specific MMIO, fences, cache handling, timers, and platform access |
| `include/` | Public APIs, shared types, and generated register headers |
| `linker/` | Future linker scripts and reviewed firmware memory placement |
| `boot/` | Proposed A53 staging/loader sources and boot-image configuration/scripts |
| `tests/` | Host-runnable firmware tests using a mock HAL |

The baseline runs inference control and fallback kernels on the RISC-V. A53 code is for boot and file staging. See [RISC-V research](../docs/RISCV_Research.md) for the proposed API, memory ownership, and completion rules.

Keep firmware objects, ELFs, boot images, and map files under `build/software/`. End-to-end hardware/software checks belong in [tests/integration/](../tests/integration/).
