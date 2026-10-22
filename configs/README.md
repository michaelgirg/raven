# Shared configuration presets

These folders reserve space for future versioned run/design presets. They contain no validated configurations yet.

| Directory | Intended contents |
|---|---|
| `hardware/` | Named compute-array, lane-count, memory-layout, and clock presets consumed by future build tooling |
| `models/` | Export recipes referencing original model paths/hashes, input shapes, numeric conventions, and deployment options |
| `simulation/` | Simulator/run options, selected tests, seeds, and configuration manifests |

Keep actual Vivado/IP recreation sources in [hw/](../hw/), canonical registers in [tools/regs/](../tools/regs/), and benchmark workloads in [benchmarks/configs/](../benchmarks/configs/). Reference those sources instead of copying their definitions here. A preset becomes usable only when its consuming tool and validation exist.

Subsystem owners review their fields; shared presets need review by all affected owners. Keep proposed settings labeled until ratified and tested.
