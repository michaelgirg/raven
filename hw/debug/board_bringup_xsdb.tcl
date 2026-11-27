# RAVEN Ultra96-V2 bring-up over JTAG (xsdb). Copied into the build handoff by hw/build.tcl.
#
#   xsdb board_bringup_xsdb.tcl [handoff-dir] [hw_server-url]
#
# handoff-dir defaults to this script's directory and must hold raven_board.bit and
# psu_init.tcl from the same build. hw_server-url defaults to the local server.
#
# There is no first-stage boot loader in this demo, so the PS (including pl_clk0 and the
# PL reset) must be initialized over JTAG before the JTAG-to-AXI core can run:
#   1. reset the system
#   2. program the PL with raven_board.bit
#   3. run psu_init (clocks, DDR, MIO; starts pl_clk0 at 50 MHz)
#   4. remove PS-PL isolation and pulse the PL reset (pl_resetn0)
# Afterwards, in Vivado Hardware Manager (same hw_server), refresh the device and run
# run_fixture.tcl -smoke. Re-run this script after any power cycle or board reset.
#
# Board setup: Ultra96-V2 with a JTAG pod on J3 (e.g. AES-ACC-U96-JTAG). Set the boot mode
# switch SW3 to JTAG, or boot with no SD card, so no SD image takes over the PS.

set here [file dirname [file normalize [info script]]]
set dir [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : $here}]
set url [expr {[llength $argv] > 1 ? [lindex $argv 1] : ""}]
set bit [file join $dir raven_board.bit]
set psu [file join $dir psu_init.tcl]
foreach f [list $bit $psu] {
    if {![file isfile $f]} { error "Missing $f; pass the handoff directory from hw/build.tcl" }
}

if {$url eq ""} { connect } else { connect -url $url }
puts "RAVEN: targets on the JTAG chain:"
puts [targets]

proc raven_select_psu {} {
    if {[catch {targets -set -nocase -filter {name =~ "*PSU*"}} msg]} {
        error "No PSU target found ($msg). Check the JTAG pod on J3, power, and boot mode."
    }
}

# 1. System reset.
raven_select_psu
rst -system
after 1000

# 2. Program the PL.
raven_select_psu
puts "RAVEN: programming $bit"
fpga -file $bit

# 3-4. PS initialization from this build, then release the PL.
raven_select_psu
source $psu
puts "RAVEN: running psu_init"
psu_init
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
catch {psu_protection}

puts "RAVEN_BRINGUP_COMPLETE: PS initialized, PL programmed, pl_resetn0 released."
puts "Next: in Vivado Hardware Manager, open the target, refresh the xczu3 device, then"
puts "      source run_fixture.tcl with -smoke."
