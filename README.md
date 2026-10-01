# innova2_flex — inn2f r2, an open Flex-slot image for the Mellanox Innova-2

Version: **inn2f r2** (USERCODE `0xDD500132`, CR identity `0xDD02`), built 2026-09-30. Identity reported to the ConnectX and to
`innova2_app`: image version **`0xDD02`**, created **30/09/2026 19:25:44**. Mellanox's image reports `0xC1`,
27/11/2018.

This image replaces Mellanox's "Innova-2 Flex" FPGA image: the one in the Flex slot of the card's flash
(0x03000000). The ConnectX-5 loads it at power-on, before handing over to the User image.

## Features

### Implemented

| feature | what it does | notes |
|---|---|---|
| **Dispatch to the User image** | drives the ConnectX's E3 frame code (long + short pulse = "boot User"), so the card boots whatever is in the User slot | same behaviour as the vendor Flex image |
| **Failsafe hop** | the hop to the User image is gated on the PCIe link state latched once, 50 ms after configuration; if the ConnectX reloads the Flex image later, the hop is refused and the card rests in Flex with a live burn endpoint | no watchdog, no retry loop (`TIMER_WORD=0`); why: `source/docs/iprog_watchdog.md`. One remaining race: see Known limitation |
| **Burn endpoint `15b3:0264` (BOPE)** | while the Flex image is resident, the host burns the User slot with Mellanox's protocol (`innova2_app` menu 6, `innova2_app -b`, or `xbflash.qspi --card <endpoint>`) | PCIe x4 Gen1, which is sufficient for burning |
| **CR responder** | answers the ConnectX's CR-space reads the way `innova2_app` and the vendor tools expect; unimplemented addresses return the vendor's own "not implemented" sentinel `0x8BADF00D` | the vendor's register map was captured once and is replayed where a value must match (see Provenance) |
| **Identity** | version `0xDD02`, our build date and time, in the CR identity block | the vendor's `0xC1` / 27-11-2018 stamp is gone |
| **Live sensors** | the SYSMON sensor page (temperature, voltages) is our die's live registers; the whole DRP space is served | not a replay of captured values |
| **DDR4 memory controller** | the MIG is present and calibrates at power-on; the calibration flag is live at CR `0x020054` | defective DDR is visible there as `0`. Specification and why: `source/docs/ddr4.md` |
| **Fan tachometer** | the app's fan-speed measurement (start, wait, read pulse count) counts real edges on pin C3 | C3 was identified by measurement (~216 pulses/s, ~6,500 RPM by the app's formula), not from documentation; it is a build parameter |
| **Power load** | "Increase FPGA power consumption" (CR `0x24`) switches on a real fabric load of the requested size | used for thermal tests |
| **ConnectX handshake signals** | the E4 heartbeat the ConnectX expects from a Flex image | an image without it is rejected |

### Not implemented

| feature | status | why |
|---|---|---|
| **DDR BIST** (start, status, result buffer at `0x020400`) | not implemented: the app's BIST poll ends immediately on the `0x8BADF00D` sentinel, with no meaningful result | we do not fake a passing test. A real memory test engine behind these registers is possible future work; until then the live calibration flag (`0x020054`) is the DDR health signal |
| **Fan-speed control** | the register (CR `0x414`) accepts and reads back a value, which changes nothing | no fan PWM output was identified on the card (the one candidate turned out not to be it), and this image deliberately drives no unidentified pins |
| **Configuration watchdog / automatic recovery** | not armed (`TIMER_WORD=0`) | a watchdog made the ConnectX retry the User image in a loop, report success over a dead card, and block JTAG rescue (`source/docs/iprog_watchdog.md`) |
| **Checking the User image before hopping** | not implemented | it would close the remaining header-break race (Known limitation). Reading the User slot's header over the QSPI before the hop is the likely approach; not yet built or tested |
| **Falling back to or restoring the Factory image** | out of scope | the image has no fallback path to Factory (no watchdog, see above) and nothing that rewrites it; the Factory slot is left as the card shipped |
| **PCIe x8 / Gen3 on the burn endpoint** | x4 Gen1 only | x4 Gen1 is sufficient for burning |

