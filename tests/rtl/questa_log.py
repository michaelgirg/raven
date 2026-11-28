"""Classify diagnostic lines shared by the Questa and ModelSim runners."""
import re


DIAGNOSTIC = re.compile(
    r'^\s*#?\s*(?:\*\*\s*)?(Warning|Error|Fatal)(?:\s+\([^)]+\))?:\s*(.*)$'
)
ERROR_COUNT = re.compile(r'^\s*#?\s*Errors:\s*[1-9]')
MESSAGE_CODE = re.compile(r'\(([a-z]+-\d+)\)')
ENVIRONMENT_WARNINGS = {'vlib-223', 'vmap-223', 'vlog-223', 'vsim-223', 'vopt-223'}
NO_SVA_WARNINGS = {'vlog-2186', 'vsim-8311'}


def has_unexpected_diagnostics(transcript, *, allow_no_sva=False):
    """Return whether the run reported an error or a warning outside the allowlist."""
    for line in transcript.splitlines():
        if ERROR_COUNT.match(line):
            return True
        diagnostic = DIAGNOSTIC.match(line)
        if not diagnostic:
            continue
        level, message = diagnostic.groups()
        if level != 'Warning':
            return True
        match = MESSAGE_CODE.search(message)
        code = match[1] if match else None
        if code == 'vopt-10587':
            continue  # Questa warns that +acc limits optimization.
        if code in ENVIRONMENT_WARNINGS and 'environment variable MGC_HOME' in message:
            continue
        if allow_no_sva and code in NO_SVA_WARNINGS:
            continue
        return True
    return False
