// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// e3_code -- decode the image-select code the ConnectX puts on E3.
//
// MEASURED (on a development build, level scope armed at 1.2 s, 80 ns/sample, one flash, both
// schedules, everything else identical):
//
//   FLEX scheduled   every 77.1 us frame carries ONE pulse,  3.83-3.93 F4 cycles (3039-3119 ns)
//   USER scheduled   every 77.1 us frame carries THAT pulse AND a second one of
//                    0.91-1.01 F4 cycles (720-800 ns), starting 1.5-1.6 us after the first ends
//
// E5 is bit-identical between the two arms (same pulses, same frame), F4 is the same clock, and a
// sweep of all 2466 boundary cells found no other pin that differs. So the second pulse is
// the selector, and "long alone" vs "long + short" is a one-bit code carried once per frame.
//
// At 100 MHz: long = 304..312 clk, short = 72..80 clk, the gap between them 150..160 clk.
// The thresholds below sit well clear of both, and a pulse that matches neither class is ignored
// rather than guessed at -- a wrong decode here fires an IPROG, which is irreversible until the
// next power cycle.
// =================================================================================================
module e3_code #(
  parameter integer LONG_MIN   = 200,   // 2.0 us: measured long is 3.0-3.1 us, short is 0.72-0.80
  parameter integer SHORT_MIN  = 30,    // 0.30 us: below this it is a glitch, not a symbol
  parameter integer SHORT_MAX  = 150,   // 1.50 us
  parameter integer WINDOW     = 600,   // 6.0 us after the long pulse to see the short one (gap 1.5)
  parameter integer NEED       = 8      // consecutive two-pulse frames before we believe it
)(
  input  wire clk,
  input  wire e3,
  output wire user_req,                 // sticky once NEED consecutive frames have carried the short
  output wire [7:0] hits_o,             // observability: how many consecutive two-pulse frames
  output wire [7:0] frames_o            // and how many frames have been classified at all
);
  reg m = 1'b0, s = 1'b0, d = 1'b0;
  always @(posedge clk) begin m <= e3; s <= m; d <= s; end
  wire rise = s & ~d;
  wire fall = ~s & d;

  reg [15:0] hi = 16'd0;                // length of the pulse currently high
  always @(posedge clk) if (s) hi <= (hi == 16'hFFFF) ? hi : hi + 16'd1; else hi <= 16'd0;

  // classify on the falling edge, using the width just completed
  wire is_long  = fall && (hi >= LONG_MIN[15:0]);
  wire is_short = fall && (hi >= SHORT_MIN[15:0]) && (hi <= SHORT_MAX[15:0]);

  reg        waiting = 1'b0;            // a long pulse has ended; watching for its short partner
  reg [15:0] wct     = 16'd0;
  reg [7:0]  hits    = 8'd0, frames = 8'd0;
  reg        req     = 1'b0;

  always @(posedge clk) begin
    if (is_long) begin                  // a long pulse always opens a new frame decision
      waiting <= 1'b1; wct <= 16'd0;
    end else if (waiting) begin
      if (is_short) begin               // long + short  -> "boot User"
        waiting <= 1'b0;
        if (hits != 8'hFF) hits <= hits + 8'd1;
        if (frames != 8'hFF) frames <= frames + 8'd1;
      end else if (wct == WINDOW[15:0]) begin   // long alone -> "stay in Flex"
        waiting <= 1'b0; hits <= 8'd0;
        if (frames != 8'hFF) frames <= frames + 8'd1;
      end else wct <= wct + 16'd1;
    end
    if (hits >= NEED[7:0]) req <= 1'b1; // sticky: the request does not have to persist to be acted on
  end

  assign user_req  = req;
  assign hits_o    = hits;
  assign frames_o  = frames;
endmodule
