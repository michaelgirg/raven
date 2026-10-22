# Explicitly vendored dependencies

This directory is reserved for upstream source dependencies if the team chooses to vendor them or add submodules. No third-party source or processor core is bundled here yet.

For each future dependency, record its upstream repository, exact revision, local patches, and update procedure, and retain its applicable license/notices. Agree the dependency before importing it.

Python/tool package versions belong in the future manifests under [tools/](../tools/). Vivado vendor-IP configuration belongs in [hw/ip/](../hw/ip/); generated vendor build products belong under `build/hw/`. Reference research projects from documentation without copying their code into this folder automatically.
