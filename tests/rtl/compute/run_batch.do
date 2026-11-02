# A real $finish exits via -onfinish exit. A break, Tcl error, or a run that
# returns without $finish must fail. Python also checks transcripts and totals.
onerror {quit -force -code 1}
onbreak {quit -force -code 1}
if {[info exists raven_log_waves] && $raven_log_waves} {
    log -r /*
}
run -all
quit -force -code 1
