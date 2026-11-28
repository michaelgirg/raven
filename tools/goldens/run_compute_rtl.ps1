# Run a named compute fixture or the complete Questa regression.
param(
    [ValidateSet('normal', 'signed', 'partial', 'full')]
    [string]$Case = 'normal'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$runner = Join-Path $repo 'tests/rtl/compute/run_questa.py'
$fixtures = @{
    normal  = 'normal_8x16x8'
    signed  = 'signed_nonzero_zp_stalled'
    partial = 'partial_tile_7x13x5'
}

if ($Case -eq 'full') {
    & python $runner
} else {
    $fixture = Join-Path $repo "tests/vectors/prealpha/$($fixtures[$Case])"
    & python $runner --fixture-case $fixture
}
if ($LASTEXITCODE -ne 0) { throw "Compute verification failed for '$Case'." }
