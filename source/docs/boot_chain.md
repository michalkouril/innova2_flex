<!--
SPDX-FileCopyrightText: 2026 the innova2 contributors

SPDX-License-Identifier: Apache-2.0
-->

# How an Innova2 boots, and what a Flex-slot image has to do

Written 2026-09-15, after - settled the last unknown. Everything here is measured
on the card in Host C (the one with the JTAG cable), not inferred from documentation.

## The chain

```
  power on
     |
     v
  FACTORY image at flash 0x0
     header: TIMER 40100000, WBSTAR 03000000, CMD IPROG      (decoded from Mellanox's own bitstream)
     -> jumps UNCONDITIONALLY to the Flex slot, per-device address 0x03000000
     |
     v
  FLEX-SLOT image  (the ConnectX calls this index 1, FACTORY; the Flex Open app relabels it
                    "Innova2 Flex Image", which is why the naming is confusing everywhere)
     runs for ~1.3 s in Mellanox's image
     reads the ConnectX's code on pin E3 and decides:
         stay resident            -- the card runs this image, ConnectX reports oper=1
         ICAPE3 IPROG 0x01000000  -- the USER image is configured, ConnectX reports oper=0
```

There is no dispatch packet anywhere in the Flex bitstream -- an earlier sweep was right about that --
and the ConnectX does not perform the hop either. The Flex image's **fabric** issues the IPROG at
runtime, which is why a packet sweep finds nothing. A PROGRAM_B pulse could not do it in any case:
that restarts at 0x0, and Factory's header sends it straight back to the Flex slot.

## The selector: a one-bit code on E3

E3 carries a 77.1 us frame. Measured with a level scope armed at 1.2 s (80 ns/sample), one flash,
both schedules, nothing else changed:

```
  Flex scheduled   ONE pulse per frame        3.83-3.93 F4 cycles   (3039-3119 ns)
  User scheduled   that pulse PLUS a partner  0.91-1.01 F4 cycles   (720-800 ns), 1.5-1.6 us later

  flex   E3 ___X---________ ... ________X--X____
  user   E3 ___X---_XX______ ... _______X--X_XX__
```

F4 is a free-running ~1.26 MHz reference the card supplies; E5 carries one ~1.9-cycle pulse per
frame and is **identical** under both schedules. A sweep of all 2466 boundary cells found no other
pin that differs. E3 is the channel, and the only one.

Timing to be aware of: the pin group starts ~629 ms after configuration, goes quiet for ~80 ms, and
only runs continuously from ~717 ms. A scope armed early triggers on that first edge and captures
the quiet patch -- which is how this went unseen for so long.

## What a replacement image must do

1. **Be accepted.** E4 must replay the vendor's measured waveform (widths/gaps in F4 cycles
   `2/15 1/9 4/34 2/33`, 100 F4 cycles = 77.3 us). A static E4 is rejected; this is the single
   variable that flips the verdict.
2. **Answer the ConnectX's CR space over I2C** -- slave 0x40, 8-byte command (bytes 4-7 = 32-bit
   big-endian CR address) then a 4-byte big-endian read. Not during boot: measured zero I2C in the
   first 2.048 s under either schedule. The polling starts when the driver probes.
3. **Decode E3 and hop.** `source/rtl/e3_code.v`: classify each high pulse at 100 MHz -- >= 200 clk
   is the long symbol, 30..150 clk the short one, anything else ignored; a long opens a 6 us window;
   a short inside it means "boot User"; 8 consecutive such frames latch the request. Then
   `flex_hop` issues sync / WBSTAR 0x01000000 / CMD IPROG through ICAPE3, remembering that ICAPE3.I
   takes each byte BIT-REVERSED with byte lanes in place.
4. **Grant JTAG** when asked, so the card stays recoverable.

## What the pins are NOT

* **F1** is a status line: 0 while a Flex-slot image runs, 1 once the User image runs. The FPGA
  drives it in neither case. It is not a selector and not a heartbeat flag.
* **I2C** is not part of the boot decision -- no edges at all in the first 2 s.
* **E5, F4, A6, D1, D2, C3** carry nothing schedule-dependent.

## Reference results

```
  early development build, one flash, six schedule flips:  6/6 correct, status=0(SUCCESS) every time
  Flex scheduled:  our image resident, CR identity block answered, JTAG grant round-trips
  User scheduled:  oper=0(USER) status=0(SUCCESS), the User image enumerates and its drivers bind
```

## Recovery, if a replacement is rejected or does not hop

The card comes up with no FPGA endpoint. Recovery over JTAG: load a BAR-matched rescue
image, warm reboot (AMT PowerState 10 if SSH is gone -- power stays on so the JTAG load survives),
restore Mellanox's Flex, select User. Never cold cycle to recover: that reloads the flash image you
are trying to escape.
