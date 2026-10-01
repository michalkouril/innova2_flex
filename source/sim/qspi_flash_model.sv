// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// a model of the AXI Quad SPI IP plus the MT25QU512 behind it, faithful to the parts the
// engine depends on: the FIFO/CR/SR/SSR register dance, and the flash's WREN / 64K sector erase /
// 4-byte page program / WIP semantics. Enough to catch a wrong opcode, a byte-order slip, a missing
// erase, or a transaction that overruns the 256-entry FIFO -- all of which look identical on
// hardware, as "the image is subtly wrong".
module qspi_flash_model #(parameter integer MEM_KB = 512) (
  input  wire        aclk,
  input  wire        aresetn,
  input  wire [31:0] awaddr, input wire awvalid, output reg awready,
  input  wire [31:0] wdata,  input wire [3:0] wstrb, input wire wvalid, output reg wready,
  output reg  [1:0]  bresp,  output reg bvalid, input wire bready,
  input  wire [31:0] araddr, input wire arvalid, output reg arready,
  output reg  [31:0] rdata,  output reg [1:0] rresp, output reg rvalid, input wire rready,
  output reg         fifo_overrun,        // more than 256 bytes staged: the IP would have dropped
  output reg         wrote_without_erase  // a program that needed a bit set: silent corruption
);
  localparam R_CR=32'h60, R_SR=32'h64, R_DTR=32'h68, R_DRR=32'h6C, R_SSR=32'h70;
  reg [31:0] cr, ssr;
  reg [7:0]  txf [0:511]; integer txn;
  reg [7:0]  rxf [0:511]; integer rxn, rxrd;
  reg [7:0]  mem0 [0:MEM_KB*1024-1];
  reg [7:0]  mem1 [0:MEM_KB*1024-1];
  reg        wel, wip;
  integer    wipcnt;
  integer    i, a;
  reg [31:0] addr32;

  // erase/program bookkeeping the testbench reads back
  integer n_erase, n_prog, n_wren;

  task automatic run_transfer(input integer slave);
    begin
      if (txn > 256) fifo_overrun = 1'b1;
      if (txn > 0) begin
        case (txf[0])
          8'h06: begin wel = 1'b1; n_wren = n_wren + 1; end
          8'h05: begin
                   // A status read only returns as many bytes as the master CLOCKS after the
                   // command. The first model answered regardless of length, so it could not catch
                   // a master that forgot the dummy byte -- which is exactly the bug that shipped.
                   rxn = 0;
                   for (i = 1; i < txn; i = i + 1) begin rxf[rxn] = {6'd0, wel, wip}; rxn = rxn + 1; end
                   if (txn < 2) $display("    MODEL RDSR with no dummy byte: nothing can be returned");
                 end
          8'hDC: begin                                  // sector erase, 64 KB, 4-byte address
                   addr32 = {txf[1],txf[2],txf[3],txf[4]};
                   if (!wel) $display("    MODEL erase without WREN at %08x", addr32);
                   for (i = 0; i < 65536; i = i + 1) begin
                     a = (addr32 & ~32'h0000FFFF) + i;
                     if (a < MEM_KB*1024) begin
                       if (slave == 0) mem0[a] = 8'hFF; else mem1[a] = 8'hFF;
                     end
                   end
                   wel = 1'b0; n_erase = n_erase + 1; wip = 1'b1; wipcnt = 20;
                 end
          8'h12: begin                                  // page program, 4-byte address
                   addr32 = {txf[1],txf[2],txf[3],txf[4]};
                   if (!wel) $display("    MODEL program without WREN at %08x", addr32);
                   for (i = 5; i < txn; i = i + 1) begin
                     a = addr32 + (i - 5);
                     if (a < MEM_KB*1024) begin
                       if (slave == 0) begin
                         if ((mem0[a] & txf[i]) != txf[i]) wrote_without_erase = 1'b1;
                         mem0[a] = mem0[a] & txf[i];     // NOR flash only clears bits
                       end else begin
                         if ((mem1[a] & txf[i]) != txf[i]) wrote_without_erase = 1'b1;
                         mem1[a] = mem1[a] & txf[i];
                       end
                     end
                   end
                   wel = 1'b0; n_prog = n_prog + 1; wip = 1'b1; wipcnt = 8;
                 end
          default: $display("    MODEL unknown opcode %02x", txf[0]);
        endcase
      end
      txn = 0;
    end
  endtask

  always @(posedge aclk) begin
    if (wip) begin
      if (wipcnt > 0) wipcnt = wipcnt - 1; else wip = 1'b0;
    end
  end

  initial begin
    awready=0; wready=0; bvalid=0; arready=0; rvalid=0; bresp=0; rresp=0;
    cr=0; ssr=32'hFFFFFFFF; txn=0; rxn=0; rxrd=0; wel=0; wip=0; wipcnt=0;
    n_erase=0; n_prog=0; n_wren=0; fifo_overrun=0; wrote_without_erase=0;
    for (i=0;i<MEM_KB*1024;i=i+1) begin mem0[i]=8'hFF; mem1[i]=8'hFF; end
  end

  // writes
  reg aw_s, w_s; reg [31:0] a_hold, d_hold;
  always @(posedge aclk) begin
    if (!aresetn) begin aw_s<=0; w_s<=0; bvalid<=0; awready<=0; wready<=0; end
    else begin
      awready <= !aw_s && !bvalid;
      wready  <= !w_s  && !bvalid;
      if (awvalid && awready) begin aw_s<=1; a_hold<=awaddr; end
      if (wvalid  && wready)  begin w_s <=1; d_hold<=wdata;  end
      if ((aw_s || (awvalid&&awready)) && (w_s || (wvalid&&wready)) && !bvalid) begin
        begin : do_write
          reg [31:0] aa, dd;
          aa = aw_s ? a_hold : awaddr;
          dd = w_s  ? d_hold : wdata;
          case (aa & 32'hFF)
            R_CR:  begin
                     if (dd[5]) txn = 0;                       // TX reset
                     if (dd[6]) begin rxn = 0; rxrd = 0; end   // RX reset
                     // inhibit released with a slave asserted -> the transfer runs
                     if (!dd[8] && (ssr != 32'hFFFFFFFF)) run_transfer(ssr[0] ? 1 : 0);
                     cr = dd;
                   end
            R_SSR: ssr = dd;
            R_DTR: begin txf[txn] = dd[7:0]; txn = txn + 1; end
            default: ;
          endcase
        end
        aw_s<=0; w_s<=0; bvalid<=1; bresp<=0;
      end
      if (bvalid && bready) bvalid<=0;
    end
  end

  // reads
  always @(posedge aclk) begin
    if (!aresetn) begin arready<=0; rvalid<=0; end
    else begin
      arready <= !rvalid;
      if (arvalid && arready) begin
        case (araddr & 32'hFF)
          R_SR:  rdata <= {28'd0, 1'b0, 1'b1 /*TXEMPTY: transfers complete instantly here*/,
                           1'b0, (rxrd >= rxn) ? 1'b1 : 1'b0};
          R_DRR: begin rdata <= {24'd0, rxf[rxrd]}; rxrd = rxrd + 1; end
          default: rdata <= 32'd0;
        endcase
        rvalid <= 1'b1; rresp <= 2'd0;
      end else if (rvalid && rready) rvalid <= 1'b0;
    end
  end
endmodule
