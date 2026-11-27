# Shared settings for the RAVEN Ultra96-V2 board prototype scripts.
# Sourced by create_project.tcl, bd.tcl and build.tcl; not run on its own.
#
# Options (pass after -tclargs; all optional):
#   -out <dir>          build directory (default <repo>/build/hw/board). On Windows keep it
#                       short: Vivado's debug-core step fails if its temp path exceeds 146
#                       characters (checked up front by raven::check_path_length).
#   -jobs <n>           parallel Vivado jobs (default 4)
#   -out0_memory <0|1>  0: pattern OUT0 source for bring-up; 1: raven_memory_banks preloaded
#                       with the fixture in fixture_dir (GEMM demo)
#   -board_part <name>  board part to use instead of the newest installed Ultra96-V2 one

namespace eval raven {
    variable root [file normalize [file join [file dirname [info script]] ..]]
    variable out [file join $root build hw board]
    variable jobs 4
    variable out0_memory 0
    variable board_part ""
    # The Ultra96-V2 board file selects the industrial-grade part; match it here.
    variable part xczu3eg-sbva484-1-i
    variable project_name raven
    variable bd_name raven_bd
    # Address map seen by the JTAG-to-AXI master (interface doc: 0xA4000000, 16 KiB window).
    variable base_addr 0xA4000000
    variable window 16K
    # Single PL clock for bring-up (B9).
    variable pl0_mhz 50
    variable pl0_period_ns 20.000

    # Synthesizable sources, in compile order.
    variable rtl_sources {
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
        rtl/memory/raven_bram_bank.sv
        rtl/memory/raven_memory_banks.sv
        rtl/memory/raven_integrity_pkg.sv
        rtl/memory/raven_read_buffer_adapter.sv
        rtl/memory/raven_output_buffer_adapter.sv
        rtl/top/raven_requant.sv
        rtl/top/raven_result_writer.sv
        rtl/top/raven_npu_top.sv
        rtl/board/raven_axil_bridge.sv
        rtl/board/raven_out0_pattern.sv
        rtl/board/raven_board_top.sv
        rtl/board/raven_board_top_v.v
    }
    # BRAM init images for -out0_memory 1 (export_fixtures.py output, see hw/fixtures/).
    variable fixture_dir hw/fixtures/normal_8x16x8
    variable fixture_images {act.hex wgt.hex prm.hex}
    variable xdc_sources {
        hw/constraints/raven_board.xdc
    }
}

proc raven::parse_args {argv} {
    variable out; variable jobs; variable out0_memory; variable board_part
    if {[llength $argv] % 2} { error "Options take one value each: $argv" }
    foreach {opt val} $argv {
        switch -- $opt {
            -out         { set out [file normalize $val] }
            -jobs        { set jobs $val }
            -out0_memory { set out0_memory $val }
            -board_part  { set board_part $val }
            default      { error "Unknown option '$opt'. See hw/board_settings.tcl for the options." }
        }
    }
    if {$out0_memory ni {0 1}} { error "-out0_memory takes 0 or 1" }
    if {![string is integer -strict $jobs] || $jobs < 1} { error "-jobs takes a positive integer" }
}

# Newest installed Ultra96-V2 board part, or a clear error explaining how to install it.
# The PS DDR and MIO settings come from the board preset, so a bare part is not enough.
proc raven::find_board_part {} {
    variable board_part
    if {$board_part ne ""} { return $board_part }
    set parts [get_board_parts -quiet -latest_file_version {avnet.com:ultra96v2:*}]
    if {[llength $parts] == 0} {
        # Boards installed from the Vivado Store are not always on the board search path in
        # batch mode; add the store's local directory and look again.
        catch {
            set store [get_property LOCAL_ROOT_DIR [xhub::get_xstores xilinx_board_store]]
            set_param board.repoPaths [concat [get_param board.repoPaths] [list $store]]
            set parts [get_board_parts -quiet -latest_file_version {avnet.com:ultra96v2:*}]
        }
    }
    if {[llength $parts] == 0} {
        error "Ultra96-V2 board files are not installed. In the Vivado Tcl console run:\n\
            xhub::refresh_catalog \[xhub::get_xstores xilinx_board_store\]\n\
            xhub::install \[xhub::get_xitems avnet.com:xilinx_board_store:Ultra96v2:1.2\]\n\
            or pass -board_part <name>."
    }
    return [lindex [lsort -dictionary $parts] end]
}

# Commit and dirty state for the build record. Windows Vivado usually has no git on its
# PATH, so fall back to reading .git directly (dirty state is then unknown).
proc raven::git_revision {} {
    variable root
    if {![catch {exec git -C $root rev-parse HEAD} rev]} {
        set dirty unknown
        catch {set dirty [expr {[string trim [exec git -C $root status --porcelain]] eq "" ? "no" : "yes"}]}
        return "[string trim $rev] (uncommitted changes: $dirty)"
    }
    set git [file join $root .git]
    if {![file isdirectory $git]} { return "unknown" }
    set fd [open [file join $git HEAD]]; set head [string trim [read $fd]]; close $fd
    if {![string match "ref: *" $head]} { return "$head (detached; uncommitted changes: unknown)" }
    set ref [string range $head 5 end]
    if {[file isfile [file join $git $ref]]} {
        set fd [open [file join $git $ref]]; set rev [string trim [read $fd]]; close $fd
        return "$rev on $ref (uncommitted changes: unknown)"
    }
    if {[file isfile [file join $git packed-refs]]} {
        set fd [open [file join $git packed-refs]]; set lines [split [read $fd] \n]; close $fd
        foreach line $lines {
            if {[lindex $line 1] eq $ref} { return "[lindex $line 0] on $ref (uncommitted changes: unknown)" }
        }
    }
    return "unknown ($ref)"
}

proc raven::project_dir {} {
    variable out
    return [file join $out prj]
}

# On Windows, debug-core insertion (the JTAG-to-AXI dbg_hub) fails when the implementation
# run's temp directory, <project>/<name>.runs/impl_1/.Xil/Vivado-<pid>-<host>, is longer than
# 146 characters. Estimate it before spending time on synthesis.
proc raven::check_path_length {} {
    variable project_name
    global tcl_platform
    if {$tcl_platform(platform) ne "windows"} return
    set tmp [file join [project_dir] $project_name.runs impl_1 .Xil Vivado-000000-[info hostname]]
    set len [string length $tmp]
    if {$len > 146} {
        error "The Vivado temp path would be about $len characters (limit 146):\n  $tmp\n\
            Pass a shorter build directory, e.g. -tclargs -out C:/rvn"
    }
    puts "RAVEN: implementation temp path is about $len characters (limit 146)"
}

proc raven::handoff_dir {} {
    variable out
    return [file join $out handoff]
}
