// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// drive the decoder with the two waveforms actually measured on the card and require
// that it separates them. A trigger that has not been shown to REFUSE the stay-case is not a
// trigger; it is an unconditional hop with extra steps -- which is what turned out to be.
module tb_e3_code;
  reg clk = 0; always #5 clk = ~clk;              // 100 MHz, 10 ns
  reg e3 = 0;
  wire req; wire [7:0] hits, frames;
  e3_code dut (.clk(clk), .e3(e3), .user_req(req), .hits_o(hits), .frames_o(frames));

  task pulse(input integer ns); begin e3 = 1; #(ns); e3 = 0; end endtask
  // measured: long 3039..3119 ns, short 720..800 ns, gap 1500..1600 ns, frame 77100 ns
  task frame_flex; begin pulse(3080); #(74020); end endtask
  task frame_user; begin pulse(3080); #(1550); pulse(760); #(71710); end endtask

  integer i, errs = 0;
  initial begin
    // 1. FLEX schedule: 40 frames of long-only must NEVER assert
    for (i = 0; i < 40; i = i + 1) frame_flex();
    if (req !== 1'b0) begin $display("FAIL asserted on the stay-case after %0d frames", frames); errs = errs + 1; end
    else $display("PASS 40 long-only frames: no request (frames=%0d hits=%0d)", frames, hits);

    // 2. USER schedule: the request must appear, and within NEED+1 frames
    for (i = 0; i < 12; i = i + 1) begin
      frame_user();
      if (req && i < 7) begin $display("FAIL asserted after only %0d two-pulse frames", i+1); errs = errs + 1; end
    end
    if (req !== 1'b1) begin $display("FAIL no request after 12 two-pulse frames"); errs = errs + 1; end
    else $display("PASS request asserted on the user-case (hits=%0d)", hits);

    // 3. sticky: it must survive the code going away
    for (i = 0; i < 5; i = i + 1) frame_flex();
    if (req !== 1'b1) begin $display("FAIL request dropped when the code stopped"); errs = errs + 1; end
    else $display("PASS request is sticky");

    $display("E3CODE-TB %s (%0d errors)", errs ? "FAIL" : "PASS", errs);
    $finish;
  end
endmodule
