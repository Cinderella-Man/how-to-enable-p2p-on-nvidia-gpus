# Turing cards (RTX 20 / GTX 16): experimental

P2P on Turing GeForce cards works, but it takes more than the RTX 30 route in [procedure.md](procedure.md): the cards
need a bigger memory window first, P2P has to be switched on per card, and a pair of two *different* chips needs a
workaround for CUDA itself. Everything here was done on the test rig on 2026-11-23 with:

| | Card | Chip | Memory | Slot |
|---|---|---|---|---|
| GPU0 `04:00.0` | EVGA GeForce RTX 2060 | TU104 (`10de:1e89`) | 6 GB | B550 chipset slot, PCIe 3.0 x4 |
| GPU1 `2b:00.0` | MSI GeForce GTX 1650 SUPER | TU116 (`10de:2187`) | 4 GB | CPU slot, PCIe 3.0 x16 |

Result: P2P on at every boot, the integrity test passed twice (240 cases, 636 GiB of byte-exact copies each time),
and the benchmarks match the RTX 3090 and 3080 pairs in the same slots ([results](#results)). As far as we could find, this is the first
integrity-verified P2P between two different Turing chips. Same-chip Turing P2P (RTX 2080 Ti with CMP 50HX cards, all
TU102) was reported earlier with other patches: [cmp50hx-unlock](https://github.com/xrip/cmp50hx-unlock/blob/master/docs/P2P.md).
With this guide, four identical TU102 cards (RTX 2080 Ti) on an Intel X79 board passed the integrity test on all six
pairs, in an outside report ([below](#outside-report-four-rtx-2080-ti-on-an-x79-board)). Five RTX 2080 Ti 22 GB in a
four-socket server copied byte-exact too, but between sockets slower than through host memory
([below](#outside-report-five-rtx-2080-ti-22-gb-on-a-four-socket-server)). An RTX 2070 (TU106) reached an RTX 3060, a
card of the next generation, through [mixed-generations.md](mixed-generations.md#outside-report-rtx-2070--rtx-3060-on-an-x570)
in a third outside report.

**Experimental.** Every piece below was verified on one pair, one board and one driver version. Run the integrity
test on your own pair before trusting it, and keep a way to reach the machine if it hangs.

**Not for GTX 10 (Pascal) or older.** NVIDIA's open kernel modules need the GSP processor that came with Turing. On
the test rig the driver rejected a GTX 1070 Ti with `not supported by open nvidia.ko because it does not include the
required GPU System Processor (GSP)`. Driver 615 and CUDA 13 no longer support Pascal at all. What does work on
Pascal and Volta with NVIDIA's stock driver: [pascal-and-volta.md](pascal-and-volta.md).

## How it differs from RTX 30 cards

| | RTX 3080 / 3090 (GA102) | Turing |
|---|---|---|
| Memory window (BAR1) | Resizable BAR from the firmware: 16 or 32 GB | **256 MB**; the cards never got NVIDIA's Resizable BAR. Grown at every boot by [geforce-bar1-resize](https://github.com/Cinderella-Man/geforce-bar1-resize) plus a pre-step from this repository (T1-T3) |
| P2P in the patched driver | on by default | **opt-in** per card: trial load, integrity test, then `p2p-enable.sh` (T4-T6) |
| Integrity test | full run, 264 cases | cards with 6 GB or less skip the 4 GB sizes, so `p2p-enable.sh` needs `--skip-integrity` |
| CUDA | peer access as soon as the driver offers it | for **two different chips** (here TU104 + TU116) CUDA refuses; a small preload shim gets around it (T5). Two identical chips do not need it |

## Before you start

Do [procedure.md](procedure.md) steps 1-10 and 11a: BIOS, Ubuntu, driver 615, IOMMU, **step 4b** (geforce-bar1-resize,
which every Turing card needs, with the initramfs fix of step 16a before its reboot), CUDA, the fork, the build and
`contrib/config.sh`. In step 4b add the USB-C pre-step [T2](#t2-add-the-usb-c-pre-step) before the reboot; T1 and T3
below show what the test rig's Turing cards printed. Skip 11b: the resize tool writes that file. Then come back here.

Check that your cards are Turing and stuck at 256 MB:

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do lspci -nns $d; sudo lspci -vv -s $d | grep -E 'Region 1:|BAR 1:'; done
```

Expected: `TU1xx` in the names, `[size=256M]` and `BAR 1: current size: 256MB, supported: 64MB 128MB 256MB`.

## T1. Install geforce-bar1-resize (pinned)

This is [procedure.md step 4b](procedure.md#4b-a-bar1-at-least-as-large-as-each-cards-memory), the same for every card
whose BAR1 is smaller than its memory: the pinned clone of
[geforce-bar1-resize](https://github.com/Cinderella-Man/geforce-bar1-resize), the read-only check, the install with
`DRIVER_OPTION=on`, and step 16a before the reboot. On the test rig the check ran with each card's memory size:

```bash
sudo scripts/geforce-bar1-resize check --vram 6G 0000:04:00.0
```

```bash
sudo scripts/geforce-bar1-resize check --vram 4G 0000:2b:00.0
```

Each card must show six lines starting with `ok` (S1 to S6) and a `PLAN` line `arm 0x610 VAL=7, resize to 8192 MiB`
(6 GB card) or `arm 0x610 VAL=6, resize to 4096 MiB` (4 GB card). An 8 GB card gets `VAL=7` too, a window as large as
its memory, which was enough for P2P on an RTX 2070 in an outside report. A card behind a chipset or other PCIe switch also
prints `behind a PCIe switch: yes` and a note that the plain resize usually fails there: T2 is what makes it work, so
add it before step 4b's reboot.

## T2. Add the USB-C pre-step

RTX 20 and GTX 16 cards have a USB-C controller (and a UCSI function) next to the GPU. Their address ranges sit in
the same window as the GPU's BAR1, and the kernel refuses to grow a window that holds another device's range: the
resize fails with `No space left on device`. Remove those two functions first and the kernel's own resize grows every
window up to the root port by itself, also behind the B550 chipset, and without touching the chipset's other devices
(network, SATA, USB).

[`tools/turing/gpu-usbc-off`](../tools/turing/gpu-usbc-off) does exactly that: it removes only NVIDIA functions of
class USB xHCI (`0c0330`) or UCSI (`0c8000`) that share a slot with an NVIDIA GPU. Run it before the resize tool,
through a systemd drop-in (the tool's own files stay unchanged):

```bash
cd ~/how-to-enable-p2p-on-nvidia-gpus
sudo install -m 0755 tools/turing/gpu-usbc-off /usr/local/sbin/gpu-usbc-off
sudo mkdir -p /etc/systemd/system/geforce-bar1-resize.service.d
printf '[Service]\nExecStartPre=/usr/local/sbin/gpu-usbc-off\n' | sudo tee /etc/systemd/system/geforce-bar1-resize.service.d/10-gpu-usbc-off.conf
sudo systemctl daemon-reload
```

Side effect: the cards' USB-C ports do not work while this is in place.

Larger windows on Turing are not new in themselves. [NvStrapsReBar](https://github.com/terminatorul/NvStrapsReBar)
does it by flashing a modified UEFI onto the motherboard, cmp50hx-unlock with kernel and firmware patches, and
geforce-bar1-resize alone already reached 4 GB on a user's GTX 1650. What T2 adds is a way to make room where the
resize fails for lack of it: no flashing, no kernel patches and no boot options, even behind a chipset.

## T3. Reboot and check the windows

The reboot of step 4b, here with the USB-C pre-step:

```bash
sudo reboot
```

```bash
journalctl -b -u geforce-bar1-resize --no-pager -o cat | grep -E 'gpu-usbc-off|armed and resized'
```

Expected (test rig):

```
gpu-usbc-off: removing 0000:04:00.2 (class 0x0c0330) next to GPU 0000:04:00.0
gpu-usbc-off: removing 0000:04:00.3 (class 0x0c8000) next to GPU 0000:04:00.0
gpu-usbc-off: removing 0000:2b:00.2 (class 0x0c0330) next to GPU 0000:2b:00.0
gpu-usbc-off: removing 0000:2b:00.3 (class 0x0c8000) next to GPU 0000:2b:00.0
... 0000:04:00.0 armed and resized to 8192 MiB
... 0000:2b:00.0 armed and resized to 4096 MiB
```

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "$d $(sudo lspci -vv -s $d | grep -oE 'Region 1:.*')"; done
```

Each `Region 1` must be at least the card's memory (`[size=8G]`, `[size=4G]`). Then check that the driver started on
every card with the new windows:

```bash
sudo dmesg | grep -E 'RmInitAdapter failed|kbusVerifyBar2' || echo clean
```

It must print `clean`. If it prints `kbusVerifyBar2_GM107: ... returned garbage` and `RmInitAdapter failed`, the
windows moved to addresses the CPU does not pass on to the cards, as on an Intel X79 board in an outside report:
[troubleshooting](troubleshooting.md#after-the-bar1-resize-every-card-fails-kbusverifybar2_gm107--returned-garbage).
Reboot after fixing it; do not unload the driver.

Then the pair check:

```bash
cd ~/geforce-dynbar1-p2p && contrib/p2p-check.sh --pairs
```

Expected: `untested (TU104 + TU116): run p2p-check.sh --integrity on a trial load ...`. Before T1-T3 it said
`not supported (BAR1 of ... is 256 MiB, smaller than its ... MiB of VRAM ...)`.

## T4. Trial load with P2P on

Do [procedure.md step 12](procedure.md#12-prepare-the-live-swap-stop-everything-that-reloads-the-stock-driver) (udev
override, mask `nvidia-persistenced`, stop the desktop), then load the patched build with P2P switched on for both
cards:

```bash
cd ~/geforce-dynbar1-p2p
sudo env P2P_ENABLE=1 contrib/p2p-load.sh --yes
```

The end of its output must show `OK` in both `topo -p2p` tables, and the windows keep their size through the driver
reload.

## T5. CUDA, and the integrity test

```bash
~/how-to-enable-p2p-on-nvidia-gpus/tools/p2p_access
```

Two identical Turing chips should print `YES` here: go straight to the integrity test below, without the shim.

A pair of **different** chips prints `NO` although the driver says `OK`. The kernel driver really does report P2P
as supported: traced on the test rig, its capability answer to CUDA was `0x2043` (reads, writes, PCIe, PCIe-BAR1) for
both directions. But NVIDIA's closed CUDA library, libcuda, refuses peer access between GPUs whose chip
*implementation* differs. It reads that from each GPU through the driver call `MC_GET_ARCH_INFO`: architecture
`0x160` (Turing) for both, implementation `0x4` (TU104) for the RTX 2060 and `0x8` (TU116) for the 1650 SUPER.

[`tools/turing/chipid-shim.c`](../tools/turing/chipid-shim.c) is a small preload library that rewrites that one answer
inside one process, so libcuda sees one chip. It changes nothing in the kernel, the driver or the GPUs, and does
nothing unless you set `P2P_CHIP_IMPL_MAP=ARCH:FROM:TO`. Build it and look up your values:

```bash
cd ~/how-to-enable-p2p-on-nvidia-gpus/tools/turing
gcc -O2 -shared -fPIC chipid-shim.c -o libchipid-shim.so -ldl
P2P_CHIP_IMPL_VERBOSE=1 LD_PRELOAD=$PWD/libchipid-shim.so ../p2p_access
```

```
chipid-shim: GPU object 0x5c000003 architecture 0x160 implementation 0x4
chipid-shim: GPU object 0x5c00000a architecture 0x160 implementation 0x8
GPU 0 -> GPU 1: NO
```

Map one implementation to the other (here TU116 `0x8` to TU104 `0x4`) and check again:

```bash
P2P_CHIP_IMPL_MAP=0x160:0x8:0x4 LD_PRELOAD=$PWD/libchipid-shim.so ../p2p_access
```

Expected: `YES` both ways. Now the real test, with the shim (or without it, for two identical chips):

```bash
cd ~/geforce-dynbar1-p2p
sudo env P2P_CHIP_IMPL_MAP=0x160:0x8:0x4 LD_PRELOAD=$HOME/how-to-enable-p2p-on-nvidia-gpus/tools/turing/libchipid-shim.so contrib/p2p-check.sh --integrity
```

The last line must be `ALL PASS`. Cards with 4 GB skip the 4 GB sizes (`skip malloc 4 GiB: ... MiB free`), so the
run has 240 cases instead of 264. The end of the test rig's run after T6, in the boot setup:

```
skip malloc 4 GiB: 5655 MiB free on A, 3654 MiB on B
skip cumem  4 GiB: 5655 MiB free on A, 3654 MiB on B
bandwidth (cudaMemcpyPeerAsync, 256 MiB x 20, contents checked): A->B 3.28 GB/s, B->A 2.93 GB/s, both ways at once 5.49 GB/s
RESULT PASS 0000:04:00.0 0000:2b:00.0 max-mib 4096 cases 240 transfers 1920 copied 636.0 GiB
PASS integrity 0000:04:00.0 <-> 0000:2b:00.0 (max-mib 4096, 240 cases)
note: a run below --max-mib 4096 (264 cases) does not count for p2p-enable.sh
```

The run on the trial load before it passed the same way (3.28 / 2.95 / 5.52 GB/s). Each took just under 5 minutes,
and the kernel log had no Xid, AER or DMAR errors. The note in the last line is why T6 needs `--skip-integrity`.

**The shim is a workaround, not a fix.** libcuda may use the chip implementation for more than this check. On the
test rig the integrity test, `p2pBandwidthLatencyTest`, `nvbandwidth` and NCCL all ran clean with it, but that is one
pair. Use it only for the programs that need P2P, never in `/etc/ld.so.preload`, and repeat the integrity test after
any driver update.

## T6. Switch P2P on for every boot

```bash
cd ~/geforce-dynbar1-p2p
sudo contrib/p2p-enable.sh --dry-run --skip-integrity 0000:04:00.0 0000:2b:00.0
```

```bash
sudo contrib/p2p-enable.sh --yes --skip-integrity 0000:04:00.0 0000:2b:00.0
```

It adds an entry per card (tied to its PCI ids) with `keys=RMDynBar1P2PEnable=1;` to `/etc/geforce-bar1-resize.conf`
and rewrites the modprobe option file. `--skip-integrity` is needed because its gate wants the full 264-case run,
which a 4 GB card cannot do; the reduced run above passed.

Do the boot install ([procedure.md step 16b](procedure.md#16b-install-and-reboot)) if you have not yet, put udev and
`nvidia-persistenced` back to Ubuntu's defaults
([as in step 16](procedure.md#put-udev-and-nvidia-persistenced-back-to-ubuntus-defaults)), and reboot. Then:

```bash
cd ~/geforce-dynbar1-p2p && sudo contrib/p2p-check.sh
```

Expected: `opted in (on, TU104 + TU116: RMDynBar1P2PEnable=1; ...)` and `SETUP OK, DATA NOT CHECKED` (no data moved:
the integrity test above checked the data); `nvidia-smi topo -p2p r` shows `OK`, P2P offered. With the shim, `p2p_access` prints `YES`; without it, `NO` (as it should).

## Using it

Run every CUDA program that should use P2P with the two variables, for example:

```bash
P2P_CHIP_IMPL_MAP=0x160:0x8:0x4 LD_PRELOAD=$HOME/how-to-enable-p2p-on-nvidia-gpus/tools/turing/libchipid-shim.so python3 your_script.py
```

NCCL picks `via P2P/direct` by itself once CUDA offers peer access (on an Intel CPU only with `NCCL_P2P_LEVEL=PHB`:
[troubleshooting](troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)). Two identical chips need
neither of the two variables.

**llama.cpp** uses peer access only with `GGML_CUDA_P2P=1` (checked at llama.cpp `52975342`), or through NCCL when it
was built with NCCL (CMake prints `NCCL not found` otherwise). **Three or more cards:** `GGML_CUDA_P2P=1` gives every
card access to all memory of every other card. Up to fork commit `25c929e` the patched driver then let each card map
only about one card's BAR1 of the others' memory in total: with four RTX 2080 Ti, about 5.3 of 11 GB per card
([troubleshooting](troubleshooting.md#three-or-more-cards-cudamalloc-runs-out-of-memory-with-peer-access-between-all-of-them)). The pinned
`b70b69c` counts per other card instead, which lifts that (checked on three RTX 3090s,
[three-cards.md](three-cards.md#peer-memory-old-and-new-build)). llama.cpp
built with NCCL, without `GGML_CUDA_P2P`, does not run into it with any build. With three or more cards, building llama.cpp with
NCCL matters more than P2P: about 4 times the prompt speed on three RTX 3090s even through host memory
([three-cards.md](three-cards.md#llamacpp-build-it-with-nccl)).

**vLLM: pass `--disable-custom-all-reduce`.** On the test rig, vLLM's custom all-reduce reset the whole machine with an
"uncorrected error caused a data fabric sync flood event". The trigger is both GPUs' kernels reading each other's memory
at the same time, which [`tools/p2p_patterns.cu`](../tools/p2p_patterns.cu) reproduces without vLLM
([troubleshooting](troubleshooting.md#the-machine-resets-data-fabric-sync-flood)). It may come from this pair being two
different chips that run through the shim above, or from GPU0 sitting behind the chipset; an outside report with
identical cards on an Intel board points to the chipset. A pair of identical Turing cards has not been tested. vLLM with
NCCL's P2P ran clean for an hour. The end-to-end numbers: [benchmarks/vllm](../benchmarks/vllm/README.md).

## Results

Same rig, same two slots as the RTX 3080 pair in [benchmarks.md](benchmarks.md) (GPU0 in the B550 chipset slot, PCIe 3.0
x4, which caps every transfer; GPU1 in a CPU slot); every CUDA program ran with the shim.
Without P2P (through host RAM) -> **with P2P**:

| | Turing pair | RTX 3080 pair |
|---|---|---|
| Delay for one GPU to send a copy to the other, average of both directions | 29 -> **1.5 µs** | 19 -> 1.4 µs |
| Both GPUs sending to each other at the same time | 3.26 -> **5.49 GB/s** | 3.50 -> 5.46 GB/s |
| NCCL all_reduce (syncing a model split across both GPUs), 512 MiB | 1.89 -> **2.74 GB/s** | 1.85 -> 2.72 GB/s |
| NCCL all_gather (each GPU collects the other's data), 512 MiB | 1.53 -> **2.73 GB/s** | 1.56 -> 2.69 GB/s |
| NCCL send/recv, 512 MiB | 1.86 -> **2.49 GB/s** | 1.79 -> 2.72 GB/s |
| Errors in 1.3 TB of GPU-to-GPU test copies (two integrity runs) | **0** | 0 |

P2P on Turing is as fast as on the RTX 3080s here: GPU0's x4 chipset link sets the pace for both pairs. NCCL's
largest size is 512 MiB because of the 4 GB card. All numbers, how they were measured, and how repeatable they are:
[benchmarks.md](benchmarks.md#turing-pair-rtx-2060--gtx-1650-super).

## Outside report: four RTX 2080 Ti on an X79 board

From an outside report by [CryptoHolmes](https://x.com/CryptoHolmes), not reproduced here
([post on X](https://x.com/CryptoHolmes/status/2125435768625889784),
[issue 2](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/2)).

| | |
|---|---|
| GPUs | 4x RTX 2080 Ti 11 GB (TU102, four identical chips), windows grown to 16 GiB with T1-T3 |
| Board | Intel X79, Xeon E5-2680 v2 (one socket); every pair through the CPU (`PHB`); slots and links not reported |
| Software | Ubuntu 26.04, this guide's patched driver 615.71.09 |

**Result:** the integrity test passed on all six pairs: 3.1 to 5.2 GB/s one way, 10.4 GB/s both ways, 0.9 µs.

On the way:

- **The board's 64-bit window.** After the resize every card failed to start: the windows had moved to addresses the
  CPU does not decode. A `memmap=` boot option fixed it
  ([troubleshooting](troubleshooting.md#after-the-bar1-resize-every-card-fails-kbusverifybar2_gm107--returned-garbage)).
  That board has room for four 16 GiB windows and no more.
- **Unloading the driver after the failed start crashed the kernel**: reboot instead (same entry).
- **Leftover packages of Ubuntu's prebuilt 595 modules** stopped `p2p-load.sh`
  ([procedure step 3](procedure.md#leftovers-of-ubuntus-prebuilt-modules)).
- **Clock lock.** These four cards fall off the bus without a 1650 MHz clock lock, and the driver swap drops it
  ([procedure step 13](procedure.md#13-trial-load-nothing-is-installed-a-reboot-returns-to-stock)).
- **NCCL** went through host RAM until `NCCL_P2P_LEVEL` was set, as on any Intel CPU
  ([troubleshooting](troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)).
- **Peer access between all four cards at once** left about 5.3 of 11 GB usable per card, a limit of the driver they
  ran that fork commit `b70b69c` changes (checked on three RTX 3090s since;
  [troubleshooting](troubleshooting.md#three-or-more-cards-cudamalloc-runs-out-of-memory-with-peer-access-between-all-of-them)).
  "Pairs" below means peer access only between cards 0-1 and 2-3 (the reporter's llama.cpp change), which avoids it.

Workloads, all at 150 W and 1650 MHz, P2P off -> on (the reporter's runs):

| Workload | P2P off | P2P on | Change |
|---|---|---|---|
| llama.cpp Qwen3.5-4B Q8, 4-GPU tensor split, pp512 / tg128 (all-to-all) | 1037 / 77.7 | 1618 / 90.0 | +56 % / +16 % |
| llama.cpp Qwen3.8-27B Q6, tensor split, tg128 (all-to-all) | 33.0 | 38.9 | +18 %, prompt runs out of memory |
| llama.cpp Qwen3.8-27B Q6, tensor split, pp512 / tg128 (pairs) | 255 / 33.0 | 304 / 35.7 | +19 % / +8 % |
| llama.cpp Qwen3.6-35B-A3B Q4, tensor split, pp512 / tg128 (pairs) | 939 / 67.2 | 993 / 73.7 | +6 % / +10 % |
| llama.cpp layer split, any model | | | none |
| ComfyUI Raylight, Wan 2.1 1.3B, 2 / 4 GPUs (NCCL), time | 79.2 / 48.5 s | 77.3 / 50.5 s | -2 % / +4 % |
| vLLM 0.34.0 Qwen3-14B FP16, TP4 throughput (NCCL) | 1152 tok/s | 1111 tok/s | -4 % |
| vLLM 0.34.0 Qwen3-14B FP16, TP2 x PP2 throughput (NCCL) | 857 tok/s | 710 tok/s | -17 % |

Tensor split gains and layer split does not, as with the Tesla P40s
([pascal-and-volta](pascal-and-volta.md#outside-report-four-tesla-p40s-on-a-dual-socket-x99)). The NCCL programs
did not gain here; the report does not say whether `NCCL_P2P_LEVEL` was set in those runs, or whether vLLM's custom
all-reduce was on. `tools/p2p_patterns` was not run, so the
[machine reset](troubleshooting.md#the-machine-resets-data-fabric-sync-flood) with reads both ways is still untested
on identical cards.

## Outside report: five RTX 2080 Ti 22 GB on a four-socket server

From an outside report by [gordan-bobic](https://github.com/gordan-bobic), not reproduced here
([issue 3](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/3)).

| | |
|---|---|
| GPUs | 5x RTX 2080 Ti modified to 22 GB (four `10de:1e07`, one `10de:1e04`, all TU102), windows grown to 32 GiB with geforce-bar1-resize |
| Machine | HP ProLiant DL580 Gen9, 4x Xeon E7-8890 v4 (Broadwell-EX). Each card on its own CPU root port (`8086:6f08`, `8086:6f04`), PCIe 3.0 x16: three cards on three sockets, two on the fourth, those two joined by an NVLink bridge. `nvidia-smi topo -m`: `SYS` between every pair except the bridged one, `NV2` (two links); the reporter's table is in [troubleshooting](troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory) |
| Software | AlmaLinux 10, kernel 6.12, this guide's patched driver 615.71.09 built through the fork's DKMS package, before `acd74cf` |

**Result: works, but between sockets slower than host memory.**

- **The windows.** geforce-bar1-resize's plain resize failed with `ENOSPC` on the CPU root ports (the firmware had
  sized their windows to 289 MiB). Its optional layout module rearranged them, and every card got a 32 GiB BAR1
  through `0x610` (the frame-buffer size override of T1; it sets the window size and has nothing to do with the
  path the data takes). No BIOS change was needed: each socket's 64-bit range is 128 GiB.
- **P2P offered** on all ten pairs with that build (`nvidia-smi topo -p2p r` and `w`: `OK`); the data below.
- **NVLink pair:** 60.8 GiB copied byte-exact in 192 cases, about 38 GB/s on 256 MiB copies. NVLink is not PCIe P2P:
  NVIDIA's stock driver offers it too.
- **Two cards on two sockets:** 246 of 252 cases, every one byte-exact both ways, up to 4 GiB, then the test's time
  limit ([troubleshooting](troubleshooting.md#p2p-checksh---integrity-times-out-on-a-slow-pair-every-case-clean)). No
  `Xid`, AER or DMAR events.
- **Speed between sockets:** 0.23 GB/s for peer writes, 1.3 GB/s for peer reads. Copies from host memory to a
  card peak at a little over 12 GB/s on that machine, so even a copy staged through host memory (two such trips) is
  about 25 times faster than the peer writes, by the reporter's estimate. ACS and the IOMMU made no real difference
  (at most 0.4 GB/s with both off). Every pair of PCIe cards in this machine is on two sockets, so P2P only made
  things slower there.

That is the path between the sockets, which NVIDIA's own driver refuses on these CPUs, and the patched driver did not.
The pinned commit refuses it too
([troubleshooting](troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)).
After the fix the reporter's `nvidia-smi topo -p2p r` shows `TNS` for the nine pairs between sockets and `OK` for the
NVLink pair. That is the expected table, but NVIDIA's own driver shows the same one, and which of the two was loaded
is not reported yet, so the fix still waits for its first run on two sockets. On such a machine, put the cards that
exchange data on one socket. Two cards on one socket of a four-socket Xeon E7 have not been measured: here the only
two are the NVLink pair, which CUDA connects over NVLink.

Also in the report: `nvAssertFailedNoLog: Assertion failed: value == 1 @ kern_disp_0400.c:236` twice per boot on one
card. That line is in `kdispDetectSliLink_v04_00`, NVIDIA's test for an SLI bridge between two cards (it drives a pin
on one card and reads it on the other), stock code that the fork does not change. Read from the source; not seen
here.

## What did not work, and why

All of these were tried on the test rig, so you do not have to:

| Tried | What happened |
|---|---|
| The resize tool alone | `resize failed (No space left on device)` for both cards: the GPUs' own USB-C functions sat in the windows. Fixed by T2. |
| The tool's layout module (`--layout dryrun`) | Plan only. It would refuse anyway: the chipset's USB and SATA controllers and the GPUs' USB-C functions already have drivers when it runs, and it never touches the boot VGA card. Upstream has not tested it on real switch hardware, and on this board it would hold the network card. |
| Arm `0x610`, then a warm reboot, hoping the firmware sizes the window | The firmware still assigned 256 MB. |
| Remove the whole chipset root port and rescan, with the BAR1 size set by hand | **Hard freeze**, power cycle needed; not even a software reboot timer fired. Do not. |
| Smaller windows | No help: the patch needs BAR1 at least as large as VRAM, and the firmware's 289 MB windows had no room above 256 MB anyway. |

The cmp50hx-unlock project solved the same window problem on TU102 cards differently, with the kernel options
`pci=realloc,hpmemsize=8G` plus a firmware or kernel ReBAR patch. Not tried here.

For experiments like these, arm the AMD chipset's hardware watchdog first, so a frozen machine resets itself
(runtime only, gone after a reboot):

```bash
sudo modprobe sp5100_tco
sudo mkdir -p /run/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=60s\n' | sudo tee /run/systemd/system.conf.d/90-watchdog.conf
sudo systemctl daemon-reexec
```

## Undo

```bash
cd ~/geforce-dynbar1-p2p && sudo contrib/p2p-enable.sh --yes --undo 0000:04:00.0 0000:2b:00.0
sudo rm -r /etc/systemd/system/geforce-bar1-resize.service.d /usr/local/sbin/gpu-usbc-off
cd ~/geforce-bar1-resize && sudo ./uninstall.sh
sudo reboot
```

`uninstall.sh` removes every `RMForceStaticBar1=0` from the modprobe option file. If you swap back to RTX 30 cards,
write that file again ([procedure.md step 11b](procedure.md#11b-driver-dynamic-bar1-for-each-card-rmforcestaticbar10)).

Leaving the patched driver as well? Run [procedure.md step 18](procedure.md#18-back-to-stock) (`p2p-fallback.sh`)
**before** `uninstall.sh`: the fallback refuses to run once that option is gone (`ABORT: restore the
RMForceStaticBar1=0 option first`). On the test rig it had to be put back for a moment to finish the switch to driver
580.
