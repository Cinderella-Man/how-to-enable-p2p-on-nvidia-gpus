# Procedure: P2P on GeForce RTX 3090s with Ubuntu 26.04

Step by step, from a fresh Ubuntu 26.04 install to two RTX 3090s that copy directly into each other's memory over PCIe.

The patched driver is [Cinderella-Man/geforce-dynbar1-p2p](https://github.com/Cinderella-Man/geforce-dynbar1-p2p).
That is a fork of [noon-at-cgn/geforce-dynbar1-p2p](https://github.com/noon-at-cgn/geforce-dynbar1-p2p)
(NVIDIA's open kernel modules 615.71.09 with a dynamic-BAR1 P2P patch series) plus the two fixes it needs to build and
run on Ubuntu 26.04 (step 9). Only the **kernel modules** are replaced. The userspace (libcuda, nvidia-smi) stays
Ubuntu's stock 615.71.09 packages.

## Status of each step

| Steps | Status |
|---|---|
| 1-16 (driver, CUDA, build from the fork, trial load, integrity test, boot install, reboot) | **Verified 2026-11-23, twice.** First on the original test rig (installed as 24.04, upgraded to 26.04). Then on the same machine **freshly installed with Ubuntu 26.04.1**, as a blind run: a reader with only this repository followed the steps in order. That run found two gaps, both fixed in this version: `git` was missing in step 6, and the initramfs needed step 16a. In both runs the integrity test passed (264 cases, 1.4 TiB byte-exact), and P2P came up by itself after every reboot, including with Ubuntu's default udev rules and `nvidia-persistenced`. |
| 4b (BAR1 with geforce-bar1-resize, every card) | The same commands as [turing.md](turing.md) T1-T3, verified at boot with two Turing cards on the test rig; on RTX 3090s whose vBIOS stops at 256 MB run once by hand on another machine ([three-cards.md](three-cards.md#bar1-on-cards-without-resizable-bar)), and at boot in outside reports ([boards.md](boards.md#outside-reports-rtx-30-pairs-on-two-huananzhi-x99-boards)). Step 4b as written ran on the test rig on 2026-11-28 with a Zotac RTX 3080 12 GB behind the chipset (Re-Size BAR Support off in the BIOS): 256 MB at boot, 16 GB after the reboot, also through the forced `0x610` route; the driver started on it, 0 Xid. The same day on an RTX 4080 SUPER (Ada) on another machine, on a CPU slot, Re-Size BAR Support off: 256 MB at boot, 16 GB after the reboot by the plain resize, the driver started on it; `0x610` run by hand on it also gave 16, 32 and 64 GiB ([the fork's hardware.md](https://github.com/Cinderella-Man/geforce-bar1-resize/blob/main/docs/hardware.md#ada-0x610-on-an-rtx-4080-super-ad103)). |
| 17-18 (updates, rollback) | Taken from the upstream scripts and README. Not run yet. |

The fork's pin has moved since those runs: to `25c929e` (an opt-in driver key, off unless set) and, on 2026-11-25, to
`b70b69c` (two fixes from an outside report, [step 9](#9-what-the-fork-changes-compared-to-upstream-nothing-to-do)),
tested on three RTX 3090s on another machine as a trial load ([three-cards.md](three-cards.md)), and then to `d8f11e2`
(two more from a second outside report: cards on two Intel CPU sockets are refused as in NVIDIA's own driver, and the
integrity test tells a slow pair from a hung one), and on 2026-11-28 to `9f80306` (`p2p-check.sh` without `--integrity`
ends in `SETUP OK, DATA NOT CHECKED` instead of `ALL PASS`; text only, checked with the fork's stand-in tests), and then
to `4361112` (cards on two root ports of an Intel desktop or laptop CPU are refused: such a CPU does not route peer
reads; the GA102 cards with passing integrity tests are verified; the original repository's compatibility reports).
`e067c4a`'s driver change has run on an AMD board only, where it changes nothing (no pair refused, below); its Intel
desktop and laptop path has not run on a GPU.
Then to `85929ec` (scripts and the integrity test only: a boot install that works on Debian's kernel versions, checks
that the next boot loads it, and the values a failed transfer read). **Run at this pin on 2026-11-28** on three RTX
3090s on another machine (AMD X570, one card behind the chipset, kernel 7.0.0-44, kmod 34.2), everything but the
reboot: steps 8-14 (the trial load, `topo -p2p r` `OK` on all three pairs, 0 pairs refused, the integrity test `ALL
PASS` on all three pairs, 264 cases each), then step 16b (`/etc/depmod.d/p2p.conf` with the anchored kernel field,
every module resolving to `updates/p2p`, `p2p-check.sh`'s new check passing), every module unloaded and loaded again by
`modprobe` from the install (our build, with its options; `ALL PASS` again), and step 18 with `--live` back to stock.
`acd74cf`'s driver change compiles and has not run on a GPU; with the cards on one socket it changes nothing. The whole
procedure has not been re-run with this pin.

Run everything below over **SSH** from another machine. Step 12 stops the desktop, because the GPUs must be idle while
the modules are swapped.

## What you need

- Two GA102 GeForce cards (RTX 3080 / 3080 Ti / 3090 / 3090 Ti). Tested with two RTX 3090s, and with an RTX 3080
  12 GB + RTX 3080 10 GB (a mixed pair works). Three or more cards: [three-cards.md](three-cards.md). Other chips are opt-in upstream; see its README. **Turing cards (RTX 20
  / GTX 16):** follow [turing.md](turing.md), which uses some of the steps below. GTX 10 (Pascal), Volta (V100) and older
  cannot use the patched driver: the open kernel modules do not run on them. What works for them with NVIDIA's stock
  driver: [pascal-and-volta.md](pascal-and-volta.md).
- A board that carries the traffic between the two slots. Both cards on CPU lanes is best; a chipset slot works with
  limits; cards behind a mining board's PCIe switches do not get P2P. What is known per board:
  [boards.md](boards.md).
- Each card's BAR1 at least as large as its VRAM (32 GiB for a 24 GiB 3090, 16 GiB for a 10 or 12 GB 3080): from
  Resizable BAR in the BIOS, or, where the BIOS has no such option or the card's vBIOS stops at 256 MB, from
  geforce-bar1-resize at every boot, without flashing anything ([step 4b](#4b-a-bar1-at-least-as-large-as-each-cards-memory)).
  Either way **Above 4G Decoding** must be on in the BIOS ([step 1](#1-bios)): without it no BAR1 can be larger than
  256 MB, and P2P cannot work.
- Secure Boot **off**. The modules you build here are unsigned.
- Ubuntu 26.04 with the `nvidia-driver-615-open` package: version **615.71.09** exactly. Any other driver branch
  will not work with this patch set.

---

## 1. BIOS

The names differ between board makers; the test rig's MSI names are given where they differ.

- **Above 4G Decoding: on. Without it P2P cannot work.** (MSI: *Above 4G memory/Crypto Currency mining*; ASUS,
  Gigabyte and ASRock: *Above 4G Decoding*.) It lets the firmware place memory windows above 4 GB. Without it no card
  gets a BAR1 larger than 256 MB: neither Resizable BAR nor geforce-bar1-resize ([step 4b](#4b-a-bar1-at-least-as-large-as-each-cards-memory)) can enlarge it
  (the resize fails with `No space left on device`), and a card with a large window of its own, such as a Tesla V100
  (32 GB), cannot get its window at all. **Check it again after changing Resizable BAR:** on the test rig's MSI B550,
  the boot after Re-Size BAR Support was switched off never reached the network, and the machine came up normally once
  Above 4G memory was enabled again.
- **Resizable BAR: on, if the BIOS has it.** (MSI, ASUS, Gigabyte: *Re-Size BAR Support*; on ASRock's AMD boards also
  *C.A.M. (Clever Access Memory)*.) It gives each card the largest window its vBIOS offers. It needs UEFI boot (CSM
  off). If the BIOS has no such option, or the card's vBIOS offers only 256 MB, [step 4b](#4b-a-bar1-at-least-as-large-as-each-cards-memory) does the same job
  without it.
- **CSM (Compatibility Support Module): off** if you use Resizable BAR from the BIOS. geforce-bar1-resize (step 4b) works
  either way: an outside report booted in legacy mode ([boards.md](boards.md#outside-report-two-rtx-3090s-on-a-huananzhi-x99-f8)).
- **IOMMU / AMD-Vi (or VT-d): on or auto.** Step 4 puts it in passthrough mode; without passthrough, peer copies can be
  lost without any error.
- **Secure Boot: off.** The modules you build here are unsigned, and with Secure Boot on the kernel refuses to load
  them (unless you sign them with a key the machine trusts, a MOK, as two outside reports did).
- **A bifurcation splitter** (several cards in one x16 slot): set that slot's lane split first (MSI: *PCI_E1 Lanes
  Configuration*, for example x4x4x4x4) and its speed (MSI: *PCI_E1 Gen Switch*, Gen3 for a Gen 3 splitter); with the
  defaults the board finds no card behind it ([boards.md](boards.md)).

Check after Ubuntu is installed (step 2):

```bash
lspci -D -d 10de::0300
```

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "== $d"; sudo lspci -vv -s "$d" | grep -E 'Region 1:|BAR 1:|LnkSta:'; done
```

Each card must show a BAR 1 at least as large as its memory: `Region 1: ... [size=32G]` and
`BAR 1: current size: 32GB` on an RTX 3090, `16G` / `16GB` on an RTX 3080. If it shows `256M`, Resizable BAR is
not active: turn it on in the BIOS if the BIOS has the option. If it has none, or the card's vBIOS lists nothing above
256 MB (`supported: 64MB 128MB 256MB`), [step 4b](#4b-a-bar1-at-least-as-large-as-each-cards-memory) gives the card its
full window with geforce-bar1-resize, with no vBIOS update and no BIOS option. Nothing after step 4b works with a
256 MB BAR1. `LnkSta` showing `2.5GT/s (downgraded)` at idle
is normal: the link slows down to save power and speeds up under load.

```bash
mokutil --sb-state
```

The output must be `SecureBoot disabled`.

## 2. Ubuntu base

Install Ubuntu 26.04. It is fine to tick "install third-party drivers" in the installer, because step 3 replaces that
driver anyway. Then:

```bash
sudo apt update && sudo apt full-upgrade -y
```

```bash
sudo reboot
```

> A fresh 26.04 install and one upgraded from 24.04 differ in one way that matters here: a fresh install builds the
> initramfs with **dracut**, which copies the NVIDIA driver into it. Step 16a handles that. (The installer's driver is
> the precompiled 595 package; step 3 replaces it either way.)

## 3. NVIDIA driver 615.71.09 (open kernel modules) from the Ubuntu archive

`ubuntu-drivers devices` lists `nvidia-driver-595-open` as **recommended**. Do **not** take that one. Install the 615
branch by name:

```bash
sudo apt install -y nvidia-driver-615-open
```

```bash
sudo reboot
```

Check:

```bash
cat /proc/driver/nvidia/version
```

The first line must contain `NVIDIA UNIX Open Kernel Module for x86_64  615.71.09`.

```bash
dpkg -l | grep -E 'nvidia-(driver|dkms|firmware)-615'
```

Expected: `nvidia-dkms-615-open`, `nvidia-driver-615-open` (and possibly `nvidia-driver-615`) and
`nvidia-firmware-615-615.71.09`, all at version `615.71.09-...`.

```bash
ls -l /lib/firmware/nvidia/615.71.09/
```

`gsp_ga10x.bin` and `ucodes_ga10x.bin` must be there. They come from the `nvidia-firmware-615-615.71.09` package. The
patched modules need exactly this firmware.

### Leftovers of Ubuntu's prebuilt modules

If the machine had Ubuntu's prebuilt NVIDIA modules before (`linux-modules-nvidia-595-<kernel>`, for example from
`ubuntu-drivers`), check that none of their packages are left:

```bash
dpkg -l | awk '/^ii/ && $2 ~ /^linux-(modules|objects|signatures)-nvidia/ && $2 !~ /-615/ {print $2}'
```

Expected: nothing. The switch to 615 can leave `linux-objects-nvidia-595-<kernel>` and
`linux-signatures-nvidia-<kernel>` installed. Their files in `/lib/modules/<kernel>/kernel/nvidia-595/bits/` made
`p2p-load.sh` stop in step 13 before fork commit `4c5a97a` (an outside report;
[troubleshooting](troubleshooting.md#p2p-loadsh-nvidiakosig-not-found-then-neither-the-stock-driver-nor-the-build)).
Nothing of the 615 driver depends on them. Remove what the check lists:

```bash
sudo apt purge $(dpkg -l | awk '/^ii/ && $2 ~ /^linux-(modules|objects|signatures)-nvidia/ && $2 !~ /-615/ {print $2}')
```

apt lists what it will remove before it asks: only those packages, nothing with `615` in its name.

### Pin the driver version

The patched kernel modules only work with userspace 615.71.09. If apt (or unattended-upgrades) moves the 615 packages to
a newer upstream release, `nvidia-smi` fails with `Driver/library version mismatch`. Hold every 615 package:

```bash
dpkg -l | awk '/^ii/ && $2 ~ /615/ {print $2}' | xargs sudo apt-mark hold
```

```bash
apt-mark showhold
```

Expected: about 20 packages, every one with `615` in its name. (Undo later with `apt-mark unhold`, the same way.)

## 4. IOMMU in passthrough mode

The patch needs the IOMMU either off or in passthrough mode. Add `iommu=pt` to `GRUB_CMDLINE_LINUX_DEFAULT`. On an
**Intel** CPU add `intel_iommu=on iommu=pt` instead. Do not skip it because P2P seems to work without it: on a machine
with two Tesla V100s and NVIDIA's stock driver, CUDA reported peer access while the IOMMU silently dropped the copies
in one direction, and an outside report saw every copy between two Tesla P40s on an Intel X99 board come back wrong
([troubleshooting](troubleshooting.md#peer-copies-faster-than-the-link-allows-or-io_page_fault-from-nvidia)). (On AMD the IOMMU is on whenever the BIOS enables it.
`amd_iommu=on` is not a valid option: the kernel logs `AMD-Vi: Unknown option - 'on'` and ignores it. Both test runs
had it, harmlessly.)

AMD:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 iommu=pt"/' /etc/default/grub
```

Intel:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_iommu=on iommu=pt"/' /etc/default/grub
```

```bash
grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
```

Expected: `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=pt"` (Intel: `"quiet splash intel_iommu=on iommu=pt"`)

```bash
sudo update-grub && sudo reboot
```

Check:

```bash
cat /proc/cmdline
```

It must contain `iommu=pt`. A `crashkernel=...` option there is Ubuntu's default and fine.

```bash
sudo dmesg | grep -i 'Default domain type'
```

Expected: `iommu: Default domain type: Passthrough (set via kernel command line)`

## 4b. A BAR1 at least as large as each card's memory

P2P needs each card's BAR1 (its memory window, `Region 1`) to be at least as large as its memory. Check it as in step
1:

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "$d $(sudo lspci -vv -s $d | grep -oE 'Region 1:.*|BAR 1: current size.*' | tr '\n' ' ')"; done
```

- **Every card shows at least its memory** (`[size=32G]` on an RTX 3090, `16G` on a 10 or 12 GB RTX 3080): go on to
  step 5.
- **A card shows less** (`[size=256M]`), and the BIOS has a Resizable BAR option that is off: turn it on, reboot, check
  again.
- **Otherwise**: the BIOS has no such option, or the card itself offers nothing larger (`supported: 64MB 128MB 256MB`).
  That is every Turing card (RTX 20, GTX 16) and many RTX 30 cards, RTX 3090s included. A vBIOS update is not needed:
  [geforce-bar1-resize](https://github.com/Cinderella-Man/geforce-bar1-resize) enlarges BAR1 at every boot, before
  the NVIDIA driver loads, through the card's frame-buffer size override in PCI config space (`0x610`). Nothing is
  flashed, a boot without it returns the stock window, and it needs no Resizable BAR option in the BIOS. It does need
  **Above 4G Decoding** on ([step 1](#1-bios); MSI: *Above 4G memory/Crypto Currency mining*): without it the resize
  fails with `No space left on device`. It gave 32 GiB to RTX 3090s
  whose vBIOS stops at 256 MB ([three-cards.md](three-cards.md#bar1-on-cards-without-resizable-bar)), also on an X99
  board without any Resizable BAR option, where two RTX 3090s of the same model took different routes (an outside
  report, [boards.md](boards.md#outside-report-two-rtx-3090s-on-a-huananzhi-x99-f8)), and 8 GB and 4 GB to the
  Turing cards of the test rig ([turing.md](turing.md)).

geforce-bar1-resize is a fork of [noon-at-cgn's](https://github.com/noon-at-cgn/geforce-bar1-resize), by the author
of the patched driver. We reviewed its code (no network access, no writes outside its documented files; its optional
"layout" kernel module stays unused here). The fork is upstream's `5346660` plus our own fixes. Pin the reviewed
commit:

```bash
cd ~
git clone https://github.com/Cinderella-Man/geforce-bar1-resize.git
cd geforce-bar1-resize
git checkout 5033f430c9d0a9728e24386eb310d51e1f1ee8fd
```

Read-only check, one card at a time, with its memory size (`24G` for an RTX 3090, `10G` or `12G` for an RTX 3080, `8G`,
`6G`, `4G` for the Turing cards):

```bash
sudo scripts/geforce-bar1-resize check --vram 24G 0000:01:00.0
```

The card must show six lines starting with `ok` (S1 to S6) and a `PLAN` line: `arm 0x610 VAL=9, resize to 32768 MiB`
for a 24 GB card (`VAL=8` and 16384 MiB for 10 and 12 GB, `VAL=7` and 8192 MiB for 6 and 8 GB, `VAL=6` and 4096 MiB for
4 GB), or `resize-only to ...` for a card that already lists the size. A card behind a chipset or other PCIe switch
also prints `behind a PCIe switch: yes`: on RTX 30 cards the kernel grew the windows by itself
([three-cards.md](three-cards.md#bar1-on-cards-without-resizable-bar)); Turing cards need
[turing.md T2](turing.md#t2-add-the-usb-c-pre-step) first.

Install it with the layout module off, dry run first. The installer records each card's memory while the driver runs
(step 3), so the next boot enlarges it:

```bash
sudo ./install.sh --dry-run --layout off --enable
```

```bash
sudo ./install.sh --layout off --enable --yes
```

The patched driver needs dynamic BAR1 on every card (step 11b). Let the tool write that for every card, not only for
those it enlarges through `0x610`:

```bash
sudo sed -i 's/^DRIVER_OPTION=auto$/DRIVER_OPTION=on/' /etc/geforce-bar1-resize.conf
sudo geforce-bar1-resize driver-option --write
```

The resize has to run before the NVIDIA driver loads. On a fresh 26.04 install dracut copies the driver into the
initramfs (the 615 install does it again), so it loads first, and the resize logs `already bound to nvidia, skip`: do
[step 16a](#16a-keep-the-nvidia-driver-out-of-the-initramfs) now, before the reboot.

**Turing cards (RTX 20, GTX 16):** add the USB-C pre-step now ([turing.md T2](turing.md#t2-add-the-usb-c-pre-step)).

Reboot and check:

```bash
sudo reboot
```

```bash
journalctl -b -u geforce-bar1-resize --no-pager -o cat | grep -E 'armed and resized|resized to|skip|failed'
```

Expected, per card: `... armed and resized to 32768 MiB` (or `resized to ...` for a resize-only card). Then the check
command at the top of this step: every `Region 1` at least the card's memory. And the driver must have started on every
card with the new window:

```bash
sudo dmesg | grep -E 'RmInitAdapter failed|kbusVerifyBar2' || echo clean
```

It must print `clean`. If it prints `kbusVerifyBar2_GM107: ... returned garbage` and `RmInitAdapter failed`, the
windows moved to addresses the CPU does not pass on to the cards, as on an Intel X79 board in an outside report:
[troubleshooting](troubleshooting.md#after-the-bar1-resize-every-card-fails-kbusverifybar2_gm107--returned-garbage).
A machine with many cards may need a larger 64-bit window per root bridge in the BIOS (eight RTX 3090 on a WRX80 board
needed `ResourceSizeForEachRb`).

## 5. CUDA Toolkit 13.5

You need this for `nvcc` (the integrity test and the test programs). These are NVIDIA's local-repo installer commands
for Ubuntu 26.04, as run on the test rig:

```bash
cd ~
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/cuda-ubuntu2604.pin
sudo mv cuda-ubuntu2604.pin /etc/apt/preferences.d/cuda-repository-pin-600
wget https://developer.download.nvidia.com/compute/cuda/13.5.0/local_installers/cuda-repo-ubuntu2604-13-5-local_13.5.0-1_amd64.deb
sudo dpkg -i cuda-repo-ubuntu2604-13-5-local_13.5.0-1_amd64.deb
sudo cp /var/cuda-repo-ubuntu2604-13-5-local/cuda-*-keyring.gpg /usr/share/keyrings/
sudo apt-get update
sudo apt-get -y install cuda-toolkit-13-5
```

The download is about 3.9 GB. `dpkg -i` prints that the repository's GPG key "does not appear to be installed": the
next line, the `cp` of the keyring, fixes that. You can delete the `.deb` once the install is done.

> Install **`cuda-toolkit-13-5`** only. Do not install the `cuda` or `cuda-drivers` metapackages: they pull in NVIDIA's
> own driver packages, which replace Ubuntu's 615.71.09.

Put `nvcc` on the PATH:

```bash
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc && source ~/.bashrc
```

```bash
nvcc --version | tail -2
```

> **Toolkit newer than driver.** Driver 615.71.09 supports CUDA **13.4** (`nvidia-smi` shows `CUDA UMD Version: 13.4`),
> but the toolkit is 13.5. A plain `nvcc` build of anything that launches a GPU kernel then fails at run time with
> `the provided PTX was compiled with an unsupported toolchain`. Compile with **`-arch=native`** (native code for the
> installed cards, no PTX JIT), as all commands below do.

## 6. Baseline: P2P is off with the stock driver

Clone this guide onto the machine. The three small test programs are in `tools/`. The NVIDIA benchmarks are git
submodules, fetched only when you ask for them (see [benchmarks.md](benchmarks.md)):

```bash
sudo apt install -y git
```

```bash
cd ~
git clone https://github.com/Cinderella-Man/how-to-enable-p2p-on-nvidia-gpus.git
cd how-to-enable-p2p-on-nvidia-gpus
```

```bash
nvcc -O2 -arch=native tools/p2p_access.cu -o tools/p2p_access
nvcc -O2 -arch=native tools/p2p_bandwidth.cu -o tools/p2p_bandwidth
nvcc -O2 -arch=native tools/pcie_bandwidth.cu -o tools/pcie_bandwidth -lnvidia-ml
```

```bash
nvidia-smi topo -p2p r
```

```bash
./tools/p2p_access
```

Stock driver: `topo -p2p r` shows `GNS` (GPU not supported) between the cards, and `p2p_access` prints `NO`.
`./tools/p2p_bandwidth` prints `CanAccessPeer 0->1: 0, 1->0: 0` and exits with status 1.

## 7. Build prerequisites

```bash
sudo apt install -y git build-essential dkms linux-headers-$(uname -r) pciutils pahole
```

`pahole` matters. Ubuntu's kernel has `CONFIG_DEBUG_INFO_BTF_MODULES=y`, and without `pahole` the module build fails at
its last step. It was the second build failure on the test rig. (Plain upstream also failed in the CXL code. The fork
fixes that, see step 9.)

## 8. Get the patched driver source

Clone the fork and pin the commit this guide was written against:

```bash
cd ~
git clone https://github.com/Cinderella-Man/geforce-dynbar1-p2p.git
cd geforce-dynbar1-p2p
git checkout 85929ec7ad9fda064f5d08fbc00172d86c5a4a46
```

```bash
git log --oneline -3
```

Expected:

```
85929ec7 contrib: the integrity test prints what a mismatching transfer read, and what it expected
6a79a2a9 contrib: p2p-check.sh FAILs when modprobe does not resolve a module to the boot install, and says why
1d38c89b contrib: p2p-install.sh refuses a depmod.d override read after p2p.conf that wins over it
```

Is the code safe to load? See [security-review.md](security-review.md): everything in the fork that is not NVIDIA's
official 615.71.09 source was reviewed, and no malicious code was found.

## 9. What the fork changes compared to upstream (nothing to do)

The fork's `main` is upstream `ab0ee7d` (upstream `main` as of 2026-11-23) plus sixteen commits:

| Commit | Why |
|---|---|
| [`9504c3e`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/9504c3e0237a2a46c24cb43664b1654b5222a3b3) CXL guard | Linux 7.0 has `<cxl/cxl.h>` but not the CXL API the 615.71.09 sources expect, so `make modules` fails. Cherry-picked from [Ubsefor's commit `0e23c574`](https://github.com/Ubsefor/open-gpu-kernel-modules/commit/0e23c574b430c27d7b5ae394bc6ca488aff346cd), with the original authorship kept. |
| [`e5ad35d`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/e5ad35de7fe517ffa85ff6d057777be7cb9ff465) `.ko.zst` | Ubuntu's stock DKMS modules are `nvidia.ko.zst`. The helper scripts only matched `nvidia.ko`, so `p2p-fallback.sh` reported every stock module as `MISSING` and refused. It only affects the scripts. |
| [`21f0c27`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/21f0c27555dfb12bbbdd21430084440541369e23) no false `ALL PASS` | `p2p-check.sh --integrity` ended in `ALL PASS` even when it had tested no pair at all (every pair skipped as unsupported, or without peer access). Now it counts the pairs and a run that tests none is a `FAIL`. Only the script and its tests change. |
| [`25c929e`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/25c929e8cfebe69f98fd07267aa28cab52b9a6b8) `RMPeerIoMemBar1` | An opt-in driver key, off unless you set it: with `RMPeerIoMemBar1=1` a GPU may register another GPU's memory window as I/O memory, the second route in [mixed-generations.md](mixed-generations.md). Without the key the driver refuses as before. |
| [`4c5a97a`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/4c5a97ae993e0ec636b3c7ac2bf1c2686c7bb62b) leftover `.sig` | After a switch from Ubuntu's prebuilt 595 modules, their leftover `nvidia.ko.sig` could be taken for the stock module, and `p2p-load.sh` stopped ([troubleshooting](troubleshooting.md#p2p-loadsh-nvidiakosig-not-found-then-neither-the-stock-driver-nor-the-build)). The scripts now take only module files. Only the scripts and their tests change. |
| [`b70b69c`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/b70b69c85093fd68d927add3d54bdadc8167c54f) peer budget per card | With three or more cards and peer access between all of them, each card could map only one card's BAR1 of all the others' memory together ([troubleshooting](troubleshooting.md#three-or-more-cards-cudamalloc-runs-out-of-memory-with-peer-access-between-all-of-them)). Now it counts per other card, and a refused allocation leaves a line in the kernel log. With two cards nothing changes (each card has one other). Tested on three RTX 3090s ([three-cards.md](three-cards.md#peer-memory-old-and-new-build)). |
| [`acd74cf`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/acd74cf67bfe935c08c2b7855243d030a667f0dc) two CPU sockets | NVIDIA's driver refuses P2P between cards on two Intel CPU sockets of the Xeon E5/E7 generations up to v4 (`TNS`): it is slower there than copying through host memory. The patched driver skipped that check along with the ones it has to skip for GeForce cards, and an outside report measured 0.23 GB/s between sockets ([troubleshooting](troubleshooting.md#two-cpu-sockets-p2p-works-but-slower-than-copying-through-host-memory)). Now it keeps it, and `p2p-check.sh --pairs` says why such a pair is not supported. Cards on one socket: no change. Compiles; not run on a GPU. |
| [`d8f11e2`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/d8f11e2b345d66c1a4c16468188ac142e9e0b017) slow pair | When the integrity test reaches its time limit for a pair but every case so far was byte-exact, `p2p-check.sh --integrity` now says `incomplete` with a larger limit to try, instead of "the GPUs may be wedged", and goes on to the next pair ([troubleshooting](troubleshooting.md#p2p-checksh---integrity-times-out-on-a-slow-pair-every-case-clean)). Only the script and its tests change. |
| [`9f80306`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/9f803069d60e2aae46baac0bfee2e75fd7e19260) no `ALL PASS` without a data check | `p2p-check.sh` without `--integrity` moves no data, but a clean run ended in `ALL PASS`, which reads as "P2P works" while `nvidia-smi topo -p2p r`'s `OK` only says the driver offers it ([`OK` is not proof](../README.md#ok-is-not-proof)). Such a run now ends in `SETUP OK, DATA NOT CHECKED`, its `topo` lines say `OK (P2P offered; no data check)`, and `ALL PASS` comes only from `--integrity`. Same exit status. Text only, with its stand-in tests |
| [`44562b5`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/44562b5f) links | The compatibility-report link, the clone and the geforce-bar1-resize links point at the Cinderella-Man forks, whose issues are open. Text only |
| [`e067c4a`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/e067c4a9) Intel client CPUs | An Intel desktop or laptop CPU (Core, and the Xeon E3/E/W-1x00 on the same dies) forwards peer writes between its root ports but not peer reads, and the fork offered reads all the same: in an outside report (Z590, Core i7-11700K, 2x RTX 3090) copies were byte-exact while kernel reads of the other card came back wrong. Such pairs are now refused (`TNS`), as NVIDIA's stock rule effectively does; cards below one PCIe switch and NVIDIA's `ForceP2P` are not. A check added in `p2p_caps.c` (CPU family and model, root port vendor), the same rule in `contrib/chips.sh`, a stand-in test |
| [`4361112`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/43611128eda058e474cdc616b9c19d4f0fa5ba51) verified cards | The GA102 cards with passing integrity tests on this driver count as verified (RTX 3080 10/12/20 GB, 3080 Ti, 3080 Ti 20GB, 3090, 3090 Ti), and the original repository's ten compatibility reports are in its README with the platform limits they showed. Scripts' verdict texts and docs |
| [`2d2f6c6`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/2d2f6c61) depmod.d kernel field | depmod reads the kernel field of an `override` line as a regular expression, so the `+` of a Debian kernel version (`6.12.115+deb13.1-amd64`) made the boot install's override never apply and the stock modules kept loading (an outside report). `p2p-install.sh` writes the field anchored, with such characters in brackets, and checks that it matches |
| [`1d38c89`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/1d38c89b) depmod.d conflicts | `p2p-install.sh` refuses, before changing anything, when another depmod.d file read after its own overrides one of the modules for this kernel (the last override read wins), naming the file and line |
| [`6a79a2a`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/6a79a2a9) boot install check | With a boot install, `p2p-check.sh` FAILs when modprobe resolves a module to anything but the installed build, and says why (a later override, its own line not applying, or modules.dep not rebuilt) |
| [`85929ec`](https://github.com/Cinderella-Man/geforce-dynbar1-p2p/commit/85929ec7ad9fda064f5d08fbc00172d86c5a4a46) integrity test | A failed transfer prints the first and last wrong word as read and as expected (an outside report's failing reads printed no value). Passing output unchanged |

To see the full difference:

```bash
git diff ab0ee7d HEAD --stat
```

## 10. Build

```bash
make modules -j"$(nproc)"
```

On the test rig (12 cores) this takes under a minute. Warnings are normal and do not mean the build failed:
`nvidia-modeset.o: warning: objtool: ...`, `Skipping BTF generation for <module>.ko due to unavailability of vmlinux`
(for all five modules), and compiler warnings such as `-Wformat` in `uvm_migrate_pageable.c` or
`-Wframe-larger-than` in `nvidia-drm-drv.c`. The build failed only if `make` exits non-zero or `kernel-open/*.ko` is
missing.

```bash
(cd kernel-open && sha256sum nvidia*.ko > SHA256SUMS)
```

Check:

```bash
cd kernel-open && for f in nvidia*.ko; do echo "== $f"; modinfo "$f" | grep -E '^(version|vermagic):'; done; cd ..
```

Every module must report `version: 615.71.09` and a `vermagic` that starts with `$(uname -r)`. You get five modules:
`nvidia`, `nvidia-modeset`, `nvidia-drm`, `nvidia-uvm`, `nvidia-peermem`.

`SHA256SUMS` pins the build. The scripts refuse any `.ko` that does not match it, so re-run that line after every
rebuild.

## 11. Configure

### 11a. Scripts: which cards, which build

`contrib/config.sh` needs the card addresses (`GPUS`) and the full path of `kernel-open` (`OUT`). Append them:

```bash
cat >> contrib/config.sh <<EOF

# --- local settings ---
GPUS="$(lspci -D -d 10de::0300 | awk '{print $1}' | xargs)"
OUT="$PWD/kernel-open"
EOF
```

```bash
tail -3 contrib/config.sh
```

Expected (your addresses and home directory):

```
# --- local settings ---
GPUS="0000:04:00.0 0000:2b:00.0"
OUT="/home/<you>/geforce-dynbar1-p2p/kernel-open"
```

Spaces between the addresses, inside one pair of quotes, never commas.

### 11b. Driver: dynamic BAR1 for each card (`RMForceStaticBar1=0`)

The patch needs `RMForceStaticBar1=0` for each card. Without it the driver keeps static BAR1 and refuses the pair. If
you installed geforce-bar1-resize in [step 4b](#4b-a-bar1-at-least-as-large-as-each-cards-memory), it wrote this line
for every card (`DRIVER_OPTION=on`): only run the `modprobe -c` check below. If every card got its window from the
BIOS, write the per-card line by hand. Use the file name geforce-bar1-resize would use, because the scripts look for it:

```bash
LINE=$(for g in $(lspci -D -d 10de::0300 | awk '{print $1}'); do printf 'pci=%s;RMForceStaticBar1=0;' "$g"; done)
echo "options nvidia NVreg_RegistryDwordsPerDevice=\"$LINE\"" | sudo tee /etc/modprobe.d/zz-geforce-bar1-resize.conf
```

```bash
sudo modprobe -c | grep NVreg_RegistryDwordsPerDevice
```

Expected: `options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:04:00.0;RMForceStaticBar1=0;pci=0000:2b:00.0;RMForceStaticBar1=0;"`

The separators here are semicolons. In `GPUS` they are spaces.

### 11c. Read-only check

```bash
contrib/p2p-check.sh --pairs
```

This judges the options of the **running** driver. Right after 11b that is still the stock driver loaded at boot,
which has not seen the new setting yet, so on a first run it prints:

```
0000:04:00.0 <-> 0000:2b:00.0: untested (GA102 + GA102): run p2p-check.sh --integrity on a trial load ..., then enable with: p2p-enable.sh --yes ...; static BAR1 on 0000:04:00.0 0000:2b:00.0 (no RMForceStaticBar1=0 ...)
```

That is expected here. Do **not** run `p2p-enable.sh`; this guide never needs it. What matters at this point is that
both cards are listed as `GA102` with `BAR1 32768 MiB, VRAM 24576 MiB`. Once a driver has loaded with the 11b setting
(after the trial load in step 13, or after any reboot), the same command prints
`on by default, untested (GA102 + GA102 ...)`. "Untested" only means that upstream has verified the RTX 3080 20GB
alone.

## 12. Prepare the live swap: stop everything that reloads the stock driver

**This is the step that cost hours on the test rig.** `p2p-load.sh` unloads the stock modules and insmods the patched
ones while udev is paused. When udev resumes, it replays the events it held back. Ubuntu's
`/usr/lib/udev/rules.d/71-nvidia.rules` runs `modprobe -r nvidia-modeset / nvidia-drm / nvidia-uvm` on the `remove`
event of the nvidia driver. That unloads the patched stack, and the next `add` event loads the **stock** modules again.
After that the two rules keep ping-ponging: about 1000 unload/reload cycles in an hour on the test rig, one every ~4 s.
See [troubleshooting.md](troubleshooting.md#the-driver-keeps-reloading-every-few-seconds).

### 12a. Disable the `remove` rules (override in /etc, the package file stays untouched)

```bash
sudo cp /usr/lib/udev/rules.d/71-nvidia.rules /etc/udev/rules.d/71-nvidia.rules
sudo sed -i '/^ACTION=="remove".*modprobe -r/ s/^/# /' /etc/udev/rules.d/71-nvidia.rules
sudo udevadm control --reload-rules
```

```bash
grep -n 'modprobe' /etc/udev/rules.d/71-nvidia.rules
```

All three `ACTION=="remove" ... modprobe -r` lines must now start with `# `. The `add` lines stay active. With the
patched modules already loaded they are no-ops.

### 12b. Stop and mask nvidia-persistenced

The same rules file starts `nvidia-persistenced` on every driver `add` event (`SYSTEMD_WANTS`), and it holds
`/dev/nvidia*`. A plain `stop` is not enough, because the next event starts it again. Mask it:

```bash
sudo systemctl stop nvidia-persistenced
sudo systemctl mask nvidia-persistenced
```

If you have your own units with `Wants=nvidia-persistenced.service` or anything else that runs `nvidia-smi` at events
(a power-limit service, monitoring, containers), stop them too.

### 12c. Stop the desktop and check that nothing holds the GPUs

```bash
sudo systemctl stop display-manager
```

```bash
sudo fuser -v /dev/nvidia* /dev/dri/* 2>&1
```

In the good case this prints **nothing** (and exits with status 1). If it lists processes, stop them, or set
`DRAIN_CMD` and `RESTORE_CMD` in `contrib/config.sh`.

## 13. Trial load (nothing is installed; a reboot returns to stock)

```bash
cd ~/geforce-dynbar1-p2p
sudo env P2P_ENABLE=1 contrib/p2p-load.sh --dry-run
```

Read the plan, then:

```bash
sudo env P2P_ENABLE=1 contrib/p2p-load.sh --yes
```

`P2P_ENABLE=1` writes `RMDynBar1P2PEnable=1` for each card. On GA102 the route is on by default, so this is the same
thing, made explicit. It is what was run on the test rig.

**Verify that the patched modules are the ones loaded and stay loaded.** Run this twice, a minute apart:

```bash
for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do printf '%-16s loaded=%-26s build=%s\n' "$m" "$(cat /sys/module/$m/srcversion 2>/dev/null || echo NOT_LOADED)" "$(modinfo -F srcversion kernel-open/${m//_/-}.ko)"; done
```

`loaded` must equal `build` on every line. `nvidia` and `nvidia_uvm` are the two that differ from stock. `nvidia_modeset`
and `nvidia_drm` have the same srcversion in both builds, so they prove nothing.

```bash
sudo dmesg | grep 'loading NVIDIA UNIX' | tail -3
```

The last line must show your own build (`Release Build (<you>@<host>) <build date>`), not NVIDIA's
`dvs-builder@...`. If new lines keep appearing every few seconds, the reload loop is running. Go back to step 12.

The real test is the number of driver loads since boot. With step 12 in place it is exactly **2** (stock at boot, then
yours) and stays 2. That is what both test runs saw. If it keeps growing, the reload loop is running:

```bash
sudo dmesg | grep -c 'loading NVIDIA UNIX'
```

(Do not count `modprobe -r` lines in the journal instead: udev logs a `modprobe -r` only when it fails, and `sudo` or
Tailscale SSH also log your own commands that contain the text.)

```bash
nvidia-smi topo -p2p r
```

Expected: `OK` between the two GPUs (instead of `GNS`). `OK` says only that the driver offers P2P for the pair, not
that the data arrives: step 14 checks that ([cases where `OK` was wrong](../README.md#ok-is-not-proof)).

**Power and clock settings.** The swap unloads the driver, and every setting made with `nvidia-smi` since boot goes
with it: power limits (`-pl`), locked clocks (`-lgc`), persistence mode. With `nvidia-persistenced` masked (12b), a
setting made now also lasts only while a program holds the card. If your cards need such settings to run stable (in an
outside report, four RTX 2080 Ti fell off the bus, `Xid 79`, without a 1650 MHz clock lock), set them again right
after the load, persistence mode first:

```bash
sudo nvidia-smi -pm 1
```

```bash
sudo nvidia-smi -pl 150 && sudo nvidia-smi -lgc 1650
```

(Your own values.) Or put the same commands in `RESTORE_CMD` in `contrib/config.sh`: `p2p-load.sh` and
`p2p-rollback.sh` run it at their end.

**If a card fails to start** (`RmInitAdapter failed` in `sudo dmesg`), reboot. Do not unload the driver by hand
(`modprobe -r`, `rmmod`): in an outside report that crashed the kernel
([troubleshooting](troubleshooting.md#after-the-bar1-resize-every-card-fails-kbusverifybar2_gm107--returned-garbage)).

## 14. Integrity test

```bash
sudo contrib/p2p-check.sh --integrity
```

It does 264 copy cases, both directions, `cudaMalloc` and `cuMem`, 4 KiB to 4 GiB, every word compared, then measures
bandwidth. It moves about 1.4 TiB, so it takes 4-11 minutes depending on the PCIe links (10.4 minutes on the test
rig, where one card is on a x4 link). The last line must be
`ALL PASS`. The full report goes to `/var/lib/geforce-dynbar1-p2p/reports/<time>/report.txt`, and the PASS is recorded
in `/var/lib/geforce-dynbar1-p2p/integrity-pass`.

Result on the test rig (one card in a B550 chipset slot, PCIe 3.0 x4):

```
cudaDeviceCanAccessPeer: A->B 1, B->A 1; P2P access attribute: A->B 1, B->A 1
bandwidth (cudaMemcpyPeerAsync, 256 MiB x 20, contents checked): A->B 3.27 GB/s, B->A 2.96 GB/s, both ways at once 5.53 GB/s
RESULT PASS 0000:04:00.0 0000:2b:00.0 max-mib 4096 cases 264 transfers 2112 copied 1403.6 GiB
ALL PASS
```

Since fork commit `21f0c27` the output also counts the pairs, `integrity: 1 pair(s) tested, 0 skipped, 0 not run (no
peer access)`, and a run that tests no pair ends in a `FAIL` line instead of `ALL PASS`. A `SKIP` or `NOT RUN` line for
your pair means it was not tested: the script names the reason.

## 15. Quick checks with the test programs

From the guide checkout of step 6:

```bash
cd ~/how-to-enable-p2p-on-nvidia-gpus
./tools/p2p_access
```

```bash
./tools/p2p_bandwidth
```

```bash
./tools/pcie_bandwidth
```

`p2p_access` must print `YES` both ways, and `p2p_bandwidth` reports GPU0 <-> GPU1 GB/s. `pcie_bandwidth` shows each
card's host link. A card behind the chipset is visibly slower, and that card caps the P2P bandwidth. On the test rig
GPU0 (B550 chipset slot) does about 3 GB/s to the host, GPU1 (CPU x16 slot) about 26 GB/s, and P2P runs at about
3.27 / 2.97 GB/s, the same as step 14 within run-to-run noise.

### NVIDIA's benchmarks

For proper numbers, P2P off against P2P on, use NVIDIA's own tools: `p2pBandwidthLatencyTest` (CUDA samples) and
`nvbandwidth`. Both are in this repository as pinned submodules. How to fetch, build and read them, and the test rig's
results, are in [benchmarks.md](benchmarks.md). The headline on the test rig: GPU-to-GPU latency 18-20 µs ->
1-2 µs, bidirectional bandwidth 3.49 -> 5.52 GB/s.

## 16. Boot install: make it survive a reboot

Steps 13-15 only swap the running driver. A reboot loads the stock modules again. That is what happened on the test
rig the first time. The upstream installer makes the patched build the one `modprobe` resolves, for the running kernel
only. But first the initramfs has to be free of NVIDIA modules.

### 16a. Keep the NVIDIA driver out of the initramfs

If the initramfs carries the NVIDIA modules, the stock driver loads from it early in boot (about 6 s on the test rig),
before the root file system with the patched modules is even mounted. `p2p-install.sh` checks for this and refuses
with `ABORT: the initramfs carries an nvidia module`. Check:

```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E '(^|/)nvidia(-drm|-modeset|-uvm|-peermem)?\.ko' || echo none
```

On a system upgraded from 24.04 (initramfs-tools) this prints `none`: go on to 16b. A **fresh 26.04 install** builds
the initramfs with dracut, whose `drm` module adds the GPU's KMS driver, so it prints the four
`updates/dkms/nvidia*.ko.zst` modules. Tell dracut to leave them out and rebuild the initramfs:

```bash
echo 'omit_drivers+=" nvidia nvidia-drm nvidia-modeset nvidia-uvm nvidia-peermem "' | sudo tee /etc/dracut.conf.d/90-omit-nvidia.conf
```

```bash
sudo update-initramfs -u -k "$(uname -r)"
```

Run the check again. It must print `none`. The setting applies to every initramfs dracut builds from now on, so new
kernels are covered too. Side effect: no early NVIDIA mode setting, so the boot splash and console switch to the
NVIDIA driver a few seconds later, once the root file system is up. Verified on the fresh 26.04.1 install: the
initramfs shrank from 130 MB to 40 MB, and the patched driver then loaded at boot.

### 16b. Install and reboot

```bash
cd ~/geforce-dynbar1-p2p
sudo contrib/p2p-install.sh --dry-run
```

```bash
sudo contrib/p2p-install.sh --yes
```

It:

1. backs up to `/var/backups/p2p-modules/<time>/`,
2. copies the five modules to `/lib/modules/$(uname -r)/updates/p2p/`,
3. writes `/etc/depmod.d/p2p.conf` (an `override` per module, this kernel only) and
   `/etc/modprobe.d/zz-nvidia-p2p.conf` (`NVreg_EnableResizableBar=0`, `uvm_disable_hmm=1`),
4. runs `depmod`.

The stock DKMS modules stay where they are. Other kernels still boot stock. It refuses if the initramfs carries an
nvidia module (see 16a).

Its dry run lists `modules.dep resolves: nvidia updates/dkms/nvidia.ko.zst` and so on: the stock modules. Plain upstream
prints `MISSING` there; the fork's `.ko.zst` commit fixes that. After `--yes` the `== verify` section must show every
module resolving to `updates/p2p/...`, followed by `INSTALLED for <kernel>`.

```bash
sudo reboot
```

After the reboot:

```bash
cd ~/geforce-dynbar1-p2p && sudo contrib/p2p-check.sh
```

The exit status is the number of FAIL lines. It must be 0 and the last line `SETUP OK, DATA NOT CHECKED: ...`: this
check moves no data, it shows that the boot loaded the build and the driver offers P2P where it should (`ALL PASS`
comes only from `--integrity`, step 14). Then run the srcversion loop
from step 13, `nvidia-smi topo -p2p r`, and `~/how-to-enable-p2p-on-nvidia-gpus/tools/p2p_access` again. `sudo dmesg | grep -c 'loading NVIDIA UNIX'`
must now be `1`: the patched build is loaded at boot, and nothing is swapped.

### Put udev and nvidia-persistenced back to Ubuntu's defaults

With the boot install in place nothing is swapped at runtime, so the udev override (12a) and the masked persistenced
(12b) are only needed for **live** swaps (`p2p-load.sh`, `p2p-rollback.sh`, `p2p-fallback.sh --live`). Undo both and
reboot:

```bash
sudo rm /etc/udev/rules.d/71-nvidia.rules && sudo udevadm control --reload-rules
```

```bash
sudo systemctl unmask nvidia-persistenced
```

```bash
sudo reboot
```

Verified on the test rig. After this reboot the patched build still loaded at boot, `nvidia-persistenced` ran next to
it, the desktop came up on the patched driver, `p2p-check.sh` had no FAIL line, and the full integrity test ended in
`ALL PASS`.
Redo step 12 before any future live swap.

## 17. Kernel and driver updates (NOT YET VERIFIED)

- **New kernel** (from `apt upgrade` / unattended-upgrades): the boot install is for one kernel. The new kernel boots
  with the stock DKMS modules: no P2P, but a working driver. To get P2P back, boot the new kernel, then:

  ```bash
  cd ~/geforce-dynbar1-p2p
  sudo env KVER=<old kernel version> contrib/p2p-fallback.sh --yes
  make clean && make modules -j"$(nproc)"
  (cd kernel-open && sha256sum nvidia*.ko > SHA256SUMS)
  sudo contrib/p2p-install.sh --yes && sudo reboot
  ```

  The first line removes the old kernel's install. `p2p-install.sh` refuses while one exists for another kernel. The
  dracut setting from 16a already keeps NVIDIA out of the new kernel's initramfs; check it with 16a's `lsinitramfs`
  line before installing.

- **New NVIDIA driver release**: the patch series targets 615.71.09 only. Keep the 615 packages on hold (step 3).
  Moving to another version means waiting for upstream to port the patch series, then rebasing the fork's
  two commits onto it.

## 18. Back to stock

```bash
cd ~/geforce-dynbar1-p2p
sudo contrib/p2p-fallback.sh --yes        # next boot loads stock
sudo reboot
```

`--live` also swaps the running driver immediately (needs step 12 in place). Without a boot install,
`sudo contrib/p2p-rollback.sh --yes` swaps a hand-loaded build back to stock.

The per-card `RMForceStaticBar1=0` file (11b) is harmless for the stock driver. The test rig boots stock with it in
place. So is the dracut setting from 16a: the stock driver then simply loads from the root file system. For a fully
stock system, remove both and rebuild the initramfs:

```bash
sudo rm /etc/modprobe.d/zz-geforce-bar1-resize.conf /etc/dracut.conf.d/90-omit-nvidia.conf
sudo update-initramfs -u -k "$(uname -r)"
```
