# Build the RAVEN Ultra96-V2 board prototype from a clean checkout (Phase 5 of
# docs/plans/nahjay_board_prototype.md). From the repository root:
#   vivado -mode batch -source hw/build.tcl [-tclargs -jobs 8 -out <dir> -out0_memory 0]
#
# Steps: recreate the project (create_project.tcl), synthesize, implement and write the
# bitstream; check the implemented clk_pl_0 is 50 MHz with non-negative setup and hold
# slack; write reports; export the hardware platform; collect the board handoff:
# <out> defaults to build/hw/board.
#   <out>/handoff/raven_board.bit      PL bitstream
#   <out>/handoff/raven_board.ltx      debug probes file (if Vivado wrote one)
#   <out>/handoff/raven_board.xsa      hardware platform (includes the bitstream)
#   <out>/handoff/psu_init.tcl         PS initialization matching this build
#   <out>/handoff/board_bringup_xsdb.tcl, run_fixture.tcl   board-side scripts
#   <out>/handoff/build_info.txt       revision, options, clock and timing summary
#   <out>/reports/*.rpt
# The batch run fails (non-zero exit) if any step or check fails.

source [file join [file dirname [info script]] create_project.tcl]

proc raven::run_or_fail {run} {
    if {[get_property PROGRESS [get_runs $run]] ne "100%"} {
        error "Run $run did not complete: [get_property STATUS [get_runs $run]]"
    }
}

proc raven::build {} {
    variable root; variable out; variable jobs; variable bd_name; variable out0_memory
    variable pl0_period_ns; variable pl0_mhz; variable base_addr; variable window

    set reports [file join $out reports]
    set handoff [handoff_dir]
    file delete -force $handoff
    file mkdir $reports $handoff

    # Implementation through the bitstream; synthesis and IP out-of-context runs follow.
    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1
    run_or_fail synth_1
    run_or_fail impl_1

    open_run impl_1
    report_utilization -hierarchical -file [file join $reports utilization_impl.rpt]
    report_utilization -file [file join $reports utilization_summary_impl.rpt]
    report_timing_summary -max_paths 10 -report_unconstrained -file [file join $reports timing_summary_impl.rpt]
    report_clocks -file [file join $reports clocks_impl.rpt]
    report_drc -file [file join $reports drc_impl.rpt]
    report_methodology -file [file join $reports methodology_impl.rpt]

    # The PL clock is the requested 50 MHz: in the PS configuration and in the timing graph.
    set ps [get_bd_cells -quiet /zynq_ultra_ps_e_0]
    if {$ps eq ""} { open_bd_design [get_files $bd_name.bd]; set ps [get_bd_cells /zynq_ultra_ps_e_0] }
    set actual_mhz [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]
    set clk [get_clocks -quiet clk_pl_0]
    if {[llength $clk] != 1} { error "Expected one clk_pl_0 clock in the implemented design, found: $clk" }
    set period [get_property PERIOD $clk]
    if {abs($period - $pl0_period_ns) > 0.2} {
        error "clk_pl_0 period is $period ns; expected $pl0_period_ns ns ($pl0_mhz MHz)"
    }
    if {abs($actual_mhz - $pl0_mhz) > 0.5} {
        error "PS reports pl_clk0 at $actual_mhz MHz; expected $pl0_mhz MHz"
    }

    # Timing is met.
    set setup [get_timing_paths -max_paths 1 -nworst 1 -setup]
    set hold [get_timing_paths -max_paths 1 -nworst 1 -hold]
    set wns [expr {$setup eq "" ? "none" : [get_property SLACK $setup]}]
    set whs [expr {$hold eq "" ? "none" : [get_property SLACK $hold]}]
    if {$wns eq "none" || $whs eq "none"} { error "No timed paths found; check the clock constraints" }
    if {$wns < 0 || $whs < 0} { error "Timing not met: WNS $wns ns, WHS $whs ns" }
    set wns [format %.3f $wns]; set whs [format %.3f $whs]

    # Bitstream and probes.
    set impl_dir [get_property DIRECTORY [get_runs impl_1]]
    set bit [file join $impl_dir ${bd_name}_wrapper.bit]
    if {![file isfile $bit]} { error "Bitstream not found: $bit" }
    file copy -force $bit [file join $handoff raven_board.bit]
    set ltx [file join $handoff raven_board.ltx]
    if {[catch {write_debug_probes -force $ltx} msg]} { puts "RAVEN: no debug probes file ($msg)" }

    # Hardware platform and the PS initialization generated for this exact configuration.
    write_hw_platform -fixed -include_bit -force [file join $handoff raven_board.xsa]
    set psu [get_files -quiet -all -of_objects [get_files $bd_name.bd] -filter {NAME =~ *psu_init.tcl}]
    if {[llength $psu] == 0} {
        set gen [file join [get_property DIRECTORY [current_project]] [current_project].gen]
        set psu [glob -nocomplain -directory $gen -types f */*/*/*/*/psu_init.tcl */*/*/*/*/*/psu_init.tcl]
    }
    if {[llength $psu] != 1} { error "Expected one generated psu_init.tcl, found: $psu" }
    file copy -force [lindex $psu 0] [file join $handoff psu_init.tcl]

    foreach f {hw/debug/board_bringup_xsdb.tcl hw/debug/run_fixture.tcl} {
        file copy -force [file join $root $f] $handoff
    }

    # Build record.
    set fd [open [file join $handoff build_info.txt] w]
    puts $fd "RAVEN board prototype build"
    puts $fd "built: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %Z}]"
    puts $fd "vivado: [version -short]"
    puts $fd "git: [git_revision]"
    puts $fd "part: [get_property PART [current_project]]  board: [get_property BOARD_PART [current_project]]"
    puts $fd "out0_source: [expr {$out0_memory ? {MEMORY} : {PATTERN}}]"
    puts $fd "raven window: $base_addr, $window (JTAG-to-AXI address space)"
    puts $fd "pl_clk0: $actual_mhz MHz (clk_pl_0 period $period ns)"
    puts $fd "timing: WNS $wns ns, WHS $whs ns"
    puts $fd "bring-up: see the header of board_bringup_xsdb.tcl, then run_fixture.tcl -smoke"
    close $fd

    puts "RAVEN_BUILD_COMPLETE pl_clk0=${actual_mhz}MHz WNS=$wns WHS=$whs handoff=$handoff"
}

raven::build
