<!--
SPDX-FileCopyrightText: 2026 the innova2 contributors

SPDX-License-Identifier: Apache-2.0
-->

# How Mellanox's Flex image reports DDR health

Measured on two cards running the vendor Flex image, read through the
ConnectX CR path (`/dev/<cx5-bdf>_mlx5_fpga_tools`, big-endian 32-bit, read-only, and only while
`oper_image != User`).

| | Host C card | Host A card |
|---|---|---|
| vendor Flex build (0x900000 / 0x900008) | 0xC0 / 11:55:10 | 0xC1 / 11:56:32 |
| DDR | good (8 GB, 72-bit) | defective (dead byte lane) |

## The builds are not the variable

A full `cr_sweep.py` of both cards answers **7982 identical addresses**. Every difference below is
therefore a *measurement of the card*, not a build default — which is the thing that had to be
established before any of it meant anything, since the two cards carry different vendor builds.

## The BIST does not report failure. It reports nothing.

The app documents `0x20004[3:2]` as `0 not started / 1 in progress / 2 success / 3 failure`.
A broken card never produces 3:

* **good card** — `0x20004` already reads `0x08` (status=2, SUCCESS) *before the host touches
  anything*. The vendor Flex runs the BIST itself at power-on. A host-issued start then re-runs it:
  `0x06` (in progress) → `0x0A` (SUCCESS) in 18.1 s.
* **bad card** — `0x20004` reads `0x00` at boot. `stop_on_failure` takes (`0x02`), `start_bist`
  is accepted and ignored, and the status stays at 0 for 180 s. The engine is held off, almost
  certainly because calibration never completed, so there is no memory to test.

`3 = failure` presumably belongs to a card that calibrates and then mis-compares. Neither card
here produces it.

## What a bad card actually looks like

**The result buffer does not exist.** `0x020400-0x0207FC` — exactly 1 KB, 256 words — answers on
the good card (`0xDEADDEAD` throughout except a handful of zeros and one `1` at `0x020408`) and
returns EIO on the bad card at every one of those 256 addresses. This window appears to be backed
by the controller; no controller, no window.

**Nine registers in the BIST block separate the two cards:**

| addr | good | bad | reading |
|---|---|---|---|
| `0x020004` | `0x00000008` | `0x00000000` | status field: SUCCESS vs never-started |
| `0x020040` | `0x00000001` | `0x00000021` | bit 5 sets only on the bad card |
| `0x020048` | `0x00000000` | `0x0000000C` | non-zero only on the bad card — an error code |
| `0x02004C` | `0xFFFFFFFF` | `0x0000001F` | all-ones vs 5 bits — looks per-lane/per-bit |
| `0x020050` | `0x000003F0` | `0x00000000` | six contiguous bits vs none |
| `0x020054` | `0x00000001` | `0x00000000` | behaves exactly like `init_calib_complete` |
| `0x020100` | `0x00000017` | `0x00000003` | configuration, narrowed on the bad card |
| `0x020108` | `0x08000000` | `0x00000000` | `0x08000000 x 64 B = 8 GB` — the sized capacity |
| `0x020110` | `0x08000000` | `0x00000000` | same, second range |

**And three outside it:**

| addr | good | bad | reading |
|---|---|---|---|
| `0x000018`, `0x00001C` | `1`, `1` | `0`, `0` | top-level ready bits |
| `0x000020` | `0x0000001F` | `0x00000007` | capability word: bits 3-4 absent on the bad card |
| `0x09006C` | `0x00000000` | `0x00000002` | the register the flex app dies on — a health code |

## The practical consequence

A card's memory can be graded **without running anything and without rebooting into a test image**:
boot the vendor Flex and read `0x020054` (calibration), `0x020108` (sized capacity) and whether
`0x020400` answers at all. `0x020048` carries a code on a failing card. This is faster than the
`ddr_bist` soak and needs no build.

`bist_probe.py`'s sampled regions stopped at `0x020040` and so could not see most of this — the
whole-space sweep is what found it. Do not go back to probing an address list.
