# RAVEN board host script for Vivado Hardware Manager (JTAG-to-AXI). Copied into the build
# handoff by hw/build.tcl. Run board_bringup_xsdb.tcl first so the PL clock is running.
#
# Batch:
#   vivado -mode batch -source run_fixture.tcl -tclargs -smoke
#   vivado -mode batch -source run_fixture.tcl -tclargs -fixture <fixture-dir> [-out out0.bin]
# GUI Tcl console (hardware target already open): set argv {-smoke -no_connect}; source run_fixture.tcl
#
# Options:
#   -smoke               bus checks plus a NOP START->DONE (works with the PATTERN build)
#   -fixture <dir>       run a GEMM from <dir>/cmd.txt (export_fixtures.py output) and dump OUT0
#   -out <file>          OUT0 dump for -fixture (default build/prototype/out0.bin)
#   -bytes <n>           OUT0 bytes to dump, a multiple of 4 (default 64)
#   -timeout_ms <ms>     completion poll limit (default 2000)
#   -soft_reset          issue SOFT_RESET first if the NPU is busy, halted or in error
#   -url <host:port>     hw_server (default localhost:3121)
#   -probes <file.ltx>   probes file, if Hardware Manager asks for one
#   -no_connect          use the hardware target already open in this Vivado session
#
# The register procedure follows docs/interfaces/RAVEN_BOARD_PROTOTYPE_INTERFACE.md. Every
# access is one aligned 32-bit AXI4-Lite transaction. The script ends with RAVEN_SMOKE_PASS,
# RAVEN_FIXTURE_DONE or an error.

namespace eval rvn {
    variable base 0xA4000000
    variable out0 0xA4002000
    # Register offsets (rtl/control/raven_ctrl_pkg.sv).
    variable ID 0x000; variable VERSION 0x004; variable CTRL 0x010; variable STATUS 0x014
    variable IRQ_STATUS 0x01C; variable NEXT_SEQ 0x020; variable DONE_SEQ 0x024
    variable ERR_CODE 0x028; variable ERR_INFO 0x02C; variable OPCODE 0x030; variable P3 0x04C
    variable NPU_ID 0x5241564E
    variable axi ""
    variable checks 0
}

# ------------------------------------------------------------------ transport
proc rvn::txn {type addr {data 0}} {
    variable axi
    set a [format %08X $addr]
    if {$type eq "write"} {
        create_hw_axi_txn -force rvn_txn $axi -type write -address $a -data [format %08X $data] -len 1
    } else {
        create_hw_axi_txn -force rvn_txn $axi -type read -address $a -len 1
    }
    # run_hw_axi fails on SLVERR/DECERR responses.
    if {[catch {run_hw_axi -quiet [get_hw_axi_txns rvn_txn]} msg]} {
        catch {reset_hw_axi $axi}
        return [list 0 $msg]
    }
    if {$type eq "write"} { return [list 1 0] }
    # Parse as unsigned: scan %x would make words with bit 31 set negative.
    set hex [string range [get_property DATA [get_hw_axi_txns rvn_txn]] end-7 end]
    return [list 1 [expr {"0x$hex" & 0xFFFFFFFF}]]
}

proc rvn::wr {addr data} {
    lassign [txn write $addr $data] ok msg
    if {!$ok} { error "AXI write [format %08X $addr] failed: $msg" }
}

proc rvn::rd {addr} {
    lassign [txn read $addr] ok value
    if {!$ok} { error "AXI read [format %08X $addr] failed: $value" }
    return $value
}

proc rvn::csr_wr {off data} { variable base; wr [expr {$base + $off}] $data }
proc rvn::csr_rd {off} { variable base; return [rd [expr {$base + $off}]] }

proc rvn::expect {what got exp} {
    variable checks
    incr checks
    if {($got & 0xFFFFFFFF) != ($exp & 0xFFFFFFFF)} { error [format "CHECK FAILED: %s: got %08X expected %08X" $what $got $exp] }
    puts [format "  ok  %-34s %08X" $what $got]
}

proc rvn::expect_error {what type addr {data 0}} {
    variable checks
    incr checks
    lassign [txn $type $addr $data] ok msg
    if {$ok} { error [format "CHECK FAILED: %s: %s %08X succeeded; expected an AXI error" $what $type $addr] }
    puts [format "  ok  %-34s AXI error as expected" $what]
}

