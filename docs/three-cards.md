# Three or more cards: three RTX 3090s

P2P between three RTX 3090s, one of them behind the chipset, on a second machine. Everything was done on 2026-11-25 as a
**trial load** (procedure step 13): the machine had to stay up, so nothing was installed for boot and it was not
rebooted. The boot install and reboots are not tested on this machine.

| | |
|---|---|
| Board, CPU | Gigabyte X570 AORUS ULTRA, Ryzen 9 5900X |
| GPU0 `04:00.0` | RTX 3090 24 GB, behind the X570 chipset, PCIe 4.0 x4 |
| GPU1 `0a:00.0` | RTX 3090 24 GB, CPU lanes, PCIe 4.0 x8 |
| GPU2 `0b:00.0` | RTX 3090 24 GB, CPU lanes, PCIe 4.0 x8 |
| Software | Ubuntu 26.04.1, kernel 7.0.0-43-generic, Ubuntu's 615.71.09 open modules, the fork at `b70b69c`, CUDA 13.5 |

**Result:** the integrity test passed on all three pairs, and every card could allocate 23 GiB of its 24 with every
other card mapping it. Between the two cards on CPU lanes, 13.1 GB/s each way and
16.65 GB/s both ways at once; with the card behind the chipset, 6.60 GB/s each way.

## What differs from two cards

