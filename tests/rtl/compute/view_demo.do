# Run from the build directory printed by run_questa.py, in the Questa GUI:
# do view_demo.do
vsim -t 1ps -onfinish stop -sva -immedassert -voptargs=+acc -wlf demo_gui.wlf -gROWS=8 -gCOLS=8 work.tb_raven_gemm_core +FIXTURES=8x8/vectors +DEMO_ONLY
add wave -divider Command
add wave sim:/tb_raven_gemm_core/clk sim:/tb_raven_gemm_core/rst_n
add wave sim:/tb_raven_gemm_core/cmd_valid sim:/tb_raven_gemm_core/cmd_ready sim:/tb_raven_gemm_core/busy
add wave -divider Memory
add wave sim:/tb_raven_gemm_core/av sim:/tb_raven_gemm_core/ar sim:/tb_raven_gemm_core/asv sim:/tb_raven_gemm_core/asr
add wave sim:/tb_raven_gemm_core/bv sim:/tb_raven_gemm_core/br sim:/tb_raven_gemm_core/bsv sim:/tb_raven_gemm_core/bsr
add wave sim:/tb_raven_gemm_core/pv sim:/tb_raven_gemm_core/pr sim:/tb_raven_gemm_core/psv sim:/tb_raven_gemm_core/psr
add wave -divider Results
add wave -radix signed sim:/tb_raven_gemm_core/rd
add wave -radix unsigned sim:/tb_raven_gemm_core/row sim:/tb_raven_gemm_core/col sim:/tb_raven_gemm_core/index_out sim:/tb_raven_gemm_core/steps
add wave sim:/tb_raven_gemm_core/rv sim:/tb_raven_gemm_core/rr sim:/tb_raven_gemm_core/rl
add wave sim:/tb_raven_gemm_core/compute_done sim:/tb_raven_gemm_core/result_done sim:/tb_raven_gemm_core/error
add wave -radix hexadecimal sim:/tb_raven_gemm_core/error_code
run -all
wave zoom full
