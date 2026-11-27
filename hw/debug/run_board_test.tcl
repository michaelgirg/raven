# Run the Ultra96-V2 MEMORY board test from a generated handoff.
#   vivado -mode batch -source <handoff>/run_board_test.tcl -tclargs [results-dir]
# The board should be on, connected by JTAG, and booted without an SD image.

namespace eval rvn_test {}

proc rvn_test::run_fixture {script args} {
    set saved_argv $::argv
    try {
        set ::argv $args
        uplevel #0 [list source $script]
    } finally {
        set ::argv $saved_argv
    }
}

proc rvn_test::main {handoff args} {
    if {[llength $args] > 1} { error {Usage: run_board_test.tcl [results-dir]} }
    set out [file normalize [expr {[llength $args] ? [lindex $args 0] : "build/prototype/board-test"}]]
    set fixture [file join $handoff normal_8x16x8]
    foreach rel {raven_board.bit psu_init.tcl build_info.txt board_bringup_xsdb.tcl
                 run_fixture.tcl normal_8x16x8/cmd.txt normal_8x16x8/expected_int8.hex} {
        if {![file isfile [file join $handoff $rel]]} {
            error "Missing $rel in $handoff. Generate a MEMORY handoff with hw/build.tcl -out0_memory 1."
        }
    }

    set fd [open [file join $handoff build_info.txt] r]
    set info [read $fd]
    close $fd
    if {![regexp -line {^out0_source:\s*MEMORY\s*$} $info]} {
        error "The board test requires a MEMORY bitstream."
    }

    set xsdb {}
    if {[info exists ::env(XILINX_VIVADO)]} {
        set launcher [expr {$::tcl_platform(platform) eq "windows" ? "xsdb.bat" : "xsdb"}]
        set xsdb [auto_execok [file join $::env(XILINX_VIVADO) bin $launcher]]
    }
    if {$xsdb eq ""} { set xsdb [auto_execok xsdb] }
    if {$xsdb eq ""} { error "XSDB was not found in the Vivado installation or on PATH." }

    file mkdir $out
    set bringup_log [file join $out bringup.log]
    set fixture_script [file join $handoff run_fixture.tcl]
    set out0 [file join $out out0.bin]
    open_hw_manager
    try {
        # Start the local server before XSDB connects. Open the target after programming.
        connect_hw_server -url localhost:3121
        set failed [catch {
            exec {*}$xsdb [file join $handoff board_bringup_xsdb.tcl] $handoff > $bringup_log 2>@1
        } message]
        set fd [open $bringup_log r]
        set transcript [read $fd]
        close $fd
        puts $transcript
        if {$failed || [string first RAVEN_BRINGUP_COMPLETE $transcript] < 0} {
            error "XSDB bring-up failed. See $bringup_log. $message"
        }

        open_hw_target
        run_fixture $fixture_script -smoke -no_connect

        # Replace the prior capture only after this run matches the golden bytes.
        set capture [file join $out ".out0-[pid].bin"]
        try {
            run_fixture $fixture_script -fixture $fixture -out $capture -timeout_ms 5000 -no_connect
            file rename -force $capture $out0
        } finally {
            if {[file exists $capture]} { file delete $capture }
        }
    } finally {
        catch {close_hw_target}
        catch {disconnect_hw_server}
        catch {close_hw_manager}
    }
    puts "RAVEN_BOARD_TEST_PASS (64/64 bytes). OUT0 saved to $out0"
}

rvn_test::main [file dirname [file normalize [info script]]] {*}$argv
