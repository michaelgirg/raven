# Benchmark definitions and results

This directory is reserved for future measurements. No measured RAVEN performance is supplied yet.

- `configs/`: versioned workload definitions, model hashes, input shapes, tile settings, clock/configuration choices, and comparison baselines.
- `results/`: reviewed result summaries, such as CSV/JSON tables and a short description of how each measurement was produced.

Record the hardware/firmware commit, tool versions, model identity, run configuration, and measurement method with results. Include DMA and CPU-fallback time in end-to-end latency. Keep measured values separate from analytical MAC-rate/bandwidth ceilings.

Large raw profiles, waveforms, and temporary benchmark output go in `build/benchmarks/`. Longer explanations and exported report figures can go in [docs/reports/](../docs/reports/). Each subsystem owner supplies its measurements; the integrated benchmark lead is TBD.
