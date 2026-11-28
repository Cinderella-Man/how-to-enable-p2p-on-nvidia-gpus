# Two generations: RTX 2060 (Turing) + RTX 3060 (Ampere), experimental

CUDA never offers peer access between GPUs of different architectures, whatever the driver says: on this pair
`cudaDeviceCanAccessPeer` is 0 both ways, and NCCL, PyTorch and vLLM send every GPU-to-GPU copy through host RAM.
On the test rig two ways around that worked, byte-exact in both directions. If neither fits, because you want to stay
on NVIDIA's stock driver or your program uses Vulkan rather than CUDA, the fallback is memory sharing with
[DRMShare](https://github.com/Cinderella-Man/drmshare/blob/main/docs/dmabuf-615.md): not P2P, Vulkan programs only, tested on this same pair
([when to use it](../README.md#when-p2p-is-not-possible-drmshare)).

| | Route 1: CUDA peer access | Route 2: I/O memory |
|---|---|---|
| How | a patched **copy** of `libcuda`, loaded only by the programs you start with it | the GPU writes into the other card's memory window (BAR1), registered as I/O memory; CUDA's peer check is never asked |
| Who uses P2P | everything: NCCL, PyTorch, vLLM, CUDA programs | only programs written for it, such as [`tools/p2p_iomem.cu`](../tools/p2p_iomem.cu), run as root |
| Changes | NVIDIA's `libcuda` binary (4 bytes, in a copy; [aikitoria's script](https://github.com/aikitoria/open-gpu-kernel-modules/blob/efed6748b6e7bfc81273f61c148554aa5944e107/patch-libcuda-p2p.py)) | a driver key of the fork, `RMPeerIoMemBar1=1` |
| Result | integrity test **PASS**, 264 cases, 1.4 TiB byte-exact; NCCL `via P2P`, all-reduce 2.72 GB/s (1.83 without P2P); a 4-byte copy in 2.1 µs (13.5-18 µs through host RAM) | 62 GiB byte-exact; writes 2.93 / 3.28 GB/s, a 4-byte copy in 1.8 µs |

Both routes run at the test rig's ceiling: the RTX 2060 sits in the B550 board's chipset slot, PCIe 3.0 x4 (about 3.3
GB/s each way at most), the RTX 3060 in a CPU slot, PCIe 4.0 x16.

**Experimental.** Verified here on one pair, one board and one driver version, on 2026-11-24. Route 1 also worked on
an RTX 2070 + RTX 3060 on an AMD X570 board, in an outside report
([below](#outside-report-rtx-2070--rtx-3060-on-an-x570)). Run the integrity test on your own pair before trusting
either route, and keep a way to reach the machine if it hangs.

The test rig:

| | Card | Chip | Memory | Slot | Memory window (BAR1) |
|---|---|---|---|---|---|
| GPU0 `04:00.0` | EVGA GeForce RTX 2060 | TU104 (`10de:1e89`), Turing | 6 GB | B550 chipset slot, PCIe 3.0 x4 | 8 GB, from [turing.md](turing.md) T1-T3 |
| GPU1 `2b:00.0` | MSI GeForce RTX 3060 VENTUS 2X 12G OC (LHR) | GA106 (`10de:2504`), Ampere | 12 GB | CPU slot, PCIe 4.0 x16 | 16 GB, from the firmware's Resizable BAR |

Software: Ubuntu 26.04.1, kernel 7.0.0-44-generic, driver 615.71.09 with the fork at `25c929e`, CUDA 13.5, aikitoria's
repository at `efed674`.

## Why CUDA says no

With the fork's driver and P2P switched on, the kernel driver offers P2P for this pair: `nvidia-smi topo -p2p r` shows
`OK` both ways. The refusal is in NVIDIA's closed CUDA library, `libcuda`. At start-up it asks the driver each GPU's
architecture (`0x160` Turing, `0x170` Ampere) and allows peer access only between matching ones. Faking the
architecture does not help: CUDA derives the compute capability from it too (the RTX 3060 then shows up as `sm_75`),
and cannot even create a context on the faked card. Two different chips of the *same* architecture are a smaller
problem, solved by the shim in [turing.md T5](turing.md#t5-cuda-and-the-integrity-test).

The fork's own pair check knows this and says so:

```
0000:04:00.0 <-> 0000:2b:00.0: not supported (TU104 + GA106: CUDA itself refuses peer access between Turing and Ampere GPUs)
```

## Before you start

1. [procedure.md](procedure.md) steps 1-10, 11a and 16a: BIOS (Above 4G Decoding and Resizable BAR on), Ubuntu, driver
   615, IOMMU in passthrough mode, CUDA 13.5, the fork at the pinned commit, the build, `contrib/config.sh` with both
   cards' addresses, the initramfs fix.
2. For the Turing card: [turing.md](turing.md) T1-T3, the bigger memory window at every boot. `geforce-bar1-resize`
   records the RTX 3060 too and leaves it alone: its firmware already gives it a window larger than its memory. With its
   default `DRIVER_OPTION=auto` it also writes `RMForceStaticBar1=0` only for the card it enlarged, so the RTX 3060
   keeps the driver's static BAR1; [procedure.md step 11b](procedure.md#11b-driver-dynamic-bar1-for-each-card-rmforcestaticbar10)
   needs the option for every card. Switch the tool to every card and rewrite its option file:

```bash
sudo sed -i 's/^DRIVER_OPTION=auto$/DRIVER_OPTION=on/' /etc/geforce-bar1-resize.conf
sudo geforce-bar1-resize driver-option --write
sudo modprobe -c | grep NVreg_RegistryDwordsPerDevice
```

   Expected: `pci=0000:04:00.0;RMForceStaticBar1=0;pci=0000:2b:00.0;RMForceStaticBar1=0;`, read at the next driver load.
   Found on the test rig on 2026-11-25, when Vulkan could map only 4 GB of the RTX 3060's 16 GB window
   ([DRMShare troubleshooting](https://github.com/Cinderella-Man/drmshare/blob/main/docs/troubleshooting.md)).
3. Check both windows. Each `Region 1` must be at least the card's memory:

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "$d $(sudo lspci -vv -s $d | grep -oE 'Region 1:.*size=[0-9A-Z]+\]')"; done
```

Expected on the test rig: `[size=8G]` for the RTX 2060 and `[size=16G]` for the RTX 3060.

## M1. Trial load with P2P on

[procedure.md step 12](procedure.md#12-prepare-the-live-swap-stop-everything-that-reloads-the-stock-driver)
(udev override, mask `nvidia-persistenced`, stop the desktop), then load the patched build with P2P on for both cards.
`RMPeerIoMemBar1=1` is the fork's key for route 2; leave `EXTRA_NVIDIA_OPTS` out if you only want route 1:

```bash
cd ~/geforce-dynbar1-p2p
sudo env P2P_ENABLE=1 EXTRA_NVIDIA_OPTS="NVreg_RegistryDwords=RMPeerIoMemBar1=1" contrib/p2p-load.sh --yes
```

The end of its output must show `OK` in both `topo -p2p` tables, and `events after: Xid 0 AER 0 DMAR 0 ...`. Then:

```bash
grep -E '^RegistryDwords' /proc/driver/nvidia/params
```

Expected: `RegistryDwords: "RMPeerIoMemBar1=1"`, and the per-device line with `RMDynBar1P2PEnable=1` for both cards.

## Route 1: CUDA peer access through a patched copy of libcuda

### M2. Patch a copy of libcuda

[aikitoria's fork](https://github.com/aikitoria/open-gpu-kernel-modules) of the open driver ships a script that
patches `libcuda` for P2P between generations. It is a pinned submodule of this repository:

```bash
cd ~/how-to-enable-p2p-on-nvidia-gpus
git submodule update --init tools/aikitoria-open-gpu-kernel-modules
```

It finds four comparisons in `libcuda` (the GPU code at offset `0xc50` of two devices, equal or one of a few allowed
pairs) and turns each `je` (`0x74`) into a `jmp` (`0xeb`), so every pair counts as compatible. It refuses if a
pattern is not found exactly once. Written for driver 615.78.08, all four patterns match 615.71.09 too.

Patch a **copy**, never the system library:

```bash
mkdir -p ~/libcuda-p2p
cp "$(readlink -f /usr/lib/x86_64-linux-gnu/libcuda.so.1)" ~/libcuda-p2p/libcuda.so.1
python3 ~/how-to-enable-p2p-on-nvidia-gpus/tools/aikitoria-open-gpu-kernel-modules/patch-libcuda-p2p.py ~/libcuda-p2p/libcuda.so.1
```

Expected (615.71.09):

```
applied: can-access predicate at 0x31ce26
applied: compatibility predicate at 0x31d031
applied: peer-device selection at 0x4b8664
applied: peer setup at 0x31cf2b
```

A program uses the copy only when you start it with `LD_LIBRARY_PATH=~/libcuda-p2p`. Everything else keeps the
system library. This is a modified NVIDIA binary: use it only on your own machine, and patch a new copy after every
driver update (the script refuses when a pattern no longer matches).

### M3. Check peer access

```bash
~/how-to-enable-p2p-on-nvidia-gpus/tools/p2p_access
LD_LIBRARY_PATH=~/libcuda-p2p ~/how-to-enable-p2p-on-nvidia-gpus/tools/p2p_access
```

Expected: `NO` both ways with the system library, `YES` both ways with the copy.

### M4. Integrity test

`p2p-check.sh --integrity` skips a pair it calls unsupported (`SKIP`, then `FAIL integrity: no pair was tested`), so
run the test itself, with the copy:

```bash
cd ~/geforce-dynbar1-p2p/contrib/integrity
[ -x p2p-integrity ] || ./build.sh
LD_LIBRARY_PATH=~/libcuda-p2p ./p2p-integrity --pair 0000:04:00.0 0000:2b:00.0 --max-mib 4096
```

Use your own two addresses. It runs as your normal user. The last line must be `RESULT PASS`. On the test rig, in 10.5
minutes:

```
cudaDeviceCanAccessPeer: A->B 1, B->A 1; P2P access attribute: A->B 1, B->A 1
bandwidth (cudaMemcpyPeerAsync, 256 MiB x 20, contents checked): A->B 3.28 GB/s, B->A 2.93 GB/s, both ways at once 5.49 GB/s
RESULT PASS 0000:04:00.0 0000:2b:00.0 max-mib 4096 cases 264 transfers 2112 copied 1403.6 GiB
```

Check the kernel log afterwards: no `Xid`, `AER` or `DMAR` lines.

### M5. NCCL, PyTorch, vLLM

Start them with `LD_LIBRARY_PATH=~/libcuda-p2p` and NCCL picks P2P by itself. Build NCCL and `nccl-tests` for both
architectures, as in [benchmarks.md](benchmarks.md#4-nccl-and-nccl-tests) but with two `-gencode` entries:

```bash
cd ~/how-to-enable-p2p-on-nvidia-gpus/tools
GEN="-gencode=arch=compute_75,code=sm_75 -gencode=arch=compute_86,code=sm_86"
make -C nccl clean && make -C nccl -j"$(nproc)" src.build NVCC_GENCODE="$GEN"
make -C nccl-tests clean && make -C nccl-tests -j"$(nproc)" MPI=0 NCCL_HOME="$PWD/nccl/build" NVCC_GENCODE="$GEN"
```

```bash
LD_LIBRARY_PATH=~/libcuda-p2p:$PWD/nccl/build/lib ./nccl-tests/build/all_reduce_perf -b 8 -e 1G -f 2 -g 2
```

```bash
NCCL_P2P_DISABLE=1 LD_LIBRARY_PATH=~/libcuda-p2p:$PWD/nccl/build/lib ./nccl-tests/build/all_reduce_perf -b 8 -e 1G -f 2 -g 2
```

Both runs check every result (the `#wrong` column must stay 0). With `NCCL_DEBUG=INFO` the first one logs
`via P2P/direct` (one process drives both cards; PyTorch's separate processes log `via P2P/CUMEM`), the second
`via SHM/direct`. On an Intel CPU the first one goes `via SHM` too unless `NCCL_P2P_LEVEL=PHB` is set
([troubleshooting](troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)). On the test rig, NCCL
2.32.6, bus bandwidth:

| `all_reduce_perf` | 1 MiB | 64 MiB | 1 GiB |
|---|---|---|---|
| With the copy: `via P2P/direct` | 2.57 GB/s | 2.72 GB/s | **2.74 GB/s** |
| With the copy and `NCCL_P2P_DISABLE=1`: `via SHM/direct` | 1.75 GB/s | 1.84 GB/s | 1.92 GB/s |
| Without the copy (system `libcuda`): `via SHM/direct` | 1.75 GB/s | 1.84 GB/s | 1.91 GB/s |

Small messages gain nothing: up to 1 KiB an all-reduce takes 12-15 µs either way.

## Route 2: I/O memory, without CUDA peer access

CUDA lets a GPU register another PCIe device's memory window as I/O memory
(`cudaHostRegister(..., cudaHostRegisterIoMemory)`) and then read and write it from kernels and copy engines.
[`tools/p2p_iomem.cu`](../tools/p2p_iomem.cu) uses that between two GPUs: Vulkan allocates memory on GPU A that the
driver maps through A's BAR1, CUDA on A imports it as an ordinary buffer, and CUDA on B registers the mapping. B then
reaches A's memory over PCIe. CUDA's peer check is never asked, so the architectures do not matter.

NVIDIA's driver refuses to register a range inside a GPU's BAR1 (`overlaps with FB or GPU BAR2` in the kernel log). Its
source says why: "an architectural deadlock scenario involved when full-duplex P2P enabled over BAR1". The fork's key
`RMPeerIoMemBar1=1` (set in M1) lifts that one refusal; without it the driver behaves as before. Move data one way at a
time: heavy reads in both directions at once are the deadlock, and on this test rig they reset the whole machine
([troubleshooting](troubleshooting.md#the-machine-resets-data-fabric-sync-flood)).

### M6. Build and run

```bash
sudo apt install -y libvulkan-dev
cd ~/how-to-enable-p2p-on-nvidia-gpus/tools
nvcc -O2 -arch=native p2p_iomem.cu -o p2p_iomem -lvulkan
```

Then each direction, with GPU numbers as `nvidia-smi` counts them. The first number owns the memory, the second
writes and reads it. Run it with `sudo`: NVIDIA's driver lets only root register I/O memory, and as a normal user the
run stops at `operation not permitted`. (NVIDIA's own key `PeerMappingOverride=1` would open that to every user; this
guide does not use it.)

```bash
sudo env CUDA_DEVICE_ORDER=PCI_BUS_ID ./p2p_iomem 0 1 64
```

```bash
sudo env CUDA_DEVICE_ORDER=PCI_BUS_ID ./p2p_iomem 1 0 64
```

The last line must be `ALL OK`. Without the key, the run stops at `B cannot register A's BAR1 as I/O memory` and
`the driver refuses BAR1 ranges without RMPeerIoMemBar1=1`. On the test rig, 30 runs of 64 MiB and 1 GiB, 62 GiB
checked word by word, 0 errors (medians where runs differ):

| | RTX 3060 into the RTX 2060 | RTX 2060 into the RTX 3060 |
|---|---|---|
| Kernels write | 2.93 GB/s | 3.28 GB/s |
| Copy engine writes | 2.93 GB/s | 3.28 GB/s |
| Kernels read (one direction at a time) | 1.11-1.14 GB/s | 2.85-2.91 GB/s |
| `cudaMemcpyPeer`, through host RAM | 2.47-2.51 GB/s | 2.78-2.79 GB/s |
| 4-byte copy | **1.77 µs** (13.5 µs through host RAM) | **1.78 µs** (18.0 µs through host RAM) |

Writes in both directions at once (two copies with `NO_READ=1`, 1 GiB each): 2.73 + 2.89 = 5.62 GB/s, byte-exact.

To time route 1 with the same steps, run it again with the copy from M2. CUDA then offers peer access, the tool turns
it on, and the `cudaMemcpyPeer` lines say `CUDA peer access` instead of `staged through host RAM`:

```bash
sudo env LD_LIBRARY_PATH=$HOME/libcuda-p2p CUDA_DEVICE_ORDER=PCI_BUS_ID ./p2p_iomem 0 1 64
```

## Results

Both routes are as fast as P2P between two cards of the same generation in these slots
([benchmarks.md](benchmarks.md)): the PCIe 3.0 x4 chipset slot sets the pace. Copies and 4-byte copies are medians of
the same `p2p_iomem` runs for all three columns (route 1 timed with the copy from M2, as above).

| | Through host RAM | Route 1 (CUDA peer access) | Route 2 (I/O memory) |
|---|---|---|---|
| Copy one way, 2060 -> 3060 / 3060 -> 2060 | 2.78 / 2.48 GB/s | 3.28 / 2.93 GB/s | 3.28 / 2.93 GB/s |
| Both ways at once | | 5.49 GB/s | 5.62 GB/s |
| 4-byte copy, 2060 -> 3060 / 3060 -> 2060 | 18.0 / 13.5 µs | 2.07 / 2.06 µs | 1.78 / 1.77 µs |
| NCCL all-reduce, 64 MiB (PyTorch's NCCL 2.30.7) | 1.83 GB/s | **2.72 GB/s** | not usable |
| NCCL all-reduce, 1 GiB (`nccl-tests`, NCCL 2.32.6) | 1.92 GB/s | **2.74 GB/s** | not usable |
| Runs as | | your normal user | root |
| Byte-exact checks | | 264 cases, 1.4 TiB | 62 GiB in 30 runs, both ways |

## Undo

- Route 1: stop using `LD_LIBRARY_PATH=~/libcuda-p2p` and delete `~/libcuda-p2p`. The system library was never
  changed.
- Both: the trial load ends at the next reboot, which loads the stock driver again. Put udev and
  `nvidia-persistenced` back as in [procedure.md](procedure.md#put-udev-and-nvidia-persistenced-back-to-ubuntus-defaults).

## Not tested yet

- A boot install for this pair (`p2p-enable.sh`, [procedure.md step 16](procedure.md#16-boot-install-make-it-survive-a-reboot)):
  only the trial load above was run here. In the outside report below, P2P was still on after a cold reboot.
- vLLM across the two cards (two architectures in one tensor-parallel group).
- Other mixed pairs: one more in the outside report below (RTX 2070 + RTX 3060). For RTX 30, 40 and 50 cards,
  aikitoria's fork documents P2P between generations with the same `libcuda` patch.

## Outside report: RTX 2070 + RTX 3060 on an X570

From an outside report by [Gavinbombay](https://github.com/Gavinbombay)
([#6](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/6), 2026-11-28), not reproduced here: route 1 on a
second pair of cards and a second board.

| | |
|---|---|
| Machine | ASUS TUF GAMING X570-PRO, Ryzen 7 5800X, Ubuntu 26.04, kernel 7.0.0-44 |
| GPU 0 | RTX 3060 12 GB (GA106, Ampere), X570 chipset slot, PCIe 4.0 x4, Resizable BAR 16 GiB |
| GPU 1 | RTX 2070 8 GB (TU106, Turing), CPU slot, PCIe 3.0 x16; memory window grown to 8 GiB by geforce-bar1-resize after the card's USB-C controller was removed ([turing.md T2](turing.md#t2-add-the-usb-c-pre-step)) |
| Software | driver 615.71.09 with the fork, a patched copy of `libcuda` ([M2](#m2-patch-a-copy-of-libcuda)), NCCL 2.32.6 (the build from [nccl-drmshare](https://github.com/Cinderella-Man/nccl-drmshare), which acts as stock NCCL when CUDA offers peer access), kernel options `amd_iommu=on iommu=pt pcie_aspm=off` |

Medians of 7 runs; the reporter checked every copy with SHA-256 (this guide's integrity test was not reported); no
Xid, AER or DMAR lines:

| | Stock driver (through host RAM) | Route 1 |
|---|---|---|
| `nvidia-smi topo -p2p r` | `NS` both ways | `OK` both ways |
| Copy 256 MiB, 3060 -> 2070 / 2070 -> 3060 | 4.07 / 3.91 GB/s | **6.59 / 6.59 GB/s** |
| 4-byte copy, 3060 -> 2070 / 2070 -> 3060 | 19.9 / 20.5 µs | 8.5 / 5.7 µs |
| PyTorch 2.11 all-reduce, 64 MiB fp16 | 3.97 GB/s | 6.47 GB/s |
| NCCL's route in llama.cpp | `via SHM/direct` | `via P2P/direct pointer` |

- 6.59 GB/s is about the limit of the chipset slot's PCIe 4.0 x4 link: an RTX 3090 in the X570 chipset slot of another
  board here moved 6.60 GB/s ([boards.md](boards.md)).
- P2P and the 8 GiB window were back after a cold reboot.
- With Ubuntu's default IOMMU mode the kernel logged `IO_PAGE_FAULT` under load from both cards, and NVMe drives
  dropped off during heavy writes; both stopped with `iommu=pt`
  ([troubleshooting](troubleshooting.md#peer-copies-faster-than-the-link-allows-or-io_page_fault-from-nvidia)).
- llama.cpp, Qwen3-8B Q4_K_M with `-sm tensor`: 91.6 tokens/s generated with NCCL through host RAM, 92.1 with P2P,
  against 65.8 for the best layer split; for generation the step to tensor split was the big one, not P2P. Prompt
  speed with and without P2P was not compared. Qwen3-30B-A3B ran out of memory on the 8 GB card with `-sm tensor` at
  its even split: on cards with different memory, split by memory with `-ts`
  ([README](../README.md#llamacpp-build-it-with-nccl), step 3).