inn2f r2 is the first public release. Its failsafe logic (`rtl/flex_hop.v`) was developed and tested on earlier,
unreleased development builds of this source. The last of them (`0xDD500131`) has the same dispatcher, pins and
features; r2 removes two development instruments from it (a JTAG boot capture and a pin-timing monitor) and its debug
build switches. Results measured on that build are labelled as such below.

## Status: what has been verified

| check | result |
|---|---|
| Timing | WNS +0.319 ns, WHS +0.010 ns |
| `test/flex_acceptance.py`, all stages, inn2f r2, Host B (kernel 6.8, DOCA-OFED), 2026-09-30 | **PASS**: written over PCIe from a running User image (readback 100 %, Factory unchanged); **accepted** (`status=0`) after a cold boot; resident with burn endpoint `15b3:0264`, identity `0xdd02` 30/09/2026 19:25:44, FPGA temperature live (36 °C); both flash chips read through its own burn endpoint; User selected, cold boot: hands over to the User image |
| `test/flex_acceptance.py`, all stages, the preceding build, three cards on three hosts (2026-09-29) | **PASS** on each: burned (or found installed), accepted (`status=0`), resident with identity, hands over to the User image, which passes its own self-test. One host is kernel 5.8 + OFED 5.2 with two cards and the shortest POST margin we have; one card has defective DDR |
| Source reproduces the shipped bitstream | **byte-identical**: a second build from the maintainers' private copy (this source plus the generated DDR4 controller output) matches the shipped r2. This public source regenerates the DDR4 controller and gives an equivalent, not identical, image (see `EVIDENCE.md`) |
| Earlier development builds with the same failsafe source (not distributed) | accepted with a good User image; a broken User image (payload break) leaves the host alive; failsafe proven on a slow-POST host; see `EVIDENCE.md` |

Burning through the app's BOPE path was verified on 2026-09-29 with the preceding build (see `EVIDENCE.md`). One limitation remains, below.

The ConnectX's acceptance has varied between rebuilds and between hosts before. Three accepting hosts is good
evidence, not a guarantee: run the acceptance test with a JTAG path available on the first card of each new host
type.

### Known limitation: a User image with no sync word can hang the host

If the User slot holds an image whose header is broken (no sync word, so configuration never starts), selecting
User and cold-booting **can leave the host hung in POST**. Measured on an HP Z440 (see `EVIDENCE.md`): 2 of 2 boots
with the preceding build and 1 of 4 with an earlier one, both with the same failsafe logic as r2. This is a race that
every Flex image we have built can hit, not something r2 introduced. The realistic failure is a corrupt payload with an intact header (a truncated
or damaged write), and the host **survives** that one.

To recover without JTAG:
1. Use a **warm** reset (for example Intel AMT power state 10, "master bus reset"). Never power-cycle: a cold boot
   reloads the same broken User slot.
2. The host POSTs, and the card rests in the Flex image with the burn endpoint `15b3:0264` present.
3. Rewrite the User slot through that endpoint (`xbflash.qspi --card <endpoint>` with the User MCS, or
   `innova2_app -b`).
4. Select User and cold-boot.

A User image only reaches the slot by being written. So after writing one, read the slot back and check that the
destriped header has its sync word before selecting User and cold-booting. `rawspi.py` in `source/host/` can read the
slot through the burn endpoint or through a User image's flash controller.

## Files

