# RAVEN Pre-Alpha — GEMM RTL Verification

Python golden references were used to test the GEMM compute RTL developed by Michael.

## 1. Generate and test Python golden references

Run from the repository root:

```powershell
python tools/goldens/generate_prealpha.py
python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 --kind int8 --actual tests/vectors/prealpha/normal_8x16x8/expected_int8.bin
```

The generator creates INT8 activations/weights, biases, quantization parameters, and expected INT32/INT8 outputs. We also independently recalculated INT32 outputs and confirmed that the checker detects an intentionally incorrect output. Comparing a reference file against itself only checks the comparison tool; it does not test RTL.

## 2. Test the GEMM RTL using Python fixtures

Compile the testbench first, and again after RTL changes:

```powershell
python tests/rtl/compute/run_questa.py --demo-only
```

Then run:

```powershell
.\tools\goldens\run_compute_rtl.ps1 -Case normal
.\tools\goldens\run_compute_rtl.ps1 -Case signed
.\tools\goldens\run_compute_rtl.ps1 -Case partial
```

| Test | QuestaSim result |
|---|---|
| Normal GEMM (8×16 × 16×8) | PASS — 64/64 INT32 outputs |
| Signed inputs and nonzero zero-point | PASS — 64/64 INT32 outputs |
| Partial tile (7×13 × 13×5) | PASS — 35/35 INT32 outputs |

All three tests passed using independent Python expected values, with input/output stalls exercised.

## 3. Run the full GEMM compute regression

```powershell
.\tools\goldens\run_compute_rtl.ps1 -Case full
```

This runs the existing compute regression, including the MAC processing element, multiple array sizes, assertion checks, invalid fixtures, and reset/restart tests. The 8×8 core passed **42 fixtures and 3 in-flight reset/restart phases**.

**Note:** `normal`, `signed`, and `partial` use our Python golden fixtures. `full` runs the existing compute RTL regression fixtures.

## Evidence and remaining work

Screenshots: `evidence/prealpha/compute/`

These supplementary fixtures verify standalone INT32 compute outputs. They were
rechecked on merged revision `3577d48d063182e0e2e9560623f58cf0804621ae` using the
Python exporter and assertion-enabled Questa commands directly. The full compute
regression also passed 168 fixtures across four array sizes and 12 reset/restart phases.

The [connected integration suite](../../../README.md#run-the-integration-tests)
now covers command control, the actual activation/weight/parameter/output buffers,
per-channel parameter delivery, requantization/clamp and committed INT8 output.
T1–T15 pass in both buffered and direct configurations with 22 independently
compared INT8 dumps each. See the
[complete validation record](../../questa/final-prealpha/results.json) and
[test coverage](../../../tests/README.md#verified-pre-alpha-results).
Physical backing banks, processor/DMA, complete board implementation and full-model
execution remain future work.

-MD and Verification done by Jackie