1. **List every card.** `GPUS` in `contrib/config.sh` ([procedure step 11a](procedure.md#11a-scripts-which-cards-which-build))
   and the per-card line of [step 11b](procedure.md#11b-driver-dynamic-bar1-for-each-card-rmforcestaticbar10) take
   all three; the commands there already do that. The integrity test then runs every pair, one after the other: three
   pairs, about 1.4 TiB of copies each.
2. **Every card needs a large BAR1, even one whose vBIOS has no Resizable BAR.** See [below](#bar1-on-cards-without-resizable-bar).
3. **Peer access between all cards at once needs fork commit `b70b69c`** or later (the guide pins it). Before it, the
   patched driver let each card map only one card's BAR1 of all the other cards' memory together
   ([troubleshooting](troubleshooting.md#three-or-more-cards-cudamalloc-runs-out-of-memory-with-peer-access-between-all-of-them)).
   With two cards that limit never showed. Programs that turn on peer access for whole cards hit it: llama.cpp with
   `GGML_CUDA_P2P=1`, for example. [Checked here](#peer-memory-old-and-new-build), old build against new.
4. **NCCL on AMD with three or more GPUs** goes through host RAM by default between cards that meet in the CPU, like
   on Intel: set `NCCL_P2P_LEVEL=PHB` ([troubleshooting](troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access);
   from NCCL's source, not tested on this machine).

## BAR1 on cards without Resizable BAR

Step 1 asks for a BAR1 at least as large as each card's memory. On this machine all three showed 256 MB: Resizable BAR
was off in the BIOS, and the vBIOS of two cards did not offer more:

```bash
for d in $(lspci -D -d 10de::0300 | awk '{print $1}'); do echo "$d $(sudo lspci -vv -s $d | grep -oE 'BAR 1: current size.*')"; done
```

```
0000:04:00.0 BAR 1: current size: 256MB, supported: 64MB 128MB 256MB
0000:0a:00.0 BAR 1: current size: 256MB, supported: 64MB 128MB 256MB
0000:0b:00.0 BAR 1: current size: 256MB, supported: 64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB 32GB
```

A card that lists `32GB` gets it from the BIOS setting. A card that does not would need a vBIOS update from its maker.
Instead, [geforce-bar1-resize](https://github.com/Cinderella-Man/geforce-bar1-resize), the tool the Turing cards use
([procedure.md step 4b](procedure.md#4b-a-bar1-at-least-as-large-as-each-cards-memory)), gave all three cards 32 GiB: by a plain resize on
`0b:00.0`, and through the frame-buffer size override in config space (`0x610`) on the other two, including the card
behind the chipset. Its read-only check shows the route per card:

```bash
sudo scripts/geforce-bar1-resize check --vram 24G 0000:04:00.0
```

```
  ok   S1 VSEC (ID 000b v1) at 0x600 in the capability chain
  ...
  ok   S6 type 0 endpoint
  switch  behind a PCIe switch: yes
  PLAN    arm 0x610 VAL=9, resize to 32768 MiB
  note    behind a PCIe switch: the plain resize usually fails with ENOSPC there
```

The note did not apply here: the kernel grew the chipset's windows by itself. Probably because an RTX 3090 has no USB-C
function next to the GPU, which is what blocked the Turing cards ([turing.md T2](turing.md#t2-add-the-usb-c-pre-step)).
The tool lists every card but the RTX 3080 20GB as untested; on the 3090 it verified every step as it ran.

**How it was run here.** The tool normally runs at every boot, before the driver loads
([procedure.md step 4b](procedure.md#4b-a-bar1-at-least-as-large-as-each-cards-memory)). Here, to avoid a reboot, it ran once by hand
with the driver unloaded (after [step 12](procedure.md#12-prepare-the-live-swap-stop-everything-that-reloads-the-stock-driver),
`rmmod` of the stock modules), as `geforce-bar1-resize record` while the driver was still loaded, then
`geforce-bar1-resize boot --card <address>` per card. The windows stay until the next reboot. For a machine that keeps
P2P, install the tool as in procedure.md step 4b and reboot: not tested on this machine, done at boot in outside
reports (two RTX 3090s on an X99 board, [geforce-dynbar1-p2p#5](https://github.com/noon-at-cgn/geforce-dynbar1-p2p/issues/5)).

**IOMMU, also without a reboot.** This machine had no `iommu=pt`
([step 4](procedure.md#4-iommu-in-passthrough-mode)). With the driver unloaded and each card's HDMI audio function
unbound, the three cards' IOMMU groups were switched to passthrough through sysfs, until the next reboot:

```bash
echo identity | sudo tee /sys/kernel/iommu_groups/<group>/type
```

The integrity test then passed. For a lasting setup use step 4.

**Power limits.** This machine caps its cards at 250 W with a unit that runs `nvidia-smi -pm 1` and `-pl 250` at boot.
The driver swap dropped both, as [step 13](procedure.md#13-trial-load-nothing-is-installed-a-reboot-returns-to-stock)
warns: the tests above ran at the cards' default limits (350-420 W), and after the return to stock the unit had to run
again (`systemctl restart <unit>`).

## Results

### Integrity test

`p2p-check.sh --integrity`, the build at `b70b69c`, all three pairs (264 cases each, both directions, 1.4 TiB
byte-exact each):

| Pair | Path | One way | Both ways at once | Result |
|---|---|---|---|---|
| GPU0 <-> GPU1 | chipset x4 <-> CPU x8 | 6.60 / 6.60 GB/s | 12.75 GB/s | **PASS** |
| GPU0 <-> GPU2 | chipset x4 <-> CPU x8 | 6.60 / 6.60 GB/s | 12.76 GB/s | **PASS** |
| GPU1 <-> GPU2 | CPU x8 <-> CPU x8 | 13.12 / 13.17 GB/s | 16.65 GB/s | **PASS** |

The kernel log had no `Xid`, `AER` or IOMMU lines. The chipset card's x4 link sets the pace for its two pairs.

### Peer memory, old and new build

[`tools/p2p_peermap`](../tools/p2p_peermap.cu) turns on peer access between all three cards, then allocates the same
size on each card in turn, so each allocation is mapped into the other two. Then every card writes into the end of
every other card's allocation, and the owner checks it word by word:

```bash
nvcc -O2 -arch=native tools/p2p_peermap.cu -o tools/p2p_peermap -lnvidia-ml
```

```bash
./tools/p2p_peermap 20480
```

| MiB per card | Old build (`25c929e`) | New build (`b70b69c`) |
|---|---|---|
| 15000, 16000 | all three ok, data exact | |
| 16352 | all three ok, data exact | |
| 16400 | **GPU1: out of memory** (23.9 GB free) | all three ok, data exact |
| 17408, 20480 | **GPU1: out of memory** | all three ok, data exact |
| 22528, 23552 | | all three ok, data exact |

16352 MiB is exactly what the old check allowed: each card may map 32768 - 64 MiB of the other two cards together,
so 16352 MiB of each. With the new build each card can map the whole of the others' memory. Each card's BAR1 holds
its own allocation once, however many cards map it (`BAR1 used` 23.5 of 32 GiB per card at 23552 MiB), so 24 GB cards
with 32 GiB windows have room to spare.

### llama.cpp: build it with NCCL

llama.cpp's CUDA backend (upstream `0ce7f21`, CUDA 13.5), tensor parallel over the three cards (`-sm tensor -ts
1/1/1`), Qwen3.8-27B Q8_0, `llama-bench -p 512,2048 -n 128 -r 3`, three rounds per route in rotating order, 250 W power
cap. Tokens per second, 2048-token prompts / generation (each route's rounds within about 1 %):

| llama.cpp | Stock driver (no P2P) | Patched driver |
|---|---|---|
| built without NCCL | 348 / 32.5 | 349 / 32.4; with `GGML_CUDA_P2P=1`: 525 / 42.3 |
| built with NCCL 2.32.6 | **1,366 / 51.2** (NCCL `via SHM`) | 1,362 / 51.0 (still `via SHM`); with `NCCL_P2P_LEVEL=SYS`: **1,695 / 54.7** (`via P2P/direct`) |

- **Build llama.cpp with NCCL.** Without it llama.cpp moves the partial results of three or more cards with generic
  copies, one after another. With NCCL the same cards read prompts about 4 times faster and generate 58 % faster,
  even through host memory on the stock driver. llama.cpp's CMake looks for NCCL by default (`GGML_CUDA_NCCL=ON`), and
  when none is installed it builds without it, printing only `NCCL not found, performance for multiple CUDA GPUs will
  be suboptimal`. Install NCCL, or build it ([NVIDIA/nccl](https://github.com/NVIDIA/nccl), `make src.build`) and pass
  `-DNCCL_ROOT=<nccl>/build`, before configuring llama.cpp.
- **`GGML_CUDA_P2P=1` matters only without NCCL** (+51 % prompts, +30 % generation there); with NCCL it changes about
  1 %, and on the stock driver nothing (peer access refused).
- **With this driver NCCL still used host memory** for the three-card ring: NCCL's own rule keeps three or more GPUs on
  an AMD CPU off P2P through the CPU ([troubleshooting](troubleshooting.md#nccl-goes-via-shm-although-cuda-offers-peer-access)).
  `NCCL_P2P_LEVEL=SYS` switched it to P2P: +24 % prompts, +7 % generation.
- Perplexity over 16 chunks: 6.3572 over P2P and over host memory, identical chunk for chunk (6.3570 without NCCL: a
  different summation order). Kernel log clean.
- Two cards (the two on CPU lanes, `-ts 1/1`): llama.cpp's own two-card all-reduce through host memory 1,668 / 42.8,
  NCCL through host memory 1,729 / 42.3, NCCL with P2P (no variable needed for two cards) 1,818 / 42.1.

### llama.cpp: the fastest settings

The same three cards a day later (2026-11-27): patched driver, NCCL 2.32.6 with `NCCL_P2P_LEVEL=SYS` (`via P2P/direct`
on every channel), 250 W cap, `llama-bench -sm tensor`, three rounds per setting in rotating order (two for the
8,192-token and 16k-context columns), tokens per second. llama.cpp:
[llama.cpp-drmshare](https://github.com/Cinderella-Man/llama.cpp-drmshare) `74ee0f3`, upstream `0ce7f213` with the
tensor-parallel changes of the [README's llama.cpp section](../README.md#more-speed-tensor-parallel-changes-in-a-llamacpp-copy-experimental), built like upstream (CUDA 13.5, sm_86, NCCL). With
none of their settings on it measured the same as upstream (1,706 / 55.0 against 1,704 / 55.0).

**Qwen3.8-27B Q8_0:**

| Cards, settings | Prompt 2048 | Prompt 8192 | Generation | Generation with 16k tokens in context |
|---|---|---|---|---|
| three, defaults | 1,704 | 1,674 | 55.0 | 53.0 |
| **three, `-ub 2048`** | **1,880-1,891** | **1,829** | **54.6-55.0** | **53.2** |
| two on CPU lanes, defaults | 1,821 | 1,787 | 42.5 | |
| two, `-ub 2048` | 1,970 | | 42.5 | |
| two, `-ub 2048` + the copy's split lanes and overlap | 1,987-1,996 | 1,924 | 42.5 | 41.2 |

```bash
export NCCL_P2P_LEVEL=SYS
llama-server -m Qwen3.8-27B-Q8_0.gguf -ngl 99 -sm tensor -ub 2048 -b 2048 -c 65536
```

- **`-ub 2048`** is upstream llama.cpp's micro-batch: 2,048 prompt tokens per step instead of 512, so a quarter as
  many all-reduces per prompt. Prompts +8-11 %, generation unchanged; `-ub 1024` gives less (1,815), `-ub 4096`
  nothing more.
- **Three cards for one server.** The two CPU-lane cards read prompts about 5 % faster (the chipset card's x4 link
  sets the pace of the three-card ring) but generate 23 % slower.
- **Leave NCCL's defaults alone.** `NCCL_PROTO=Simple` cuts generation to 46.9 (-14 %), `NCCL_ALGO=Tree` gives
  1,811 / 46.9, all-reduces in f32 (`GGML_CUDA_NCCL_BF16_MIN_NE=1000000000`) cut prompts to 1,267 (-33 %); all in
  bf16 changes nothing.
- **The llama.cpp copy's changes add little with P2P.** They were made for cards linked through host memory, where
  they add 35 % ([README](../README.md#more-speed-tensor-parallel-changes-in-a-llamacpp-copy-experimental)). Here the split lanes and the overlap add about 1 % to `-ub 2048` on two cards, and on
  three the overlap costs 0.7 % (the split lanes need exactly two cards). Upstream llama.cpp with `-ub 2048` is the
  recipe.
- **As a server** (the command above; two prompts of about 3,000 tokens, 128 tokens each, no prompt cache): 1,553-1,594
  tokens/s on prompts, 53.2-53.5 generating. It used 11.5 GB per card at `-c 65536`, so much longer contexts fit.
- Perplexity (16 chunks of 512): 6.3572 with the defaults, 6.3598 at `-ub 2048` (a larger batch rounds differently);
  the overlap gave the same chunks as the same chunks run one after another. Kernel log clean.

**Qwen3.8-Flash-Next** (mixture of experts, 177 B parameters, 3 B active per token), the biggest file that fits: an
IQ3_S quantisation of 77.9 GiB. Its 26.8 GiB per-layer token table stays in host RAM, so the cards hold 50.7 GiB;
unsloth's UD-Q4_K_XL would need 76.2 GiB on the cards. Two rounds per setting, the same binary:

| Split, `-ub` | Prompt 2048 | Generation | Prompt 2048 with 16k tokens in context | Generation with 16k tokens in context |
|---|---|---|---|---|
| layer (llama.cpp's default), 512 | 2,021-2,044 | 74.4-74.6 | 1,669-1,683 | 71.6-71.9 |
| layer, 2048 | 2,168-2,209 | 74.2-74.5 | 1,773-1,776 | 71.6-71.7 |
| tensor, 512 | 2,134-2,142 | 77.3-77.4 | 1,875-1,882 | 73.7-73.9 |
| **tensor, 2048** | **2,737-2,744** | **77.8-77.9** | **2,305-2,313** | **73.7-73.8** |

```bash
export NCCL_P2P_LEVEL=SYS
llama-server -m Qwen3.8-Flash-Next-IQ3_S-00001-of-00002.gguf -ngl 99 -sm tensor -ub 2048 -b 2048 -c 131072
```

- **Tensor split with `-ub 2048`:** prompts +34 % over llama.cpp's defaults (layer split), generation +5 %; 8,192-token
  prompts 2,665 tokens/s.
- **Memory is the limit.** `-c 131072` fits (23.3 of 24 GB per card); `-c 262144`, and `-ub 4096` with long prompts,
  run out of memory. As a server (two prompts of about 3,000 tokens, 128 tokens each): 1,817-2,121 tokens/s on
  prompts, 71.7-74.0 generating.
- **Keep the model file in RAM.** The token table is read from host memory for every token. When another model's file
  had pushed part of it out of the page cache (121 GB of RAM in this machine), the same server fell to 113-151 / 24-44
  tokens/s, reading the table from disk. Leave room for the whole 78 GiB file, and load nothing big beside it.
- Perplexity (16 chunks of 512): 7.0050 with layer split, 6.9974 with tensor split (a different summation order).

### llama.cpp: speculative decoding

The same cards, driver and build on the same day, as a server (`llama-server -np 1 --jinja -c 32768` with the settings
above): ten chat requests (code, a story, a technical explanation, arithmetic and a bulleted rewrite of a given text,
twice each), temperature 0, 512 tokens each. Generation, tokens per second over all ten, and the share of drafted
tokens the model accepted:

**Qwen3.8-27B Q8_0:**

| Split, cards | No speculation | MTP, 3 tokens | Other drafts |
|---|---|---|---|
| **tensor, three** | 54.2-55.0 | **92.9** (56 %) | MTP 1 / 2 / 4 tokens: 78.7 / 90.8 / 89.1 (80 / 68 / 50 %) |
| tensor, three, NCCL through host memory (`NCCL_P2P_DISABLE=1`) | 50.6 | 84.9 (56 %) | |
| tensor, two on CPU lanes | 42.2 | 73.5 (58 %) | |
| layer (llama.cpp's default), three | 28.5 | 58.6 (57 %) | DFlash2, 7 / 4 tokens: 76.9 / 69.0 (36 / 52 %) |

```bash
export NCCL_P2P_LEVEL=SYS
llama-server -m Qwen3.8-27B-Q8_0.gguf -ngl 99 -sm tensor -ub 2048 -b 2048 -c 65536 \
  --spec-type draft-mtp --spec-draft-n-max 3
```

- **MTP** (multi-token prediction) drafts with a layer the model already has: Qwen3.8-27B's GGUF carries one, so
  there is no second file. Three drafted tokens are the best here (the default of `--spec-draft-n-max`).
- **Generation +69 %**, most where the text is predictable: per request about 80 tokens/s for the story and the
  explanation, 78-90 for code, 103-119 for arithmetic and the rewrite of a given text.
- **P2P still counts.** Through host memory the same speculation gives 84.9 (-9 %), with exactly the same drafted and
  accepted tokens: only the link differs.
- **Not character-identical to plain decoding.** At temperature 0 the answers part from the plain ones after a few
  hundred characters, at near-tie words: checking 4 tokens in one step rounds slightly differently from one token at
  a time. Plain decoding does the same when it moves to layer split or to two cards; P2P against host memory gives
  identical text. Every token is still the model's own choice, and each setting gives the same answer every time.
- **DFlash2 needs layer split** in this llama.cpp: with `-sm tensor` it aborts at load
  (`ggml-backend-meta.cpp:578: GGML_ASSERT(src_ss[0].axis != GGML_BACKEND_SPLIT_AXIS_0)`), also with the draft on one
  card (`-devd`). With layer split z-lab's Qwen3.8-27B-DFlash2 draft (Q4_K_M, 1.1 GB) beats MTP, but tensor split
  with MTP is faster still.

**Qwen3.8-Flash-Next IQ3_S:**

| Split | No speculation | DFlash2, 3 tokens | Other |
|---|---|---|---|
| tensor | 74.9-75.8 | aborts (as above) | n-gram (`ngram-mod`): no gain on new text |
| **layer** | 71.7 | **112.6** (57 %) | DFlash2 2 / 4 / 5 / 7 tokens: 104.1 / 106.6 / 101.2 / 86.9 (63 / 48 / 40 / 32 %) |

```bash
llama-server -m Qwen3.8-Flash-Next-IQ3_S-00001-of-00002.gguf -ngl 99 -sm layer -ub 2048 -b 2048 -c 131072 \
  -md Qwen3.8-Flash-Next-DFlash2-Q8_0.gguf --spec-type draft-dflash2 --spec-draft-n-max 3
```

- **Generation +49 % over the best plain setting** (tensor split, 75.8), on every request: per request 92-117 for
  the story, the explanation and code, 135-142 for arithmetic and the rewrite. It fits at `-c 131072` (21.4 / 22.0 /
  23.8 GB: the last card nearly full) and runs as fast there.
- **Short drafts.** This mixture-of-experts model checks a draft cheaply but its draft misses more often than the
  27B's: 3 tokens is best, 7 gives 86.9, slower than plain on the story and the explanation.
- **The price is prompt speed**: layer split reads 2048-token prompts at 2,021-2,209 tokens/s against 2,737-2,744
  with tensor split (table above). For long prompts and short answers keep tensor split.
- **Layer split adds nothing up between the cards** (each passes one layer's output to the next), so NCCL is not used
  and the link should matter little for this recipe; it was not measured without P2P.
- No MTP for Flash-Next in llama.cpp: this IQ3_S has no MTP layer, and the separately published distilled MTP head
  (`mtp-Qwen3.8-Flash-Next-shared-distillG-Q8_0.gguf`) does not load (`tensor 'token_embd.weight' not found`: it
  borrows the target's tensors through a key llama.cpp does not read, upstream included as of 2026-11-26). The draft
  here is incoai's Qwen3.8-Flash-Next-DFlash2 (Q8_0, 652 MB).
- n-gram speculation drafts from text already in the context: nothing to find in a new answer (74.7 on the first round),
  a lot when a request repeats an earlier answer (275 tokens/s on the repeated arithmetic). Useful for rewrites of
  long text and repeated questions, not as a general setting.

Not tested here: the boot install, reboots, NCCL's own `nccl-tests` on three cards, long llama.cpp runs (hours of
serving), prompts and contexts beyond 16k tokens with NCCL, `tools/p2p_patterns`, and the driver's new log line for a
refused window (a 3090 cannot fill another card's 32 GiB window).
