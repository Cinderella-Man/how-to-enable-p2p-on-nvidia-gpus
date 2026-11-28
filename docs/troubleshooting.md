# Troubleshooting

Every problem below came up in this order, on the test rig unless noted. The `static BAR1` and initramfs entries showed
up only on a fresh Ubuntu 26.04 install, the two `Turing:` entries only with Turing cards ([turing.md](turing.md)), the
`IO_PAGE_FAULT` entry on a machine with two Tesla V100s ([pascal-and-volta.md](pascal-and-volta.md); its Intel form,
`DMAR`, in an outside report with Tesla P40s), and the machine reset with vLLM on the Turing pair, two different chips
([benchmarks/vllm](../benchmarks/vllm/README.md)). The next two entries come from outside reports on Intel boards:
reads returning `0xffffffff`, and NCCL not using P2P (checked on the test rig). The four after them come from an
outside report with four RTX 2080 Ti on an Intel X79 board: the board's 64-bit window, leftovers of Ubuntu's prebuilt
modules, settings the driver swap drops, and memory with three or more cards. The last three, P2P between two CPU
sockets, the integrity test's time limit and the driver's log line for a card whose window was not grown, come from an
outside report with five RTX 2080 Ti on a four-socket server.

## `make modules` fails in the CXL code

**Symptom:** the build of `geforce-dynbar1-p2p` stops with errors in `nv-linux.h` / `nv-pci.h` around `struct nv_cxl`
(`struct cxl_dev_state`, `cxl_memdev`).

**Cause:** Linux 7.0 has `<cxl/cxl.h>` and `<cxl/pci.h>`, so the driver's conftest defines `NV_CXL_CXL_H_PRESENT`.
But the kernel's CXL API is not the one the 615.71.09 sources were written for. The headers are guarded only on
"header present", not on "API usable".

