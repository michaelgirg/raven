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

## 6. Proposed pipeline

These are logical stages; exact register placement depends on DSP inference and the agreed scratchpad-read latency.

| Stage | Work |
|---|---|
| Tile setup | Latch dimensions/masks and initialize or restore sums |
| Operand preparation | Read or receive packed A/B vectors and align them |
| Operand registers | Register signed values and distribute them across rows/columns |
| Multiply | Produce signed products in DSP multipliers |
| Accumulate | Update PE-local sums for valid products |
| Capture/drain | Hold completed sums and transfer them to the result interface |

Target initiation interval one: each PE accepts one new product per cycle after fill. Multiplier pipelining can precede accumulation; extra registers inside the accumulator feedback loop require special handling to preserve that rate.

Consume A/B vectors as a pair. Delay valid, masks, and end-of-reduction information with the data. Missing operands introduce bubbles; only valid products update sums. Count committed products when deciding completion. Hold result data stable under backpressure.

An 8×8 tile contains 64 outputs. One result lane takes 64 drain issue cycles; four lanes take 16; eight take eight. With no overlap, `K=256` and a single lane give an arithmetic-plus-drain ceiling of `256/(256+64)=80%` before pipeline overhead. A snapshot buffer can decouple compute from drain, but sustained throughput still depends on the downstream operator's initiation interval and buffer capacity.

## 7. GEMM mapping and tiling

The initial neural-network operation is `C=A×B+bias`. Each PE owns one C element, while k advances through the reduction. Arbitrary BLAS alpha/beta and transpose combinations remain separate decisions.

```text
for each output microtile (m0, n0):
    initialize active sums once
    for each K chunk:
        obtain its A and B panels
        issue one reduction step per cycle when operands are available
        preserve sums across chunk boundaries
    wait for the final product to commit
    emit completed INT32 sums
```

For `M=24,N=16,K=256`, an 8×8 array handles six output microtiles: 98,304 MACs and 1,536 ideal issue cycles. At 100 MHz that is 15.36 microseconds of issue time, excluding all overhead.

Distinguish the physical microtile from larger BRAM panels. Reusing panels across microtiles reduces repeated DDR reads. If multiple output microtiles are interleaved across K chunks, their partial sums need local save/restore storage; keeping only one microtile active avoids that requirement.

For INT8 panels and a full INT32 partial-sum workspace, an illustrative double-buffered working set is:

```text
bytes = 2 × (Tm×Tk + Tk×Tn) + 4×Tm×Tn
```

`Tm=Tn=32,Tk=256` gives 36 KiB logically: 32 KiB of double-buffered operands and 4 KiB of partial sums. This excludes FIFOs, padding, metadata, output buffers, and convolution staging. It is a tiling example for coordination with Taylor, not a finalized scratchpad allocation.

