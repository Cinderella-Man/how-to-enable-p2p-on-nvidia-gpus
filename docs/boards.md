# Boards and slots: will P2P work on yours?

The cards decide which driver you need (the table at the top of the [README](../README.md#which-path-is-yours)). The
**motherboard** decides whether the traffic between the two cards gets through, and how fast. P2P data travels from one
card through the board's PCIe paths into the other card, and each board has its own paths. This page collects what is
known, per board, from the test rig, three other machines, upstream's machine, and six outside reports.

## In short

- **Best: both cards on CPU lanes** (the CPU splits its lanes x8/x8 or x16/x16, no switch in between). Upstream's
  machine got 10.27 GB/s one way and 19.33 GB/s both ways at once.
- **Works with limits: one card in a chipset slot.** Speed is capped by the chipset's link (about 3 GB/s each way on the
  test rig's B550). Some traffic patterns break, and how depends on the chipset: on the B550, heavy reads in both
  directions at once reset the machine; on an Intel B460 (outside report), reads do not work at all.
- **Does not work: two cards behind the same chipset**, AMD or Intel. Every byte between them is lost, with no error,
  while `nvidia-smi topo -p2p r` says `OK`; each of the two works with a card on CPU lanes. Seen twice on 2026-11-27: on
  an Intel Z390 with CUDA P2P on the stock driver (three RTX A2000s, outside report:
  [issue #5](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/5)), and on the test rig's AMD
  B550 with DRMShare's memory sharing, where the chipset's own ports answer the traffic with "Unsupported Request"
  ([drmshare troubleshooting](https://github.com/Cinderella-Man/drmshare/blob/main/docs/troubleshooting.md#two-cards-behind-one-amd-chipset-the-copy-finishes-nothing-arrives)).
  Keep at most one card that uses P2P behind the chipset; more need CPU lanes, for example a bifurcation splitter in the
  CPU slot. On the test rig a x16 -> 4 x x4 Gen 3 splitter fixed it: the same three cards each on their own CPU port,
  every pair 3.30 GB/s, 0 wrong; a fourth card in the chipset slot then worked with all three (the one card behind the
  chipset). Set the board's lane setting for that slot (x4x4x4x4) and its speed (Gen3 for a Gen 3
  splitter) first, with one card straight in the slot: with the defaults the B550 found no card behind the splitter
  (no picture, its VGA debug light on).
- **Does not work: cards behind the cheap PCIe switches of mining boards.** The switch sends the traffic up to the
  chipset instead of across to the other card, and the chipset drops it. That holds for CUDA P2P and for the memory
  sharing of [drmshare](https://github.com/Cinderella-Man/drmshare/blob/main/docs/volta-dmabuf.md) alike.
- **Old Xeon boards (X79 with a Xeon E5 v1/v2):** the CPU passes 64-bit PCI addresses on only in a part of the range
  the firmware gives Linux. Windows grown at boot (Turing cards) can land outside it, and every card then fails to start
  ([troubleshooting](troubleshooting.md#after-the-bar1-resize-every-card-fails-kbusverifybar2_gm107--returned-garbage)).
- **Servers with two or more CPU sockets:** keep the cards that exchange data on one socket. Between two sockets the
  traffic crosses the link between the CPUs, and on a four-socket Xeon E7 v4 (outside report) peer writes ran at
  0.23 GB/s, about 25 times slower than copies through host memory. On Intel's Xeon E5/E7 up to v4 the driver refuses
  such pairs (`TNS`), as NVIDIA's own does
  ([troubleshooting](troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)).
- **On every board:** the IOMMU in passthrough mode ([procedure step 4](procedure.md#4-iommu-in-passthrough-mode)), or
  peer writes can be lost without any error. And test before you trust it ([below](#check-your-board)).

## What is known, board by board

| Board, CPU | Slots | Cards | Result |
|---|---|---|---|
| Upstream: X99, Xeon E5-2696 v4 | each card on its own CPU root port, no switch | 2x RTX 3080 20GB (patched driver) | **works**: 10.27 GB/s one way, 19.33 GB/s both ways ([upstream README](https://github.com/Cinderella-Man/geforce-dynbar1-p2p#tested-on)) |
| The test rig: B550, Ryzen 9 3900X | GPU0 in a **chipset slot** (PCIe 3.0 x4), GPU1 in the CPU slot (PCIe 4.0 x16) | 2x RTX 3090, RTX 3080 12 GB + 10 GB, RTX 2060 + GTX 1650 SUPER (patched driver); 2x P106-090 (stock driver); Tesla V100 + RTX 3090, V100 + RTX 2060 and V100 + GTX 1070 Ti (memory sharing through a dma-buf, [volta-dmabuf](https://github.com/Cinderella-Man/drmshare/blob/main/docs/volta-dmabuf.md)); RTX 2060 + RTX 3060 (the same on drivers 595 and 615, [dmabuf-615](https://github.com/Cinderella-Man/drmshare/blob/main/docs/dmabuf-615.md), [dmabuf-drivers](https://github.com/Cinderella-Man/drmshare/blob/main/docs/dmabuf-drivers.md)) | **works**, integrity test passed with every pair: about 3 GB/s each way, 5.5 GB/s both ways ([benchmarks](benchmarks.md)); the P106-090s 0.84 GB/s, their own PCIe 1.0 x4 limit. **But:** both GPUs' kernels reading each other's memory at once, with many threads, reset the machine ([troubleshooting](troubleshooting.md#the-machine-resets-data-fabric-sync-flood)); tested only with the Turing pair; memory sharing V100 + RTX 3090: 2.96 / 3.26 GB/s, V100 + RTX 2060: 2.91 / 3.28 GB/s, V100 + GTX 1070 Ti: 2.96 / 3.28 GB/s, RTX 2060 + RTX 3060 on driver 615: 2.93 / 3.28 GB/s (595: 2.97 / 3.28), 5.62-5.63 GB/s both ways for all four, byte-exact |
| ASUS TUF GAMING B450-PLUS II, Ryzen 7 5700X | GPU0 in a **chipset slot** (PCIe 2.0 x4), GPU1 in the CPU slot (PCIe 3.0 x16) | 2x Tesla V100 PCIe 32 GB (stock driver) | **works with `iommu=pt`**: 1.62 / 1.67 GB/s, 2.90 GB/s both ways. Without it, one direction's data was silently lost ([pascal-and-volta](pascal-and-volta.md#volta-two-tesla-v100s)). Memory sharing through a dma-buf ([volta-dmabuf](https://github.com/Cinderella-Man/drmshare/blob/main/docs/volta-dmabuf.md)): 1.67 / 1.63 GB/s, byte-exact |
| Gigabyte X570 AORUS ULTRA, Ryzen 9 5900X | GPU0 in a **chipset slot** (PCIe 4.0 x4), GPU1 and GPU2 on CPU lanes (PCIe 4.0 x8 each) | 3x RTX 3090 (patched driver, trial load; [three-cards](three-cards.md)) | **works**: integrity test passed on all three pairs, 6.60 GB/s one way and 12.75 GB/s both ways for the two pairs with the chipset card, 13.12 / 13.17 GB/s one way and 16.65 GB/s both ways for the two CPU-lane cards. Two of the cards' vBIOS have no Resizable BAR: geforce-bar1-resize enlarged all three, behind the chipset too |
| Mining board, Celeron 3865U (Intel Sunrise Point-LP chipset) | two ASMedia ASM1184e **switches**, four GPUs each, PCIe 1.0 x1 | 9x P106-090 (stock driver, `ForceP2P`) | **does not work**: the driver said yes, the first copy lost all its data ([pascal-and-volta](pascal-and-volta.md#the-test-on-a-mining-box-the-driver-said-yes-the-hardware-said-no)). Memory sharing through a dma-buf ([volta-dmabuf](https://github.com/Cinderella-Man/drmshare/blob/main/docs/volta-dmabuf.md#on-a-board-that-does-not-carry-peer-traffic)): the import works, but 0 of 16,777,216 words arrived on every path, without any error |
| Outside report, not verified here: ASUS B460, Core i5-10400 | GPU0 on CPU lanes (PCIe 3.0 x8), GPU1 in a **chipset slot** (x4 over DMI 3.0) | 2x RTX 4060 Ti 16GB (driver 620.70.06, a different P2P method) | **writes only**: byte-exact both ways, 5.44 GB/s both ways at once; every read came back as `0xffffffff`, without any error ([troubleshooting](troubleshooting.md#peer-reads-return-0xffffffff-writes-work)) |
| Outside report, not verified here: Z390, Core i3-9100F ([issue #5](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/5), [write-up and checker](https://gist.github.com/Cavemanmining/f8b12d6ab30dfa992309bfed3b661db2)) | GPU A on the CPU's x16 root port; GPU B on an x1 riser and GPU C in an x4 slot, **both on the chipset's root ports**; IOMMU off | 3x RTX A2000 12GB (stock driver 580: P2P enabled for these cards) | **works between the CPU-port card and either chipset card** (103 GiB checked, byte-exact); **between the two chipset cards every write is lost**, copy engine and SM stores, every size, both directions, while `topo -p2p r` says `OK`; no Xid, and nothing latched even in the raw error registers of the chipset's ports and the cards (the firmware keeps AER from Linux). llama.cpp with `GGML_CUDA_P2P=1` across them printed `0000...` |
| Outside report, not verified here: dual-socket Intel X99 | each card on PCIe 3.0 x16 CPU lanes, two cards per socket | 4x Tesla P40 24 GB (stock driver 580) | **works between two cards on the same socket, with `iommu=pt`**: 10.3 GB/s one way, 19.2 GB/s both ways, byte-exact (the reporter's own test, one pair). Without it every copy came back wrong, with `DMAR` faults and no error. Across the sockets the driver offers no P2P (`TNS`) ([pascal-and-volta](pascal-and-volta.md#outside-report-four-tesla-p40s-on-a-dual-socket-x99)) |
| Outside report, not verified here: HP ProLiant DL580 Gen9, 4x Xeon E7-8890 v4 (four sockets) | each card on its own CPU root port, PCIe 3.0 x16; three cards on three sockets, two on the fourth, those two joined by an NVLink bridge (`nvidia-smi topo -m`: `SYS` between every other pair, `NV2` for the bridged one) | 5x RTX 2080 Ti 22 GB (patched driver up to `b70b69c`, [turing.md](turing.md#outside-report-five-rtx-2080-ti-22-gb-on-a-four-socket-server)) | **works, but slower than host memory between sockets**: byte-exact over NVLink (about 38 GB/s) and between two sockets (246 of 252 cases, both ways), but between sockets peer writes ran at 0.23 GB/s and reads at 1.3 GB/s, while copies from host memory to a card peak at a little over 12 GB/s, so a copy staged through host memory is about 25 times faster (the reporter's estimate). The pinned driver refuses such pairs, as NVIDIA's own does ([troubleshooting](troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)); the reporter's table after the fix shows `TNS` for them, but whether the pinned build was loaded for it is not reported. No pair of PCIe cards on one socket to compare: the only two on one socket are the NVLink pair |
| Outside report, not verified here: Intel X79, Xeon E5-2680 v2 (one socket) | four cards, every pair through the CPU (`PHB`); slots and links not reported | 4x RTX 2080 Ti 11 GB (patched driver, [turing.md](turing.md#outside-report-four-rtx-2080-ti-on-an-x79-board)) | **works, after a boot option for the board's 64-bit window**: the grown windows first landed where the CPU does not decode them, and every card failed to start until `memmap=` kept Linux out of that range ([troubleshooting](troubleshooting.md#after-the-bar1-resize-every-card-fails-kbusverifybar2_gm107--returned-garbage)). Then the integrity test passed on all six pairs: 3.1-5.2 GB/s one way, 10.4 GB/s both ways, 0.9 µs. Room for four 16 GiB windows, not more |
| Outside report, not verified here: ASUS TUF GAMING X570-PRO, Ryzen 7 5800X ([drmshare#1](https://github.com/Cinderella-Man/drmshare/issues/1)) | GPU0 in a **chipset slot** (PCIe 4.0 x4), GPU1 in the CPU slot (PCIe 3.0 x16, the card's own limit) | RTX 3060 12 GB + RTX 2070 8 GB (patched driver and a patched copy of `libcuda`: two generations, [mixed-generations](mixed-generations.md#outside-report-rtx-2070--rtx-3060-on-an-x570)) | **works, with `iommu=pt`**: 6.59 GB/s each way, the chipset link's limit (the X570 AORUS ULTRA's chipset slot above: 6.60 GB/s), byte-exact by the reporter's own SHA-256 checks. With Ubuntu's default IOMMU mode the kernel logged `IO_PAGE_FAULT` under load from both cards, and NVMe drives dropped off during heavy writes |

## What the board decides

### The route

Look at the path between the two cards:

```bash
nvidia-smi topo -m
```

| Shown | Path between the two GPUs |
|---|---|
| `PIX`, `PXB` | through one or more PCIe switches, without the CPU (on mining boards: the switches that fail above) |
| `PHB` | through the CPU's PCIe host bridge: two CPU slots, or one CPU slot and one chipset slot (the test rig shows `PHB`) |
| `NODE`, `SYS` | between host bridges of one socket (`NODE`) or between CPU sockets (`SYS`). Across sockets P2P can be slower than host memory, and on Intel's Xeon E5/E7 up to v4 the driver refuses it ([troubleshooting](troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)) |

`topo -m` does not tell a CPU slot from a chipset slot. The board manual's block diagram does, or the PCI tree: a card
behind the chipset sits under the chipset's own bridges (`lspci -tv`; on the test rig GPU0 hangs below a CPU root port
and two bridges of the B550 chipset, GPU1 straight below a CPU root port).

### The speed

The slowest link on the path sets the speed, in both directions. A chipset slot shares the chipset's own link to the
CPU (PCIe 3.0 x4 on the B550, DMI 3.0 on Intel 400-series boards, about 4 GB/s), and a slot that is x16 in size may be
wired x4 or x1. How to read the real link: [troubleshooting](troubleshooting.md#p2p-works-but-the-bandwidth-is-low-3-gbs).

### What gets through

A **write** into the other card needs no answer, and every board above that carried P2P at all carried writes. A
**read** needs an answer back across the same path, and that is where chipsets differ:

| | Writes | Reads, one direction at a time | Reads, both directions at once, heavy |
|---|---|---|---|
| CPU lanes (upstream X99) | yes | yes | not tested |
| CPU lanes, Intel X79 (outside report) | yes | yes (integrity test, all six pairs) | not tested |
| X570 chipset slot (three RTX 3090s) | yes | yes, byte-exact (integrity test) | not tested |
| B550 chipset slot (test rig) | yes | yes, byte-exact | **resets the machine** (tested with two different Turing chips; identical cards not tested) |
| B460 chipset slot (outside report) | yes | **no**: `0xffffffff` | no |
| Two chipset slots, card to card: B550 (test rig, memory sharing), Z390 (outside report, CUDA P2P) | **no** | no | no |
| ASM1184e switch (mining board) | **no** | no | no |

NCCL (what PyTorch uses, and vLLM with its custom all-reduce off) mostly writes; on the test rig NCCL ran clean on
every pair. On an Intel CPU NCCL uses no P2P through the CPU (two CPU slots, or a CPU slot and a chipset slot) unless
`NCCL_P2P_LEVEL=PHB` is set ([troubleshooting](troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)). vLLM's custom all-reduce, on by default whenever CUDA offers P2P, reads in both directions at once
([benchmarks/vllm](../benchmarks/vllm/README.md)).

## Check your board

1. **IOMMU in passthrough mode**, [procedure step 4](procedure.md#4-iommu-in-passthrough-mode). Without it the V100
   machine (AMD) and the P40 machine (Intel, outside report) lost data silently.
2. **The route and the links**: `nvidia-smi topo -m`, the link check above, and with P2P enabled `nvidia-smi topo -p2p
   r` must show `OK`. `OK` is not proof: between two cards behind one chipset it showed `OK` and every write was lost,
   and so did a 16 GB RTX 50 card without static BAR1
   ([troubleshooting](troubleshooting.md#rtx-50-with-16-gb-ok-and-peer-access-but-copies-lose-their-data)).
   Find where each card hangs (`lspci -tv`) and run step 3 on every pair.
3. **The integrity test**, [procedure step 14](procedure.md#14-integrity-test): `ALL PASS` or nothing. It checks writes
   and reads byte by byte, so it catches lost writes and reads that do not work, as on the B460.
4. **The traffic patterns**, [`tools/p2p_patterns.cu`](../tools/p2p_patterns.cu): `r01` and `r10` (reads in each
   direction), `cewbi` and `cerbi` (copies both ways). Each ends with `DATA OK` or `DATA WRONG`. The mode `rbi` (heavy
   reads both ways at once) reset the test rig: run it only with your work saved
   ([troubleshooting](troubleshooting.md#the-machine-resets-data-fabric-sync-flood)).

Tested another board? A report helps: the board, the slots, the cards, and what steps 3 and 4 printed, in an
[issue](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues).
