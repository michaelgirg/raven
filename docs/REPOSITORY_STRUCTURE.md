# Repository structure

This layout reserves implementation locations for RAVEN while preserving the existing research documents and model paths. Empty implementation directories contain `.gitkeep` so Git retains them. The skeleton does not add RTL, firmware, tests, build commands, or measured results.

## Directory map

```text
raven/
├── README.md
├── .gitignore
├── .github/
│   ├── README.md
│   └── workflows/             # Future CI; no runnable workflow yet
├── configs/
│   ├── README.md
│   ├── hardware/              # Future named design presets
│   ├── models/                # Future model-export recipes
│   └── simulation/            # Future simulator/test-run presets
├── data/
│   ├── README.md
│   ├── raw/                   # Local datasets; contents Git-ignored
│   └── processed/             # Local prepared inputs; contents Git-ignored
├── docs/
│   ├── NPU_ARCHITECTURE.md
│   ├── NPU_Operators_Research.md
│   ├── Quantized_Models.md
│   ├── RAVEN_Memory_System_Research.md
│   ├── RISCV_Research.md
│   ├── REPOSITORY_STRUCTURE.md
│   ├── decisions/             # Architecture decision records
│   ├── diagrams/              # Editable diagram sources and reviewable exports
│   ├── guides/                # Setup, programming, troubleshooting, and handoff
│   ├── interfaces/            # Reviewed cross-subsystem contracts
│   ├── regs/                  # Planned generated register documentation
│   └── reports/               # Reviewed reports and measurement explanations
├── rtl/
│   ├── README.md
│   ├── common/                # Shared SV types, interfaces, and utilities
│   ├── compute/               # Michael: MAC core and compute frontends
│   ├── operators/             # Quan: output/support operators
│   ├── memory/                # Taylor: scratchpad, adapter, ownership
│   ├── control/               # Nahjay: CSR, queue, dispatch, IRQ/status
│   └── top/                   # RTL integration
├── hw/
│   ├── README.md              # Project/block-design Tcl belongs alongside this file
│   ├── constraints/           # Board and timing constraints
│   ├── debug/                 # Future ILA/JTAG/debug configuration and Tcl
│   └── ip/                    # Vendor-IP configuration sources
├── software/
│   ├── README.md
│   ├── apps/                  # Self-tests and demo entry points
│   ├── runtime/               # Layer executor, tiler, scheduling, CPU fallback
│   ├── drivers/               # NPU, DMA, adapter, interrupt drivers
│   ├── hal/                   # Core/platform-specific access and ordering
│   ├── include/               # Public headers and generated registers
│   ├── linker/                # Firmware memory placement/linker scripts
│   ├── boot/                  # A53 loader and boot configuration
│   └── tests/                 # Host firmware tests with a mock HAL
├── tools/
│   ├── README.md              # Version/dependency manifests added when validated
│   ├── benchmarks/            # Future host measurement/analysis scripts
│   ├── models/                # Jackie: inspect/export/pack/golden tools
│   └── regs/                  # Canonical SystemRDL and generator configuration
├── tests/
│   ├── README.md
│   ├── rtl/
│   │   ├── compute/
│   │   ├── operators/
│   │   ├── memory/
│   │   └── control/
│   ├── formal/                # Optional future property harnesses
│   ├── integration/           # Cross-subsystem simulation and board checks
│   ├── vectors/               # Small curated tensor fixtures
│   └── traces/                # Golden register transactions
├── benchmarks/
│   ├── README.md
│   ├── configs/               # Reproducible workload/run definitions
│   └── results/               # Reviewed measurement summaries
├── models/
│   ├── README.md
│   ├── DS-CNN/
│   ├── deep_autoencoder/
│   ├── modelnetv1/            # Existing directory spelling retained
│   ├── resnet-8/
│   └── streaming-ds-cnn/
└── third_party/
    └── README.md              # Upstream source dependencies if explicitly adopted
```

`build/` is the reserved, Git-ignored destination for local generated output. Build tools will create it when implemented; it is not part of the tracked directory skeleton.

The additional preset, dataset, debug, linker, decision, dependency, and automation locations are organizational provisions for future work. In particular, `tests/formal/` is optional; this layout does not add a formal-verification requirement.

## Where work belongs

| Work | Location | Accountable subsystem lead |
|---|---|---|
| MAC array, compute pipeline, Conv/GEMM mapping | `rtl/compute/`, `tests/rtl/compute/` | Michael |
| Requantization, ReLU, pooling, EWADD | `rtl/operators/`, `tests/rtl/operators/` | Quan |
| Scratchpad, stream adapter, memory ownership | `rtl/memory/`, `tests/rtl/memory/` | Taylor |
| MMIO/queue/control RTL and register definition | `rtl/control/`, `tools/regs/`, `tests/rtl/control/` | Nahjay, with interface review by consumers |
| RISC-V firmware, runtime, drivers, HAL | `software/` | Nahjay |
| Model inspection/export, packing, golden generation | `tools/models/`, original artifacts in `models/` | Jackie |
| Vivado/PS block design, vendor IP, board constraints | `hw/` | Taylor and Nahjay for their blocks; integration lead TBD |
| Shared RTL, end-to-end checks, benchmark releases | `rtl/common/`, `rtl/top/`, `tests/integration/`, `benchmarks/` | Name an individual lead for each integration milestone |

The named subsystem leads follow the research documents. Shared milestone ownership still needs team agreement.

## Source and generated files

- Keep synthesizable custom logic under `rtl/`; simulation-only harnesses belong under `tests/rtl/`.
- Keep Vivado recreation/programming scripts under `hw/`. Planned script names such as `create_project.tcl` and `bd.tcl` match the control proposal; they are not implemented by this skeleton.
- Keep the canonical register description under `tools/regs/`. The proposed generated destinations are `rtl/control/`, `software/include/`, and `docs/regs/`. Review source and outputs together.
- Keep original TFLite artifacts under their existing `models/` paths. Derived deployment blobs and bulk tensors go under `build/models/`.
- Use `build/hw/`, `build/software/`, `build/tests/`, and `build/benchmarks/` for local generated products. Waveforms, bitstreams, ELFs, caches, and logs are build output.
- Small intentional test fixtures and reviewed benchmark summaries may be tracked in `tests/vectors/`, `tests/traces/`, or `benchmarks/results/`; include provenance and reproduction instructions.
- Local dataset contents in `data/raw/` and `data/processed/` are ignored. Keep their `.gitkeep` files to preserve the directory paths; record download/preprocessing provenance with the relevant configuration.
- Use `configs/` for named presets consumed by tooling, keeping canonical registers, vendor-IP configuration, and benchmark workload definitions in their existing designated locations.
- Adopt vendored upstream code under `third_party/` deliberately, with exact revisions and applicable notices. Package manifests and generated vendor products have their own locations.
- Retain `.gitkeep` until a source directory gains a real source or documentation file, then remove the unnecessary placeholder. The ignored dataset directories keep their placeholder exceptions.

## Implementation documentation

Each top-level implementation area has a README describing its role. Keep setup/run commands with the actual working implementation and record tested dependencies when available. Add a root Makefile or CI jobs once their commands perform real checks; this skeleton supplies neither.

The five research documents remain the current proposals. Put future reviewed interface contracts under `docs/interfaces/`, editable diagrams under `docs/diagrams/`, and setup/handoff material under `docs/guides/`, then link them from the relevant research document and root README. Until ratified, keep proposed choices labeled as proposals.
