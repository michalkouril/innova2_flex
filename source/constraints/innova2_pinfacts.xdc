# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# =================================================================================================
# innova2_pinfacts.xdc -- the single place recording what each Innova2 pin IS and what we MEASURED.
#
# DOCUMENTATION ONLY. Every line here is a comment and the build does not use this file; the active
# constraints are flex_pins.xdc, static_pins.xdc, pcie_x8_lanes.xdc, spi1_rescue.xdc and
# ddr4_72bit_gen.xdc (DDR pinout).
#
# MEASURED means a number from hardware, with the instrument named. INFERRED means a reading of
# those numbers. NAMED means a label from the schematic or mwrnd's notes, not something we verified.
# The distinction matters here: several long-standing "facts" on this card turned out to be
# properties of the instrument rather than the board (see the retractions below).
#
# =================================================================================================
# THE BOOT CHAIN, because no pin below makes sense without it (measured end to end)
# =================================================================================================
#   power on -> FACTORY at flash 0x0. Only its HEADER is consumed: TIMER 40100000, WBSTAR 03000000,
#               CMD IPROG -- a pointer plus a fallback watchdog, not a design that runs.
#            -> the FLEX-SLOT image at 0x03000000 configures and RUNS, on EVERY boot, both selections.
#            -> it reads E3's frame code and either stays resident (Flex scheduled) or issues an
#               ICAPE3 IPROG to 0x01000000 (User scheduled), which is where the User image comes from.
#   So the Flex slot is in the path of every boot. Overwriting it with an image that does not decode
#   E3 makes a byte-perfect User slot unreachable -- that is the whole reason this file exists.
#
# =================================================================================================
# BANK 90 -- HDIO, 3.3 V. The management-side pins.
# =================================================================================================
#   D2   i2c_scl     NAMED    ConnectX -> FPGA management I2C clock. Idle high, never seen active:
#                             the ConnectX issues ZERO I2C at boot, for images it ACCEPTS as well as
#                             ones it rejects (positively controlled).
#   D1   i2c_sda     NAMED    same bus, data. Open-drain; our slave drives only the low side.
#
#   F1   -           MEASURED **A STATUS LINE REPORTING WHICH IMAGE IS RUNNING**.
#                             0 while ANY Flex-slot image runs -- accepted or rejected, either
#                             schedule; 1 once the User image runs. 40 boundary-scan samples over
#                             10 s in each state, on a settled card. The FPGA drives it in NEITHER
#                             state (control cell Hi-Z both times), so the ConnectX drives it.
#                             It follows what is CONFIGURED, not the ConnectX's verdict: it read 1
#                             on a boot the ConnectX itself called FACTORY_FAILOVER/FAILURE, and it
#                             was right -- both 10ee PFs were present.
#                             DEAD HYPOTHESES: image selector (0 throughout the Flex window under
#                             both schedules); heartbeat-OK flag (E4 silent predicted 1,
#                             measured 0). `PULLTYPE PULLDOWN` matches the vendor cell-for-
#                             cell and changed no verdict.
#   A6   GPIO_LED_0  MEASURED Driven by both Mellanox designs as a 0.5 Hz square wave, 1 s on /
#                             1 s off (high runs 997/999/1001 ms). Ours drove nothing at first.
#                             Matching it changed nothing.
#   B6   GPIO_LED_1  MEASURED Driven LOW by both Mellanox designs. A PULLDOWN on our side is REFUSED
#                             -- the pad stays high -- which is how we know B6 is actively driven
#                             while F1 is only pulled.
#
#   F4   -           MEASURED Free-running reference clock from the card, 1.257-1.260 MHz, ~48.6%
#                             duty (in-fabric logic analyser). It is the timebase E3,
#                             E4 and E5 are all measured against -- 13 of 14 E3 edges land 0 ns from
#                             an F4 edge.
#
#   E3   -           MEASURED **THE IMAGE-SELECT CODE.** One bit per 77.1 us frame:
#                                 Flex scheduled : ONE pulse,  3.83-3.93 F4 cycles (3039-3119 ns)
#                                 User scheduled : that pulse PLUS a second of 0.91-1.01 F4 cycles
#                                                  (720-800 ns), starting 1.5-1.6 us after it
#                             Decoded by rtl/e3_code.v; acted on by flex_hop, which IPROGs
#                             to 0x01000000. Proven by function, not just correlation: one flash,
#                             six schedule flips, 6/6 correct, status=0 every time.
#                             RETRACTED: "INFERRED: 4-wire PWM fan control, 25.9 kHz" -- that was
#                             an edge rate counting both pulses of a frame as if they were periodic.
#                             The fan tachometer is C3; the fan PWM is not on this pin.
#                             TIMING: the group starts ~629 ms after configuration, pauses, and runs
#                             continuously from ~717 ms. A short capture armed early lands
#                             in that gap and reads E3 as FLAT.
#
#   E4   -           MEASURED **THE ACCEPTANCE WAVEFORM.** Not static: it carries a repeating
#                             message whose widths/gaps in F4 cycles are 2/15 1/9 4/34 2/33, a
#                             77.3 us frame. An image whose E4 is static is REJECTED; the
#                             same image replaying this waveform is ACCEPTED -- one variable, both
#                             arms in one session (e4_replay.v). On a rejected card the ConnectX
#                             sends a longer varying message ~133 ms and then abandons it; on an
#                             accepted one a short fixed cycle continues indefinitely.
#                             RETRACTED: "E4 never changes in 2 s" -- the instrument was sampling
#                             it on F4 edges, which is where its transitions are.
#
#   E5   -           MEASURED 12.97 kHz, one pulse of ~1.9 F4 cycles per 77.1 us frame -- the same
#                             frame as E3, and IDENTICAL under both schedules to four digits
#                             (242,885 vs 242,889 transitions in 10 s). That invariance is
#                             what makes it a useful control: whatever E3 is doing, E5 is not.
#
#   F2   -           MEASURED **pcie_perstn** -- the ConnectX's PCIe reset to the FPGA. Exactly ONE
#                             transition per boot, 0 -> 1, ~490-510 ms after configuration
#                             (fabric-side) and +2.044 s after the rails come up, identical
#                             on a Flex boot and a User boot (logic analyser ch6).
#                             In a design with PCIe this is xdma sys_rst_n; in the probe designs it
#                             is simply watched.
#
#   C3   -           MEASURED ~0.4 kHz, ~216 pulses/s, running from ~10 ms after configuration.
#                             INFERRED: the FAN TACHOMETER -- through the vendor app's own formula
#                             (pulses/2 * 60 / seconds) that is ~6,500 RPM, and the vendor CR block
#                             has a tacho register file at 0x40C-0x420 with nothing else to feed it.
#                             cr_regs.v counts it; if the app prints nonsense, change the pin here,
#                             not the arithmetic.
#   D3               MEASURED Essentially static.
#
#   A3 A4 B4 B5 D5 E1   MEASURED  Read 1 under Mellanox, 0 under ours, with NEITHER design driving
#                             them -- i.e. an internal pull. `PULLTYPE PULLUP` closed all six
#. B2 C2 C4 C5 D3 D6 E3 E5 F2 F3 already matched.
#
#   RETRACTED: "the vendor drives nothing in bank 90, so there is no pin-level behaviour to
#   imitate". That rested on the boundary-scan CONTROL cell, which reports
#   "not driving" for every pin in every design INCLUDING ones demonstrably driving. A pad nobody
#   drives cannot make a 1 Hz square wave. Trust the `input` cell (level); never the driven column.
#
# =================================================================================================
# BANK 65 -- SPI_1, the second QSPI flash. LVCMOS18.
# =================================================================================================
#   AM12 spi1_io0 | AN12 spi1_io1 | AR13 spi1_io2 | AR12 spi1_io3
#        MEASURED  Driven LOW by both Mellanox designs. Also config data D04..D07 -- this card boots
#                  SPI x8, so the configuration engine owns them until end-of-startup.
#        NOTE      The boundary-scan control cell misreports here too: our OBUFs demonstrably drive
#                  these pads (building the same design driving 1 moved every pad 0 -> 1) while the
#                  control cell read "disabled" in both builds.
#   AV11 FCS2_B   MEASURED  Second flash chip select. Z and HIGH under every design -- deselected,
#                  driven by nobody. DELIBERATELY NOT BONDED: that is what makes driving the data
#                  lines inert, and bonding it is the only way this could reach flash contents.
#   AM14 EMCCLK, AR14, AT14   MEASURED  Active under every design including the User image.
#   AR14/AT14  MEASURED  ONE DIFFERENTIAL SIGNAL, not two pins and not a bus: complementary on
#                        94.9% of samples, a metronomic 39.5 kHz square wave at ~48% duty with no
#                        framing, no idle gaps and no run-length variation (Host A card).
#                        The 100 MHz counters report ~47.6 kHz and a 10 ns minimum run -- that is
#                        edge chatter from reading a differential pair with two single-ended
#                        buffers, NOT a real feature. Trust the scope fundamental.
#   AM14       MEASURED  Free-running clock ABOVE 50 MHz -- ~45 MHz apparent edge rate and a
#                        min-low of 0 clk, which only happens when the input outruns the 100 MHz
#                        sampler. ALIASED by both instruments; its scope trace is meaningless.
#
# =================================================================================================
# DDR4 -- banks 66/67/68. Pinout in src/ddr4_72bit_gen.xdc (lanes 0-8, 72-bit).
# =================================================================================================
#   AP24/AP25  C0_SYS_CLK  MEASURED 9996.02 ps, i.e. 100.04 MHz. Free-running from board
#              power, independent of PCIe -- which is why every standalone image clocks off it.
#              In a DDR build the MIG OWNS this pair and the fabric clock comes from the MIG's
#              addn_ui_clkout1 instead, which does not run until calibration completes ~500 ms in.
#              That delay masqueraded as "the bus starts at 513 ms" until a no-DDR control.
#   26 pins in bank 66 are the command/address bus; both Mellanox designs drive it, ours does after
#. DQS activity varies run to run and is NOT a design property.
#
# =================================================================================================
# FLASH LAYOUT (per device; two MT25QU512 nibble-interleaved, first 0x68 bytes read narrow)
# =================================================================================================
#   0x00000000  Factory   header carries WBSTAR 0x03000000 + a jump: it boots the FLEX slot
#                         unconditionally. A copy of Factory placed in Flex therefore loops for
#                         ever unless the jump is removed.
#   0x01000000  User      the User image. Freely writable.
#   0x03000000  Flex      writable deliberately, cabled card only. Guard in mk_flex_mcs refuses a
#                         payload past 0x03DFFFFF.
# =================================================================================================
