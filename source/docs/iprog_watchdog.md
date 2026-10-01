<!--
SPDX-FileCopyrightText: 2026 the innova2 contributors

SPDX-License-Identifier: Apache-2.0
-->

# The configuration watchdog and the failsafe: results

Why inn2f r2 hops to the User image **without** a configuration watchdog (`TIMER_WORD = 0`) and instead gates the
hop on the PCIe link state latched 50 ms after configuration (`rtl/flex_hop.v`). Measured on development builds of
this source, on cards whose User slot held an image that cannot configure.

## The problem

When the ConnectX selects the User image, the Flex image issues an IPROG to the User slot. If that image cannot
configure, the FPGA is left without a working PCIe endpoint. If this happens while the host is in POST, the BIOS
hangs, and because the image selection is latched in the ConnectX, every cold boot repeats it. Without a failsafe
the only way out is JTAG.

## The IPROG sequence

The vendor's golden image arms the watchdog before the jump:

```
AA995566                      sync
30022001 40100000             TIMER (register 17): TIMER_CFG_MON, count 0x100000
30020001 03000000             WBSTAR = the Flex slot
30008001 0000000F             CMD = IPROG
```

`flex_hop.v` emits the same packets, with the TIMER value as the parameter `TIMER_WORD` (0 = no watchdog; the
packet length does not change). Note that TIMER is register **17**; 12 is IDCODE, and writing 12 produces a
plausible-looking packet that does nothing.

## Results

| design | broken User image, cold boot | verdict |
|---|---|---|
| hop, no watchdog, no gate | host **hangs in POST**; `DONE=0`; ConnectX `FACTORY_FAILOVER` / `FAILURE`; JTAG needed | unsafe |
| hop with the watchdog armed | host boots, but the watchdog fallback starts a **retry loop** (the ConnectX keeps re-selecting User), the ConnectX reports `USER` / `SUCCESS` over a card with no endpoint, and a looping card cannot be rescued over JTAG | rejected |
| gate the hop on in-image signals (`BOOTSTS` fallback / watchdog bits, the F1 status line) | identical end state for every gate (`DONE=0`, `BOOT_STATUS 0x0000070d`): a retry cannot be told apart from a first boot from inside the image | rejected |
| **no watchdog + early latched link gate (shipped)** | the first configuration hops normally (the link trains long after 50 ms); a later reload by the ConnectX finds the link already up, refuses to hop, and the card rests in Flex with a live burn endpoint; the host stays up | **used** |

The remaining limitation (an image with no sync word at all can still hang the host in a race) is described in the
README under "Known limitation".

## Related findings

* **Watchdog fallback does not return the card to Flex.** The fallback targets address 0 (Factory); it leaves the
  FPGA unconfigured rather than running a usable image.
* **JTAG is not free while the host is down.** The ConnectX owns the JTAG mux from power-on; the FPGA is only
  visible to a cable after the JTAG grant, which needs a running host (or a host stuck in POST).
* **BOOTSTS is readable.** CR `0x020058` reports the FPGA's boot status (`0x05` on a normal boot: status valid,
  IPROG, no fallback), and CR `0x02005C` reports F1 and the hop state; F1 reads 0 while a Flex-slot image runs.
