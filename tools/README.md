# Host-side tooling

This directory is reserved for host-side scripts and their future dependency manifests. No exporter or register generator is implemented yet.

- `benchmarks/`: future host-side benchmark runners, counter/profile parsers, and measurement-analysis scripts. Workload definitions and reviewed summaries live in `benchmarks/configs/` and `benchmarks/results/` at the repository root.
- `models/`: model inspection/export, weight packing, corrected-bias and quantization records, tensor planning, and golden-reference generation. Jackie leads this area with the numeric/compute owners.
- `regs/`: canonical SystemRDL register source and generation configuration. Nahjay leads this area with Taylor, Michael, and Quan reviewing shared fields.
- Root of `tools/`: shared helpers, a tested `VERSIONS.md`, and dependency/version-check files when introduced and validated.

The register-generation proposal writes CSR RTL to `rtl/control/`, C headers to `software/include/`, and register documentation to `docs/regs/`. Review generated outputs together with the canonical source; do not fix only a generated copy.

Read the [model inventory](../docs/Quantized_Models.md), [numeric proposal](../docs/NPU_Operators_Research.md), and [register proposal](../docs/RISCV_Research.md) before implementing conversions. Original `.tflite` artifacts remain in [models/](../models/); generated model blobs and bulk tensors belong under `build/models/`.
