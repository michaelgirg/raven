# Inspect an out-of-context NPU checkpoint; this does not run a board build.
if {$argc != 2} {
    error "Usage: vivado -mode batch -source check_staging_integrity_netlist.tcl -tclargs <synthesis.dcp> <report.rpt>"
}
open_checkpoint [file normalize [lindex $argv 0]]
set parity_cells [get_cells -hier -filter {NAME =~ *parity_q_reg*}]
set error_cells [get_cells -hier -filter {NAME =~ *integrity_error_o_reg*}]
set fd [open [file normalize [lindex $argv 1]] w]
puts $fd "Retained parity registers: [llength $parity_cells]"
puts $fd "Retained integrity error registers: [llength $error_cells]"
set instances {}
for {set b 0} {$b < 6} {incr b} {
    lappend instances [format {g_read_ports[%d].g_buffered.u_adapter/} $b]
}
lappend instances {g_output_buffer.u_adapter/}
foreach instance $instances {
    set parity_count 0
    set error_count 0
    foreach cell $parity_cells {if {[string first $instance $cell] >= 0} {incr parity_count}}
    foreach cell $error_cells {if {[string first $instance $cell] >= 0} {incr error_count}}
    puts $fd "$instance parity=$parity_count integrity_errors=$error_count"
    if {$parity_count == 0 || $error_count == 0} {
        close $fd
        error "Integrity state missing from $instance"
    }
}
foreach cell $parity_cells {puts $fd $cell}
foreach cell $error_cells {puts $fd $cell}
close $fd
puts "RAVEN_INTEGRITY_NETLIST_PASS parity=[llength $parity_cells] errors=[llength $error_cells]"
exit
