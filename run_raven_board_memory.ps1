# Run from the RAVEN repo root. Requires Questa 'vlib', 'vlog', 'vsim' on PATH.
$ErrorActionPreference = 'Stop'
$repo = (Get-Location).Path
if (-not (Test-Path 'tests/rtl/board/run_questa.py')) {
    throw 'Run this script from the RAVEN repository root.'
}

# Export full 128-bit memory images plus cmd.txt.
python tests/rtl/integration/export_fixtures.py --output build/prototype/fixtures
if ($LASTEXITCODE -ne 0) { throw 'Fixture exporter failed' }

$fixture = Join-Path $repo 'build/prototype/fixtures/normal_8x16x8'
foreach ($name in @('act.hex','wgt.hex','prm.hex','cmd.txt')) {
    if (-not (Test-Path (Join-Path $fixture $name))) { throw "Missing fixture $name" }
}

# Isolated Questa working directory; avoid modifying the passing pattern regression.
$build = Join-Path $repo 'build/tests/board/memory_functional'
New-Item -ItemType Directory -Force $build | Out-Null

# cmd.txt path used by tb_raven_board_memory below.
$relativeFixture = 'build/prototype/fixtures/normal_8x16x8'
$dest = Join-Path $build $relativeFixture
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $fixture '*.hex') $dest -Force
Copy-Item (Join-Path $fixture 'cmd.txt') $dest -Force
# raven_board_top loads act.hex/wgt.hex/prm.hex by bare name from the vsim directory.
Copy-Item (Join-Path $fixture '*.hex') $build -Force

# The runner's canonical source list + BRAM modules + our new TB.
$sources = @(python -c "import runpy; d=runpy.run_path(r'$repo/tests/rtl/board/run_questa.py'); print(*(str(p) for p in d['SOURCES']), sep='\n')")
# SOURCES already includes rtl/memory/raven_bram_bank.sv and raven_memory_banks.sv.
$memory = @()
$tb = Join-Path $repo 'tests/rtl/board/tb_raven_board_memory.sv'
if (-not (Test-Path $tb)) { throw "Copy tb_raven_board_memory.sv into $tb first" }

Push-Location $build
try {
    if (-not (Test-Path 'work')) { vlib work; if ($LASTEXITCODE -ne 0) {throw 'vlib failed'} }
    vlog -sv -timescale 1ns/1ps -work work @sources @memory $tb
    if ($LASTEXITCODE -ne 0) { throw 'vlog compilation failed' }

    vsim -c -sva -immedassert -voptargs='+acc' -l memory-functional.log `
       work.tb_raven_board_memory `
       '+CMD=build/prototype/fixtures/normal_8x16x8/cmd.txt' '+OUT=out0.bin' `
       -do 'onerror {quit -code 1}; run -all; quit -f'
    if ($LASTEXITCODE -ne 0) { throw 'Questa functional simulation failed; inspect memory-functional.log' }
    if (-not (Select-String -Path 'memory-functional.log' -Pattern 'BOARD_MEMORY_READBACK_PASS' -Quiet)) {
        throw 'Functional test did not report PASS; inspect memory-functional.log'
    }
    if ((Get-Item 'out0.bin').Length -ne 64) { throw 'OUT0 file is not 64 bytes' }
} finally {
    Pop-Location
}

New-Item -ItemType Directory -Force 'build/prototype' | Out-Null
Copy-Item (Join-Path $build 'out0.bin') 'build/prototype/out0.bin' -Force
python tools/goldens/compare_prealpha.py `
    --case tests/vectors/prealpha/normal_8x16x8 `
    --kind int8 --actual build/prototype/out0.bin
if ($LASTEXITCODE -ne 0) { throw 'Golden comparison failed' }
Write-Host 'MEMORY MODE: 64/64 board-wrapper simulation match' -ForegroundColor Green
