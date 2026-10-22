# Future repository automation

`workflows/` reserves the location for future GitHub Actions workflows. It currently contains only `.gitkeep`; no CI workflow runs or reports passing tests from this skeleton.

Add workflows when working commands exist for checks such as host tests, RTL simulation, register generation, or documentation validation. Pin the required environments and keep workflow commands consistent with the tested local build instructions. The control proposal places Vivado implementation on a lab workstation unless a suitable runner is configured.

Repository organization and ownership are documented in [the directory guide](../docs/REPOSITORY_STRUCTURE.md).
