// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// power_burn -- an adjustable fabric load, with no I/O at all.
//
// Behind the app's "Increase FPGA power consumption" (CR 0x24): NCHAIN free-running LFSRs in 16
// groups, and the level written to CR 0x24 decides how many groups clock. Level 0 (the reset value)
// clocks nothing, so a normal boot draws no extra power; 1023 clocks all 32K flops. It is here so the
// app's menu item does something real; no tool in this repository writes it, and it only runs while
// the card rests in the Flex image. It drives no pin, so it cannot disturb any board net.
//
// Every chain carries DONT_TOUCH: a load with no consumer is exactly what synthesis removes.
// `alive` (the XOR of all chains) exists only so the chains have an output.
// =================================================================================================
module power_burn #(
  parameter integer NCHAIN = 512,      // parallel LFSRs
  parameter integer WIDTH  = 64        // bits each  -> NCHAIN*WIDTH toggling flops
)(
  input  wire clk,
  // the app's "Increase FPGA power consumption" writes a level to CR 0x24 and reads it
  // back masked to 0x3FF, so the dial has 10 useful bits. The chains are split into 16 groups and a
  // group only clocks if the level reaches it -- level 0 burns nothing, 1023 burns everything.
  input  wire [15:0] level,
  output wire alive
);
  wire [NCHAIN-1:0] taps;
  // 16 groups, gated by the dial. `lvl6` is the level in units of 64, so a 10-bit value spans the
  // groups: 0 -> nothing clocks, 1023 -> every group clocks. Registered so the comparison is not in
  // the LFSR's own timing path -- these chains exist to burn power, not to fail timing.
  reg [4:0] lvl6;
  always @(posedge clk) lvl6 <= level[9:6];
  genvar g;
  generate for (g = 0; g < NCHAIN; g = g + 1) begin : g_chain
    localparam integer GRP = (g * 16) / NCHAIN;              // which of the 16 groups this chain is
    (* DONT_TOUCH = "true" *) reg [WIDTH-1:0] lfsr = g + 1;  // non-zero seed, or it never moves
    always @(posedge clk)
      if (lvl6 > GRP[4:0])
        lfsr <= {lfsr[WIDTH-2:0], lfsr[WIDTH-1] ^ lfsr[WIDTH-2] ^ lfsr[WIDTH-3] ^ lfsr[WIDTH-5]};
    assign taps[g] = ^lfsr;
  end endgenerate
  assign alive = ^taps;
endmodule
