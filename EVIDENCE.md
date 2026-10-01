<!--
SPDX-FileCopyrightText: 2026 the innova2 contributors

SPDX-License-Identifier: Apache-2.0
-->

# Flex image inn2f r2 — evidence (summary)

Summary of the checks behind this image (2026-09-12 … 30). The raw logs and engineering notes are kept by the
maintainers and are not part of this repository. Test hosts are HP Z440 workstations with Innova-2 cards; one card
has defective DDR and served for failure-path tests.

## Hardware acceptance of inn2f r2 (`test/flex_acceptance.py`, Host B, 2026-09-30)

| stage | result |
|---|---|
| pre (from a running User image) | both chips answer `20 BB 20`; the Flex slot held an older development image; Factory scanned |
| burn | written with `xbflash.qspi` through the User image's flash controller; readback 100 % inn2f r2; Factory 0 of 32 samples changed |
| check-flex (cold boot, Flex selected) | **accepted** (`oper=1 status=0`); burn endpoint `15b3:0264`; identity `0xdd02` 30/09/2026 19:25:44; 36 °C |
| pre through inn2f r2's own burn endpoint | both chips read, Flex slot 100 % inn2f r2, Factory scanned |
| check-user (cold boot, User selected) | the ConnectX runs the User image (`status=0`); both User PCIe functions enumerate and bind |

Two host-tool fixes came out of the endpoint stage: the endpoint's PCI memory space is off after boot (no driver
binds to it), and the first SPI transaction to chip 0 after configuration is lost in the FPGA's STARTUPE3.
`rawspi.py` now enables memory space and discards one read first.

## The preceding development build (`0xDD500131`, not distributed)

Same dispatcher, pins, DDR4 controller and features as r2; it also carried a JTAG boot capture and a pin-timing
monitor, which r2 removes. The results below were measured on it.

| check | result |
|---|---|
| written over PCIe from a running User image, cold boot | **accepted** by the ConnectX (`status=0`) |
| User image selected, cold boot | dispatches: the User image comes up on PCIe and passes its own self-test |
| Flex image selected, cold boot | resident: burn endpoint `15b3:0264` present; identity `0xdd01`, 28/09/2026 08:30:00; FPGA temperature live |

### Acceptance test rollout (`test/flex_acceptance.py`, 2026-09-29)

| host | card | Flex slot before | pre | burn | check-flex | check-user |
|---|---|---|---|---|---|---|
| Host A (kernel 5.8, OFED 5.2, XRT 2.19) | defective DDR | an older experimental Flex | PASS | written, readback 100 %. The first run's Factory check read through `/dev/xfpga` and reported a false 444 of 512 changed; a direct SPI read showed Factory identical to its backup. The suite now reads directly; rerun: Factory unchanged | accepted, `15b3:0264`, identity, 48 °C | PASS (DDR mode EMU) |
| Host B (kernel 6.8, DOCA-OFED, XRT 2.19) | good | the same build | PASS | already installed; Factory unchanged | accepted, `15b3:0264`, identity, 35 °C | PASS |
| Host C (kernel 5.8, OFED 5.2, XRT 2.19), two cards | good, x1 riser | an older experimental Flex | PASS | written, readback 100 %; Factory 0 of 32 samples changed | accepted, `15b3:0264`, identity, 36 °C | PASS |

Host C has the shortest POST margin measured (80 ms). The other card in it was left as it was.

### BOPE burn path (`innova2_app -b <bin>,<chip>`, the vendor flow), Host C (the card in PCIe slot 4), 2026-09-29

1. With the preceding build resident (accepted, identity `0xdd01`, burn endpoint present), the User slot was broken on purpose:
   64 bytes per chip cleared, read back as zero.
2. A User image was burned through the endpoint as per-chip `.bin` files, extracted from its MCS pair and
   destripe-verified identical to its bitstream. The burn took 86 s.