# OUT0 byte p reads p[7:0]^0x5A in the PATTERN build (rtl/board/raven_out0_pattern.sv).
proc rvn::pattern_word {offset} {
    set w 0
    for {set n 0} {$n < 4} {incr n} {
        set w [expr {$w | (((($offset + $n) & 0xFF) ^ 0x5A) << (8 * $n))}]
    }
    return $w
}

proc rvn::diagnostics {} {
    variable STATUS; variable ERR_CODE; variable ERR_INFO; variable IRQ_STATUS
    variable NEXT_SEQ; variable DONE_SEQ
    foreach {name off} [list STATUS $STATUS IRQ_STATUS $IRQ_STATUS ERR_CODE $ERR_CODE \
                             ERR_INFO $ERR_INFO NEXT_SEQ $NEXT_SEQ DONE_SEQ $DONE_SEQ] {
        if {[catch {puts [format "  %-10s %08X" $name [csr_rd $off]]} msg]} { puts "  $name unreadable: $msg" }
    }
}

# Busy, halted or error: optionally SOFT_RESET, otherwise stop with diagnostics.
proc rvn::require_idle {soft_reset} {
    variable STATUS; variable CTRL
    set s [csr_rd $STATUS]
    if {($s & 0x7) == 0} { return }
    if {!$soft_reset} {
        diagnostics
        error [format "NPU not idle (STATUS %08X); rerun with -soft_reset to issue SOFT_RESET" $s]
    }
    puts [format "RAVEN: STATUS %08X, issuing SOFT_RESET" $s]
    csr_wr $CTRL 0x2
    set s [csr_rd $STATUS]
    if {($s & 0x7) != 0} { diagnostics; error [format "Still not idle after SOFT_RESET (STATUS %08X)" $s] }
}

# START the staged command and wait for retirement. Returns the command sequence.
proc rvn::start_and_wait {timeout_ms} {
    variable IRQ_STATUS; variable NEXT_SEQ; variable CTRL; variable STATUS; variable DONE_SEQ
    set seq [expr {[csr_rd $NEXT_SEQ] & 0xFFFF}]
    csr_wr $CTRL 0x1
    set deadline [expr {[clock milliseconds] + $timeout_ms}]
    while 1 {
        set s [csr_rd $STATUS]
        set irq [csr_rd $IRQ_STATUS]
        if {$s & 0x4} { diagnostics; error [format "NPU reported an error (STATUS %08X)" $s] }
        if {$s & 0x2} { diagnostics; error [format "NPU halted (STATUS %08X)" $s] }
        if {($irq & 0x1) && !($s & 0x1)} break
        if {[clock milliseconds] > $deadline} {
            diagnostics
            error "No DONE within $timeout_ms ms (a GEMM never completes in the PATTERN build)"
        }
    }
    expect "DONE_SEQ matches NEXT_SEQ" [expr {[csr_rd $DONE_SEQ] & 0xFFFF}] $seq
    return $seq
}

# ------------------------------------------------------------------ modes
proc rvn::smoke {soft_reset timeout_ms} {
    variable ID; variable VERSION; variable NPU_ID; variable P3; variable out0; variable base
    variable OPCODE; variable IRQ_STATUS; variable STATUS
    puts "RAVEN smoke test"
    expect "ID (RAVN)" [csr_rd $ID] $NPU_ID
    expect "VERSION" [csr_rd $VERSION] 0x00000001
    puts [format "  --  %-34s %08X" STATUS [csr_rd $STATUS]]
    csr_wr $P3 0x12345678
    expect "staging P3 write/read" [csr_rd $P3] 0x12345678
    csr_wr $P3 0
    for {set off 0} {$off < 0x40} {incr off 4} {
        expect [format "OUT0 pattern +0x%03X" $off] [rd [expr {$out0 + $off}]] [pattern_word $off]
    }
    expect "OUT0 pattern +0x1FFC" [rd [expr {$out0 + 0x1FFC}]] [pattern_word 0x1FFC]
    expect_error "unmapped hole read" read [expr {$base + 0x1000}]
    expect_error "OUT0 write rejected" write $out0 0
    expect_error "outside window (interconnect)" read [expr {$base + 0x4000}]
    expect "ID after error responses" [csr_rd $ID] $NPU_ID
    # Live START -> DONE through the controller with a NOP (no memory needed).
    require_idle $soft_reset
    csr_wr $IRQ_STATUS 0x1
    csr_wr $OPCODE 0x00000000
    set seq [start_and_wait $timeout_ms]
    puts [format "  ok  %-34s seq %d" "NOP START -> DONE" $seq]
    csr_wr $IRQ_STATUS 0x1
}

