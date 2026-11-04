# Host-side tooling

This directory contains host-side scripts and reserves locations for future tooling and dependency manifests.

- `benchmarks/`: future host-side benchmark runners, counter/profile parsers, and measurement-analysis scripts. Workload definitions and reviewed summaries live in `benchmarks/configs/` and `benchmarks/results/` at the repository root.
- `goldens/`: pre-alpha fixture generation, byte comparison and standalone RTL golden checks. Reviewed verification notes are under [evidence/prealpha/](../evidence/prealpha/); input fixtures remain under [tests/vectors/prealpha/](../tests/vectors/prealpha/).
- `models/`: model inspection/export, weight packing, corrected-bias and quantization records, tensor planning, and golden-reference generation. Jackie leads this area with the numeric/compute owners.
- `regs/`: canonical SystemRDL register source and generation configuration. Nahjay leads this area with Taylor, Michael, and Quan reviewing shared fields.
- `verification/`: isolated buffered/direct pipeline cycle measurements for the [FPGA readiness review](../docs/reviews/RAVEN_BOARD_READINESS_REVIEW.md#reproduce-the-checks); requires the PR #4 source checkout, Python and Questa.
- Root of `tools/`: shared helpers, a tested `VERSIONS.md`, and dependency/version-check files when introduced and validated.

The register-generation proposal writes CSR RTL to `rtl/control/`, C headers to `software/include/`, and register documentation to `docs/regs/`. Review generated outputs together with the canonical source; do not fix only a generated copy.

Read the [model inventory](../docs/Quantized_Models.md), [numeric proposal](../docs/NPU_Operators_Research.md), and [register proposal](../docs/RISCV_Research.md) before implementing conversions. Original `.tflite` artifacts remain in [models/](../models/); generated model blobs and bulk tensors belong under `build/models/`.