| file | what | used by |
|---|---|---|
| `images/inn2f_r2.bit` | the bitstream | JTAG load (volatile) |
| `images/inn2f_r2_{primary,secondary}.mcs` | per-chip MCS, **guard-aware**: declared at 0x02FFF000 so stock `xbflash.qspi`'s +0x1000 shift lands the payload at **0x03000000** | burning over PCIe (below) |
| `images/inn2f_r2_split_{primary,secondary}.bin` | the raw per-chip payload, identical to the MCS data | the vendor-style burn: `innova2_app --flex_image -b <bin>,<chip>` |
| `source/` | the source of this bitstream; `source/build/build.sh` rebuilds it with a regenerated DDR4 controller (Vivado 2023.2, ~1 h; see Building from source) |
| `test/flex_acceptance.py` | acceptance test: burn, then prove the ConnectX accepts the image and hands over (below) | the host, as root |
| `EVIDENCE.md` | summary of the hardware results, reproducibility proofs and design findings |
| `SHA256SUMS` | manifest of every file: `sha256sum -c SHA256SUMS` |

## Installing: this writes the Flex slot, so read this first

Only write the Flex slot (0x03000000) **deliberately**, and only on a card with a way back: a JTAG cable
attached and proven. If the Flex, Factory and User slots are all bad, JTAG is the only recovery.

Writing the slot needs a design on the FPGA that gives the host an AXI Quad SPI controller reaching **both** flash
chips (the image is split across them):

* the **burn endpoint of inn2f r2** itself (`15b3:0264`, controller at BAR0 + 0x40000), for reinstalling or
  updating a card that already runs it;
* for a first install, a **User image** that exposes such a controller on one of its BARs.

The vendor Flex image is not known to offer one. Without either, write the slot over JTAG (Vivado indirect SPI
programming with the `.mcs` pair). A controller that reaches only one chip must not be used: it would write half an
image.

The write itself is XRT's stock `xbflash.qspi`; only the XRT tools package is needed on the host:

```
sudo FLASH_VIA_USER=1 /opt/xilinx/xrt/bin/xbflash.qspi --primary inn2f_r2_primary.mcs \
     --secondary inn2f_r2_secondary.mcs --card <flash BDF> --bar <n> --bar-offset <offset> --force
```

Check first that both chips answer Micron's `20 BB 20`: `sudo BDF=<flash BDF> source/host/rawspi.py rdid`
(`RAWSPI_BAR` / `RAWSPI_BAR_OFFSET` for another design). The acceptance test below does this for you.

Then **cold** cycle. The ConnectX takes its verdict on the Flex image at power-on, so check it afterwards:
`innova2_app --batch query` must report `status=0`. To see the image itself: select Flex
(`innova2_app --batch image-sel flex`), cold-cycle, and run `innova2_app -d <cx5> --batch identity`. Then select
User and cold-cycle again.

### Acceptance test

`test/flex_acceptance.py` runs the path above as stages, with the checks built in. Copy `images/`, `source/host/`
and `test/` together (the script finds the MCS pair and the helpers relative to itself). It needs the
`mlx5_fpga_tools` device of the card's ConnectX and, for `burn` only, `xbflash.qspi` (`--xbflash <path>` if it is
not in `/opt/xilinx/xrt/bin`).

```
sudo test/flex_acceptance.py pre      --cx5 <ConnectX BDF>   # read-only: both chips, what the Flex slot holds, Factory scan
sudo test/flex_acceptance.py burn     --cx5 <ConnectX BDF>   # writes 0x03000000 (skipped if already inn2f r2), reads back, Factory unchanged
sudo test/flex_acceptance.py select-flex --cx5 <ConnectX BDF>   # then COLD cycle
sudo test/flex_acceptance.py check-flex  --cx5 <ConnectX BDF>   # accepted (status=0), burn endpoint, identity, temperature
sudo test/flex_acceptance.py select-user --cx5 <ConnectX BDF>   # then COLD cycle
sudo test/flex_acceptance.py check-user  --cx5 <ConnectX BDF>   # User image running (status=0) and visible on PCIe
```

