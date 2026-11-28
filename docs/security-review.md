# Security review of the fork

Before loading a third-party kernel driver as root, it is worth knowing what is in it. This is a review of
[Cinderella-Man/geforce-dynbar1-p2p](https://github.com/Cinderella-Man/geforce-dynbar1-p2p) at
`e5ad35de7fe517ffa85ff6d057777be7cb9ff465`, done on 2026-11-23, extended on 2026-11-24 to
`25c929e8cfebe69f98fd07267aa28cab52b9a6b8` (two more commits: a change to one script and its tests, and an opt-in
driver key), on 2026-11-25 to `b70b69c85093fd68d927add3d54bdadc8167c54f` (two more commits: two script helpers with
a test, and a counting change in the driver), the same day to `d8f11e2b345d66c1a4c16468188ac142e9e0b017` (two more commits: a P2P
capability check put back in the driver, and a script message), and on 2026-11-28 to
`9f803069d60e2aae46baac0bfee2e75fd7e19260` (one more commit: the last line and the `topo` lines `p2p-check.sh` prints), and then
to `43611128eda058e474cdc616b9c19d4f0fa5ba51` (three more commits: links, a P2P refusal for Intel client CPUs in the driver, and the
scripts' verified cards), and then to `85929ec7ad9fda064f5d08fbc00172d86c5a4a46`, the commit
[procedure.md](procedure.md#8-get-the-patched-driver-source) now pins (four more commits, scripts and the integrity
test only; [below](#verdict-no-malicious-code-found)).

## Scope: only what is not NVIDIA's code

The fork's history contains NVIDIA's official
[open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) tag `615.71.09` (commit
`61dcc93722ecb418bb5f2e00923f05b4b8051dd1`, checked against NVIDIA's repository). So everything that is not NVIDIA's
code is exactly this diff:

```bash
git diff 61dcc93722ecb418bb5f2e00923f05b4b8051dd1 85929ec7ad9fda064f5d08fbc00172d86c5a4a46
```

That is 39 commits by noon-at-cgn (10), dingiv (7), aikitoria (4), the fork owner (15), Duanyll (2) and Ubsefor (1). It
touches 133 files, about 6,500 lines without docs: roughly 3,000 in the kernel driver, 2,000 in shell scripts, and the
rest tests and packaging. There are **no binary files** in the diff.

## Verdict: no malicious code found

The whole diff was read hunk by hunk (kernel driver, contrib scripts, integrity test, packaging, tests), and grepped for
red flags:

- **Kernel driver:** no network or file I/O from the kernel (`sock_*`, `filp_open`, `kernel_read/write`, `vfs_*`), no
  process spawning (`call_usermodehelper`), no credential or capability changes, no new ioctls, no encoded blobs. The
  changes are dynamic BAR1 windows, forced P2P capabilities, the UVM BAR1 gate, and hugepage pinning: all P2P, BAR1 or
  UVM work. Several existing bounds checks on mmap paths were made stricter, not weaker.
- **Scripts:** no network access (a report URL is only printed). Writes go only to the documented paths: `updates/p2p`,
  `/etc/depmod.d/p2p.conf`, `/etc/modprobe.d/zz-*.conf`, `/run/modprobe.d/`, `/var/backups/...`,
  `/var/lib/geforce-dynbar1-p2p`. Every `rm -rf` targets a fixed path or a temp directory.
- **Integrity test** (`contrib/integrity/p2p-integrity.cu`): only CUDA allocation, copies, kernels and compares. No
  file, network or exec I/O. Its report (CPU, board, PCIe paths, no UUIDs) stays local.
- **Build and packaging:** Kbuild/Makefile only add an include path and an optional debug define. DKMS packaging builds
  offline.
- **Hidden tricks:** no zero-width or bidirectional Unicode in the diff. `.github/` holds only issue templates and a
  funding file, no CI workflows.
- **The fork's own sixteen commits** (`9504c3e`, `e5ad35d`, `21f0c27`, `25c929e`, `4c5a97a`, `b70b69c`, `acd74cf`, `d8f11e2`, `9f80306`, `44562b5`, `e067c4a`, `4361112`, `2d2f6c6`, `1d38c89`, `6a79a2a`, `85929ec`) are a 4-line `#if` change, a 14-line
  `awk` change, a change to `contrib/p2p-check.sh` (9 lines: it counts the pairs the integrity test ran, and a run that
  tests none is a FAIL) with its stand-in tests, and a 33-line driver change in `osmemdesc.c` and `nvrm_registry.h`.
  That last one reads one registry key, `RMPeerIoMemBar1`, on the GPU that registers I/O memory, and only when it is 1
  skips one existing check (a range inside another GPU's BAR1). It adds no I/O, ioctls or privileges. NVIDIA's check
  just before it, that only root may register I/O memory (unless NVIDIA's own `PeerMappingOverride=1` is set), stays:
  on the test rig a normal user's registration is still refused. Off unless you set it: see risk 6 below.
  The last two change two `find` patterns in `contrib/common.sh` (only `nvidia.ko` and its compressed forms count as a
  module) with a stand-in test, and 40 lines in `_nvGpuOpsDynBar1Create` (`nv_gpu_ops.c`): the peer-window budget is
  counted per remote GPU instead of over all of them, and a refused window logs a rate-limited line. No I/O, ioctls or
  privileges, and no check is removed.
  `acd74cf` moves NVIDIA's list of Intel root ports into a helper and repeats NVIDIA's own check with it in
  `p2pGetCapsStatus` (`p2p_caps.c`): two cards on two Intel CPU sockets get no P2P, unless NVIDIA's `ForceP2P` key is
  set; plus the same test in `contrib/chips.sh` and a stand-in test. It reads one existing registry key and adds a check
  rather than removing one. `d8f11e2` changes what `p2p-check.sh --integrity` prints after a time-out (13 lines; it
  runs the test binary's host-only `--selftest` to count the planned cases), with a stand-in test. `9f80306` changes
  only what `p2p-check.sh` prints (its last line without `--integrity`, and its `topo` lines), with its stand-in tests
  and a README comment. `44562b5` changes links. `e067c4a` adds 164 lines to `p2p_caps.c`: two helpers that read the
  CPU's family and model (already read by NVIDIA's code at init) and the two GPUs' root port vendor and address, and a
  refusal of the pair in `p2pGetCapsStatus` when both GPUs sit on different root ports of an Intel client CPU, unless
  NVIDIA's `ForceP2P` is set; it adds a check and removes none, with no I/O, ioctls or privileges. `4361112` changes the
  scripts' list of verified cards and their texts, with the tests and docs. `2d2f6c6`, `1d38c89` and `6a79a2a` change how
  `p2p-install.sh` writes and checks its depmod.d file and what `p2p-check.sh` checks (read-only: `modinfo`, the
  depmod.d files); `85929ec` changes what the integrity test prints on a mismatch (a counter and a copy of the wrong
  words in its own buffers). No network access, no new writes outside the files they already manage.

What was **not** covered: the correctness of the new locking and refcounting (bugs there would mean instability, not
malice), and the external `geforce-bar1-resize` tool, which step 4b uses for every card whose BAR1 is smaller than its memory;
[procedure.md step 4b](procedure.md#4b-a-bar1-at-least-as-large-as-each-cards-memory) notes what was checked in it before it ran on the test rig.

## Risky but legitimate: know these

1. **P2P safety checks are bypassed by design.** On GA102 the driver forces P2P read/write over BAR1 and skips NVIDIA's
   chipset and topology checks. On an untested platform that can mean silent data corruption or hangs. That is why the
   integrity test (step 14) is not optional.
2. **IOMMU in passthrough mode** (`iommu=pt`) lets the GPUs DMA into any host memory. It is standard for P2P setups,
   but it is a host-security trade-off.
3. **Do not use the top-level `install.sh`.** It runs `sudo make modules_install` over the stock modules with no backup
   and no checksum pinning. Use the `contrib/` flow from [procedure.md](procedure.md), which backs up, pins and can
   fall back.
4. **The scripts run your config as root.** `contrib/config.sh` is sourced, and `DRAIN_CMD`/`RESTORE_CMD` run via
   `sh -c`. Keep the checkout owned by you and not writable by others.
5. **Known low-severity issues upstream documents itself:** a BAR1 range can leak on a lock failure, and memory-safety
   assumptions in the hugepage pin path hold only while `os_lock_user_pages` is the only producer. Neither is
   reachable by unprivileged users.
6. **`RMPeerIoMemBar1=1` lifts one of NVIDIA's own refusals.** NVIDIA's driver will not register a range inside a GPU's
   BAR1 as I/O memory, because "full-duplex P2P over BAR1" can deadlock; on the test rig, heavy reads in both
   directions at once reset the whole machine. Set the key only for the second route in
   [mixed-generations.md](mixed-generations.md), and move data one way at a time.

## Also reviewed: aikitoria's `libcuda` patch script

The first route in [mixed-generations.md](mixed-generations.md) runs `patch-libcuda-p2p.py` from
[aikitoria/open-gpu-kernel-modules](https://github.com/aikitoria/open-gpu-kernel-modules) at
`efed6748b6e7bfc81273f61c148554aa5944e107` (a pinned submodule). It is 133 lines of Python with only the standard
library: it reads the file named on its command line, finds four byte patterns (each must match exactly once, or it
stops), changes one byte in each (`je` to `jmp`), and writes that same file. No network, no other files, no
processes. The guide runs it on a copy of `libcuda`, never on the system library.

## Re-checking a newer version

If the fork moves to a newer driver, repeat the same scoping: find NVIDIA's official tag commit, confirm it is an
ancestor of the fork's HEAD (`git merge-base --is-ancestor <tag-commit> HEAD`), and review only that diff.
