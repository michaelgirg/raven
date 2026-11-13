# Run from any writable build directory:
# vivado -mode batch -source check_npu_synthesis.tcl -tclargs <repo> <output> <buffered:0|1>
# Out-of-context estimate only: this is not the complete board design.
if {$argc != 3 || [lindex $argv 2] ni {0 1}} {
    error "Usage: vivado -mode batch -source check_npu_synthesis.tcl -tclargs <reviewed-repo> <output> <buffered:0|1>"
}
set root [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set buffered [lindex $argv 2]
if {![file isfile [file join $root rtl memory raven_read_buffer_adapter.sv]]} {
    error "Source checkout must contain PR #4 or revision bf944c1749310a615bb6b7924edeb3b453fc21f9"
}
file mkdir $out
set part xczu3eg-sbva484-1-e
set_param general.maxThreads 4
create_project -in_memory -part $part
foreach source {
    rtl/control/raven_ctrl_pkg.sv
    rtl/control/raven_ctrl_regs.sv
    rtl/control/raven_ctrl.sv
    rtl/compute/raven_mac_pe.sv
    rtl/compute/raven_mac_array.sv
    rtl/compute/raven_gemm_frontend.sv
    rtl/compute/raven_gemm_core.sv
    rtl/operators/raven_requantize_clamp.sv
    rtl/memory/activation_buffer.sv
    rtl/memory/weight_buffer.sv
    rtl/memory/parameter_buffer.sv
    rtl/memory/output_buffer.sv
    rtl/memory/raven_integrity_pkg.sv
    rtl/memory/raven_read_buffer_adapter.sv
    rtl/memory/raven_output_buffer_adapter.sv
    rtl/top/raven_requant.sv
    rtl/top/raven_result_writer.sv
    rtl/top/raven_npu_top.sv
} {
    read_verilog -sv [file join $root $source]
}
set clockfile [file join $out estimate_clock.xdc]
set fd [open $clockfile w]
puts $fd {create_clock -name npu_clk -period 10.000 [get_ports clk_i]}
close $fd
read_xdc $clockfile
synth_design -top raven_npu_top -part $part -mode out_of_context -generic USE_TILE_BUFFERS=$buffered
report_utilization -hierarchical -file [file join $out utilization_synth.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $out timing_synth.rpt]
report_timing -from [all_registers] -to [all_registers] -max_paths 10 -file [file join $out internal_timing_synth.rpt]
write_checkpoint -force [file join $out synthesis.dcp]
puts "RAVEN_SYNTHESIS_COMPLETE buffered=$buffered part=$part"
exit
