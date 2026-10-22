# Local datasets

This directory reserves local storage for future model evaluation and demo inputs. No dataset downloader or dataset files are supplied.

- `raw/`: original downloaded datasets, ignored by Git except for the directory placeholder.
- `processed/`: generated/preprocessed evaluation inputs, likewise ignored except for the placeholder.

Document each dataset's source/version, applicable usage terms, split, checksum, and preprocessing recipe in the relevant export/benchmark configuration. Put download/preprocessing code in [tools/models/](../tools/models/) when implemented. Large dataset contents stay local; Git tracks only the placeholders and this guide.

Original `.tflite` artifacts belong in [models/](../models/). Small reviewed test fixtures belong in [tests/vectors/](../tests/vectors/) with their reproduction method; generated model blobs and bulk tensor dumps belong under `build/models/`.
