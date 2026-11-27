# RAVEN Ultra96-V2 board prototype constraints.
#
# No package pins: every RAVEN signal is internal to the block design, and the host
# reaches it over the board's JTAG header through the JTAG-to-AXI debug core.
#
# Clocking: pl_clk0 is constrained by the Zynq UltraScale+ PS IP itself (clock clk_pl_0,
# 20 ns at 50 MHz). The design has one clock domain, so no clock-crossing constraints
# are needed. hw/build.tcl checks the implemented clk_pl_0 period and timing.

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
