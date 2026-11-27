# Out-of-context inference check for the physical ACT/WGT/PARAM/OUT0 banks.
# Run from any writable directory:
#   vivado -mode batch -source <repo>/hw/check_memory_banks_synthesis.tcl -tclargs <repo> <output>
# This is a bank-memory inference check, not a complete NPU or board build.
if {$argc != 2} {
    error "Usage: vivado -mode batch -source check_memory_banks_synthesis.tcl -tclargs <repo> <output>"
}
set root [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {![file isfile [file join $root rtl memory raven_bram_bank.sv]] ||
    ![file isfile [file join $root rtl memory raven_memory_banks.sv]]} {
    error "Source checkout must contain raven_bram_bank.sv and raven_memory_banks.sv"
}

file mkdir $out
set part xczu3eg-sbva484-1-e
set_param general.maxThreads 4
create_project -in_memory -part $part
foreach source {
    rtl/memory/raven_bram_bank.sv
    rtl/memory/raven_memory_banks.sv
} {
    read_verilog -sv [file join $root $source]
}

set clockfile [file join $out memory_banks_clock.xdc]
set fd [open $clockfile w]
puts $fd {create_clock -name bank_clk -period 10.000 [get_ports clk_i]}
close $fd
read_xdc $clockfile

synth_design -top raven_memory_banks -part $part -mode out_of_context
report_utilization -hierarchical -file [file join $out utilization_synth.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $out timing_synth.rpt]
write_checkpoint -force [file join $out synthesis.dcp]

set ramb36_count [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}]]
set ramb18_count [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB18*}]]
set inferred_bram_bits [expr {$ramb36_count * 36 * 1024 + $ramb18_count * 18 * 1024}]
set expected_storage_bits [expr {(4 * 16 * 1024 + 2 * 4 * 1024 + 8 * 1024) * 8}]
puts "RAVEN_MEMORY_BANKS_SYNTHESIS part=$part RAMB36=$ramb36_count RAMB18=$ramb18_count inferred_bram_bits=$inferred_bram_bits expected_storage_bits=$expected_storage_bits"
if {$inferred_bram_bits < $expected_storage_bits} {
    error "Inferred BRAM capacity is below the aggregate's 80 KiB logical storage"
}
puts "RAVEN_MEMORY_BANKS_SYNTHESIS_COMPLETE"
exit
