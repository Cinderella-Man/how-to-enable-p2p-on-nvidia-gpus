# How to enable P2P on NVIDIA GeForce GPUs (Ubuntu 26.04)

A step-by-step guide to **GPU-to-GPU peer-to-peer (P2P) over PCIe** on consumer GeForce cards (tested on two RTX
3090s, on two RTX 3080s, and, with extra steps, on an RTX 2060 + GTX 1650 SUPER and on an RTX 2060 + RTX 3060, two
generations) with Ubuntu 26.04, the
Ubuntu-packaged NVIDIA 615 driver, and CUDA 13.5.

The stock GeForce driver reports no peer access (`cudaDeviceCanAccessPeer` = 0, `nvidia-smi topo -p2p r` = `GNS`), so
CUDA, NCCL, PyTorch and vLLM stage every GPU-to-GPU copy through host RAM. This guide swaps NVIDIA's open **kernel
modules** for a patched build of the same version:
[Cinderella-Man/geforce-dynbar1-p2p](https://github.com/Cinderella-Man/geforce-dynbar1-p2p).
That is a fork of [noon-at-cgn/geforce-dynbar1-p2p](https://github.com/noon-at-cgn/geforce-dynbar1-p2p) (615.71.09 plus
a dynamic BAR1 P2P patch series) with the two fixes Ubuntu 26.04 / Linux 7.0 needs. The userspace driver (libcuda,
nvidia-smi) stays Ubuntu's stock package. Copies then go card to card. Check that they arrive: `nvidia-smi topo -p2p
r` showing `OK` is not proof ([why](#ok-is-not-proof)).

**Running one model across several cards with llama.cpp?** Build llama.cpp with NCCL first: that is the biggest single
step, with or without P2P (three RTX 3090s: 348 -> 1,366 tokens/s on prompts through host RAM, 1,695 with P2P).
[llama.cpp: build it with NCCL](#llamacpp-build-it-with-nccl).

**Field reports and problems** with CUDA P2P go to [this repository's issues](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues);
those about DRMShare, its NCCL fork or the llama.cpp copy to [DRMShare's](https://github.com/Cinderella-Man/drmshare/issues).

## Which path is yours

| Your two cards | Chip | Driver | Follow | Tested here |
|---|---|---|---|---|
| RTX 3080, 3080 Ti, 3090, 3090 Ti | GA102 (Ampere) | the patched open driver, 615.71.09 | [procedure.md](docs/procedure.md) | **verified**: 2x RTX 3090; RTX 3080 12 GB + 10 GB; 3x RTX 3090 on another machine, trial load ([three cards](docs/three-cards.md)); outside reports: 2x RTX 3090 and RTX 3080 Ti + RTX 3090 on Intel X99 boards ([boards](docs/boards.md#outside-reports-rtx-30-pairs-on-two-huananzhi-x99-boards)) |
| RTX 20 series, GTX 16 series | Turing | the patched driver, plus a bigger memory window at every boot and P2P switched on per card | [procedure.md](docs/procedure.md), then [turing.md](docs/turing.md) | **works, experimental**: RTX 2060 + GTX 1650 SUPER; outside reports: 4x RTX 2080 Ti on an Intel X79 board, 5x RTX 2080 Ti 22 GB on a four-socket server |
| GTX 10 series, P106 / P104 mining cards | Pascal | NVIDIA's stock driver 580, no patch | [pascal-and-volta.md](docs/pascal-and-volta.md) | **verified**: 2x P106-090 |
| Tesla V100 | Volta | NVIDIA's stock driver 580, no patch | [pascal-and-volta.md](docs/pascal-and-volta.md) | **verified**: 2x V100 PCIe 32 GB, on another machine |
| Two generations: RTX 2060 + RTX 3060 | Turing + Ampere | the patched driver; then a patched copy of `libcuda` (CUDA peer access), or the fork's key for writes through the other card's memory window | [procedure.md](docs/procedure.md) (step 4b for the Turing card's window, with [turing.md](docs/turing.md) T2), then [mixed-generations.md](docs/mixed-generations.md) | **works, experimental**: RTX 2060 + RTX 3060; outside report: RTX 2070 + RTX 3060 (CUDA peer access) |
| RTX 3050 to 3070 Ti, RTX 40 series | other Ampere chips, Ada | the patched driver; P2P opt-in per card upstream | [procedure.md](docs/procedure.md), then upstream's [opt-in](https://github.com/Cinderella-Man/geforce-dynbar1-p2p#opt-in-for-other-chips) | not tested |
| RTX 50 series | Blackwell | upstream leaves these to NVIDIA's own driver, which offers BAR1 P2P (untested upstream too). **16 GB cards** (BAR1 only as large as their memory) need static BAR1 forced first, or P2P shows `OK` while copies lose their data ([troubleshooting](docs/troubleshooting.md#rtx-50-with-16-gb-ok-and-peer-access-but-copies-lose-their-data)) | upstream's [README](https://github.com/Cinderella-Man/geforce-dynbar1-p2p) | not tested here; outside report: RTX 5080 + RTX 5060 Ti 16 GB, `NS` on NVIDIA's 620.73.04, offered (`OK`) with another P2P patch, data not checked yet ([issue #4](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/4)) |

Two cards of **different generations** (say an RTX 3090 with an RTX 2080) get no P2P from CUDA as it is: CUDA itself
refuses peer access between architectures. Two ways around it worked on an RTX 2060 + RTX 3060, byte-exact:
[docs/mixed-generations.md](docs/mixed-generations.md). Two different cards of one generation can work: an RTX 3080
12 GB + 10 GB (one chip, GA102), and an RTX 2060 + GTX 1650 SUPER (two different chips, with a workaround for CUDA).
A Tesla V100 with a GeForce card can use neither, because the V100 needs NVIDIA's closed driver: for that pair, and
the other cases P2P cannot cover, see [When P2P is not possible](#when-p2p-is-not-possible-drmshare) below.

Whatever the cards, the **motherboard** decides whether the traffic gets through and how fast: both cards on CPU lanes
is best, a chipset slot works with limits, cheap PCIe switches do not work, and on a server with several CPU sockets
the cards that exchange data belong on one socket. What is known per board, and how to check
yours: [docs/boards.md](docs/boards.md).

## `OK` is not proof

`nvidia-smi topo -p2p r` showing `OK` (and `cudaDeviceCanAccessPeer` = 1) means only that the driver offers P2P for
that pair. It does not mean the data arrives, nor that P2P is faster than going through host RAM. So this guide says
**offered** for `OK` and **verified** only once the data was checked, and so does the fork's `p2p-check.sh`: without
`--integrity` a clean run ends in `SETUP OK, DATA NOT CHECKED`, and `ALL PASS` comes only from the integrity test.
So far `OK` was wrong in all of these cases, most of them without any error:

| `OK`, but | When | Seen on |
|---|---|---|
| every write is lost | both cards behind the same chipset | Intel Z390 (outside report), AMD B550 ([troubleshooting](docs/troubleshooting.md#nvidia-smi-topo--p2p-r-says-ok-but-nothing-arrives-between-two-cards)) |
| copies are lost or blocked | the IOMMU translating addresses instead of passthrough | two Tesla V100s on an AMD B450, four Tesla P40s on an Intel X99 (outside report) ([troubleshooting](docs/troubleshooting.md#peer-copies-faster-than-the-link-allows-or-io_page_fault-from-nvidia)) |
| every copy is lost, at a speed no link can carry | a 16 GB RTX 50 card without static BAR1 | RTX 5060 Ti 16 GB (outside report) ([troubleshooting](docs/troubleshooting.md#rtx-50-with-16-gb-ok-and-peer-access-but-copies-lose-their-data)) |
| every read returns `0xffffffff`, writes work | one card behind an Intel B460 chipset | 2x RTX 4060 Ti (outside report) ([troubleshooting](docs/troubleshooting.md#peer-reads-return-0xffffffff-writes-work)) |
| kernel reads of the other card return wrong data; copies and writes are byte-exact | two CPU root ports of an Intel client CPU (Core i7-11700K on a Z590), with the driver forcing reads on | 2x RTX 3090 (outside report, [geforce-dynbar1-p2p#9](https://github.com/noon-at-cgn/geforce-dynbar1-p2p/issues/9)); NVIDIA: Intel client CPUs support only P2P writes ([#1253](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1253)); the pinned driver refuses such pairs since fork commit `e067c4a` |
| the first copy loses all its data | cards behind a mining board's PCIe switches, P2P forced on | 9x P106-090 ([pascal-and-volta](docs/pascal-and-volta.md#the-test-on-a-mining-box-the-driver-said-yes-the-hardware-said-no)) |
| byte-exact, but about 25 times slower than through host RAM | cards on two CPU sockets of a Xeon E7 v4 server | 5x RTX 2080 Ti (outside report) ([troubleshooting](docs/troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)) |
| CUDA gives no peer access at all | two different Turing chips; two GPU generations | RTX 2060 + GTX 1650 SUPER, RTX 2060 + RTX 3060 ([turing.md T5](docs/turing.md#t5-cuda-and-the-integrity-test), [mixed-generations](docs/mixed-generations.md#why-cuda-says-no)) |

What does prove it:

- **The data, checked.** The integrity test ([procedure step 14](docs/procedure.md#14-integrity-test): `ALL PASS`)
  compares every byte, both directions, many sizes. With another driver or patch,
  [`tools/p2p_patterns.cu`](tools/p2p_patterns.cu) needs only `nvcc`: `r01` and `r10` (reads), `cewbi` and `cerbi`
  (copies both ways), each ending with `DATA OK` or `DATA WRONG`.
- **A speed the link can carry.** A copy faster than the slower card's PCIe link allows means the data is not arriving
  (6.6 GB/s into a 2 GB/s link on the V100s, 69-72 GB/s on the RTX 5060 Ti).
- **For NCCL, PyTorch and vLLM, the `via` line.** NCCL has its own rule and can still go through host RAM
  ([troubleshooting](docs/troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)).

<a id="when-p2p-is-not-possible-hidden-gem"></a>

## When P2P is not possible: DRMShare

Use P2P whenever your pair has a route in the table above: it works for every CUDA program (NCCL, PyTorch, vLLM) and
needs no change to them (on an Intel CPU, NCCL needs one variable,
[`NCCL_P2P_LEVEL=PHB`](docs/troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)). For the cases below, where no P2P route exists or none fits, the companion repository
**[DRMShare](https://github.com/Cinderella-Man/drmshare)** (formerly Hidden GEM) shares video memory between the two cards instead: one opt-in option in `nvidia-drm` on
NVIDIA's own driver (580, 595 or 615), no patched driver and no patched `libcuda`. It is **not P2P**: only Vulkan
programs can use it, and llama.cpp can, for one model split across both cards. CUDA programs keep going through host
RAM, unless they talk through DRMShare's experimental NCCL fork ([nccl.md](https://github.com/Cinderella-Man/drmshare/blob/main/docs/nccl.md)).

| Your situation | Why P2P does not fit | DRMShare, tested |
|---|---|---|
| A Tesla V100 with a GeForce card | the V100 runs only on NVIDIA's closed driver 580 (this guide's patched driver cannot run it), and CUDA refuses peer access between two architectures | V100 + RTX 3090, V100 + RTX 3080, V100 + RTX 2060, V100 + GTX 1070 Ti, on 580 |
| A Pascal card (GTX 10, P106) with a card of another generation | the same: Pascal runs only on 580, and CUDA refuses peer access between two architectures | Volta + Pascal (V100 + GTX 1070 Ti); Pascal with Turing or Ampere not tested |
| Two generations of Turing or newer (for example RTX 2060 + RTX 3060), on NVIDIA's stock driver | the routes of [mixed-generations.md](docs/mixed-generations.md) need this guide's patched driver, plus a patched copy of `libcuda` or root | RTX 2060 + RTX 3060 on 580, 595 and 615 |
| Your program uses Vulkan, not CUDA (llama.cpp's Vulkan backend) | P2P only reaches CUDA programs | llama.cpp tensor parallel with the all-reduce through shared video memory: same results; faster on V100 + RTX 3090 (prompts +18 %), not on RTX 2060 + RTX 3060. Together with this guide's patched driver: not tested |

DRMShare does not get around the board: where the board does not carry peer traffic (the switches of mining boards),
nothing arrives either way ([docs/boards.md](docs/boards.md)).

## llama.cpp: build it with NCCL

For one model split across several cards (llama.cpp's tensor parallelism, `-sm tensor`), the biggest single step is
not P2P but **llama.cpp built with NCCL**: the cards then add up each layer's results with NCCL instead of generic
copies one after another. It needs no patched driver and works through host RAM where P2P is not possible:

| Cards, Qwen3.8-27B Q8_0, `-sm tensor` | without NCCL | with NCCL, through host RAM | with NCCL and P2P |
|---|---|---|---|
| 3x RTX 3090 (one at PCIe 4.0 x4 behind the chipset, two at PCIe 4.0 x8), prompt 2048 / generation, tokens/s ([three cards](docs/three-cards.md#llamacpp-build-it-with-nccl)) | 348 / 32.5 | 1,366 / 51.2 | 1,695 / 54.7 (`NCCL_P2P_LEVEL=SYS`) |
| Tesla V100 (PCIe 3.0 x4, chipset slot) + RTX 3090 (PCIe 4.0 x16) (no P2P possible: two generations) | 647 / 34.7 (llama.cpp's own all-reduce) | 720 / 33.2 | |

1. **NCCL**: install NVIDIA's packages, or build it ([NVIDIA/nccl](https://github.com/NVIDIA/nccl): `make src.build
   NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86"` with your cards' compute capabilities). A Tesla V100 needs a CUDA
   12 toolkit and an NCCL built with it: CUDA 13 dropped Volta.
2. **llama.cpp**: `cmake -B build -DGGML_CUDA=ON -DNCCL_ROOT=<nccl>/build` (NCCL is on by default, `GGML_CUDA_NCCL=ON`).
   CMake must print `Found NCCL`; when it finds none it builds without, saying only `NCCL not found, performance for
   multiple CUDA GPUs will be suboptimal`.
3. **Run with `-sm tensor`.** On Linux llama.cpp then adds up through NCCL by default (`GGML_CUDA_ALLREDUCE` picks
   another way). With P2P on an AMD CPU and three or more cards, NCCL needs `NCCL_P2P_LEVEL=SYS`
   ([troubleshooting](docs/troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)).
   **Cards with different amounts of memory need `-ts` too**: `-sm tensor` gives every card an equal share of each
   layer (the default layer split divides by free memory instead), so the smaller card fills up first, and llama.cpp's
   automatic fit (`--fit`, on by default in `llama-server`) does not handle `-sm tensor`. Split by memory, in the order
   llama.cpp lists the devices when it starts: `-ts 12/8` for a 12 GB card first and an 8 GB card second (`llama-bench`
   separates the numbers with `/`, `llama-server` with `,`). An outside report with an RTX 3060 12 GB and an RTX 2070
   8 GB ran out of memory on the 8 GB card with Qwen3-30B-A3B (17.3 GiB) at the even split
   ([#6](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/6)); a split by memory was not tried there.

NCCL matters most from three cards on. With two cards llama.cpp's own two-card all-reduce comes close (two RTX 3090s
on CPU lanes, prompt 2048 / generation: 1,668 / 42.8 without NCCL, 1,818 / 42.1 with NCCL and P2P). And only
`-sm tensor` uses it: llama.cpp's default layer split passes each card's output to the next and adds nothing up.

### More speed: tensor-parallel changes in a llama.cpp copy (experimental)

[Cinderella-Man/llama.cpp-drmshare](https://github.com/Cinderella-Man/llama.cpp-drmshare), branch
`vk-allreduce-shared-vram`, carries four changes for links through host memory, measured on the Tesla V100 + RTX 3090
(V100 in a PCIe 3.0 x4 chipset slot, RTX 3090 at PCIe 4.0 x16) with stock NCCL, every perplexity chunk identical:

| llama.cpp, prompt 2048 / generation, tokens/s | V100 + RTX 3090 |
|---|---|
| upstream with NCCL, even split | 715 / 33.2 |
| two all-reduce lanes (`GGML_CUDA_ALLREDUCE=split`: small ones by llama.cpp itself, large ones by NCCL) | 729 / 34.8 |
| + more work on the faster card, `-ts 3/2` (best for generation) | 782 / 37.0-37.3 |
| + `-ub 2048` and the all-reduce overlapped with the next part of the layer (`GGML_META_ASYNC_AR=1`), `-ts 3/1` (best for prompts) | **977-984 / 33.8** |

- `-sm tensor` splits **evenly** by default, whatever the cards; a faster card should take more (`-ts`), a card with
  less memory less (step 3 above): split for memory first, then for speed. One load has one split: `-ts 3/2` for
  chat, `-ts 3/1` for long prompts on this pair. This copy warns when it loads without `-ts` on cards whose free memory
  differs by more than 10 %, and prints a split by memory.
- The overlap cuts each layer's work into token chunks (Qwen3.5 / 3.8-family models so far) and needs `-ub 1024` or
  more; NCCL's bf16 threshold can go to 0 on such links (`GGML_CUDA_NCCL_BF16_MIN_NE=0`).
- Tested on one pair for one evening; the changes are new. Moving the data is still half of the prompt time on this
  pair, so a faster link helps most.
- **With P2P they add little.** On three RTX 3090s with P2P the gain comes from upstream's own `-ub 2048` (+8-11 % on
  prompts), and for a mixture-of-experts model from tensor split (Qwen3.8-Flash-Next +34 % on prompts over the default
  layer split): tuned settings and server commands in [three-cards.md](docs/three-cards.md#llamacpp-the-fastest-settings).
- **Speculative decoding** adds more to generation on the same cards: Qwen3.8-27B 55 -> 92.9 tokens/s with its own
  MTP layer (tensor split, P2P still worth 9 % there), Qwen3.8-Flash-Next 75.8 -> 112.6 with a DFlash2 draft (layer
  split, which costs prompt speed): [three-cards.md](docs/three-cards.md#llamacpp-speculative-decoding).

## Documents

| | |
|---|---|
| [docs/procedure.md](docs/procedure.md) | **The procedure.** From a fresh Ubuntu 26.04 install to P2P working, with a check after each step. |
| [docs/turing.md](docs/turing.md) | **Turing cards (RTX 20 / GTX 16), experimental.** The extra steps they need: a bigger memory window at every boot, P2P switched on per card, and a CUDA workaround for two different chips. |
| [docs/mixed-generations.md](docs/mixed-generations.md) | **Two generations: RTX 2060 (Turing) + RTX 3060 (Ampere), experimental.** CUDA refuses P2P between architectures; two ways around it, with every step: a patched copy of `libcuda` (CUDA peer access, so NCCL and PyTorch use P2P), or writes through the other card's memory window with the fork's `RMPeerIoMemBar1` key. |
| [drmshare](https://github.com/Cinderella-Man/drmshare) | **When P2P is not possible: DRMShare**, experimental, in its own repository ([which cases](#when-p2p-is-not-possible-drmshare)). Memory sharing, not CUDA P2P: one opt-in option in `nvidia-drm` on NVIDIA's own drivers 580, 595 and 615 lets Vulkan on one card import the other's video memory through a dma-buf. Tesla V100 with an RTX 3090, RTX 2060 or GTX 1070 Ti; an RTX 2060 with an RTX 3060. Byte-exact, as fast as CUDA P2P in the same slots, and llama.cpp runs Qwen tensor-parallel across both cards. |
| [docs/pascal-and-volta.md](docs/pascal-and-volta.md) | **Pascal (GTX 10, P106) and Volta (V100)**, on NVIDIA's stock driver 580, no patch. Both get P2P with the IOMMU in passthrough mode, on a board that routes the traffic: two V100s, two P106-090s in the test rig, and Tesla P40s on an Intel X99 board (outside report). Without passthrough, data is silently lost, on AMD and Intel alike. |
| [docs/boards.md](docs/boards.md) | **Boards and slots**: what is known per motherboard (CPU lanes, chipset slots, mining-board switches), which traffic gets through, and how to check yours. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Each failure hit on the way, with its cause and fix. The big one: Ubuntu's udev rules reloading the stock driver every few seconds. |
| [docs/three-cards.md](docs/three-cards.md) | **Three or more cards: three RTX 3090s**, one behind the chipset, on another machine. What differs from two cards: every card listed, a large BAR1 even for cards whose vBIOS has no Resizable BAR, and fork commit `b70b69c` for peer access between all cards at once (old and new build compared). |
| [docs/benchmarks.md](docs/benchmarks.md) | P2P on vs off with NVIDIA's tools (`p2pBandwidthLatencyTest`, `nvbandwidth`, NCCL): how to run them, and the test rig's numbers. |
| [benchmarks/vllm](benchmarks/vllm/README.md) | **A language model on both cards**: vLLM with tensor parallel 2 on Qwen3, P2P off vs on, with every script and raw result. On the Turing pair P2P made generation 1 % faster, and vLLM's custom all-reduce reset the machine (possibly because of the two different chips, or the card behind the chipset). |
| [docs/security-review.md](docs/security-review.md) | What is in the fork beyond NVIDIA's official source, and whether it is safe to load. |
| [docs/test-rig-session.md](docs/test-rig-session.md) | What was actually done on the test rig, reconstructed from shell history and logs, dead ends included. |
| [tools/](tools) | Seven small CUDA programs (peer access matrix, P2P bandwidth, host-GPU bandwidth, peer access patterns, data checked, that find traffic a pair cannot carry, P2P through I/O memory for pairs CUDA will not pair, a copy through system memory as the baseline, and how much each card can allocate with every other card mapping it), the two Turing helpers in [tools/turing](tools/turing), plus NVIDIA's `cuda-samples`, `nvbandwidth`, `nccl` and `nccl-tests`, and aikitoria's `open-gpu-kernel-modules` (for its `libcuda` patch) as pinned submodules. |

## The procedure in short

For RTX 30 cards (GA102). Turing cards need the extra steps in [docs/turing.md](docs/turing.md). Pascal and Volta cards
use NVIDIA's stock driver instead: [docs/pascal-and-volta.md](docs/pascal-and-volta.md).

1. BIOS ([procedure step 1](docs/procedure.md#1-bios)): **Above 4G Decoding on** (without it no BAR1 above 256 MB, so
   no P2P), Resizable BAR (*Re-Size BAR Support*) on if the BIOS has it, Secure Boot off. BAR1 must be at least VRAM: a
   card left at 256 MB (no Resizable BAR in the BIOS or in its vBIOS) gets its window from geforce-bar1-resize at every
   boot, without flashing ([procedure step 4b](docs/procedure.md#4b-a-bar1-at-least-as-large-as-each-cards-memory)).
2. Ubuntu 26.04, then **`nvidia-driver-615-open`**. Not the `595` that `ubuntu-drivers` recommends. Hold the 615
   packages.
3. Kernel command line `iommu=pt` (IOMMU passthrough; Intel: `intel_iommu=on iommu=pt`). CUDA Toolkit 13.5 (`cuda-toolkit-13-5` only).
4. Clone the fork (pinned to `85929ec`), install `pahole`, run `make modules`.
5. Set `RMForceStaticBar1=0` for each card in modprobe.d. Set the card addresses and build path in `contrib/config.sh`.
6. **Disable the `remove` rules in udev's `71-nvidia.rules` and mask `nvidia-persistenced`.** Otherwise udev puts the
   stock driver back right after the swap.
7. Stop the desktop, run `p2p-load.sh`, run `p2p-check.sh --integrity`. The result must be `ALL PASS`.
8. Keep the NVIDIA driver out of the initramfs (needed on a fresh 26.04 install), then run `p2p-install.sh` and
   reboot, so the patched modules load at every boot. Then put the udev rules and
   `nvidia-persistenced` back to default and reboot once more.

## Status

| | |
|---|---|
| Whole procedure on a **fresh Ubuntu 26.04.1 install**, followed in order by a reader with only this repository (blind run) | **verified** 2026-11-23, after two fixes that are now in the docs |
| Whole procedure on the original test rig (24.04 upgraded to 26.04) | **verified** 2026-11-23 |
| Live load + integrity test (264 cases, 1.4 TiB byte-exact, both directions) | **passed** on both RTX 30 pairs |
| RTX 3080 pair (a 12 GB and a 10 GB card, swapped in for the 3090s) | **works**: P2P on at boot, integrity test passed twice, all benchmarks run twice with the same results, same speeds as the 3090s |
| Turing pair: RTX 2060 + GTX 1650 SUPER, two different chips ([docs/turing.md](docs/turing.md)) | **works, experimental**: memory windows grown from 256 MB to 8 GB and 4 GB at every boot, P2P on at boot, integrity test passed twice (240 cases), benchmarks run twice, same speeds as the RTX 30 pairs. CUDA needs a small preload shim for two different chips |
| Three RTX 3090s on another machine, one behind the chipset at PCIe 4.0 x4, two at PCIe 4.0 x8 ([docs/three-cards.md](docs/three-cards.md)) | **works**, trial load only: integrity test passed on all three pairs, 6.60 GB/s one way and 12.75 GB/s both ways for the pairs with the chipset card, 13.1 and 16.65 GB/s between the two CPU-lane cards. With peer access between all three, the old build refused any allocation above 16352 MiB per card; `b70b69c` allowed 23552 MiB per card, every byte checked. Two of the cards' vBIOS have no Resizable BAR: geforce-bar1-resize gave all three a 32 GiB BAR1 |
| Outside report: two RTX 3090s with a 256 MB BAR1 on a Huananzhi X99-F8 with a Xeon E5-2690 v4, legacy boot, no Resizable BAR setting in the BIOS ([docs/boards.md](docs/boards.md#outside-report-two-rtx-3090s-on-a-huananzhi-x99-f8)) | **works**: BAR1 256 MB -> 32 GB on both cards with geforce-bar1-resize, one card by resizing only and the other through `0x610`; integrity test passed (264 cases, 1.4 TiB byte-exact), 10.27 GB/s each way, 19.64 GB/s both ways at once |
| Outside report: RTX 3080 Ti + RTX 3090 on a Huananzhi X99-QD3 with a Xeon E5-2696 v4, the 3080 Ti on an OCuLink cable at PCIe 3.0 x4; boot install with Secure Boot on (MOK-signed modules) ([docs/boards.md](docs/boards.md#outside-report-rtx-3080-ti--rtx-3090-on-a-huananzhi-x99-qd3)) | **works**: integrity test passed (264 cases, 1.4 TiB byte-exact), 3.29 / 2.84 GB/s one way and 3.46 GB/s both ways, the x4 link's limit; latency 13.4-15.0 -> 1.0-1.1 µs. NCCL with `NCCL_P2P_LEVEL=PHB` was slower than through host RAM for large messages. After the integrity test the RTX 3090 stayed in P2 at about 165 W until a reboot ([troubleshooting](docs/troubleshooting.md#after-the-integrity-test-a-card-stays-in-p2-at-full-clocks)) |
| Outside report: four RTX 2080 Ti (TU102) on an Intel X79 board with a Xeon E5-2680 v2 ([docs/turing.md](docs/turing.md#outside-report-four-rtx-2080-ti-on-an-x79-board)) | **works**: integrity test passed on all six pairs, 3.1-5.2 GB/s one way, 10.4 GB/s both ways. Needed a boot option for the board's 64-bit address window. With peer access between all four cards at once, each card could use only about 5.3 of its 11 GB: a limit of the patched driver with three or more cards, changed since in fork commit `b70b69c`, confirmed on three RTX 3090s ([three cards](docs/three-cards.md#peer-memory-old-and-new-build); [troubleshooting](docs/troubleshooting.md#three-or-more-cards-cudamalloc-runs-out-of-memory-with-peer-access-between-all-of-them)) |
| Outside report: five RTX 2080 Ti 22 GB in a four-socket HP DL580 Gen9 with Xeon E7-8890 v4 ([docs/turing.md](docs/turing.md#outside-report-five-rtx-2080-ti-22-gb-on-a-four-socket-server)) | **works, but slower than host memory between sockets**: byte-exact over NVLink and between two sockets, but between sockets peer writes ran at 0.23 GB/s, about 25 times slower than copies through host memory. NVIDIA's own driver refuses P2P between sockets on these CPUs; the patched driver did not, and from fork commit `acd74cf` it does too ([troubleshooting](docs/troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)) |
| Outside report: three RTX A2000 12GB on an Intel Z390, one card in the CPU slot, two in chipset slots (NVIDIA's stock driver 580; [docs/boards.md](docs/boards.md), [issue #5](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/5)) | **works between the CPU-slot card and either chipset card** (byte-exact); **between the two chipset cards every write is lost**, with no error, while `nvidia-smi topo -p2p r` says `OK`. The same on the test rig's AMD B550 with DRMShare: two cards behind one chipset cannot reach each other |
| Outside report: RTX 5080 + RTX 5060 Ti 16 GB (Blackwell) on an ASUS X670E, the 5060 Ti on an M.2 adapter at PCIe 5.0 x4; NVIDIA's 620.73.04 with [QuixiAI's P2P patch](https://github.com/QuixiAI/open-gpu-kernel-modules), not this guide's driver ([issue #4](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/4)) | **P2P offered both ways, data not checked yet**: `NS` on the stock driver, `OK` with the patch, BAR1 16384 MiB on both cards, as large as their memory. On a 16 GB RTX 5060 Ti in another report that same `OK` came with every copy losing its data until static BAR1 was forced ([troubleshooting](docs/troubleshooting.md#rtx-50-with-16-gb-ok-and-peer-access-but-copies-lose-their-data)) |
| Two generations: RTX 2060 + RTX 3060, Turing + Ampere ([docs/mixed-generations.md](docs/mixed-generations.md)) | **works, experimental**, trial load only: with a patched copy of `libcuda`, CUDA peer access both ways, integrity test passed (264 cases, 1.4 TiB byte-exact) and NCCL `via P2P` (all-reduce 2.72 vs 1.83 GB/s); without it, as root, writes through the other card's memory window with the fork's `RMPeerIoMemBar1` key, byte-exact both ways, a 4-byte copy in 1.8 µs instead of 13.5-18 µs |
| Outside report: RTX 2070 8 GB (Turing, TU106) + RTX 3060 12 GB (Ampere) on an AMD X570 board, the patched copy of `libcuda` ([docs/mixed-generations.md](docs/mixed-generations.md#outside-report-rtx-2070--rtx-3060-on-an-x570), [#6](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/6)) | **works**: CUDA peer access both ways, 6.59 GB/s each way from the chipset's PCIe 4.0 x4 slot (4.07 / 3.91 GB/s on the stock driver), a 4-byte copy in 8.5 / 5.7 µs (19.9 / 20.5), NCCL `via P2P/direct pointer`, still on after a cold reboot. Byte-exact by the reporter's own SHA-256 checks; the integrity test was not reported. Needed `iommu=pt` |
| Tesla V100 pair (another machine, NVIDIA's stock driver 580, no patch; [docs/pascal-and-volta.md](docs/pascal-and-volta.md)) | **works** with the IOMMU in passthrough mode: integrity test passed (264 cases). Without passthrough, CUDA reported P2P while the IOMMU silently dropped the data |
| When P2P is not possible: memory sharing with DRMShare ([drmshare](https://github.com/Cinderella-Man/drmshare)) | **works, experimental**, not P2P, Vulkan programs only: Tesla V100 with an RTX 3090, an RTX 2060 or a GTX 1070 Ti on driver 580; RTX 2060 + RTX 3060 on 580, 595 and 615. Every copy byte-exact, as fast as CUDA P2P in the same slots; results in its repository |
| Pascal: 2x P106-090 in the test rig (NVIDIA's stock driver 580, no patch, no override; [docs/pascal-and-volta.md](docs/pascal-and-volta.md)) | **works**: integrity test passed (264 cases, 1.4 TiB byte-exact). CUDA 12.4 and PyTorch 2.14.1 verified on a GTX 1070 Ti. A P106-090 mining board could not carry P2P: its switches and chipset reject the traffic |
| Boot install: P2P on at every boot, with Ubuntu's default udev rules and `nvidia-persistenced` | **verified** over two reboots |
| vLLM end to end on the Turing pair (Qwen3, tensor parallel 2, [benchmarks/vllm](benchmarks/vllm/README.md)) | **run**: NCCL P2P made generation 1 % faster and prompts no faster, because the GTX 1650 SUPER's compute sets the pace. vLLM's custom all-reduce reset the machine; use `--disable-custom-all-reduce` there. Possibly caused by the two different chips or the chipset slot, see the next row |
| Both GPUs' kernels reading each other's memory at once (Turing pair, [troubleshooting](docs/troubleshooting.md#the-machine-resets-data-fabric-sync-flood)) | **resets the machine** at 36 x 512 threads (reproduced twice with `tools/p2p_patterns`, no vLLM); clean up to 24 x 512. One direction at a time, and copy engines both ways, are clean. Seen only on this pair of two different chips (which need the CUDA shim), with GPU0 behind the chipset: either may be the reason. Identical cards in the same slots: not tested yet. An outside report with identical cards on an Intel B460 board saw every read through the chipset come back as `0xffffffff` ([troubleshooting](docs/troubleshooting.md#peer-reads-return-0xffffffff-writes-work)), which points to the chipset |
| Kernel-update and rollback steps (17-18) | not run yet |
| Security review of everything in the fork that is not NVIDIA's code | [no malicious code found](docs/security-review.md) |

Test rig: Ryzen 9 3900X on a B550 board (one card in the chipset x4 slot), Ubuntu 26.04.1, kernel 7.0.0-44-generic,
driver 615.71.09, CUDA 13.5. Cards: 2x RTX 3090 (24 GiB, 32 GiB BAR1); then an RTX 3080 12 GB + RTX 3080 10 GB (16 GiB
BAR1 each) in the same slots, both GA102; then an RTX 2060 6 GB (TU104, 8 GiB BAR1) + GTX 1650 SUPER 4 GB (TU116,
4 GiB BAR1), see [docs/turing.md](docs/turing.md); then two P106-090 mining cards (GP106, Pascal) on NVIDIA's stock driver
580, see [docs/pascal-and-volta.md](docs/pascal-and-volta.md).

### What P2P changed on that rig

Without P2P, every transfer between the two cards makes a detour: GPU -> the computer's main memory -> the other GPU.
With P2P, one card writes straight into the other's memory. **The slots set the numbers:** one card sits in the B550
board's chipset slot, PCIe 3.0 x4 (about 3.3 GB/s each way at most), the other in a CPU slot, PCIe 4.0 x16, so every
route between them is capped by the x4 link. Two cards on PCIe 4.0 x8 CPU lanes copied 13.1 GB/s with P2P
([three cards](docs/three-cards.md)). Without P2P -> **with P2P**:

| | RTX 3090 pair | RTX 3080 pair | |
|---|---|---|---|
| Delay for one GPU to send a copy to the other | 19 -> **1.5 µs** | 19 -> **1.4 µs** | about 13x less |
| Both GPUs sending to each other at the same time | 3.49 -> **5.52 GB/s** | 3.50 -> **5.46 GB/s** | +56-58 % |
| Syncing a model split across both GPUs: they add up their partial results ¹ | 1.88 -> **2.75 GB/s** | 1.85 -> **2.72 GB/s** | +46-47 % |
| Collecting each other's data, so each GPU has a full copy ² | 1.61 -> **2.74 GB/s** | 1.57 -> **2.71 GB/s** | +70-73 % |
| Errors in 1.5 TB of GPU-to-GPU test copies | **0** | **0** | |

The latency figures are the average of both directions.

¹ NCCL `all_reduce`: when one model runs split across two GPUs, each computes half of every layer, and after the layer
the two halves are added up so both GPUs have the result. ² NCCL `all_gather`: each GPU holds a different chunk (for
example its half of the weights), and afterwards each has all of it. NCCL is the library that PyTorch, vLLM and most
multi-GPU software use to move data between GPUs.

These are speeds of the data exchange itself, **not** of a whole AI workload: how much faster a model runs depends on
how much of its time it spends exchanging data. (On upstream's own two-GPU machine, vLLM generated tokens anywhere from
no faster to 32 % faster, depending on prompt length. On this rig's Turing pair it was 1 % faster:
[benchmarks/vllm](benchmarks/vllm/README.md).) Absolute speeds on this rig are also held back by one card sitting in a slow x4 slot; with
both cards on CPU lanes they are several times higher. Full numbers and how to measure them:
[docs/benchmarks.md](docs/benchmarks.md).

## Disclaimer

This loads an **experimental, patched kernel driver**. It can hang the machine or corrupt GPU memory. The upstream
project has verified it only on RTX 3080 20GB pairs; other GA102 cards are "on by default, untested" there, and Turing
cards are opt-in. Use at your own risk, run the integrity test on your own pair, and keep a way back to stock
(`p2p-fallback.sh`).

## Credits

- [noon-at-cgn/geforce-dynbar1-p2p](https://github.com/noon-at-cgn/geforce-dynbar1-p2p): the patched driver and its
  scripts, which [the fork](https://github.com/Cinderella-Man/geforce-dynbar1-p2p) builds on. It in
  turn builds on the P2P work of tinygrad, aikitoria, Duanyll and dingiv (see its README).
- [noon-at-cgn/geforce-bar1-resize](https://github.com/noon-at-cgn/geforce-bar1-resize): enlarges the Turing cards'
  memory window at every boot ([docs/turing.md](docs/turing.md)); this guide uses [the fork](https://github.com/Cinderella-Man/geforce-bar1-resize), which carries
  fixes since.
- [aikitoria/open-gpu-kernel-modules](https://github.com/aikitoria/open-gpu-kernel-modules): the `libcuda` patch
  script that lets CUDA pair two GPU generations ([docs/mixed-generations.md](docs/mixed-generations.md)).
- Christian König and the [amdgpu](https://sources.debian.org/src/linux/6.19.6-2/drivers/gpu/drm/amd/amdgpu/amdgpu_dma_buf.c)
  developers: the dma-buf technique behind [drmshare](https://github.com/Cinderella-Man/drmshare), whose own credits name the llama.cpp work it builds on.
- [cmp50hx-unlock](https://github.com/xrip/cmp50hx-unlock): the earlier same-chip Turing P2P report (TU102), with a
  different route to large windows.
- [Ubsefor](https://github.com/Ubsefor/open-gpu-kernel-modules/commit/0e23c574b430c27d7b5ae394bc6ca488aff346cd): the
  CXL build fix for Linux 7.0.
- [NVIDIA open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules): the driver, dual MIT/GPLv2.