**Fix:** already in the fork as commit [`9504c3e`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/9504c3e0237a2a46c24cb43664b1654b5222a3b3). It adds
`&& defined(NV_CXL_INIT_SUPPORTED)` to the four guards and is cherry-picked from
[Ubsefor's commit `0e23c574`](https://github.com/Ubsefor/open-gpu-kernel-modules/commit/0e23c574b430c27d7b5ae394bc6ca488aff346cd).
If you see this error, you are building plain upstream. Check that the fix is in your tree:

```bash
grep -n 'NV_CXL_CXL_H_PRESENT.*NV_CXL_INIT_SUPPORTED' kernel-open/common/inc/nv-linux.h kernel-open/common/inc/nv-pci.h
```

## `make modules` fails at the very end (BTF)

**Symptom:** everything compiles, and the final module step fails (`pahole: not found` / BTF generation).

**Cause:** Ubuntu's kernel is built with `CONFIG_DEBUG_INFO_BTF_MODULES=y`. Building an external module then needs
`pahole`, which is not installed by default.

**Fix:**

```bash
sudo apt install -y pahole
```

Then run `make modules` again.

With `pahole` installed, two kinds of lines still show up and are harmless: `nvidia-modeset.o: warning: objtool: ...`
and `Skipping BTF generation for nvidia-uvm.ko due to unavailability of vmlinux`.

## A CUDA program fails: `the provided PTX was compiled with an unsupported toolchain`

**Symptom:** for example `p2pBandwidthLatencyTest` prints the connectivity matrix, then
`Cuda failure ...: 'the provided PTX was compiled with an unsupported toolchain.'` Programs that only copy memory (no
GPU kernels), like this repository's `tools/`, are not affected.

**Cause:** the CUDA toolkit (13.5) is newer than what driver 615.71.09 supports (13.4; `nvidia-smi` shows
`CUDA UMD Version: 13.4`). A plain `nvcc` build of an RTX 3090 program carries PTX that the driver has to JIT-compile,
and the driver refuses PTX from a newer toolkit. It has nothing to do with P2P or the patched modules: the stock
driver does the same.

**Fix:** compile native code for your cards so nothing is JIT-compiled:

```bash
nvcc -O2 -arch=native ...
```

`-arch=sm_86` also works for RTX 30-series cards. Check with `cuobjdump --list-elf <binary>`: it must list an `sm_86`
cubin.

## `p2p-load.sh` refuses: GPUs still held

**Symptom:** `holders:` lists processes, then `ABORT: GPUs still held; nothing unloaded`.

**Cause:** the desktop (gnome-shell, Xwayland) and `nvidia-persistenced` keep `/dev/nvidia*` / `/dev/dri/*` open.

**Fix:** run over SSH, then:

```bash
sudo systemctl stop display-manager
sudo systemctl stop nvidia-persistenced && sudo systemctl mask nvidia-persistenced
sudo fuser -v /dev/nvidia* /dev/dri/* 2>&1
```

You have to *mask* persistenced, not just stop it. udev's `71-nvidia.rules` starts it again on every nvidia driver
`add` event (`ENV{SYSTEMD_WANTS}="nvidia-persistenced.service"`), and so does any unit with
`Wants=nvidia-persistenced.service`.

## The driver keeps reloading every few seconds

This was the big one: "something keeps restarting the kernel service".

**Symptom:** right after `p2p-load.sh` reports success, the kernel log repeats this block every ~4 seconds:

```
[nvidia-drm] [GPU ID 0x00002b00] Unloading driver
nvidia-modeset: Unloading
nvidia-nvlink: Unregistered Nvlink Core, major device number 510
NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  615.71.09  Release Build  (dvs-builder@...)
nvidia-modeset: Loading NVIDIA UNIX Open Kernel Mode Setting Driver ...
(udev-worker)[...]: nvidia: Process '/sbin/modprobe -r nvidia-modeset' failed with exit code 1.
```

`dvs-builder@...` is NVIDIA's stock build. Your own build shows `(<you>@<host>)`. On the test rig the patched module
was loaded once (18:16:47), and from then on only stock loads followed: about 1000 cycles until 19:26. The first
integrity run then failed because `nvidia` and `nvidia-uvm` were the stock ones:

```
FAIL nvidia loaded: '040E903CBCB6AA48C223679', not the srcversion of .../kernel-open/nvidia.ko
FAIL nvidia-uvm loaded: '4D46B930398C9ECEC64A213', not the srcversion of .../kernel-open/nvidia-uvm.ko
...
RESULT NO_P2P 0000:04:00.0 0000:2b:00.0
```

**Cause:** Ubuntu's `/usr/lib/udev/rules.d/71-nvidia.rules` (from the driver packages) contains:

```
ACTION=="add",    DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/sbin/modprobe nvidia-modeset"
ACTION=="remove", DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/sbin/modprobe -r nvidia-modeset"
(the same pair for nvidia-drm and nvidia-uvm)
```

`p2p-load.sh` pauses udev (`udevadm control --stop-exec-queue`), runs `rmmod` on the stock stack, insmods the patched
build, and resumes udev. On resume udev replays the queued `remove` event. `modprobe -r nvidia-uvm` takes the patched
`nvidia-uvm` out, and with it `nvidia`, which is now unused. The queued or next `add` event then runs
`modprobe nvidia-modeset`, which resolves to the **stock** `.ko.zst` in `updates/dkms/` and loads stock `nvidia` as a
dependency. Each unload emits a new `remove` and each load a new `add`, so the two rules keep each other going. (The
`modprobe -r` "failed with exit code 1" lines show up because the rules run in parallel and race each other. The
unloads still happen.)

**How it was found** (in case it comes back in another form):

```bash
# who unloads modules: the delete_module syscall with the calling process
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_delete_module { printf("DELETE_MODULE pid=%d ppid=%d comm=%s module=%s\n", pid, curtask->real_parent->tgid, comm, str(args->name_user)); }'

# every modprobe that is started, with its arguments
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_execve /comm == "modprobe"/ { printf("MODPROBE ppid=%d %s %s %s\n", curtask->real_parent->tgid, str(args->argv[1]), str(args->argv[2]), str(args->argv[3])); }'

# the parent turns out to be a (udev-worker); its environment names the event
sudo tr '\0' '\n' < /proc/<ppid>/environ | grep -E '^(ACTION|DEVPATH|SUBSYSTEM|DRIVER|SEQNUM)='

# the rules that match
sudo grep -RniE 'modprobe.*(-r|--remove)|rmmod' /etc/udev/rules.d /usr/lib/udev/rules.d
```

**Fix:** override the rules file in `/etc` with the three `remove` lines commented out, then run the load again.

1. If the loop is already running, freeze it first:

   ```bash
   sudo udevadm control --stop-exec-queue
   sudo pkill -f '/sbin/modprobe.*nvidia'
   ```

2. Install the override:

   ```bash
   sudo cp /usr/lib/udev/rules.d/71-nvidia.rules /etc/udev/rules.d/71-nvidia.rules
   sudo sed -i '/^ACTION=="remove".*modprobe -r/ s/^/# /' /etc/udev/rules.d/71-nvidia.rules
   sudo udevadm control --reload-rules
   ```

3. Load again (steps 12-13 of [procedure.md](procedure.md)). `p2p-load.sh` resumes the udev queue itself at its end.

After the override the next `p2p-load.sh` (19:29:30) loaded the patched build, it stayed loaded, and the integrity test
passed.

**Remove the override** once you no longer swap drivers at runtime:

```bash
sudo rm /etc/udev/rules.d/71-nvidia.rules && sudo udevadm control --reload-rules
```

## `p2p-fallback.sh` refuses: "restore the RMForceStaticBar1=0 option first"

**Cause:** the scripts expect the per-card `RMForceStaticBar1=0` line in modprobe.d. The geforce-bar1-resize tool would
normally write it, but a stock-ReBAR RTX 3090 does not need that tool.

**Fix:** write the line by hand. See [procedure step 11b](procedure.md#11b-driver-dynamic-bar1-for-each-card-rmforcestaticbar10).

## `p2p-fallback.sh` fails its verification: modules `MISSING` / `WANT stock`

**Symptom:**

```
modules.dep resolves:
  nvidia MISSING
  nvidia-modeset MISSING
  ...
verification failed
```

**Cause:** `resolution()` in `contrib/common.sh` only matched `/<module>.ko`. Ubuntu builds the stock DKMS modules as
`updates/dkms/nvidia.ko.zst` (`CONFIG_MODULE_COMPRESS_ZSTD=y`).

**Fix:** already in the fork as commit [`e5ad35d`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/e5ad35de7fe517ffa85ff6d057777be7cb9ff465).

## `nvidia-smi` shows `GNS` again after a reboot

**Cause:** `p2p-load.sh` swaps the running driver only. After a reboot `modprobe` resolves the stock DKMS modules again.
That is how the test rig ended up the next morning:

```bash
for m in nvidia nvidia_uvm; do echo "$m loaded=$(cat /sys/module/$m/srcversion) stock=$(modinfo -F srcversion $m)"; done
```

When `loaded` equals `stock`, the stock driver is running.

**Fix:** the boot install, [procedure step 16](procedure.md#16-boot-install-make-it-survive-a-reboot).

## P2P works but the bandwidth is low (~3 GB/s)

**Cause:** the slowest PCIe link on the path. On the test rig GPU0 sits in a B550 chipset slot (`PCIe x4`, 3.0 through
the chipset) and GPU1 in the CPU's x16 slot:

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "$d $(cat /sys/bus/pci/devices/$d/current_link_speed) x$(cat /sys/bus/pci/devices/$d/current_link_width) (max $(cat /sys/bus/pci/devices/$d/max_link_speed) x$(cat /sys/bus/pci/devices/$d/max_link_width))"; done
```

Read the link while the GPUs are busy. At idle they drop to 2.5 GT/s to save power, so a reading of `2.5 GT/s` at idle
means nothing.

`./tools/pcie_bandwidth` measures each card's host link. P2P cannot be faster than the slower card's link.

## `Driver/library version mismatch` after an update

**Cause:** apt replaced the 615.71.09 userspace with another version, while the patched 615.71.09 kernel module is still
loaded.

**Fix:** hold the 615 packages ([procedure step 3](procedure.md#pin-the-driver-version)). If it already happened,
downgrade to 615.71.09 or fall back to stock (`p2p-fallback.sh --yes`, reboot).

## `p2p-check.sh --pairs` says `untested ... static BAR1 ... (no RMForceStaticBar1=0 ...)`

**Symptom:** right after [procedure step 11b](procedure.md#11b-driver-dynamic-bar1-for-each-card-rmforcestaticbar10),
`contrib/p2p-check.sh --pairs` prints `untested (GA102 + GA102): ... then enable with: p2p-enable.sh ...; static BAR1
on <both cards> (no RMForceStaticBar1=0 ...)`. It looks as if 11b did not work.

**Cause:** the check judges the options of the **running** driver (the first line of its output says so). That is
still the stock driver loaded at boot, before 11b wrote its file:

```bash
grep -E '^RegistryDwordsPerDevice:' /proc/driver/nvidia/params
```

prints `RegistryDwordsPerDevice: ""`.

**Fix:** nothing to fix, and do not run `p2p-enable.sh`. Check that 11b's file is what modprobe reads
(`sudo modprobe -c | grep NVreg_RegistryDwordsPerDevice`) and carry on. After the trial load (step 13) or any reboot,
`--pairs` prints `on by default, untested (GA102 + GA102 ...)`.

## `p2p-install.sh` refuses: `ABORT: the initramfs carries an nvidia module`

**Symptom:** the boot install ([procedure step 16](procedure.md#16-boot-install-make-it-survive-a-reboot)) stops in its
preflight with `ABORT: the initramfs carries an nvidia module; the driver must load from the root file system, after
the BAR1 resize`.

**Cause:** a fresh Ubuntu 26.04 install builds the initramfs with **dracut**. Its `drm` module (in hostonly mode, the
default) adds the KMS driver of every GPU it finds, so the stock `nvidia`, `nvidia-modeset`, `nvidia-drm` and
`nvidia-uvm` from `updates/dkms` end up in the initramfs, with their firmware. The stock driver then loads before the
root file system is mounted, and the patched modules installed there would never be used. A system upgraded from
24.04 keeps initramfs-tools, which leaves them out; that is why the original test rig never hit this. To see it:

```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E '(^|/)nvidia(-drm|-modeset|-uvm|-peermem)?\.ko'
```

```bash
journalctl -b -o short-monotonic | grep -E 'Switching root|loading NVIDIA UNIX'
```

The second one shows `loading NVIDIA UNIX` before `Switching root.`.

**Fix:** [procedure step 16a](procedure.md#16a-keep-the-nvidia-driver-out-of-the-initramfs): an `omit_drivers` line in
`/etc/dracut.conf.d/90-omit-nvidia.conf`, then `sudo update-initramfs -u -k "$(uname -r)"`. The script is right to
refuse; do not work around the check.

## Turing: `geforce-bar1-resize` logs `resize failed (No space left on device)`

**Symptom:** with RTX 20 or GTX 16 cards, `journalctl -b -u geforce-bar1-resize` shows `<card> resize failed (No space
left on device); left armed for the layout module (a PCIe switch above it?)`, and BAR1 stays at 256 MB. On the test
rig this happened in the CPU slot too, not only behind the chipset.

**Cause:** these cards have a USB-C controller (function `.2`) and a UCSI function (`.3`) next to the GPU, and their
64-bit prefetchable address ranges sit in the same bridge window as BAR1. The kernel cannot grow a window that holds
another device's range. To see them:

```bash
lspci -D -d 10de: | grep -iE 'usb|ucsi'
```

**Fix:** remove those two functions before the resize: [turing.md step T2](turing.md#t2-add-the-usb-c-pre-step). Do not
try the remove-and-rescan of the whole root port instead; on the test rig that froze the machine.

## Turing: `nvidia-smi topo -p2p r` shows `OK`, but CUDA has no peer access

**Symptom:** after a trial load with P2P on, `nvidia-smi topo -p2p r` shows `OK`, but `tools/p2p_access` prints `NO`,
and the integrity test stops at once with `RESULT NO_P2P` and `FAIL integrity ...: no peer access although the pair is
opted-in`.

**Cause:** the two cards are **different chips** of the same generation (on the test rig TU104 + TU116). The kernel
driver reports P2P as supported, but NVIDIA's closed CUDA library refuses peer access between GPUs whose chip
implementation differs.

**Fix:** the preload shim in [turing.md step T5](turing.md#t5-cuda-and-the-integrity-test), for the programs that
should use P2P. Two identical chips do not hit this; if they show the same symptom, the cause is something else.
Two different *architectures* (for example an RTX 2060 with an RTX 3060) the shim cannot help: CUDA refuses those
pairs outright. What works there: [mixed-generations.md](mixed-generations.md).

## Peer copies faster than the link allows, or `IO_PAGE_FAULT` from nvidia

**Symptom:** CUDA reports peer access and `nvidia-smi topo -p2p r` shows `OK`, but `tools/p2p_bandwidth` measures one
direction faster than the slower card's PCIe link can carry, or the integrity test fails. On two Tesla V100s with the
stock driver: 6.6 GB/s into a card whose PCIe 2.0 x4 link carries at most 2 GB/s. The kernel log has lines like

```
nvidia 0000:07:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT domain=0x0012 address=0x7000000000 flags=0x0020]
```

On Intel the same block shows up as a `DMAR` fault. From an outside report, four Tesla P40s on a dual-socket X99 board
with the stock driver ([pascal-and-volta](pascal-and-volta.md#outside-report-four-tesla-p40s-on-a-dual-socket-x99)):

```
DMAR: [DMA Write NO_PASID] Request device [xx:00.0] fault addr ... [fault reason 0x05] PTE Write access is not set
```

There every copy, in both directions, came back wrong, and on PCIe 3.0 x16 links the speed looked normal: only the
kernel log and a byte-by-byte check showed it.

Another outside report, an RTX 3060 + RTX 2070 on an AMD X570 board
([mixed-generations](mixed-generations.md#outside-report-rtx-2070--rtx-3060-on-an-x570)), saw `AMD-Vi: IO_PAGE_FAULT`
lines under load from both cards, and **NVMe drives dropping off during heavy writes**; both stopped with `iommu=pt`.

**Cause:** the IOMMU translates device addresses (Ubuntu's default wherever the firmware turns the IOMMU on), and it
blocks one GPU's writes into the other GPU's memory. The copy completes without the data, and neither the driver nor
CUDA reports an error: **the data is silently lost.**

**Fix:** IOMMU passthrough, [procedure step 4](procedure.md#4-iommu-in-passthrough-mode). Afterwards every IOMMU group
must be `identity`:

```bash
cat /sys/kernel/iommu_groups/*/type | sort | uniq -c
```

Then repeat the copy test (both directions now at or below the link speed) and the integrity test.

## `cudaGetDeviceCount: invalid device ordinal` with one GPU that failed to start

**Symptom:** every CUDA program fails at once with `cudaGetDeviceCount: invalid device ordinal` (`tools/p2p_access`
from before 2026-11-23 printed endless `GPU 0 -> GPU n: NO` lines instead), although `nvidia-smi` lists the GPUs. The
kernel log has, for one card:

```
NVRM: Xid (PCI:0000:05:00): 79, GPU has fallen off the bus.
NVRM: GPU 0000:05:00.0: RmInitAdapter failed! (0x25:0xf:1636)
```

**Cause:** one GPU failed to start, and CUDA then gives up on all of them; `CUDA_VISIBLE_DEVICES` does not help. On the
test rig it was a display card on a mining riser in a PCIe x1 slot, most likely without power on the riser.

**Fix:** connect the riser's power and reboot. Until the next reboot, removing the failed card from the PCI bus (every
function of it, here `05:00.0` and its audio function `05:00.1`) lets CUDA start on the other GPUs:

```bash
for f in /sys/bus/pci/devices/0000:05:00.*; do echo 1 | sudo tee $f/remove; done
```

## The machine resets: `data fabric sync flood`

**Symptom:** the whole machine freezes and resets while a program uses P2P. The kernel log just stops, and kdump saves
nothing. The next boot logs:

```
x86/amd: Previous system reset reason [0x08000800]: an uncorrected error caused a data fabric sync flood event
mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 5: bea0000000000108
```

(After a normal reboot the same line reads `software wrote 0x6 to reset control register 0xCF9`, with no machine check.)
On the test rig it first happened in vLLM with its custom all-reduce (on by default whenever CUDA offers P2P), on the
first prompt.

**Cause:** the trigger is the kernels of **both GPUs reading each other's memory at the same time**, with many threads.
Why the machine cannot take it is not known: it was seen only on a pair of **two different chips** with one card
**behind the chipset**, and either may be the reason (see below). [`tools/p2p_patterns.cu`](../tools/p2p_patterns.cu)
reproduces it without vLLM, on the Turing pair:

| Pattern | Result |
|---|---|
| One GPU's kernels read the other's memory, either direction | clean |
| One GPU's kernels read while the other's kernels write | clean |
| Copy engines, both directions at once, reading or writing (`cudaMemcpyPeerAsync`) | clean |
| Both GPUs' kernels read each other's memory at once, 1 to 24 blocks x 512 threads | clean |
| Both GPUs' kernels read each other's memory at once, **36 blocks x 512 threads** | **reset within a second, twice** |

A sync flood is how an AMD CPU stops when an error on its internal interconnect (the data fabric) cannot be recovered;
a read whose answer never comes back is a typical way to get one. vLLM's custom all-reduce has each GPU read the other's
buffer on every call, with 36 x 512 threads. A small message while generating keeps only a few threads busy and got
through; a 1 MiB message for a prompt did not. The integrity test does not catch this: it reads in one direction at a
time. Every result: [p2p-patterns.txt](../benchmarks/vllm/results/2026-11-24-turing-pair/p2p-patterns.txt).

**Tested only on the Turing pair**, and two things about it are unusual, so either may be the real reason:

- **two different chips** (TU104 + TU116). CUDA offers peer access between them only through the shim, which makes it
  treat both cards as the same chip, and CUDA may rely on that chip identity for more than the one check the shim
  changes ([turing.md T5](turing.md#t5-cuda-and-the-integrity-test));
- **GPU0 behind the B550 chipset**, so every read from the other card needs an answer back through the chipset.

A pair of identical cards in the same slots, which needs no shim, would tell the two apart; it has not been tested yet.
Until then, treat this as a risk for any pair, not as proven for any pair but this one.

An outside report, not verified here, points to the chipset. On an Intel i5-10400 with a B460 board, two identical RTX
4060 Ti 16GB cards (no shim needed), one on CPU lanes and one behind the chipset (DMI 3.0), driver 620.70.06 and a
different P2P method: peer writes were byte-exact both ways (5.44 GB/s at once, as here), but **every peer read came
back as `0xffffffff`**, with no error and no hang ([next entry](#peer-reads-return-0xffffffff-writes-work)). So on both
boards, reads through the chipset are the weak spot; they just fail differently. The Intel chipset does not forward them
at all. The B550 forwards them, and they work at light load, but heavy reads in both directions at once reset the
machine.

**Fix:** run vLLM with `--disable-custom-all-reduce`; with NCCL's P2P it ran clean for an hour. Other programs with their
own P2P all-reduce kernels may read the same way. In your own code, have each GPU write into the other's memory, or
use `cudaMemcpyPeerAsync`, rather than letting both GPUs' kernels read across at once.

To test a pair for it, **save your work first: on the test rig's mixed pair this resets the machine.**

```bash
nvcc -O2 -arch=native tools/p2p_patterns.cu -o tools/p2p_patterns
```

```bash
sync
```

```bash
tools/p2p_patterns rbi 30
```

For two different Turing chips, put the shim's two variables in front, as in
[turing.md T5](turing.md#t5-cuda-and-the-integrity-test). `BLOCKS=16 tools/p2p_patterns rbi 30` runs a lighter load.
Running `tools/p2p_patterns` without arguments lists the other modes. Every mode checks the data it moves and ends with
`DATA OK`, or `DATA WRONG` and exit status 1: run `r01` and `r10` first, to see whether reads work at all on your board.

## Peer reads return `0xffffffff`, writes work

From an outside report, not reproduced here: an Intel i5-10400 with a B460 board, one card on CPU lanes and one behind
the chipset (previous entry).

**Symptom:** writes into the other card's memory arrive byte-exact in both directions, but everything read from the
other card comes back as `0xffffffff`, in both directions. No error, no hang, nothing in the kernel log. Expect the
integrity test's read transfers (`load` and `pull`) and `tools/p2p_patterns r01` / `r10` to fail.

**Cause:** the chipset passes peer writes on but not peer reads. A write needs no answer; a read needs one, and the
chipset does not route it between its own port and the CPU's. `0xffffffff` is what a PCIe read gets back when it fails.

**Fix:** none in software. Either put both cards on CPU lanes (a board that splits them x8/x8), or use only software
that writes into the other card. NCCL shows its mode at the end of each `via P2P/...` line with `NCCL_DEBUG=INFO`:
`/read` means it reads (on the test rig it wrote, `via P2P/CUMEM`). Never trust P2P on such a board without the
integrity test: the wrong data arrives silently.

## NCCL goes `via SHM` although CUDA offers peer access

From an outside report on an Intel board, whose NCCL runs set `NCCL_P2P_LEVEL=PHB`
([pascal-and-volta](pascal-and-volta.md#outside-report-four-tesla-p40s-on-a-dual-socket-x99)), and NCCL's source.
NCCL's choice was checked on the test rig, and seen on Intel hardware in a second outside report (below).

**Symptom:** `nvidia-smi topo -p2p r` shows `OK`, CUDA reports peer access and the integrity test passes, but NCCL logs
`via SHM/direct` with `NCCL_DEBUG=INFO` and runs at host RAM speed. So do PyTorch and vLLM, which use NCCL. No error.

**Cause:** NCCL has its own rule on top of CUDA's. By default it uses P2P only between cards behind the same PCIe
switch, not through the CPU, except on an AMD CPU with at most two GPUs. Two cards in separate CPU slots, or one behind
the chipset, are a path through the CPU (`PHB` in `nvidia-smi topo -m`):

| CPU | Two cards through the CPU: NCCL's default |
|---|---|
| AMD, two GPUs (the test rig) | P2P |
| Intel | host RAM |
| AMD, three or more GPUs | host RAM (NCCL 2.26 and later; checked with three RTX 3090s and NCCL 2.32.6, below) |

The rule is in `ncclTopoCheckP2p` (`src/graph/paths.cc`). The Intel row holds in every version checked, 2.21.5 to
2.32.6.

**Fix:** once the integrity test has passed, allow P2P through the CPU:

```bash
export NCCL_P2P_LEVEL=PHB
```

Then check the `via` line again ([benchmarks](benchmarks.md#4-nccl-and-nccl-tests)). The NCCL inside PyTorch and vLLM
reads the same variable. Upstream's README gives the same advice. (`SYS` would also allow pairs on two different CPU
sockets. On Intel's Xeon E5/E7 up to v4 the driver offers no P2P between those, and elsewhere it can be slower than host
memory: [two CPU sockets](#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory).)

**Seen on Intel hardware:** with four RTX 2080 Ti on an X79 board
([turing.md](turing.md#outside-report-four-rtx-2080-ti-on-an-x79-board)), NCCL went `via SHM` by default and `via
P2P/CUMEM` with `NCCL_P2P_LEVEL=SYS`. On one socket `PHB` is enough.

**Checked with three RTX 3090s** on an AMD X570 board (one card behind the chipset, two on CPU lanes), the patched
driver, NCCL 2.32.6 and llama.cpp's CUDA backend built with it ([three-cards.md](three-cards.md#llamacpp-build-it-with-nccl)):
all three cards ran `via SHM/direct` although `nvidia-smi topo -p2p r` showed `OK` everywhere, and `via P2P/direct` with
`NCCL_P2P_LEVEL=SYS`. The cost of the default there: 1,362 against 1,695 tokens per second on 2048-token prompts (+24 %
with P2P), 51.0 against 54.7 generating (+7 %), the same perplexity chunk for chunk. Two of the same cards on their
own went `via P2P/direct` without the variable, as the table says. (`PHB` should be enough on one socket; it was not
tried there.)

**Checked on the test rig** (a Ryzen with an RTX 2060 + RTX 3060 on the stock driver 615, which offers this pair no
P2P, so NCCL always ends at host RAM there): NCCL logs `P2P is disabled between connected GPUs` only when its own rule
allowed the pair and the driver then said no. With NCCL's description of the machine changed to an Intel CPU
(`NCCL_TOPO_FILE`), that line disappeared, in NCCL 2.32.6 and in PyTorch's NCCL 2.30.7 and 2.29.3, and it came back
with `NCCL_P2P_LEVEL=PHB`. That shows NCCL's choice, not what it costs: on the test rig's RTX 30 pairs (one card in a PCIe 3.0 x4 chipset slot) a 1 GiB
all-reduce ran at 2.72-2.75 GB/s with P2P and 1.85-1.88 GB/s through host RAM
([benchmarks](benchmarks.md#4-nccl-and-nccl-tests)).

## After the BAR1 resize every card fails: `kbusVerifyBar2_GM107: ... returned garbage`

From an outside report, not reproduced here: four RTX 2080 Ti on an Intel X79 board with a Xeon E5-2680 v2
([turing.md](turing.md#outside-report-four-rtx-2080-ti-on-an-x79-board)).

**Symptom:** with Turing cards, after geforce-bar1-resize grew the windows at boot
([procedure.md step 4b](procedure.md#4b-a-bar1-at-least-as-large-as-each-cards-memory), turing.md T1-T3), the driver fails on every card:

```
kbusVerifyBar2_GM107: MMUTest BAR0 window offset 0x70e000 returned garbage 0x0
RmInitAdapter failed
```

With the stock 256 MB windows the same machine booted fine.

**Cause:** the resize moved the windows to addresses the CPU does not pass on to PCIe. Linux places them anywhere in
the 64-bit range the firmware declares for the PCI root (ACPI `_CRS`; in `dmesg` as `root bus resource [mem ...
window]`). On this board that range starts at `0xa40000000`, but the Xeon E5 v2 forwards 64-bit addresses only from
its MMIOH range, `0x380000000000-0x381fffffffff` (128 GiB, read from the CPU's registers). The firmware had put the 256
MB windows there; after the resize Linux took the lowest free addresses, from `0xc00000000` on, and the driver's first
read through them got nothing back.

To see where your windows are: the firmware's placement at boot comes first in the log, the resize's after it.

```bash
sudo dmesg | grep -E 'root bus resource \[mem'
```

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do sudo dmesg | grep -E "$d: BAR [13] "; done
```

Windows that the resize moved far below where the firmware had them (here from `0x381f...` to `0xc...`) point to this.

**Fix (the reporter's):** reserve the part of the range below MMIOH, so Linux leaves it alone. The kernel option is
`memmap=<size>$<start>`, with `<start>` the start of the 64-bit root range and `<size>` the MMIOH base minus that
start. On this board, `0x380000000000 - 0xa40000000`:

```
memmap=0x37F5C0000000$0xa40000000
```

Your values differ: take `<start>` from the `root bus resource` line above, and the MMIOH base from where the firmware
put the 64-bit windows at boot (or from the CPU's registers). In `/etc/default/grub` the `$` must be written `\\\$`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=on iommu=pt memmap=0x37F5C0000000\\\$0xa40000000"
```

After `sudo update-grub` and a reboot, `cat /proc/cmdline` must show `memmap=0x37F5C0000000$0xa40000000`, and
`sudo dmesg | grep 'E820 reservations'` must say `Using E820 reservations for host bridge windows`. Linux does that by
default when the BIOS is older than 2023; with a newer BIOS add `pci=use_e820`. On the reporter's board the four
windows then landed at `0x3800`, `0x3808`, `0x3810` and `0x3818_0000_0000`, and every card came up. That filled MMIOH:
each card's 16 GiB BAR1 took 32 GiB of addresses there, so larger windows do not fit on that board.

**Do not unload the driver to retry.** With every card failed, `modprobe -r nvidia_drm nvidia_modeset nvidia_uvm
nvidia` crashed the kernel there (stock 615.71.09: `BUG: unable to handle page fault ... RIP: gpuGetRpc+0x2e
[nvidia]`, after `Internal device object leak`). After `RmInitAdapter failed`, reboot.

## `p2p-load.sh`: `nvidia.ko.sig not found`, then `neither the stock driver nor the build`

From an outside report (the X79 board above).

**Symptom:** `p2p-load.sh` stops in its preflight with

```
modinfo: ERROR: Module /lib/modules/<kernel>/kernel/nvidia-595/bits/nvidia.ko.sig not found.
ABORT: loaded nvidia (srcversion ...) is neither the stock driver nor the build in .../kernel-open
```

**Cause:** files left by Ubuntu's prebuilt 595 modules. `linux-objects-nvidia-595-<kernel>` and
`linux-signatures-nvidia-<kernel>` put object files and `nvidia.ko.sig` into `kernel/nvidia-595/bits/`, and they stay
installed after the switch to 615. The scripts look for the stock module by its file name, `nvidia.ko*`, and can take
the `.sig` for it. `p2p-rollback.sh` can trip over the same files.

**Fix:** remove those packages
([procedure step 3](procedure.md#leftovers-of-ubuntus-prebuilt-modules)), then run `p2p-load.sh` again. Fixed in
the fork at `4c5a97a`, pinned since 2026-11-25: the scripts take only module files, so a build from it is not stopped by
these files. Removing the packages is still the clean state.

## `nvidia-smi topo -p2p r` says `OK`, but nothing arrives between two cards

From an outside report ([issue #5](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/5)):
three RTX A2000s on an Intel Z390, NVIDIA's stock driver 580; and on the test rig's AMD B550 with DRMShare.

**Symptom:** P2P is reported as supported for every pair, but between two particular cards every write is lost and
every read fails, with nothing in the kernel log: no Xid, no AER, no IOMMU message. `p2pBandwidthLatencyTest` shows it
only as a latency of about 49 ms for that pair (its flag never lands); llama.cpp with `GGML_CUDA_P2P=1` across those
cards prints `0000...`. Every pair that includes a card on the CPU's lanes is byte-exact.

**Cause:** both cards sit behind the board's chipset. The chipset does not pass traffic from one of its slots to
another; the IOMMU is not involved. On the B550 its ports answer it with "Unsupported Request", which the copying card
logs in its error registers (`lspci -vvv`, `UESta`). On the Z390 nothing is recorded anywhere, not even in the raw
registers (its firmware also keeps AER from Linux): the writes just vanish.

**Fix:** find where each card hangs (`lspci -tv`; [boards.md](boards.md#the-route)) and keep at most one card that uses
P2P behind the chipset, the others on CPU lanes; or leave P2P off for that pair. Run the integrity test
([procedure step 14](procedure.md#14-integrity-test)) on every pair: `OK` from `topo` is not proof.

## RTX 50 with 16 GB: `OK` and peer access, but copies lose their data

From an outside report by tronx2100 in
[geforce-bar1-resize#4](https://github.com/noon-at-cgn/geforce-bar1-resize/issues/4) (an RTX 5060 Ti 16 GB, GB206),
not reproduced here: this guide has no Blackwell card.

**Symptom:** with P2P forced on (NVIDIA's keys `ForceP2P`, `RMForceP2PType`, or a driver patch that does the same in
its code), `nvidia-smi topo -p2p r` shows `OK` and `cudaDeviceCanAccessPeer` is 1, but every copy between the cards
silently loses its data: the destination stays as it was, and the copies report a speed no link can carry (69-72 GB/s
in that report). No error anywhere.

**Cause:** NVIDIA's BAR1 P2P on Blackwell needs static BAR1, a mapping of all of the card's memory into its BAR1. The
driver places that mapping 512 MiB into BAR1, so on a card whose BAR1 is only as large as its memory (the 16 GB RTX 50
cards: BAR1 16384 MiB) it does not fit, and the driver does not turn it on by itself.

**Fix:** force static BAR1 with `RMForceStaticBar1=1`, together with `RMIncreaseRsvdMemorySizeMB` so the mapping fits
(drivers 610 and later; without it the card fails to initialize). The value comes from a formula in
geforce-bar1-resize's [driver-option.md](https://github.com/Cinderella-Man/geforce-bar1-resize/blob/main/docs/driver-option.md#static-bar1-on-a-card-whose-bar1-equals-vram);
in the report, `24` on 620.70.06 made the copies correct both ways, at about 48 MiB of memory per card. Then check the
data: the integrity test, or [`tools/p2p_patterns.cu`](../tools/p2p_patterns.cu) (`cewbi` and `cerbi`, each ending
with `DATA OK` or `DATA WRONG`), which needs only `nvcc`. Seen on one card model; other 16 GB RTX 50 cards (an RTX 5080,
an RTX 5070 Ti) are in the same position by the same reasoning, untested
([issue #4](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/4) has an RTX 5080 + RTX 5060 Ti
16 GB at `OK`, data not checked yet).

## Cards fall off the bus after `p2p-load.sh` (`Xid 79`)

From an outside report: four RTX 2080 Ti that need a clock lock to run stable.

**Symptom:** the cards ran stable on the stock driver, but after the live swap, under load, they drop off the bus:
`NVRM: Xid (PCI:...): 79, GPU has fallen off the bus`.

**Cause:** the swap unloads the driver, and with it every setting `nvidia-smi` made at run time: power limits,
locked clocks, persistence mode. With `nvidia-persistenced` masked
([procedure step 12b](procedure.md#12b-stop-and-mask-nvidia-persistenced)), a setting made afterwards also lasts only
while a program holds the card.

**Fix:** reboot if a card already fell off the bus. After each live swap, set persistence mode first and then your
settings, or put them in `RESTORE_CMD`
([procedure step 13](procedure.md#13-trial-load-nothing-is-installed-a-reboot-returns-to-stock)).

**Another cause: a card on a PCIe x1 riser.** A GTX 1650 SUPER on a USB-cable x1 riser (the mining kind) fell off the
bus about 4 seconds after the driver loaded, at every boot, with the stock driver too: the card comes up at 2.5 GT/s
and the driver raises the link speed, which the riser did not carry. Held at 2.5 GT/s before the driver loads, it ran
([drmshare's riser script](https://github.com/Cinderella-Man/drmshare/blob/main/docs/troubleshooting.md#a-card-on-a-pcie-x1-riser-falls-off-the-bus-xid-79-when-the-driver-starts-it)).
Risers differ: the RTX A2000 in the outside report above ran at 8 GT/s on its x1 riser, also a USB-cable one, but that
link logged correctable errors (`RxErr`, `BadTLP` in `lspci -vvv`'s `CESta`, on the card and its port) while the other
links were clean: no margin left. A riser link that logs correctable errors under load is worth capping a step lower. The test rig's riser showed both
sides: at 5 GT/s it ran (0 wrong words) but logged those errors from the driver start on, at 2.5 GT/s none.

## Three or more cards: `cudaMalloc` runs out of memory with peer access between all of them

From an outside report (four RTX 2080 Ti, the X79 board above), explained from the patched driver's source; not
reproduced here, the test rig has two slots.

**Changed in the fork at `b70b69c`**, pinned since 2026-11-25: the count described below is now kept per other card,
so each card can map all of every other card's memory (BAR1 is at least as large as VRAM). Checked on three RTX 3090s:
the old build refused any allocation above 16352 MiB per card, `b70b69c` allowed 23552
([three-cards.md](three-cards.md#peer-memory-old-and-new-build)). This entry describes builds up to `25c929e`.

**Symptom:** with peer access between every pair of three or more cards (for example llama.cpp with
`GGML_CUDA_P2P=1`), `cudaMalloc` fails with out of memory long before the cards are full. `nvidia-smi` shows free
memory and free BAR1, and the kernel log has nothing (from `b70b69c` on, a refusal logs `METHOD3: peer window
refused`). On four RTX 2080 Ti (16 GiB BAR1 each) about 5.3 of 11 GB per
card were usable. The integrity test passes, because it tests one pair at a time.

**Cause:** a check in the patched driver. Every allocation another card can reach gets a window in its owner's BAR1,
once, however many cards use it. Before it makes one, the driver adds up the peer memory the *mapping* card already
has open on *all* other cards, and compares that sum with the BAR1 size of *one* card, minus 64 MiB
(`_nvGpuOpsDynBar1Create` in `nv_gpu_ops.c`; upstream calls it a rough early guard). With two cards that is the right
bound. With four, each card can map at most 16 GiB - 64 MiB of the other three cards' memory together:

| Allocated on each of four cards, every card mapping every other | Each card maps | Result (outside report) |
|---|---|---|
| 3000-5000 MiB | up to 15000 MiB | all ok |
| 5500-6400 MiB | 16500 MiB and more | the third card's allocation fails |
| 8192 MiB | 16384 MiB | the second card's allocation fails |

**Fix:** build from the fork at `b70b69c` or later (the guide pins a later one). With an older build, give peers access to the
buffers they exchange, not to whole cards. llama.cpp built with NCCL, without
`GGML_CUDA_P2P`, does that (NCCL maps only its own buffers), and the outside report then used all of the cards'
memory. Peer access only within pairs also works. A larger BAR1 raises the limit, where the board has room for it.
Static BAR1 is no way around it: the patched driver refuses P2P for a card with static BAR1.

## Two CPU sockets: P2P works, but slower than copying through host memory

From an outside report by [gordan-bobic](https://github.com/gordan-bobic)
([issue 3](https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus/issues/3)): five RTX 2080 Ti 22 GB in an
HP ProLiant DL580 Gen9 with four Xeon E7-8890 v4, each card on its own CPU root port. Explained from the driver's
source; not reproduced here (no machine with two sockets).

**Symptom:** with builds up to `b70b69c`, `nvidia-smi topo -p2p r` shows `OK` for cards on different CPU sockets, and the
integrity test passes byte-exact, but peer copies crawl. On links running at PCIe 3.0 x16:

| 4 GiB between two sockets | Time | Speed |
|---|---|---|
| `cudaMemcpyPeer`, writing into the other card | 18.3 s | 0.23 GB/s |
| a kernel writing into the other card | 14.4-18.1 s | 0.24-0.30 GB/s |
| a kernel reading from the other card | 3.34 s | 1.3 GB/s |

Copies from host memory to a card peak at a little over 12 GB/s on the same machine. A copy staged through host memory
makes two such trips, and still comes out about 25 times faster than the peer writes (the reporter's estimate; the
staged copy was not timed as one number). During peer copies nvtop and `nvidia-smi` show about
0.24 GB/s of PCIe traffic, and the cards 100 % busy at about twice their idle power: kernels waiting on the path.
Turning off ACS and the IOMMU together raised it to at most 0.4 GB/s. A slow pair can also make
`p2p-check.sh --integrity` reach its time limit
([next entry](#p2p-checksh---integrity-times-out-on-a-slow-pair-every-case-clean)).

**Cause:** the path between the sockets. The data crosses the link between the CPUs (QPI on these Xeons), and Intel's
older server CPUs pass peer traffic over it very slowly. NVIDIA's own driver refuses it: for the root ports of the
X58/5520 IOH and of the Xeon E5/E7 generations from Sandy Bridge-EP to Broadwell-EP/EX (PCI device IDs `3408`-`3411`,
`3420`, `3421`, `3c02`-`3c0b`, `0e02`-`0e0b`, `2f01`-`2f0b`, `6f01`-`6f0b`; the report's cards sit on `6f08` and
`6f04`), it offers no P2P between cards under two different I/O hubs, which is one per socket, and shows `TNS`
(`_kp2pCapsGetStatusOverPcie` in `p2p_caps.c`). The Tesla P40s on a dual-socket X99
([pascal-and-volta](pascal-and-volta.md#outside-report-four-tesla-p40s-on-a-dual-socket-x99)) got exactly that from
the stock driver. The patched driver forces P2P on for its cards, and up to `b70b69c` that skipped this check along with
the chipset checks it has to skip for GeForce cards, so CUDA was offered the slow path.

How the numbers fit, as our reading and not measured here: 0.23 GB/s is one 64-byte write every 280 ns, about one round
trip between two sockets, as if each write waited for the one before. Reads can have several requests in flight and
got five times as far.

**Fixed in the fork at `acd74cf`** (pinned since 2026-11-25): the patched driver keeps NVIDIA's check. Such a pair
shows `TNS`, CUDA reports no peer access, copies go through host memory by themselves (the fast path on these
machines), the kernel log gets one rate-limited `DynBar1P2P: ... peer on another Intel CPU socket (I/O hub)` line, and
`p2p-check.sh --pairs` says `not supported` and names both root ports. NVLink pairs and cards on one socket are not
affected. Not yet confirmed on a machine with two sockets: after the fix the reporter's `nvidia-smi topo -p2p r` shows
the expected table, `TNS` for the nine pairs between sockets and `OK` for the NVLink pair, but NVIDIA's own driver
shows the same table, and which of the two was loaded is not reported yet. With the pinned build the
`peer on another Intel CPU socket` line above is the sign that it was the patched driver.

**Check your machine:**

```bash
nvidia-smi topo -m
```

`SYS` between two GPUs means different sockets; `NODE`, one socket but different host bridges; `PHB`, one host bridge;
`NV#`, an NVLink bridge. The `NUMA Affinity` column is the card's socket (one NUMA node per socket, unless the
firmware splits sockets into several nodes). The reporter's server, three cards on three sockets and the bridged two on
the fourth (the last column cut):

```
        GPU0    GPU1    GPU2    GPU3    GPU4    CPU Affinity    NUMA Affinity
GPU0     X      SYS     SYS     SYS     SYS     0-23,96-119     0
GPU1    SYS      X      SYS     SYS     SYS     24-47,120-143   1
GPU2    SYS     SYS      X      SYS     SYS     48-71,144-167   2
GPU3    SYS     SYS     SYS      X      NV2     72-95,168-191   3
GPU4    SYS     SYS     SYS     NV2      X      72-95,168-191   3
```

The same from sysfs (`-1` when the firmware does not say):

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "$d socket $(cat /sys/bus/pci/devices/$d/numa_node)"; done
```

`lspci -tv` shows the root port above each card: from Sandy Bridge-EP on, all root ports of one socket sit on one bus
(`00`, `40`, `80`, `c0` on a four-socket machine). On the reporter's server the cards `04`, `41` and `81` sit below
root port `03.0` of the first three buses, and `c1` and `c4` below `c0:03.0` and `c0:02.0`.

**What to do:**

- **Put the cards that exchange data on one socket.** The board manual's slot table says which slot hangs off which
  CPU. Between two root ports of one socket the CPU's own I/O hub carries the traffic, and NVIDIA allows it: an outside
  report on a one-socket X79 measured 3.1-5.2 GB/s
  ([turing.md](turing.md#outside-report-four-rtx-2080-ti-on-an-x79-board)). One socket of a four-socket Xeon E7 has
  not been measured: in the report the only two cards on one socket are joined by an NVLink bridge, and CUDA copies
  between them over NVLink.
- **Otherwise let copies go through host memory.** With the pinned build that happens by itself for these pairs. For
  NCCL, `NCCL_P2P_LEVEL=PHB` (or `NODE`) keeps P2P inside a socket
  ([NCCL entry](#nccl-goes-via-shm-although-cuda-offers-peer-access)).
- **To measure the slow path anyway**, set `ForceP2P=0x11` for the driver (`NVreg_RegistryDwords=ForceP2P=0x11`, in
  `EXTRA_NVIDIA_OPTS` of `contrib/config.sh` for a trial load). NVIDIA's own key then overrides the check, as in the
  stock driver. `p2p-check.sh` still skips the pair; run `contrib/integrity/p2p-integrity --pair <A> <B>` yourself.

**Other servers:** Intel from Skylake-SP on (UPI) and AMD EPYC are not in NVIDIA's list, and the patched driver offers
P2P across their sockets. Nobody has measured that with it: compare the integrity test's bandwidth line with a copy
through host memory (`tools/staged_baseline.cu`) before you rely on it.

## `p2p-check.sh --integrity` times out on a slow pair, every case clean

From the same outside report.

**Symptom:** on a slow pair (above), `p2p-check.sh --integrity` ends in `FAIL integrity <A> <B>: timed out (hung peer
transfer?...)` and `STOPPED after the timeout: the GPUs may be wedged`, although every case that ran was byte-exact and
the kernel log is clean. In the report it stopped at case 246 of 252.

**Cause:** the time limit for the whole pair, 1200 s plus `--max-mib`/2 seconds (3248 s at the default 4096 MiB), is
for pairs that move several GB/s. At 0.23 GB/s the 4 GiB cases alone take longer.

**Fixed in the fork at `d8f11e2`** (pinned since 2026-11-25): when the limit for the whole pair is reached but every
complete case was byte-exact, no single transfer went over its own limit and the kernel log has no new events, the
script says `FAIL integrity <A> <B>: incomplete ... a slow peer path, not a hung one`, prints a larger limit estimated
from the cases done, and tests the next pair. A real hang still stops the run.

**Fix:** run it again with a larger limit, for example

```bash
sudo INTEGRITY_TIMEOUT=7200 contrib/p2p-check.sh --integrity
```

(7200 s was enough in the report). Then compare the pair's bandwidth with copies through host memory: a pair this slow
is better off without P2P.

## Kernel log: `DynBar1P2P: ... BAR1 is smaller than VRAM; BAR1 P2P not advertised`

From the same outside report; explained from the driver's source.

**Symptom:** the kernel log has lines like

```
NVRM: dynBar1P2PLogRefusal: DynBar1P2P: GPU 0000:81:00: BAR1 is smaller than VRAM; BAR1 P2P not advertised for pair GPU2 <-> GPU3
```

and the pairs with that card get no peer access.

**Cause:** at that boot the card's memory window (BAR1) was smaller than its memory. The patched driver needs a window
at least as large as the memory, so it refuses P2P for every pair with that card, on purpose: CUDA then reports no
peer access and copies through host memory, instead of offering a peer access that would fail at the first copy. On
Turing the window is grown at every boot by geforce-bar1-resize; a boot where it did not run before the driver loaded,
or failed for that card, leaves the 256 MB window the card starts with. The address is the card with the small window;
`GPU2 <-> GPU3` are the driver's internal numbers for the pair.

The patched driver logs refusals only, at most 10 lines in 5 seconds; a pair that gets P2P adds nothing to the log.
With the pinned build, a pair on two Intel CPU sockets of the older generations is refused before this check, with the
`peer on another Intel CPU socket` line ([above](#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)),
so for such pairs this line comes only from older builds.

**Check** each card's window:

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "$d $(sudo lspci -vv -s $d | grep -oE 'Region 1:.*')"; done
```

and whether the resize ran at this boot:

```bash
journalctl -b -u geforce-bar1-resize --no-pager -o cat | grep 'armed and resized'
```

**Fix:** get the window grown before the driver loads: on Turing, the boot install
([procedure step 16](procedure.md#16-boot-install-make-it-survive-a-reboot)) and a reboot, then the check in
[turing.md T3](turing.md#t3-reboot-and-check-the-windows). Each `Region 1` must be at least the card's memory.
