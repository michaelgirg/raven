# Batch script for tb_raven_npu_top (copied into each run directory by run_questa.py).
# A real $finish exits via -onfinish exit. A break, Tcl error, or a run that
# returns without $finish must fail. Python also checks transcripts and totals.
onerror {quit -force -code 1}
onbreak {quit -force -code 1}
run -all
quit -force -code 1
