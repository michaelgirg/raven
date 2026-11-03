# RAVEN pre-alpha: verify the GEMM compute RTL.
# Run from the repository root with:
#   .\tools\goldens\run_compute_rtl.ps1 -Case normal
#   .\tools\goldens\run_compute_rtl.ps1 -Case signed
#   .\tools\goldens\run_compute_rtl.ps1 -Case partial
#   .\tools\goldens\run_compute_rtl.ps1 -Case full
# For normal/signed/partial, compile first and after RTL changes:
#   python tests/rtl/compute/run_questa.py --demo-only

param(
    [ValidateSet('normal', 'signed', 'partial', 'full')]
    [string]$Case = 'normal'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$caseNames = @{
    normal  = 'normal_8x16x8'
    signed  = 'signed_nonzero_zp_stalled'
    partial = 'partial_tile_7x13x5'
}
$outputNames = @{
    normal  = 'jackie_compute'
    signed  = 'jackie_signed_compute'
    partial = 'jackie_partial_compute'
}

Push-Location $repoRoot
try {
    $buildDir = 'build/tests/compute/questa'

    if ($Case -eq 'full') {
        # Run the existing full compute regression, including reset/restart.
        Write-Host 'Running full GEMM compute regression...'
        & python tests/rtl/compute/run_questa.py
        if ($LASTEXITCODE -ne 0) { throw 'Full GEMM regression failed.' }

        $run = Get-ChildItem $buildDir -Directory -Filter 'run_*' |
            Where-Object { Test-Path (Join-Path $_.FullName 'core-8x8.console.log') } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if (-not $run) { throw 'Full regression finished, but the 8x8 log was not found.' }

        $logPath = Join-Path $run.FullName 'core-8x8.console.log'
        $summary = Select-String -Path $logPath `
            -Pattern 'PASS CORE 8x8: (\d+) fixtures and (\d+) in-flight reset/restart phases' |
            Select-Object -Last 1
        if (-not $summary) { throw "8x8 PASS/reset summary not found: $logPath" }

        Write-Host 'PASS: Full GEMM compute regression.'
        Write-Host "8x8 summary: $($summary.Line.Trim())"
        Write-Host "Evidence: $($run.FullName)"
        return
    }

    # Convert the selected independent Python reference to the compute fixture format.
    $caseDir = "tests/vectors/prealpha/$($caseNames[$Case])"
    $outputDir = "build/tests/prealpha/$($outputNames[$Case])"
    & python tools/goldens/export_compute_fixture.py --case $caseDir --output $outputDir
    if ($LASTEXITCODE -ne 0) { throw 'Fixture export failed.' }
    $fixture = (Resolve-Path $outputDir).Path.Replace('\', '/')

    # Reuse a compiled QuestaSim run (compile again whenever RTL changes).
    if (-not (Test-Path $buildDir)) {
        throw 'No compiled Questa run found. Run: python tests/rtl/compute/run_questa.py --demo-only'
    }
    $run = Get-ChildItem $buildDir -Directory -Filter 'run_*' |
        Where-Object {
            (Test-Path (Join-Path $_.FullName 'run_batch.do')) -and
            (Test-Path (Join-Path $_.FullName 'work'))
        } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $run) {
        throw 'No compiled Questa run found. Run: python tests/rtl/compute/run_questa.py --demo-only'
    }

    $logName = "jackie_${Case}_gemm.log"
    Write-Host "Running '$Case' GEMM RTL test..."
    Push-Location $run.FullName
    try {
        & vsim -c -onfinish exit -t 1ps -sva -immedassert `
            -l $logName -gROWS=8 -gCOLS=8 work.tb_raven_gemm_core `
            "+FIXTURES=$fixture" '+DEMO_ONLY' -do 'do run_batch.do'
        $exitCode = $LASTEXITCODE
        if (-not (Test-Path $logName)) { throw "Simulation log not found: $logName" }
        $logText = Get-Content $logName -Raw
        if ($exitCode -ne 0 -or
            $logText -notmatch 'PASS GEMM 8x8 case 0\b[^\r\n]*\berror=0\b' -or
            $logText -notmatch 'PASS CORE 8x8: 1 fixtures' -or
            $logText -notmatch 'Errors: 0, Warnings: 0') {
            throw "RTL simulation did not pass. See $($run.FullName)\$logName"
        }
        Write-Host "PASS: $Case GEMM RTL matched the Python golden reference."
        Write-Host "Log: $($run.FullName)\$logName"
    }
    finally { Pop-Location }
}
finally { Pop-Location }
