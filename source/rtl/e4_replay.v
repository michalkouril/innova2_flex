// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// e4_replay -- reproduce the E4 waveform Mellanox's Flex image emits.
//
// Measured on the wire with a logic analyser,, identical on two cards and stable over
// seconds. Widths and gaps in F4 CLOCK CYCLES:
//
//     HIGH 2   LOW 15   HIGH 1   LOW 9   HIGH 4   LOW 34   HIGH 2   LOW 33      = 100 cycles
//
// 100 cycles x 773 ns = 77.3 us, which is the same 77.1 us frame E3 and E5 sit on. That the
// frame comes out as a round 100 clocks is a check on the decode, not an assumption fed into it.
//
// WHY NOT CLOCK THIS FROM F4 DIRECTLY. F4 is an ordinary I/O pin here and may not be clock-capable;
// routing it to a BUFG to use as a clock invites a placement failure or, worse, a build that closes
// timing on a path nobody constrained. Instead F4 is synchronised into the existing 100 MHz domain
// and its rising edges advance the phase counter. At 100 MHz an F4 period is ~77 clocks, so each
// edge is placed within 10 ns -- well inside the 40 ns the analyser itself could resolve.
//
// The output is held LOW until F4 has been seen toggling. A dead or absent clock must not produce a
// stuck-high pin or a free-running pattern at the wrong rate: either would be a signal we never
// measured, and the point of this module is to emit only what was measured.
// =================================================================================================
module e4_replay #(
  parameter integer PHASE0 = 0        // starting phase, for sweeping alignment against E3's frame
)(
  input  wire clk,                    // 100 MHz fabric clock
  input  wire f4_in,                  // F4 as sampled by an IBUF
  output wire e4_out,
  output wire locked                  // F4 seen toggling; e4_out is meaningful
);
  reg s0 = 1'b0, s1 = 1'b0, s2 = 1'b0;
  always @(posedge clk) begin s0 <= f4_in; s1 <= s0; s2 <= s1; end
  wire f4_rise = s1 & ~s2;

  // "F4 is alive" = at least 64 rising edges seen, and never more than 4096 fabric clocks between
  // them (F4 at 1.26 MHz is ~77). A single glitch must not arm this.
  reg [11:0] since = 12'd0;
  reg [6:0]  seen  = 7'd0;
  reg        live  = 1'b0;
  always @(posedge clk) begin
    if (f4_rise) begin
      since <= 12'd0;
      if (!live && seen != 7'd64) seen <= seen + 7'd1;
      if (seen == 7'd64) live <= 1'b1;
    end else if (since != 12'hFFF) since <= since + 12'd1;
    if (since == 12'hFFF) begin live <= 1'b0; seen <= 7'd0; end   // clock stopped: disarm
  end

  reg [6:0] phase = PHASE0[6:0];
  always @(posedge clk)
    if (f4_rise) phase <= (phase == 7'd99) ? 7'd0 : phase + 7'd1;

  // HIGH windows, from the measurement:  [0,1]  [17]  [27,30]  [65,66]
  wire hi = (phase <= 7'd1)                    // HIGH 2
          | (phase == 7'd17)                   // HIGH 1
          | (phase >= 7'd27 && phase <= 7'd30) // HIGH 4
          | (phase >= 7'd65 && phase <= 7'd66);// HIGH 2
  reg q = 1'b0;
  always @(posedge clk) q <= live & hi;
  assign e4_out = q;
  assign locked = live;
endmodule
