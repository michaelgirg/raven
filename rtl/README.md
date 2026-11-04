# RTL

The compute directory contains the MAC PE, parameterized array, operand frontend
and single-microtile GEMM controller. They are verified in standalone RTL
simulation. See the [implementation and run instructions](../README.md#compute-implementation-and-tests).
The [memory directory](memory/README.md) contains a standalone activation buffer,
and [operators](operators/README.md) contains a standalone one-lane
requantization/clamp block. Their benches are under `tests/rtl/`. The control
directory contains the pre-alpha register block and single-command FSM. The top
directory contains the pre-alpha NPU simulation top (`raven_npu_top`), which connects
control, the GEMM core, a PARAM-loading wrapper around Quan's requant block, and the INT8
result writer. Its banks are top-level ports, served by testbench models for now. See
[Control pre-alpha and integration](../README.md#control-pre-alpha-and-integration) and the
[control plan](../docs/plans/nahjay_control_integration_prealpha.md). Common interfaces
remain reserved, and an integrated FPGA build is not supplied. See the
[current subsystem status](../README.md#current-subsystem-status-and-integration).

| Directory | Intended contents | Lead |
|---|---|---|
| `compute/` | Processing elements, MAC array, microtile sequencing, and operand/window frontend | Michael |
| `operators/` | Requantization, clamps/ReLU, pooling, and EWADD | Quan |
| `memory/` | Scratchpad banks, stream adapter, and bank-state enforcement | Taylor |
| `control/` | Pre-alpha register block and single-command FSM; later the generated CSR block, command queue/dispatch, completion, IRQs, and counters | Nahjay |
| `common/` | Shared types, interfaces, and utilities reviewed by their consumers | Shared; assign a lead per change |
| `top/` | Pre-alpha NPU top, requant PARAM loader and INT8 result writer; later the system-level RTL integration | Nahjay (pre-alpha); system integration lead TBD |

Keep simulation-only testbenches in [tests/rtl/](../tests/rtl/). Vivado setup and board constraints belong in [hw/](../hw/). The proposed register source belongs in [tools/regs/](../tools/regs/); generated CSR RTL belongs in `control/` and must stay consistent with it.

Start from the relevant [research document](../README.md#documentation-and-ownership) and review interfaces with the consuming subsystem before implementing them.
