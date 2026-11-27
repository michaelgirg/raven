# Out-of-context synthesis check of the board prototype wrapper (Phase 3 of
# docs/plans/nahjay_board_prototype.md). Run from any writable build directory:
#   vivado -mode batch -source <repo>/hw/check_board_synthesis.tcl -tclargs <repo> <output>
# Synthesizes raven_board_top_v (the Verilog shell the block design uses) in PATTERN mode
# at the 50 MHz bring-up clock. This catches non-synthesizable constructs and gives a
# resource/timing estimate before the block design exists. It is not the board build.
if {$argc != 2} {
    error "Usage: vivado -mode batch -source check_board_synthesis.tcl -tclargs <repo> <output>"
}
set root [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {![file isfile [file join $root rtl board raven_board_top_v.v]]} {
    error "Source checkout must contain rtl/board/raven_board_top_v.v"
}
file mkdir $out
set part xczu3eg-sbva484-1-i ;# Ultra96-V2 board part
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
    rtl/board/raven_axil_bridge.sv
    rtl/board/raven_out0_pattern.sv
    rtl/board/raven_board_top.sv
} {
    read_verilog -sv [file join $root $source]
}
read_verilog [file join $root rtl board raven_board_top_v.v]
# 50 MHz pl_clk0. AXI ports are internal to the block design, so I/O delays are left
# unconstrained here; only register-to-register paths are meaningful.
set clockfile [file join $out board_clock.xdc]
set fd [open $clockfile w]
puts $fd {create_clock -name pl_clk0 -period 20.000 [get_ports aclk]}
close $fd
read_xdc $clockfile
# OUT0_SOURCE defaults to "PATTERN". With the bank ports tied idle, synthesis trims logic
# that can only be reached through bank data, so utilization here is a lower bound and
# not the cost of the full NPU; hw/check_npu_synthesis.tcl remains the NPU estimate.
synth_design -top raven_board_top_v -part $part -mode out_of_context
report_utilization -hierarchical -file [file join $out utilization_synth.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $out timing_synth.rpt]
report_timing -from [all_registers] -to [all_registers] -max_paths 10 -file [file join $out internal_timing_synth.rpt]
write_checkpoint -force [file join $out synthesis.dcp]
# Fail the batch run on critical warnings or negative internal setup slack.
set critical [get_msg_config -count -severity {CRITICAL WARNING}]
set slack [get_property SLACK [get_timing_paths -from [all_registers] -to [all_registers] -max_paths 1 -setup]]
puts "RAVEN_BOARD_SYNTHESIS critical_warnings=$critical internal_setup_slack=$slack part=$part"
if {$critical > 0} { error "Synthesis reported $critical critical warnings" }
if {$slack ne "" && $slack < 0} { error "Negative internal setup slack: $slack ns" }
puts "RAVEN_BOARD_SYNTHESIS_COMPLETE"
exit
