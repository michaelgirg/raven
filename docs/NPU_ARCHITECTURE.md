# RAVEN NPU Compute Architecture

**Status:** Initial research and proposed architecture; RTL implementation has not started.

**Owner:** Michael — NPU compute architecture and RTL.

**Target:** AMD/Avnet Ultra96-V2.

This document covers the compute core: MAC organization, dataflow, numeric formats, pipeline, tiling, and Conv/GEMM mapping. Memory delivery and output operators appear as interfaces that the compute core must agree on with the other subsystem owners. Proposed dimensions and interfaces remain subject to model analysis, simulation, and synthesis.

## 1. Initial proposal

Build a parameterized **output-stationary MAC array** with signed INT8 operands and architectural INT32 accumulation. Evaluate a small broadcast interconnect first, with a systolic implementation as an alternative if routing or timing favors it.

| Item | Proposed starting point | Status |
|---|---|---|
| Initial array | 8×8, or 64 scalar MACs | Bring-up configuration |
| Larger configuration | 8×16 or 16×8, or 128 scalar MACs | Evaluate after the baseline works |
| Dataflow | Output-stationary | Initial recommendation |
| Operand formats | Signed INT8 activations and weights | Initial compatibility profile |
| Raw product | Signed 16-bit | Required for INT8×INT8 |
| Accumulator/result | Signed INT32, with validated ranges | Initial architectural contract |
| Arithmetic rate | One MAC per PE per cycle after pipeline fill | Design target |
| Clock | At least 100 MHz | Design target; not achieved |
| Primary operations | GEMM and dense Conv2D on the same arithmetic core | Initial compute scope |
| Optional extension | Vector dot-product mode using the same multipliers | Investigate after baseline validation |

Choose the final array using actual layer shapes, routed timing, resource use, and operand/output throughput. The initial 8×8 size is a practical starting point, not a permanent performance ceiling.

## 2. Architecture research and tradeoffs

VTA illustrates a reusable GEMM engine with supporting tensor operations and explicit local memory. Gemmini illustrates configurable systolic arrays, local accumulation, and tiled execution. These are useful architectural references; RAVEN's control interface remains its own design. [VTA architecture](https://tvm.apache.org/2018/07/12/vta-release-announcement.html), [Gemmini architecture](https://github.com/ucb-bar/gemmini#architecture).

FINN demonstrates network-specific streaming FPGA architectures. That approach provides useful examples of quantized datapaths, while RAVEN's goal favors reusing one compute engine across different models. Eyeriss v2 explains why compact networks' varying layer shapes and bandwidth demands can leave a fixed array underused. [FINN](https://xilinx.github.io/finn/), [Eyeriss v2](https://arxiv.org/pdf/1807.07928).

| Compute organization | Main benefit | Main cost | RAVEN direction |
|---|---|---|---|
| Broadcast outer-product array | Simple operand timing and control for a small array | Operand fanout and routing grow with array size | First candidate |
| Systolic array | Neighbor-to-neighbor communication supports physical scaling | Input skew, wavefront timing, and result collection | Compare if broadcast timing/routing is poor |
| Parallel dot-product lanes | Parallelizes K, helping narrow matrix/vector operations | Wider operand delivery and reduction hardware | Optional extension |
| Runtime-selectable dataflows | Can accommodate more reuse patterns | More muxing, control, storage, and verification | Requires measured justification |

Output-stationary keeps an output's partial sum local; weight-stationary keeps a weight local. These describe reuse, while broadcast and systolic describe communication. A programmable NPU can use a systolic MAC core together with other operators and software scheduling.