Every check prints `CHECK <name> PASS|FAIL`, and each stage ends with `ACCEPTANCE-<stage> PASS|FAIL`.

* `pre` and `burn` find the burn endpoint `15b3:0264` on the card by themselves. For a User image, pass
  `--card <BDF> --bar <n> --bar-offset <offset>`. If the slot was written some other way (JTAG), skip them.
* The select and check stages need nothing from the User image. `check-user` passes for any User image that the
  ConnectX reports running and that shows up on PCIe.
* On a host with several cards, the FPGA functions are taken from the card behind `--cx5`, and a `--card` on
  another card is refused.

## Building from source

```
source/build/build.sh [output dir]      # Vivado 2023.2 on PATH (or VIVADO=<path>); ~1 hour
```

It fixes the release flags (DDR4, link gate, no watchdog) and refuses the debug switches (`OBSERVE_ONLY`,
`NOHOP`, …), which make images that must never be flashed. It writes the bitstream, the guard-aware MCS pair and
the split `.bin` pair.

**Use the prebuilt image in `images/` unless you need to change the design.** This repository ships the DDR4 memory
controller only as its configuration (`source/ip/ddr4_flex_ip/ddr4_flex/ddr4_flex.xci`). The build regenerates the
controller with your own Vivado licence, in the build directory. Vivado then generates it differently from the
shipped image and re-places the whole design, so the result is **functionally equivalent but not byte-identical** to
inn2f r2. The ConnectX's acceptance of a Flex image has varied between rebuilds. So a self-built image must pass
`test/flex_acceptance.py` on a card with a working JTAG cable before anyone relies on it. The build says which path
it took (`RESCUE MIG: …`).

AMD's generated controller output is "confidential and proprietary" and is not in this repository. The maintainers
keep a private copy with it, which rebuilds the shipped image byte for byte (see `EVIDENCE.md`).

Two pitfalls:
* The DDR4 IP's `.xci` names its custom memory-part CSV by a **relative** path, `../../../board/…`. At any other
  depth Vivado silently falls back to a part without bank groups. The build keeps the depth when it copies the
  `.xci` into the build directory, and it stops at once if the regenerated pin constraints have no bank-group pins.
  Without that check, the failure appeared about 8 minutes later as a misleading `LVCMOS18` error on `bg[0]`.
* The identity block lives in the **CR table** (`rtl/cr_map_gen.v`, addresses 0x900000-0x900008). The
  `IMAGE_*` parameters on `i2c_cr_slave` are unused.

## Provenance: read before redistributing

* **The HDL is original.** No Mellanox Verilog, netlist or bitstream was read or transformed.
* **The identity is ours** (version `0xDD02`, our build date and time). The vendor's `0xC1` / 27-11-2018 stamp is
  gone.
* **The SYSMON sensor page is our die's live registers,** not captured values.
* **Still Mellanox's, deliberately:**
  * the PCI identity `15b3:0264` of the burn endpoint, so Mellanox's and our tools bind to it;
  * the remaining captured CR constants (DDR/BIST region and a few named registers), which the ConnectX and the
    tools read.
* **The BOPE burn protocol and the `mlx5_fpga_tools` ioctl numbers** come from Mellanox's published
  `burn_app.c` / `mlx_fpga_bope.c` (© 2018 Mellanox, **dual GPLv2 / OpenIB.org BSD**). Their attribution and licence
  text travel with this folder: `LICENSES/Linux-OpenIB.txt` and `NOTICE`.

Our work here is Apache-2.0, © 2026 the innova2 contributors (REUSE-compliant; see `LICENSES/`, `REUSE.toml`, `NOTICE`). The flash images contain AMD IP cores (`LicenseRef-AMD-IP`). They are distributed as Bitstreams under the AMD Vivado EULA, section 3(a)(3)C, and only for use to program AMD (Xilinx) devices. No AMD-proprietary source is included: the DDR4 controller ships as its `.xci`, and the build regenerates it.
