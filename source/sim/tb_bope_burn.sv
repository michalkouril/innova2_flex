// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// burn a chunk end to end in simulation -- protocol in, flash contents out. The failure this
// is really guarding against is not "it does nothing", it is "it writes something almost right":
// a byte-order slip, a missing erase, a piece that overruns the IP's 256-byte FIFO, or an address
// that drifts across a page boundary. Each of those produces an image that flashes cleanly and
// then does not boot, which on this card costs a JTAG rescue to find out.
module tb_bope_burn;
  reg clk = 0; always #5 clk = ~clk;          // 100 MHz
  reg rstn = 0;
  reg [31:0] cmd = 0; reg cmdv = 0;
  wire afull, busy, er, ef; wire [6:0] prog; wire [1:0] dcnt;
  wire [31:0] awaddr, wdata, araddr; wire awvalid, wvalid, arvalid; wire [3:0] wstrb;
  wire awready, wready, arready, bvalid, rvalid; wire [1:0] bresp, rresp; wire [31:0] rdata;
  wire bready, rready, overrun, no_erase;

  // SETTLE is a real-hardware workaround for a clock-domain crossing inside the SPI controller
  // the model has no such domain, and the hardware value of 500 cycles per control write
  // makes this testbench run past its own time limit. Shrink it here -- what is under test is the
  // command sequence, not the pause.
  bope_burn #(.FIFO_AW(14), .QSPI_BASE(32'h00040000), .WIP_LIMIT(32'd100000), .PIECE(128),
              .SETTLE(16'd4)) dut (
    .clk(clk), .rstn(rstn), .cmd_data(cmd), .cmd_valid(cmdv),
    .afull(afull), .progress(prog), .done_cnt(dcnt), .busy(busy),
    .err_recov(er), .err_fatal(ef),
    .m_awaddr(awaddr), .m_awvalid(awvalid), .m_awready(awready),
    .m_wdata(wdata), .m_wstrb(wstrb), .m_wvalid(wvalid), .m_wready(wready),
    .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
    .m_araddr(araddr), .m_arvalid(arvalid), .m_arready(arready),
    .m_rdata(rdata), .m_rresp(rresp), .m_rvalid(rvalid), .m_rready(rready));

  qspi_flash_model #(.MEM_KB(512)) flash (
    .aclk(clk), .aresetn(rstn),
    .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
    .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .araddr(araddr), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
    .fifo_overrun(overrun), .wrote_without_erase(no_erase));

  integer errs = 0;
  reg [7:0] sent [0:8191];
  integer nsent;

  task put(input [31:0] w); begin
    @(posedge clk); cmd <= w; cmdv <= 1'b1; @(posedge clk); cmdv <= 1'b0;
  end endtask

  task burn(input [31:0] off, input integer nbytes, input [7:0] seed);
    integer i; reg [31:0] w;
    begin
      nsent = nbytes;
      for (i = 0; i < nbytes; i = i + 1) sent[i] = seed + i[7:0];
      put(32'hC001BABE); put(32'h60000000); put(off); put(nbytes);
      for (i = 0; i < nbytes; i = i + 4) begin
        w = { (i+3 < nbytes) ? sent[i+3] : 8'hFF, (i+2 < nbytes) ? sent[i+2] : 8'hFF,
              (i+1 < nbytes) ? sent[i+1] : 8'hFF, sent[i] };
        put(w);
        while (afull) @(posedge clk);          // the protocol's own back-pressure
      end
    end
  endtask

  task wait_done(input [1:0] want_cnt);
    integer guard;
    begin
      guard = 0;
      while (dcnt !== want_cnt) begin
        @(posedge clk); guard = guard + 1;
        if (guard > 4000000) begin $display("FAIL burn never completed (done=%0d busy=%b)", dcnt, busy); errs=errs+1; disable wait_done; end
      end
    end
  endtask

  task check(input integer slave, input [31:0] off, input integer nbytes, input [7:0] seed);
    integer i; reg [7:0] got, want; integer bad;
    begin
      bad = 0;
      for (i = 0; i < nbytes; i = i + 1) begin
        got  = slave ? flash.mem1[off + i] : flash.mem0[off + i];
        want = seed + i[7:0];
        if (got !== want) begin
          if (bad < 4) $display("    byte %0d at 0x%08x: got %02x want %02x", i, off+i, got, want);
          bad = bad + 1;
        end
      end
      if (bad != 0) begin $display("FAIL %0d of %0d bytes wrong on chip %0d", bad, nbytes, slave); errs=errs+1; end
      else $display("PASS %0d bytes at 0x%08x on chip %0d are byte-exact", nbytes, off, slave);
    end
  endtask

  integer e0, p0, seen_prog;
  always @(posedge clk) if (prog > 0 && prog <= 100) seen_prog = 1;
  initial begin
    repeat (5) @(posedge clk); rstn <= 1; repeat (2) @(posedge clk);

    // 1. a plain 1 KB chunk on chip 0
    e0 = flash.n_erase;
    burn(32'h00001000, 1024, 8'h10);
    wait_done(2'd1);
    check(0, 32'h00001000, 1024, 8'h10);
    if (flash.n_erase - e0 != 1) begin $display("FAIL %0d erases for a 1 KB chunk, want 1", flash.n_erase-e0); errs=errs+1; end
    else $display("PASS one sector erase for a chunk inside one sector");

    // 2. the OTHER chip, selected by bit31, and a size that is not a multiple of four
    burn(32'h80002000, 300, 8'h40);
    wait_done(2'd2);
    check(1, 32'h00002000, 300, 8'h40);

    // 3. a chunk that crosses a 64 KB sector boundary -- both sectors must be erased
    e0 = flash.n_erase;
    burn(32'h0000FF00, 768, 8'h70);
    wait_done(2'd3);
    check(0, 32'h0000FF00, 768, 8'h70);
    if (flash.n_erase - e0 != 2) begin $display("FAIL %0d erases across a sector boundary, want 2", flash.n_erase-e0); errs=errs+1; end
    else $display("PASS the sector boundary triggers a second erase");

    // 4. the model's own alarms
    if (overrun)  begin $display("FAIL a transaction overran the 256-byte IP FIFO"); errs=errs+1; end
    else $display("PASS no transaction exceeded the IP FIFO");
    if (no_erase) begin $display("FAIL programmed a bit that needed an erase first"); errs=errs+1; end
    else $display("PASS every programmed byte had been erased");
    if (ef) begin $display("FAIL err_fatal asserted"); errs=errs+1; end

    if (!seen_prog) begin $display("FAIL progress never moved during a burn"); errs=errs+1; end
    else $display("PASS progress advanced while burning");

    // 5. status behaviour: busy clears, progress returns to 0, done counted three chunks
    begin : status_checks
      integer bad_st; bad_st = 0;
      if (busy)        begin $display("FAIL busy still set after the last chunk"); bad_st=bad_st+1; end
      if (prog != 0)   begin $display("FAIL progress %0d, want 0 when idle", prog); bad_st=bad_st+1; end
      if (dcnt != 2'd3)begin $display("FAIL done counter %0d, want 3", dcnt); bad_st=bad_st+1; end
      errs = errs + bad_st;
      if (bad_st == 0) $display("PASS busy low, progress 0, done counter advanced once per chunk");
    end

    $display("BOPE-BURN-TB %s (%0d errors)", errs ? "FAIL" : "PASS", errs);
    $finish;
  end
  initial begin #80000000; $display("BOPE-BURN-TB FAIL (timeout)"); $finish; end
endmodule
