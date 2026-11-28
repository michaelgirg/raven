# RTL

The compute directory contains the MAC PE, parameterized array, operand frontend
and single-microtile GEMM controller. They are verified in standalone RTL
simulation. See the [implementation and run instructions](../README.md#compute-implementation-and-tests).
The [memory directory](memory/README.md) contains activation, weight, parameter and
output buffers plus adapters connecting them to the pre-alpha pipeline,
and [operators](operators/README.md) contains a one-lane
requantization/clamp block. Their benches are under `tests/rtl/`. The control
directory contains the pre-alpha register block and single-command FSM. The top
directory contains `raven_npu_top`, which connects
control, the GEMM core, a PARAM-loading wrapper around Quan's requant block, and the INT8
result writer. Every bank transfer passes through the native memory-buffer RTL by
default. The integration testbench and the MEMORY board wrapper both connect
the NPU bank ports to the synthesizable `raven_memory_banks` aggregate.
[Control and integration](../README.md#control-pre-alpha-and-integration) · [FPGA build](../hw/README.md)

The standalone aggregate passed Vivado BRAM inference, and the Ultra96-V2
prototype read the 64-byte GEMM result from OUT0.
[BRAM synthesis](../hw/README.md#physical-memory-bank-synthesis) · [Live board evidence](../evidence/vivado/board-prototype/live-gemm/results.json)

| Directory | Intended contents | Lead |
|---|---|---|
| `compute/` | Processing elements, MAC array, microtile sequencing, and operand/window frontend | Michael |
| `operators/` | Requantization, clamps/ReLU, pooling, and EWADD | Quan |
| `memory/` | Scratchpad banks, stream adapter, and bank-state enforcement | Taylor |
| `control/` | Pre-alpha register block and single-command FSM; later the generated CSR block, command queue/dispatch, completion, IRQs, and counters | Nahjay |
| `common/` | Shared types, interfaces, and utilities reviewed by their consumers | Shared; assign a lead per change |
| `top/` | Pre-alpha NPU top, requant PARAM loader and INT8 result writer; later the system-level RTL integration | Nahjay (pre-alpha); system integration lead TBD |
| `board/` | AXI4-Lite bridge, Ultra96-V2 wrapper and OUT0 readback | Shared |

Keep simulation-only testbenches in [tests/rtl/](../tests/rtl/). Vivado setup and board constraints belong in [hw/](../hw/). The proposed register source belongs in [tools/regs/](../tools/regs/); generated CSR RTL belongs in `control/` and must stay consistent with it.

Start from the relevant [research document](../README.md#documentation-and-ownership) and review interfaces with the consuming subsystem before implementing them.
