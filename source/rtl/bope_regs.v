// SPDX-FileCopyrightText: 2026 the innova2 contributors
// SPDX-FileCopyrightText: Mellanox Technologies Ltd.
//
// SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

`timescale 1ns/1ps
// =================================================================================================
// bope_regs -- the ONE register the Innova2 Flex Open burn utility talks to.
//
// Contract, read out of Mellanox's own sources (`work/ref/{burn_app.c,mlx_fpga_bope.c}`):
// the driver and the --enable_sysfs path both do `*(volatile uint32_t *)base` with
// `BUG_ON(count != 4)`. So BAR0 + 0 is a write FIFO going in and a status word coming out:
//
//   bits [15:0]  fpga_version              bit [25]  non-recoverable error
//   bits [22:16] mb_progress (0..100)      bit [26]  busy
//   bits [24:23] mb_status_done            bit [27]  pcie_test
//   bit  [28]    recoverable error         bit [29]  buffer_almost_full
//
// pci_test() is the app's first move and it is a pure register behaviour:
//   write 0x01234567 -> pcie_test reads 0 ;  write 0xA5A5A5A5 -> 1 ;  write 0x01234567 -> 0.
// Those two words are therefore NOT data and must never reach the flash path.
//
// The AXI side is deliberately minimal: the host issues single-beat 32-bit accesses to offset 0,
// so this accepts one beat at a time and answers every one. It never stalls a write it cannot
// store -- it drops it and raises the FIFO's own back-pressure flag instead, because the protocol
// says the app must WAIT while buffer_almost_full is set, and a dropped word with the flag clear
// would corrupt an image silently. See `full_drop_o`, which the build gate reads back in simulation.
// =================================================================================================
module bope_regs #(
  parameter integer AXI_DW  = 64,
  parameter integer AXI_IDW = 4,       // the SmartConnect port carries IDs; they must be echoed or
                                       // the interconnect never retires the transaction
  parameter [15:0]  VERSION = 16'h0001,
  // in a DEBUG build the version field carries live engine state instead of a constant.
  // The app only prints it; we read the raw word. That buys full visibility over PCIe, at the
  // speed of a register read, instead of one JTAG capture per hypothesis.
  parameter integer DEBUG_STATUS = 0
)(
  input  wire                   aclk,
  input  wire                   aresetn,
  // --- AXI4 slave, single beat, offset 0 is the only live address -------------------------------
  input  wire [AXI_IDW-1:0]     s_awid,
  input  wire [31:0]            s_awaddr,
  input  wire [7:0]             s_awlen,
  input  wire                   s_awvalid,
  output wire                   s_awready,
  input  wire [AXI_DW-1:0]      s_wdata,
  input  wire [AXI_DW/8-1:0]    s_wstrb,
  input  wire                   s_wlast,
  input  wire                   s_wvalid,
  output wire                   s_wready,
  output reg  [AXI_IDW-1:0]     s_bid,
  output reg  [1:0]             s_bresp,
  output reg                    s_bvalid,
  input  wire                   s_bready,
  input  wire [AXI_IDW-1:0]     s_arid,
  input  wire [31:0]            s_araddr,
  input  wire [7:0]             s_arlen,
  input  wire                   s_arvalid,
  output wire                   s_arready,
  output reg  [AXI_IDW-1:0]     s_rid,
  output reg  [AXI_DW-1:0]      s_rdata,
  output reg                    s_rlast,
  output reg  [1:0]             s_rresp,
  output reg                    s_rvalid,
  input  wire                   s_rready,
  // --- to the burn engine ----------------------------------------------------------------------
  output reg  [31:0]            cmd_data,      // word written by the host
  output reg                    cmd_valid,     // one cycle per accepted write (test words excluded)
  input  wire                   fifo_afull,    // fewer than 8K dwords free
  input  wire [6:0]             progress,      // 0..100
  input  wire [1:0]             done_cnt,
  input  wire                   busy,
  input  wire                   err_recov,
  input  wire                   err_fatal,
  input  wire [15:0]            dbg16,         // live engine state, shown in place of VERSION when
                                               // DEBUG_STATUS -- see the parameter comment above
  output reg                    full_drop_o    // a data word arrived with no room: never expected
);
  localparam [31:0] PAT_CLR = 32'h01234567;
  localparam [31:0] PAT_SET = 32'hA5A5A5A5;

  // Writes: take AW and W independently. The first version required them in order and would have
  // hung the host the same way clk_freq_counter did (the AXI bug found earlier) -- an AXI
  // master may present W before AW, and a slave that never answers B wedges the root port.
  reg aw_seen, w_seen;
  reg [31:0] wword;
  reg [AXI_IDW-1:0] awid_q, arid_q;
  reg [7:0]  rbeats;
  wire wr_fire = (aw_seen | s_awvalid) & (w_seen | s_wvalid) & ~s_bvalid;

  // The 32-bit word inside a wider bus: the app writes 4 bytes at offset 0, so the live lane is
  // the one its strobes select. Only offset 0 exists, so lane 0 is the only lane that can be it.
  wire [31:0] wdata32 = s_wdata[31:0];

  assign s_awready = ~aw_seen & ~s_bvalid;
  assign s_wready  = ~w_seen  & ~s_bvalid;
  assign s_arready = ~s_rvalid;

  always @(posedge aclk) begin
    if (!aresetn) begin
      aw_seen <= 1'b0; w_seen <= 1'b0; s_bvalid <= 1'b0; s_bresp <= 2'b00;
      cmd_valid <= 1'b0; cmd_data <= 32'd0; full_drop_o <= 1'b0;
    end else begin
      cmd_valid <= 1'b0;
      if (s_awvalid && s_awready) begin aw_seen <= 1'b1; awid_q <= s_awid; end
      if (s_wvalid  && s_wready)  begin w_seen <= 1'b1; wword <= wdata32; end
      if (wr_fire) begin
        // the word that fires is whichever we have: the just-arriving one or the latched one
        cmd_data  <= w_seen ? wword : wdata32;
        cmd_valid <= 1'b1;
        aw_seen <= 1'b0; w_seen <= 1'b0; s_bvalid <= 1'b1; s_bresp <= 2'b00;
        s_bid <= aw_seen ? awid_q : s_awid;
      end
      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
      if (busy && fifo_afull && cmd_valid) full_drop_o <= 1'b1;   // diagnostic, never expected
    end
  end

  // pcie_test: a latch driven by the two magic words. Kept here, not in the engine, because the
  // app runs pci_test BEFORE any burn and expects an answer with nothing else going on.
  reg pcie_test;
  always @(posedge aclk) begin
    if (!aresetn) pcie_test <= 1'b0;
    else if (cmd_valid) begin
      if      (cmd_data == PAT_SET) pcie_test <= 1'b1;
      else if (cmd_data == PAT_CLR) pcie_test <= 1'b0;
    end
  end

  wire [15:0] verfield = (DEBUG_STATUS != 0) ? dbg16 : VERSION;
  wire [31:0] status = {2'b00, fifo_afull, err_recov, pcie_test, busy, err_fatal,
                        done_cnt, progress, verfield};

  always @(posedge aclk) begin
    if (!aresetn) begin
      s_rvalid <= 1'b0; s_rresp <= 2'b00; s_rdata <= {AXI_DW{1'b0}}; s_rlast <= 1'b0; rbeats <= 8'd0;
    end else begin
      if (s_arvalid && s_arready) begin
        s_rdata  <= {{(AXI_DW-32){1'b0}}, status};
        s_rresp  <= 2'b00;
        s_rid    <= s_arid;
        rbeats   <= s_arlen;                      // honour a burst rather than hang on beat two
        s_rlast  <= (s_arlen == 8'd0);
        s_rvalid <= 1'b1;
      end else if (s_rvalid && s_rready) begin
        if (rbeats == 8'd0) s_rvalid <= 1'b0;
        else begin
          rbeats  <= rbeats - 8'd1;
          s_rlast <= (rbeats == 8'd1);
          s_rdata <= {{(AXI_DW-32){1'b0}}, status};
        end
      end
    end
  end
endmodule
