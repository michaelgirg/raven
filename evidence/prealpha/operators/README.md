# RAVEN Pre-Alpha — Requantization RTL Verification

Python golden references were used to test the INT32-to-INT8 requantization and clamp RTL developed by Quan.

## 1. Generate and test Python golden references

Run from the repository root:

```powershell
python tools/goldens/generate_prealpha.py
python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/rounding_ties --kind int8 --actual tests/vectors/prealpha/rounding_ties/expected_int8.bin
```

The generator creates expected INT32 and INT8 results using saved quantization parameters. Comparing a reference file against itself checks the comparison tool only; it does not test RTL.

## 2. Run the existing requantization RTL regression

```powershell
python tests/rtl/operators/run_questa.py
```

The standalone QuestaSim testbench passed rounding, clamping, output tags, stalls/backpressure, reset, and consecutive inputs.

## 3. Test requantization RTL using Python fixtures

```powershell
python tools/goldens/run_requant_golden.py --case rounding_ties
python tools/goldens/run_requant_golden.py --case positive_negative_saturation
python tools/goldens/run_requant_golden.py --case channel_scales_relu_clamp
python tools/goldens/run_requant_golden.py --case normal_8x16x8
python tools/goldens/run_requant_golden.py --case signed_nonzero_zp_stalled
python tools/goldens/run_requant_golden.py --case partial_tile_7x13x5
```

| Test | QuestaSim result |
|---|---|
| Rounding ties | PASS — 8/8 INT8 outputs |
| Positive/negative saturation | PASS — 64/64 INT8 outputs |
| Per-channel scaling and ReLU clamping | PASS — 64/64 INT8 outputs |
| Normal GEMM output | PASS — 64/64 INT8 outputs |
| Signed inputs and nonzero zero-point | PASS — 64/64 INT8 outputs |
| Partial tile | PASS — 35/35 INT8 outputs |

All six tests passed against the Python golden references: **299/299 INT8 outputs matched**.

**Note:** These tests feed the saved INT32 reference values into Quan's RTL. They do not run Michael's GEMM core and Quan's requantization pipeline together.

## Evidence and remaining work

Screenshots: `evidence/prealpha/operators/`

Standalone requantization verification passed for the tests above. Integration with the GEMM core, memory buffers, per-channel parameter loading, command control, and output storage still needs a connected testbench and end-to-end checking.

-MD and Verification done by Jackie
