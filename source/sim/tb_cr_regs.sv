// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// drive cr_regs the way fpga_get_fan_rpm and fpga_set_power do, and check the number the
// app would PRINT -- not just that registers hold values. The app divides what we report; a counter
// that is right in the wrong field, or seconds that count something else, produces a confident and
// wrong RPM, which is the failure mode this test exists to catch.
module tb_cr_regs;
  // Time is SCALED, and getting the scale wrong is why the first run of this test reported
  // "seconds=0": at a real 1 MHz a simulated second costs 10^9 ns of simulation. CLK_HZ=1000 makes
  // the DUT's "second" 1000 clocks = 1 ms of sim time, and the tach below is 100 pulses per such
  // second, so the app's arithmetic still has to produce 3000 RPM.
  localparam integer CLK_HZ = 1000;
  reg clk = 0; always #500 clk = ~clk;          // 1 MHz clock, 1 us period
  reg [31:0] wa = 0, wd = 0; reg ws = 0;
  reg [31:0] ra = 0;
  wire hit; wire [31:0] rd; wire [15:0] power;
  reg tach = 0;
  cr_regs #(.CLK_HZ(CLK_HZ)) dut (.clk(clk), .wr_addr(wa), .wr_data(wd), .wr_stb(ws),
                                  .rd_addr(ra), .hit(hit), .rdata(rd),
                                  .tach_in(tach), .power_level(power));

  // a 100 Hz tachometer: 100 pulses per simulated second
  always begin #5000 tach = 1; #5000 tach = 0; end

  integer errs = 0;
  task wr(input [31:0] a, input [31:0] d);
    begin @(posedge clk); wa <= a; wd <= d; ws <= 1'b1; @(posedge clk); ws <= 1'b0; end
  endtask
  task rdreg(input [31:0] a, output [31:0] v);
    begin @(posedge clk); ra <= a; @(posedge clk); #1 v = rd; end
  endtask

  reg [31:0] v; integer pulses, seconds, rpm;
  initial begin
    // ---- the power dial ----
    rdreg(32'h24, v);
    if (v !== 32'd0) begin $display("FAIL power starts at %0d", v); errs=errs+1; end
    wr(32'h24, 32'd768);
    rdreg(32'h24, v);
    if (v[15:0] !== 16'd768) begin $display("FAIL power reads back %0d, wrote 768", v[15:0]); errs=errs+1; end
    else if (power !== 16'd768) begin $display("FAIL power_level output is %0d", power); errs=errs+1; end
    else $display("PASS power 0x24 is writable, reads back, and reaches the burner");
    // the app masks to 0x3FF on read-back, so anything above that is its business, not ours
    wr(32'h24, 32'h0000FFFF);
    rdreg(32'h24, v);
    if ((v & 32'h3FF) !== 32'h3FF) begin $display("FAIL masked read-back %08x", v); errs=errs+1; end

    // ---- the fan sequence, exactly as fpga_get_fan_rpm() performs it ----
    wr(32'h41C, 32'd1);                      // start
    rdreg(32'h420, v);
    if (v[0] !== 1'b0) begin $display("FAIL done set while measuring"); errs=errs+1; end
    #3_000_000;                              // the app's sleep(3): three simulated seconds
    wr(32'h41C, 32'd0);                      // stop
    rdreg(32'h420, v);
    if (v[0] !== 1'b1) begin $display("FAIL done not set after stop"); errs=errs+1; end
    else $display("PASS done is raised when the measurement stops");
    rdreg(32'h418, v);
    seconds = (v >> 24) & 8'hFF;
    pulses  = (v & 24'hFFFFFF) / 2;
    rpm     = (seconds == 0) ? 0 : pulses * 60 / seconds;
    $display("    counters=%08x -> seconds=%0d pulses(/2)=%0d -> app would print %0d RPM",
             v, seconds, pulses, rpm);
    if (seconds < 2 || seconds > 4) begin $display("FAIL seconds field %0d, expected ~3", seconds); errs=errs+1; end
    // 100 Hz tach for ~3 s = ~300 edges; the app halves them and scales to a minute -> ~3000 RPM
    if (rpm < 2700 || rpm > 3300) begin $display("FAIL RPM %0d outside 2700..3300", rpm); errs=errs+1; end
    else $display("PASS the fan measurement yields the RPM the tach frequency implies");

    // ---- a second run must not accumulate on top of the first ----
    wr(32'h41C, 32'd1); #2_000_000; wr(32'h41C, 32'd0);
    rdreg(32'h418, v);
    if (((v >> 24) & 8'hFF) > 3) begin $display("FAIL second run accumulated: seconds=%0d", (v>>24)&255); errs=errs+1; end
    else $display("PASS a new measurement starts from zero");

    // ---- addresses we do NOT own must fall through, or the captured map stops answering ----
    rdreg(32'h900004, v);
    if (hit !== 1'b0) begin $display("FAIL cr_regs claimed 0x900004, which belongs to the map"); errs=errs+1; end
    else $display("PASS unowned addresses fall through to the captured map");

    $display("CR-REGS-TB %s (%0d errors)", errs ? "FAIL" : "PASS", errs);
    $finish;
  end
endmodule
