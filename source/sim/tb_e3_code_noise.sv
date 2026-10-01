// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// second gate: near-misses must not fire it. Glitches, a short that arrives too late, and a
// run of two-pulse frames BROKEN by stay-frames all have to stay below the threshold.
module tb_e3_code_noise;
  reg clk = 0; always #5 clk = ~clk;
  reg e3 = 0;
  wire req; wire [7:0] hits, frames;
  e3_code dut (.clk(clk), .e3(e3), .user_req(req), .hits_o(hits), .frames_o(frames));
  task pulse(input integer ns); begin e3 = 1; #(ns); e3 = 0; end endtask
  integer i, errs = 0;
  initial begin
    // a) 100 ns glitches after each long pulse -- below SHORT_MIN, must be ignored
    for (i = 0; i < 20; i = i + 1) begin pulse(3080); #(1550); pulse(100); #(71710); end
    if (req !== 1'b0) begin $display("FAIL fired on 100 ns glitches"); errs = errs + 1; end
    else $display("PASS 100 ns glitches ignored (hits=%0d)", hits);
    // b) a short that arrives 8 us after the long -- outside WINDOW, must be ignored
    for (i = 0; i < 20; i = i + 1) begin pulse(3080); #(8000); pulse(760); #(65000); end
    if (req !== 1'b0) begin $display("FAIL fired on a late short (window should have closed)"); errs = errs + 1; end
    else $display("PASS late short ignored (hits=%0d)", hits);
    // c) alternating two-pulse / one-pulse frames: never NEED in a row
    for (i = 0; i < 40; i = i + 1) begin
      pulse(3080);
      if (i[0]) begin #(1550); pulse(760); #(71710); end else #(74020);
    end
    if (req !== 1'b0) begin $display("FAIL fired on alternating frames (hits=%0d)", hits); errs = errs + 1; end
    else $display("PASS alternating frames never reach the threshold");
    $display("E3CODE-NOISE-TB %s (%0d errors)", errs ? "FAIL" : "PASS", errs);
    $finish;
  end
endmodule