For that macro-operation, loading each operand panel once and writing INT8 outputs transfers 17,408 bytes for 262,144 MACs. Actual traffic depends on successful reuse, packing, and scheduling. FPGA research uses loop tiling and compute/bandwidth analysis to examine these tradeoffs. [Zhang et al., FPGA 2015](https://ceca.pku.edu.cn/media/lw/b73586e2ac7b5f8d63e8e584f398f17f.pdf).

### Compute-side memory requirements

An 8×8 dense array needs simultaneous 64-bit A and 64-bit B streams; 8×16 needs 64-bit A and 128-bit B. At 100 MHz these represent 1.6 and 2.4 GB/s of local operand delivery. They do not specify the DMA bus width or predict sustained DDR bandwidth.

A possible packed format is `A_panel[k][row_lane]` and `B_panel[k][column_lane]`. Ordinary row-major A needs packing, banking, or transposition to produce multiple rows at one k. A dual-port BRAM cannot supply eight unrelated scalar reads per cycle. Bank mapping, packing responsibility, refill ownership, and read latency must be agreed with Taylor.

## 8. Conv2D mapping

Map dense convolution to the same GEMM core:

```text
M = batch × Hout × Wout
N = Cout
K = Kh × Kw × Cin
```

Each A row is one flattened input window; each B column is one flattened output-channel filter. An 8×8 array computes eight output positions across eight output channels. Implicit GEMM constructs the required tiles without materializing the full expanded activation matrix. [CUTLASS convolution mapping](https://docs.nvidia.com/cutlass/4.5.0/media/docs/cpp/implicit_gemm_convolution.html).

Use neural-network cross-correlation indexing:

```text
k = ((kh × Kw) + kw) × Cin + ci
ih = oh × stride_h − pad_top  + kh × dilation_h
iw = ow × stride_w − pad_left + kw × dilation_w
A[m,k] = input[batch,ih,iw,ci]  // activation zero-point outside bounds
B[k,n] = weight[n,kh,kw,ci]
```

NHWC is a candidate external layout because channels at a pixel are contiguous; the packed compute-panel layout is a separate interface decision.

| Conv frontend | Tradeoff | Proposed use |
|---|---|---|
| Full software im2col | Simple core input, but duplicates activations and increases storage/traffic | Small correctness experiments |
| Tile-local window packing | Bounds staging storage while reusing the GEMM core | First Conv implementation candidate |
| Streaming line/window buffers | Reuses overlapping pixels but needs deliberate banking and scheduling | Optimize after functional Conv |

A 1×1 convolution uses `K=Cin` without spatial window expansion. A synthetic `Hout=Wout=16,Cin=16,Cout=32,Kh=Kw=3` layer maps to `M=256,N=32,K=144`: 1,179,648 MACs and 18,432 ideal issue cycles on 8×8.

Depthwise convolution operates per input channel. Treating its weights as a dense, mostly zero matrix wastes work. Evaluate a direct per-channel mapping, an additional compute mode, or a separate operator unit with Quan if candidate models require it. FPGA work demonstrates configurable reductions for depthwise/pointwise computation, but its published implementation sizes and performance do not transfer directly to Ultra96. [Bai et al., 2018](https://users.wpi.edu/~xhuang/pubs/2018_bai_tcas2.pdf).

## 9. Utilization and optional vector mode

For dense broadcast with no K padding, geometric occupancy is:

```text
occupancy = (M×N) / (ceil(M/R)×R × ceil(N/S)×S)
```

Batch-one fully connected layers have `M=1`; on 8×8, at most one row is active, giving 12.5% occupancy for sufficiently large N. Tail dimensions also waste lanes. Masks preserve correctness but do not eliminate this cost.

An optional vector mode could use array rows as K-reduction lanes and columns as output channels. Each PE accumulates strided K terms, followed by a reduction across rows. Bias/correction must appear exactly once per output, and the final reduction needs sufficient guard width.

For synthetic `M=1,N=64,K=512`, dense 8×8 requires 4,096 ideal MAC issue cycles; vector mode requires 512. That arithmetic improvement excludes final reduction and other overhead. The vector mapping needs 64 weight bytes plus eight activation bytes per cycle, versus 16 total bytes in dense mode. Wider BRAM delivery and additional routing are significant costs; cold DDR transfers may dominate either mapping.

Keep vector mode as an experiment until model profiles and measured bottlenecks justify it. The baseline compute core should remain independently useful and verifiable.

## 10. Compute-core block diagram

```mermaid
flowchart TB
    CMD["Tile command interface"] --> CTRL["Compute controller<br/>M/N/K loops, masks, init/continue"]
    A["Packed activation stream<br/>from BRAM / Conv window frontend"] --> AF["A operand buffer"]
    B["Packed weight stream<br/>from BRAM"] --> BF["B operand buffer"]
    AF --> ISSUE["Paired operand issue / valid alignment"]
    BF --> ISSUE
    ISSUE --> MAC["Parameterized output-stationary MAC array<br/>INT8 multiply / INT32 architectural sums"]
    SEED["Bias-corrected seed or restored partial sums"] --> MAC
    CTRL -.-> ISSUE
    CTRL -.-> MAC
    MAC --> RESULT["Result capture / drain<br/>optional snapshot buffering"]
    RESULT --> OUT["INT32 result interface<br/>to output operators or local storage"]
    RESULT -.-> CTRL
    CTRL --> STATUS["Compute completion / error / cycle counters"]
```

The diagram shows the proposed baseline. Optional vector reduction would sit between the MAC array and result capture. Scratchpad/DMA implementation, MMIO register decoding, and requantization/activation internals are surrounding subsystem interfaces.
