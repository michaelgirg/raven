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

Screenshots: `docs/logs/prealpha/gemm_verification/`

Standalone INT32 GEMM verification passed for the tests above. A separate
[requantization/clamp implementation and bench](../../../rtl/operators/README.md)
now provide standalone INT8-tail coverage. These GEMM fixtures still check only
the compute INT32 outputs; they do not pass through that tail or the
[activation buffer](../../../rtl/memory/README). Integration with memory,
per-channel parameters, command control and output storage still needs a
connected testbench and end-to-end checking.

-MD and Verification done by Jackie
