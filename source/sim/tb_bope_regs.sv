// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// the register block is what the vendor app touches first. If pci_test does not behave, the
// app gives up before a single byte of image is sent -- so test that sequence exactly as burn_app.c
// performs it, and test both AXI channel orders, because a slave that only answers when AW precedes
// W wedges the root port (the clk_freq_counter bug, found in review, not on hardware).
module tb_bope_regs;
  localparam DW = 64;
  reg clk = 0; always #2 clk = ~clk;
  reg rstn = 0;
  reg [31:0] awaddr = 0, araddr = 0; reg awvalid = 0, wvalid = 0, arvalid = 0, bready = 1, rready = 1;
  reg [DW-1:0] wdata = 0; reg [DW/8-1:0] wstrb = 8'h0F;
  wire awready, wready, arready, bvalid, rvalid; wire [1:0] bresp, rresp; wire [DW-1:0] rdata;
  wire [31:0] cmd_data; wire cmd_valid, full_drop;
  reg afull = 0, busy = 0, er = 0, ef = 0; reg [6:0] prog = 0; reg [1:0] dcnt = 0;
  wire [3:0] bid_w, rid_w; wire rlast_w;
  bope_regs #(.AXI_DW(DW), .AXI_IDW(4), .VERSION(16'h0001)) dut (
    .aclk(clk), .aresetn(rstn),
    .s_awid(4'd5), .s_awaddr(awaddr), .s_awlen(8'd0), .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(1'b1), .s_wvalid(wvalid), .s_wready(wready),
    .s_bid(bid_w), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_arid(4'd7), .s_araddr(araddr), .s_arlen(8'd0), .s_arvalid(arvalid), .s_arready(arready),
    .s_rid(rid_w), .s_rdata(rdata), .s_rlast(rlast_w), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
    .cmd_data(cmd_data), .cmd_valid(cmd_valid), .fifo_afull(afull), .progress(prog),
    .done_cnt(dcnt), .busy(busy), .err_recov(er), .err_fatal(ef), .dbg16(16'h0001),
    .full_drop_o(full_drop));

  integer errs = 0;
  reg [31:0] last_cmd; integer ncmd = 0;
  always @(posedge clk) if (cmd_valid) begin last_cmd <= cmd_data; ncmd = ncmd + 1;
    $display("    [%0t] cmd pulse #%0d = %08x", $time, ncmd, cmd_data); end

  task wr_ordered(input [31:0] d);           // AW then W, the usual order
    begin
      @(posedge clk); awvalid <= 1; awaddr <= 0;
      wait (awready); @(posedge clk); awvalid <= 0;
      wdata <= {32'd0, d}; wvalid <= 1;
      wait (wready); @(posedge clk); wvalid <= 0;
      wait (bvalid); @(posedge clk);
    end
  endtask
  task wr_wfirst(input [31:0] d);            // W before AW -- legal, and the case that wedges
    begin
      @(posedge clk); wdata <= {32'd0, d}; wvalid <= 1;
      wait (wready); @(posedge clk); wvalid <= 0;
      awvalid <= 1; awaddr <= 0;
      wait (awready); @(posedge clk); awvalid <= 0;
      wait (bvalid); @(posedge clk);
    end
  endtask
  task rd(output [31:0] d);
    begin
      @(posedge clk); arvalid <= 1; araddr <= 0;
      wait (arready); @(posedge clk); arvalid <= 0;
      wait (rvalid); d = rdata[31:0]; @(posedge clk);
    end
  endtask

  reg [31:0] st;
  initial begin
    repeat (4) @(posedge clk); rstn <= 1; repeat (2) @(posedge clk);

    // --- pci_test, exactly as burn_app.c runs it ---
    wr_ordered(32'h01234567); rd(st);
    if (st[27] !== 1'b0) begin $display("FAIL pcie_test should be 0 after 0x01234567 (st=%08x)", st); errs=errs+1; end
    wr_ordered(32'hA5A5A5A5); rd(st);
    if (st[27] !== 1'b1) begin $display("FAIL pcie_test should be 1 after 0xA5A5A5A5 (st=%08x)", st); errs=errs+1; end
    wr_ordered(32'h01234567); rd(st);
    if (st[27] !== 1'b0) begin $display("FAIL pcie_test should be 0 again (st=%08x)", st); errs=errs+1; end
    else $display("PASS pci_test sequence");

    // --- the same three writes with W ahead of AW ---
    wr_wfirst(32'hA5A5A5A5); rd(st);
    if (st[27] !== 1'b1) begin $display("FAIL W-before-AW write was lost"); errs=errs+1; end
    else $display("PASS W-before-AW accepted and answered");

    // --- status packing ---
    prog = 7'd100; dcnt = 2'd2; busy = 1; afull = 1; er = 1; ef = 1; @(posedge clk);
    rd(st);
    if (st[15:0]  !== 16'h0001) begin $display("FAIL version field = %04x", st[15:0]); errs=errs+1; end
    if (st[22:16] !== 7'd100)   begin $display("FAIL progress field = %0d", st[22:16]); errs=errs+1; end
    if (st[24:23] !== 2'd2)     begin $display("FAIL done field = %0d", st[24:23]); errs=errs+1; end
    if (st[25] !== 1'b1 || st[26] !== 1'b1 || st[28] !== 1'b1 || st[29] !== 1'b1) begin
      $display("FAIL flag bits = %b", st[29:25]); errs=errs+1; end
    if (st[31:30] !== 2'b00)    begin $display("FAIL reserved bits set"); errs=errs+1; end
    if (errs == 0) $display("PASS status word packs to the documented bit map");

    // --- every write must be visible to the engine exactly once ---
    begin : count_check
      integer n0; n0 = ncmd;
      wr_ordered(32'hc001babe); wr_ordered(32'h60000000); wr_ordered(32'h01000000);
      repeat (3) @(posedge clk);          // the monitor counts on the edge AFTER cmd_valid rises;
                                          // checking in the same delta was a testbench race, not a
                                          // DUT fault -- the pulse was there, just not yet counted
      if (ncmd - n0 != 3) begin $display("FAIL %0d cmd pulses for 3 writes", ncmd-n0); errs=errs+1; end
      else if (last_cmd !== 32'h01000000) begin $display("FAIL last cmd = %08x", last_cmd); errs=errs+1; end
      else $display("PASS three writes -> three command pulses, values intact");
    end

    if (bid_w !== 4'd5) begin $display("FAIL BID not echoed (%0d)", bid_w); errs=errs+1; end
    else if (rid_w !== 4'd7) begin $display("FAIL RID not echoed (%0d)", rid_w); errs=errs+1; end
    else $display("PASS write and read IDs are echoed");
    $display("BOPE-REGS-TB %s (%0d errors)", errs ? "FAIL" : "PASS", errs);
    $finish;
  end
  initial begin #200000; $display("BOPE-REGS-TB FAIL (timeout -- a channel never answered)"); $finish; end
endmodule
