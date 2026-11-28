# Host-side tooling

This directory contains host-side scripts and reserves locations for future tooling and dependency manifests.

## Tool setup

| Task | Tools |
|---|---|
| Host checks and fixture tools | Python 3.12.10 tested locally. CI uses Python 3.12. These checks use the standard library. |
| RTL simulation | Questa Intel Starter FPGA Edition 2021.2 verified with SVA active. Put the tools on `PATH` or set `QUESTA_BIN`. |
| Board build and live demo | Vivado and XSDB 2025.2, with Zynq UltraScale+ support and Ultra96-V2 board files. |
| Optional model inspection and export | TensorFlow 2.20.0 and NumPy 2.2.6 verified with Python 3.12.10. |

Install the optional model dependencies in an activated virtual environment
using `python -m pip install tensorflow==2.20.0 numpy==2.2.6`. Both AD01 scripts
resolve the committed model relative to their own location. The extractor
writes tensors and metadata under `build/models/ad01/`.
[Model tools](models/) · [RTL tests](../tests/README.md#run-the-main-suites) · [Board setup](../hw/README.md)

## Directory guide

- `benchmarks/`: future host-side benchmark runners, counter/profile parsers, and measurement-analysis scripts. Workload definitions and reviewed summaries live in `benchmarks/configs/` and `benchmarks/results/` at the repository root.
- `goldens/`: pre-alpha fixture generation, byte comparison and standalone RTL golden checks. Reviewed verification notes are under [evidence/prealpha/](../evidence/prealpha/); input fixtures remain under [tests/vectors/prealpha/](../tests/vectors/prealpha/).
- `models/`: model inspection/export, weight packing, corrected-bias and quantization records, tensor planning, and golden-reference generation. Jackie leads this area with the numeric/compute owners.
- `regs/`: canonical SystemRDL register source and generation configuration. Nahjay leads this area with Taylor, Michael, and Quan reviewing shared fields.
- `verification/`: Markdown link checks and buffered/direct cycle measurements.
  Use the pinned revision for reproducing the original FPGA review. [Reproduction instructions](../docs/reviews/RAVEN_BOARD_READINESS_REVIEW.md#reproduce-the-checks)

The register-generation proposal writes CSR RTL to `rtl/control/`, C headers to `software/include/`, and register documentation to `docs/regs/`. Review generated outputs together with the canonical source; do not fix only a generated copy.

Read the [model inventory](../docs/Quantized_Models.md), [numeric proposal](../docs/NPU_Operators_Research.md), and [register proposal](../docs/RISCV_Research.md) before implementing conversions. Original `.tflite` artifacts remain in [models/](../models/); generated model blobs and bulk tensors belong under `build/models/`.
