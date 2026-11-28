# Host verification

The [workflow](workflows/verify.yml) checks Markdown paths and headings, tests
the Questa warning parser, and compares the captured board output with the
independent golden fixture on pull requests and pushes to `main`.

Run the same host checks with Python 3.12 from the repository root.

```sh
python tools/verification/check_doc_links.py
python -m unittest discover -s tests/rtl -p test_questa_log.py
python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 --kind int8 --actual evidence/vivado/board-prototype/live-gemm/out0.bin
```

Run Questa regressions and Vivado programming on a machine with the required
tools and hardware. The CI comparison checks the saved capture.
[Test commands](../tests/README.md#run-the-main-suites) · [Hardware instructions](../hw/README.md#run-the-full-board-test)

Repository organization and ownership are documented in [the directory guide](../docs/REPOSITORY_STRUCTURE.md).
