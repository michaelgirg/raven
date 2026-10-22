# Candidate model artifacts

The five existing subdirectories contain the original quantized TFLite candidates used by the research documents. Their presence does not establish FPGA support.

See [Quantized Models Research](../docs/Quantized_Models.md) for source revisions, shapes, operators, quantization, parameter counts, and execution candidates. Jackie leads model analysis/export.

Preserve existing model paths and original artifacts so research references remain reproducible. Record provenance and a checksum when adding or intentionally replacing a model. Host inspection/export code belongs in [tools/models/](../tools/models/); generated deployment blobs and bulk tensor dumps belong under `build/models/`.

Small test fixtures may be committed in [tests/vectors/](../tests/vectors/) with their generation method. Keep large datasets and temporary conversion products outside this source directory.
