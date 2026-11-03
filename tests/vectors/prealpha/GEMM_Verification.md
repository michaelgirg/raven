# RAVEN Pre-Alpha Golden Reference Testing

Generate Python golden references and use them to verify the GEMM compute RTL developed by Michael.

## 1. Generate the golden references

Run from the RAVEN repository root:

```powershell
python tools/goldens/generate_prealpha.py
```

This creates INT8 activation and weight matrices, biases, quantization parameters, and expected INT32/INT8 outputs in `tests/vectors/prealpha/`.

## 2. Test the Python comparison script

```powershell
python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 --kind int8 --actual tests/vectors/prealpha/normal_8x16x8/expected_int8.bin
```

Expected: **PASS, 0 mismatches**. An intentionally modified output file was also used to confirm that the checker detects incorrect values. These checks validate the comparison tool, not the RTL.

## 3. Test the GEMM RTL in QuestaSim

Compile the testbench first (and again after RTL changes):

```powershell
python tests/rtl/compute/run_questa.py --demo-only
```

Then run the tests with the Python-generated fixtures:

```powershell
.\tools\goldens\run_compute_rtl.ps1 -Case normal
.\tools\goldens\run_compute_rtl.ps1 -Case signed
.\tools\goldens\run_compute_rtl.ps1 -Case partial
```

The script exports each fixture, runs the RTL simulation, checks the result, and saves a log.

## Results

| Test | RTL result |
|---|---|
| Normal GEMM (8×16 × 16×8) | PASS — 64/64 INT32 outputs |
| Signed inputs with nonzero zero-point | PASS — 64/64 INT32 outputs |
| Partial tile (7×13 × 13×5) | PASS — 35/35 INT32 outputs |

All three runs reported zero simulation errors and exercised input/output stalls. These tests cover the INT32 compute core, not INT8 requantization or full-system integration.

-ReadME and Verification done Jackie
