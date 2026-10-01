# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# USERCODE of this image. Every hardware check reads USERCODE over JTAG, so a verdict can always be tied to the
# image that was actually running (and not confused with the vendor Flex image).
#
# inn2f r2 (USERCODE 0xDD500132) contains:
#   * the DDR4 memory controller (the "shipping top"), its calibration status readable in CR space;
#   * the image-select decoder and the one-shot hop to the User image, gated on the PCIe link state latched
#     50 ms after configuration (rtl/flex_hop.v): a broken User image leaves the card resting in Flex with a live
#     burn endpoint instead of reconfiguring during host POST;
#   * NO configuration watchdog (TIMER_WORD = 0): a watchdog makes the ConnectX retry the User image in a loop,
#     report success over a dead card and block JTAG rescue;
#   * the full live SYSMON sensor page: the whole DRP space (0x00-0xFF) is swept and the page decoded on
#     craddr[10:0], so DRP 0x40-0x43 report the configuration this image sets, not the vendor's;
#   * this project's own identity in the CR table (version 0xDD02).
# r2 removes the development instruments of earlier builds (the JTAG boot capture and the pin-timing monitor behind CR 0x020060)
# and its debug build switches; the pins, the dispatcher and every feature are unchanged.
set_property BITSTREAM.CONFIG.USERID 0xDD500132 [current_design]
