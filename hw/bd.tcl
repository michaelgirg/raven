# Block design for the RAVEN board prototype (Phase 5 of docs/plans/nahjay_board_prototype.md).
# Sourced by create_project.tcl with the project open; not run on its own.
#
#   zynq_ultra_ps_e (Ultra96-V2 preset)
#     pl_clk0 (50 MHz) -----------+------------------+-----------------+-----------------+
#     pl_resetn0 -> proc_sys_reset |                  |                 |                 |
#                     | peripheral_aresetn ----------- jtag_axi_0 ---> smartconnect ---> raven_board_0
#                     | interconnect_aresetn ---------------------------^          (raven_board_top_v)
#
# The JTAG-to-AXI master (AXI4-Lite) reaches the RAVEN slave at 0xA4000000-0xA4003FFF;
# SmartConnect answers any other address with DECERR. Every PS-PL AXI port is disabled:
# the host reaches the design only over JTAG for this demo.

# Setting PL0_REF_CTRL__FREQMHZ from Tcl does not make the PS IP recompute its clock
# dividers: the Ultra96-V2 preset keeps IOPLL/15/1 = 100 MHz. Derive the source PLL
# frequency from the current setting, choose DIVISOR0/DIVISOR1 for the requested
# frequency, and stop if the IP's actual frequency is still wrong.
proc raven::set_pl0_clock {ps mhz} {
    set prefix CONFIG.PSU__CRL_APB__PL0_REF_CTRL__
    set act [get_property ${prefix}ACT_FREQMHZ $ps]
    set src [expr {$act * [get_property ${prefix}DIVISOR0 $ps] * [get_property ${prefix}DIVISOR1 $ps]}]
    set best {}
    for {set d1 1} {$d1 <= 63} {incr d1} {
        for {set d0 1} {$d0 <= 63} {incr d0} {
            set err [expr {abs($src / ($d0 * $d1) - $mhz)}]
            if {$best eq "" || $err < [lindex $best 0]} { set best [list $err $d0 $d1] }
        }
    }
    lassign $best err d0 d1
    set_property -dict [list ${prefix}DIVISOR0 $d0 ${prefix}DIVISOR1 $d1] $ps
    set act [get_property ${prefix}ACT_FREQMHZ $ps]
    set pin [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]]
    puts "RAVEN: pl_clk0 source [format %.3f $src] MHz / $d0 / $d1 = $act MHz (pin FREQ_HZ $pin)"
    if {abs($act - $mhz) > 0.5 || abs($pin - $mhz * 1e6) > 0.5e6} {
        error "pl_clk0 is $act MHz (pin $pin Hz) after setting dividers; expected $mhz MHz"
    }
}

proc raven::create_bd {} {
    variable bd_name; variable base_addr; variable window; variable pl0_mhz; variable out0_memory

    create_bd_design $bd_name

    # Processing system with the board preset (DDR, MIO, clocks), then only what we use.
    set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
    set_property -dict [list \
        CONFIG.PSU__USE__M_AXI_GP0 {0} \
        CONFIG.PSU__USE__M_AXI_GP1 {0} \
        CONFIG.PSU__USE__M_AXI_GP2 {0} \
        CONFIG.PSU__USE__IRQ0 {0} \
        CONFIG.PSU__USE__IRQ1 {0} \
        CONFIG.PSU__FPGA_PL0_ENABLE {1} \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $pl0_mhz \
        CONFIG.PSU__NUM_FABRIC_RESETS {1} \
    ] $ps
    set_pl0_clock $ps $pl0_mhz

    # Board reset synchronized to pl_clk0 (B6).
    set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl_clk0]

    # JTAG-to-AXI master in AXI4-Lite mode (PROTOCOL 2), 32-bit address and data.
    set jtag [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0]
    set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_AXI_DATA_WIDTH {32} CONFIG.M_AXI_ADDR_WIDTH {32}] $jtag

    # One-to-one interconnect: decodes the 16 KiB window and returns DECERR elsewhere.
    set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc

    # RAVEN wrapper through the Verilog shell (B8).
    set raven [create_bd_cell -type module -reference raven_board_top_v raven_board_0]
    set_property CONFIG.OUT0_MEMORY $out0_memory $raven

    # Clock: one free-running pl_clk0 for everything (B9).
    set clk [get_bd_pins $ps/pl_clk0]
    connect_bd_net $clk \
        [get_bd_pins $rst/slowest_sync_clk] \
        [get_bd_pins $jtag/aclk] \
        [get_bd_pins $sc/aclk] \
        [get_bd_pins $raven/aclk]

    # Reset: debug core, bridge and NPU registers on the board reset (B6).
    connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rst/ext_reset_in]
    connect_bd_net [get_bd_pins $rst/peripheral_aresetn] \
        [get_bd_pins $jtag/aresetn] \
        [get_bd_pins $raven/aresetn]
    connect_bd_net [get_bd_pins $rst/interconnect_aresetn] [get_bd_pins $sc/aresetn]

    # AXI path.
    connect_bd_intf_net [get_bd_intf_pins $jtag/M_AXI] [get_bd_intf_pins $sc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $raven/s_axi]

    # Address map in the JTAG master's address space.
    set segs [get_bd_addr_segs $raven/s_axi/*]
    if {[llength $segs] != 1} { error "Expected one address segment on raven_board_0/s_axi, found: $segs" }
    assign_bd_address -target_address_space [get_bd_addr_spaces $jtag/Data] \
        -offset $base_addr -range $window $segs

    validate_bd_design
    save_bd_design
}
