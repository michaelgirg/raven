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

## 3. Device constraints and rough array size

Ultra96-V2's ZU3EG provides **360 DSP slices, 216 BRAM blocks, 70,560 LUTs, and 141,120 flip-flops**, with no UltraRAM. Local buffering must use BRAM or other available fabric resources. [Avnet hardware guide, printed page 22](https://www.avnet.com/wps/wcm/connect/onesite/b85b9556-0b2a-42b3-ad6a-8dcf3eac1ff9/Ultra96-V2-HW-User-Guide-v1_3.pdf?CACHEID=ROOTWORKSPACE.Z18_NA5A1I41L0ICD0ABNDMDDG0000-b85b9556-0b2a-42b3-ad6a-8dcf3eac1ff9-nDNP5R3&MOD=AJPERES).

At 100 MHz, assuming one DSP per scalar MAC and full occupancy:

| Array | MACs/cycle | MAC-array DSP estimate | Share of device DSPs | Peak GMAC/s | New operand bytes/cycle |
|---|---:|---:|---:|---:|---:|
| 8×8 | 64 | 64 | 17.8% | 6.4 | 16 |
| 8×16 / 16×8 | 128 | 128 | 35.6% | 12.8 | 24 |
| 16×16 | 256 | 256 | 71.1% | 25.6 | 32 |

These are analytical arithmetic ceilings, not measured throughput. They exclude pipeline overhead, stalls, masked lanes, result drain, and other operators. Counting multiplication and addition separately gives twice these values in GOPS. DSP estimates cover the MAC array only.

DSP48E2 includes a signed 27×18 multiplier, a 48-bit accumulator, and optional pipeline registers. An INT8 MAC fits those capabilities, but synthesis must confirm inference. Its SIMD adder modes do not automatically provide multiple independent INT8 multipliers. [AMD UG579](https://docs.amd.com/api/khub/documents/pTysoma4TYgNH95BrY1Sbw/content).

The 64- and 128-MAC options leave substantial DSP capacity for the surrounding system. A 256-MAC array deserves consideration only after the smaller designs establish the memory, routing, and output-processing costs.

## 4. Processing element and dataflow

For `C[M,N] = A[M,K] × B[K,N]`, an `R×S` array computes an output microtile with up to R rows and S columns. At reduction step k:

```text
PE[r,c].sum += A[m0+r,k] × B[k,n0+c]
```

Each PE contains a signed multiplier, an accumulator, and the control needed for initialization, valid products, and result capture. In broadcast mode, each A value feeds one array row, and each B value feeds one array column.

For 8×8, eight A bytes and eight B bytes support 64 MACs per cycle. Each input is reused across eight PEs. The 64 INT32 sums represent 256 logical bytes of accumulator state; this does not mean they require a BRAM allocation if implemented in DSP/register state.

Keep sums local across the complete reduction, including K chunks. Initialize once, retain partial sums across chunks, and emit a completed result only after the final product commits. Incomplete M/N tiles require lane masks.

## 5. Numeric widths and quantization

For unrestricted signed INT8 operands, the maximum product magnitude is `128×128 = 16,384`. A conservative accumulator-width bound before bias is:

```text
ACC_BITS >= 16 + ceil(log2(K)), for K >= 1
```

For `K=576`, such as a 3×3 convolution with 64 input channels, this gives 26 bits. For `K=4096`, it gives 28 bits. INT32 therefore provides useful headroom for these examples, but every supported layer still needs a range check.

A sufficient bound including the initial accumulator value is:

```text
abs(seed) + K × maximum_product_magnitude <= 2^(ACC_BITS−1) − 1
```

Check intermediate sums as well as the final output. Tiling K does not reduce the width required for the full reduction. Saturating or truncating after each chunk changes the computation. Declare signed RTL operands explicitly, preserve the 16-bit product, and sign-extend before accumulation.

### Activation zero-points

LiteRT INT8 models can use nonzero activation zero-points, symmetric weights, INT32 convolution bias, and per-channel convolution scaling. These affect the compute contract. [LiteRT quantization specification](https://developers.google.com/edge/litert/conversion/tensorflow/quantization/quantization_spec).

For symmetric weights, use this algebra to retain an INT8×INT8 multiplier:

```text
sum((a_q − z_a) × w_q) + bias
  = sum(a_q × w_q) + bias_corrected

bias_corrected = bias − z_a × sum(w_q)
```

Compute corrected bias per output channel in wide software arithmetic and apply it once per completed output reduction, for example as the initial accumulator seed. This follows the general technique of moving constant zero-point corrections outside the inner product. [Jacob et al., section 2.3](https://arxiv.org/pdf/1712.05877).

Convolution padding must supply `a_q = z_a` when using a correction based on all kernel weights. Corrected bias and raw intermediate sums can overflow INT32 even when the final centered result fits; validate that implementation or explicitly widen its contract.

Subtracting the zero-point before multiplication is an alternative: centered activations require signed 9 bits, and products with INT8 weights require signed 17 bits. This also fits a DSP48E2 but changes the operand datapath. The initial proposal uses raw INT8 multiplication with validated correction. Nonzero weight zero-points need further support.

The physical DSP may accumulate in 48 bits while exposing an INT32 architectural result; narrowing behavior and range checks must be defined. Requantization occurs after the complete reduction. Its exact multiplier, shift, rounding, zero-point, and clamp behavior must agree with Quan's output-operator interface.