proc rvn::fixture {dir out bytes soft_reset timeout_ms} {
    variable IRQ_STATUS; variable out0
    set cmd [file join $dir cmd.txt]
    if {![file isfile $cmd]} { error "Missing $cmd (generate with tests/rtl/integration/export_fixtures.py)" }
    set pairs {}
    set fd [open $cmd r]
    foreach line [split [read $fd] \n] {
        if {[string trim $line] eq ""} continue
        if {[scan $line "%x %x" off value] != 2} { close $fd; error "Bad cmd.txt line: $line" }
        lappend pairs $off $value
    }
    close $fd
    puts "RAVEN fixture [file tail $dir]: [expr {[llength $pairs] / 2}] staging writes"

    require_idle $soft_reset
    csr_wr $IRQ_STATUS 0x1
    foreach {off value} $pairs { csr_wr $off $value }
    set seq [start_and_wait $timeout_ms]
    puts "  ok  command $seq retired"

    file mkdir [file dirname $out]
    set fd [open $out wb]
    for {set off 0} {$off < $bytes} {incr off 4} {
        puts -nonewline $fd [binary format i [rd [expr {$out0 + $off}]]]
    }
    close $fd
    puts "Wrote $bytes bytes to $out. Compare with:"
    puts "  python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/[file tail $dir] --kind int8 --actual $out"
}

# ------------------------------------------------------------------ main
proc rvn::main {argv} {
    variable axi
    set mode ""; set dir ""; set out build/prototype/out0.bin; set bytes 64
    set timeout_ms 2000; set soft_reset 0; set url localhost:3121; set probes ""; set connect 1
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set opt [lindex $argv $i]
        switch -- $opt {
            -smoke      { set mode smoke }
            -fixture    { set mode fixture; set dir [lindex $argv [incr i]] }
            -out        { set out [lindex $argv [incr i]] }
            -bytes      { set bytes [lindex $argv [incr i]] }
            -timeout_ms { set timeout_ms [lindex $argv [incr i]] }
            -soft_reset { set soft_reset 1 }
            -url        { set url [lindex $argv [incr i]] }
            -probes     { set probes [lindex $argv [incr i]] }
            -no_connect { set connect 0 }
            default     { error "Unknown option $opt (see the header of run_fixture.tcl)" }
        }
    }
    if {$mode eq ""} { error "Choose -smoke or -fixture <dir>" }
    if {$bytes % 4 || $bytes <= 0 || $bytes > 0x2000} { error "-bytes must be a positive multiple of 4, at most 8192" }

    if {$connect} {
        open_hw_manager
        connect_hw_server -url $url
        open_hw_target
    }
    set dev [lindex [get_hw_devices -quiet xczu*] 0]
    if {$dev eq ""} { error "No Zynq UltraScale+ device on the JTAG chain: [get_hw_devices]" }
    current_hw_device $dev
    if {$probes ne ""} { set_property PROBES.FILE $probes $dev }
    refresh_hw_device $dev
    set axi [lindex [get_hw_axis -quiet] 0]
    if {$axi eq ""} {
        error "No JTAG-to-AXI core found. Run board_bringup_xsdb.tcl first (the PL clock must be running), then retry."
    }
    reset_hw_axi $axi

    if {$mode eq "smoke"} {
        smoke $soft_reset $timeout_ms
        puts "RAVEN_SMOKE_PASS ($::rvn::checks checks)"
    } else {
        fixture $dir $out $bytes $soft_reset $timeout_ms
        puts "RAVEN_FIXTURE_DONE ($::rvn::checks checks)"
    }
}

rvn::main $argv
