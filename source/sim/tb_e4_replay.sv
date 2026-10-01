// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

// does e4_replay emit EXACTLY the measured waveform? Widths and gaps are checked in F4
// cycles against the measured numbers -- 2/15 1/9 4/34 2/33 -- because "it looks about right on a
// waveform" is how a replayer ships with an off-by-one that no flash verdict could ever diagnose.
`timescale 1ns/1ps
module tb_e4_replay;
  reg clk = 0; always #5 clk = ~clk;            // 100 MHz
  reg f4  = 0; always #386.5 f4 = ~f4;          // 773 ns period = 1.2937 MHz
  wire e4, locked;
  e4_replay #(.PHASE0(0)) dut (.clk(clk), .f4_in(f4), .e4_out(e4), .locked(locked));

  integer nrise = 0;
  always @(posedge f4) nrise = nrise + 1;

  integer last = 0, i, fails = 0, checks = 0;
  integer widths [0:7];
  integer nseg = 0;
  reg prev = 0;
  // measure each run of e4 in whole F4 cycles
  always @(posedge clk) begin
    if (e4 !== prev) begin
      if (locked && nseg < 8 && last != 0) begin
        widths[nseg] = nrise - last; nseg = nseg + 1;
      end
      last = nrise; prev = e4;
    end
  end

  task ck(input integer got, input integer want, input [127:0] what);
    begin
      checks = checks + 1;
      if (got !== want) begin fails = fails + 1; $display("  FAIL %0s: got %0d want %0d", what, got, want); end
    end
  endtask

  initial begin
    wait (locked);
    $display("  locked after %0d F4 rising edges", nrise);
    wait (nseg == 8);
    // segments alternate starting from whichever level came first; identify by the pattern
    $display("  measured run lengths (F4 cycles): %0d %0d %0d %0d %0d %0d %0d %0d",
             widths[0],widths[1],widths[2],widths[3],widths[4],widths[5],widths[6],widths[7]);
    // the cycle must sum to 100
    ck(widths[0]+widths[1]+widths[2]+widths[3]+widths[4]+widths[5]+widths[6]+widths[7], 100, "frame is 100 F4 cycles");
    // and must contain the measured multiset of HIGH widths {2,1,4,2} and LOW widths {15,9,34,33}
    begin : chk
      integer h2, h1, h4, l15, l9, l34, l33;
      h2=0; h1=0; h4=0; l15=0; l9=0; l34=0; l33=0;
      for (i = 0; i < 8; i = i + 1) begin
        case (widths[i])
          1:  h1  = h1  + 1;
          2:  h2  = h2  + 1;
          4:  h4  = h4  + 1;
          9:  l9  = l9  + 1;
          15: l15 = l15 + 1;
          33: l33 = l33 + 1;
          34: l34 = l34 + 1;
          default: begin fails = fails + 1; $display("  FAIL: unexpected run length %0d", widths[i]); end
        endcase
      end
      ck(h2,2,"two HIGH runs of 2"); ck(h1,1,"one HIGH run of 1"); ck(h4,1,"one HIGH run of 4");
      ck(l15,1,"one LOW 15"); ck(l9,1,"one LOW 9"); ck(l34,1,"one LOW 34"); ck(l33,1,"one LOW 33");
    end
    $display("  %0d checks, %0d failures", checks, fails);
    $display(fails == 0 ? "  RESULT PASS" : "  RESULT FAIL");
    $finish;
  end
  initial begin #5_000_000; $display("  RESULT FAIL -- timed out"); $finish; end
endmodule