3. Direct SPI read-back of the header and of the broken region matched the image on both chips.
4. Select User, cold boot: the User image came up and `check-user` passed.

### Broken User image (failsafe), Host B (HP Z440, PERST# 590-600 ms and link-up 610-620 ms after the Flex image starts)

The User slot was broken through the flash controller of the running User image and verified by destriping, then User was selected and the host
cold-booted. After each run the slot was rewritten and `check-user` passed.

| Flex image | payload break (64 B per chip, header intact) | header break (sync word removed) |
|---|---|---|
| the preceding build | host **survives**; card off PCIe, ConnectX `FACTORY_FAILOVER` / `FAILURE` | host **hung in POST**, 2 of 2 |
| earlier development build, same failsafe source (not distributed) | (survived earlier, on Host C) | 1 of 4 hung, 3 survived |
| development build identical to the preceding build except for the vendor identity (not distributed) | not run | 2 of 2 survived |

* Every hang recovered with an AMT **warm** reset and no JTAG. The card then rested in the Flex image with the burn
  endpoint present.
* The configuration register writes of that earlier build, the preceding build and r2 are identical packet for packet, and
  `flex_hop.v` is unchanged. The hang is a race that all these images share: the early-link-latch gate does not reliably refuse the
  ConnectX's second hop on this host.
* The earlier build's first 1/1 survival on this host was luck.

## Reproducibility

| build | result |
|---|---|
| inn2f r2: the maintainers' tree (this source plus the generated DDR4 IP output), built twice from separate copies | identical (15,027,072 bytes of configuration data); MCS pair and split images identical |
| shipping tree + DDR IP, isolated directory, vs an earlier development bitstream built from it | identical (15,545,024 bytes of configuration data) |
| the maintainers' source tree (with the generated DDR4 IP output), from a copy at a different path, vs the preceding build that was burned and tested | identical (16,082,720 bytes); MCS pair identical |
| the same with the DDR4 IP reduced to its `.xci`, which is what this public repository ships | **not** identical: the MIG is regenerated differently and the design re-placed. Such an image needs its own acceptance test |
| the tree after adding SPDX headers (16 RTL files), rebuilt at a new path | identical; MCS pair identical |

Since 2026-09-29 the generated DDR4 IP output (AMD confidential and proprietary) is kept only in the maintainers'
private copy, and this repository's history was rewritten to remove it.

Configuration data is compared from the sync word `0xAA995566` on (the `.bit` header carries a build date).

## Design findings the image relies on

| finding | measured result |
|---|---|
| **Acceptance is per image and per host.** The ConnectX takes its verdict at power-on, and the OS/driver cannot influence it. | An old experimental Flex build was rejected on one host (`oper=1 status=1`, no burn endpoint) and accepted on another. An earlier development build of this source, written to the same card, was accepted on both (positive control). |
| **The image-select channel is pin E3**, one code per 77.1 µs frame. | Flex scheduled: one pulse (≈3.0–3.1 µs). User scheduled: that pulse plus a short partner (≈0.72–0.80 µs) 1.5–1.6 µs later. A sweep of all 2466 boundary cells found no other differing pin. |
| **Failsafe:** latch the PCIe link state 50 ms after configuration, and hop to the User image only if it was down then. | The first load hops (link trains 820–920 ms later). The ConnectX's reload about 31 s in stays resident and keeps the burn endpoint, so a User image that will not configure leaves the host healthy with no JTAG rescue. |
| **Boot timing** (from this image coming alive, four cold boots) | PERST# at 760 ms (spread 0), link up 820–920 ms, boot chain 310 ms: at least 510 ms of margin |
| **Broken User image, two failure modes** | A payload break (header intact, the realistic case) ends in FACTORY_FAILOVER with the host up, the same as the vendor image. A header break (no sync word) causes a second dispatch around 31 s and wedged the host, so a test using only header breaks is not representative. |
