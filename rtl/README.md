# RTL

This is the planned home for synthesizable SystemVerilog. The subdirectories are placeholders; no RTL implementation is supplied yet.

| Directory | Intended contents | Lead |
|---|---|---|
| `compute/` | Processing elements, MAC array, microtile sequencing, and operand/window frontend | Michael |
| `operators/` | Requantization, clamps/ReLU, pooling, and EWADD | Quan |
| `memory/` | Scratchpad banks, stream adapter, and bank-state enforcement | Taylor |
| `control/` | Generated CSR block, command queue/dispatch, completion, IRQs, and counters | Nahjay |
| `common/` | Shared types, interfaces, and utilities reviewed by their consumers | Shared; assign a lead per change |
| `top/` | NPU subsystem and system-level RTL integration | Shared; integration lead TBD |

Keep simulation-only testbenches in [tests/rtl/](../tests/rtl/). Vivado setup and board constraints belong in [hw/](../hw/). The proposed register source belongs in [tools/regs/](../tools/regs/); generated CSR RTL belongs in `control/` and must stay consistent with it.

Start from the relevant [research document](../README.md#documentation-and-ownership) and review interfaces with the consuming subsystem before implementing them.
