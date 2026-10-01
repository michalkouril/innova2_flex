// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// flex_burn_top -- the Flex-slot replacement WITH the vendor burn endpoint.
//
// The proven PCIe + dual-quad-QSPI block design alongside the CR responder, plus:
//
//   * e4_replay  -- E4 carries the measured vendor waveform, which is what makes the ConnectX
//                   ACCEPT the image at all. Without it nothing else here matters.
//   * e3_code    -- decode the ConnectX's image-select code on E3: one long pulse per
//                   77.1 us frame means stay, long + a short partner means boot User.
//   * flex_hop   -- act on that with an ICAPE3 IPROG to 0x01000000 (stay / hop / stay,
//                   six flips, 6/6).
//   * bope_regs  -- BAR0+0, the single register the Innova2 Flex Open burn utility talks to.
//   * bope_burn  -- its chunk protocol, streamed straight into the config flash through the QSPI
//                   controller already in the block design.
//
// PIN NOTE: F2 is pcie_perstn, owned by the block design. E4 is an OUTPUT (the acceptance
// waveform); every other bank-90 pin stays an input.
// =================================================================================================
module flex_burn_top (
  // ---- PCIe, straight through to the block design ----
  input  wire [3:0] pci_express_x8_rxn,
  input  wire [3:0] pci_express_x8_rxp,
  output wire [3:0] pci_express_x8_txn,
  output wire [3:0] pci_express_x8_txp,
  input  wire       pcie_perstn,          // F2 -- also watched, see below
  input  wire [0:0] pcie_refclk_clk_n,
  input  wire [0:0] pcie_refclk_clk_p,
  inout  wire       spi1_io0_io,
  inout  wire       spi1_io1_io,
  inout  wire       spi1_io2_io,
  inout  wire       spi1_io3_io,
  inout  wire       spi1_ss_io,
  // ---- DDR4 and the I2C responder ----
  // the MIG owns the reference oscillator pair, because two buffers on one pad is a
  // build error -- so the logic clock below comes out of the MIG instead of out of our own IBUFDS.
  // Port names are exactly those in src/ddr4_72bit_gen.xdc; that pinout file is the constraint.
  input  wire        C0_SYS_CLK_0_clk_p,
  input  wire        C0_SYS_CLK_0_clk_n,
  output wire        C0_DDR4_0_act_n,
  output wire [16:0] C0_DDR4_0_adr,
  output wire [1:0]  C0_DDR4_0_ba,
  output wire [1:0]  C0_DDR4_0_bg,
  output wire [0:0]  C0_DDR4_0_ck_c,
  output wire [0:0]  C0_DDR4_0_ck_t,
  output wire [0:0]  C0_DDR4_0_cke,
  output wire [0:0]  C0_DDR4_0_cs_n,
  inout  wire [8:0]  C0_DDR4_0_dm_n,
  inout  wire [71:0] C0_DDR4_0_dq,
  inout  wire [8:0]  C0_DDR4_0_dqs_c,
  inout  wire [8:0]  C0_DDR4_0_dqs_t,
  output wire [0:0]  C0_DDR4_0_odt,
  output wire        C0_DDR4_0_reset_n,
  input  wire i2c_scl,                    // D2 -- INPUT ONLY; a slave that drives SCL is
  inout  wire i2c_sda,                    // D1 -- open drain      indistinguishable from a dead bus
  input  wire pin_f1,
  input  wire pin_c3,
  input  wire pin_a3,
  input  wire pin_a4,
  input  wire pin_a6,
  input  wire pin_b4,
  input  wire pin_b5,
  input  wire pin_b6,
  input  wire pin_c4,
  input  wire pin_c5,
  input  wire pin_d3,
  input  wire pin_d5,
  input  wire pin_d6,
  input  wire pin_e1,
  input  wire pin_e3,
  input  wire pin_e5,
  input  wire pin_f4,
  output wire pin_e4        // E4 is ours to drive: the acceptance waveform
);

  // ---- PCIe + dual-quad SPI: the flash_rescue block design, unmodified ------------------------
  wire        axi_clk, axi_rstn, lnk_up;
  wire [5:0]  ltssm;
  wire [4:0]  dbg_fs, dbg_xs;
  wire [15:0] dbg16;
  // The SmartConnect's EXTERNAL ports are 32-bit AXI4 with no ID field -- it drops IDs at the BD
  // boundary. The first attempt wired 64-bit data and awid/bid/arid/rid and synthesis rejected the
  // instance port by port. Widths and signal sets come from the generated wrapper, not from what
  // the interconnect carries internally.
  wire [31:0] m01_awaddr, m01_araddr, m01_wdata, m01_rdata;
  wire [7:0]  m01_awlen, m01_arlen;
  wire [3:0]  m01_wstrb;
  wire        m01_awvalid, m01_awready, m01_wvalid, m01_wready, m01_wlast;
  wire        m01_bvalid, m01_bready, m01_arvalid, m01_arready, m01_rvalid, m01_rready, m01_rlast;
  wire [1:0]  m01_bresp, m01_rresp;
  wire [31:0] s01_awaddr, s01_araddr, s01_wdata, s01_rdata;
  wire [3:0]  s01_wstrb;
  wire        s01_awvalid, s01_awready, s01_wvalid, s01_wready, s01_bvalid, s01_bready;
  wire        s01_arvalid, s01_arready, s01_rvalid, s01_rready;
  wire [1:0]  s01_bresp, s01_rresp;

  flexburn_bd_wrapper u_bd (
    .pci_express_x8_rxn(pci_express_x8_rxn), .pci_express_x8_rxp(pci_express_x8_rxp),
    .pci_express_x8_txn(pci_express_x8_txn), .pci_express_x8_txp(pci_express_x8_txp),
    .pcie_perstn(pcie_perstn),
    .pcie_refclk_clk_n(pcie_refclk_clk_n), .pcie_refclk_clk_p(pcie_refclk_clk_p),
    .spi1_io0_io(spi1_io0_io), .spi1_io1_io(spi1_io1_io), .spi1_io2_io(spi1_io2_io),
    .spi1_io3_io(spi1_io3_io), .spi1_ss_io(spi1_ss_io),
    .axi_aclk(axi_clk), .axi_aresetn(axi_rstn), .user_lnk_up(lnk_up), .ltssm_state(ltssm),
    // BAR0 -> our register
    .M01_AXI_awaddr(m01_awaddr), .M01_AXI_awlen(m01_awlen), .M01_AXI_awsize(), .M01_AXI_awburst(),
    .M01_AXI_awlock(), .M01_AXI_awcache(), .M01_AXI_awprot(), .M01_AXI_awqos(),
    .M01_AXI_awvalid(m01_awvalid), .M01_AXI_awready(m01_awready),
    .M01_AXI_wdata(m01_wdata), .M01_AXI_wstrb(m01_wstrb), .M01_AXI_wlast(m01_wlast),
    .M01_AXI_wvalid(m01_wvalid), .M01_AXI_wready(m01_wready),
    .M01_AXI_bresp(m01_bresp), .M01_AXI_bvalid(m01_bvalid), .M01_AXI_bready(m01_bready),
    .M01_AXI_araddr(m01_araddr), .M01_AXI_arlen(m01_arlen), .M01_AXI_arsize(), .M01_AXI_arburst(),
    .M01_AXI_arlock(), .M01_AXI_arcache(), .M01_AXI_arprot(), .M01_AXI_arqos(),
    .M01_AXI_arvalid(m01_arvalid), .M01_AXI_arready(m01_arready),
    .M01_AXI_rdata(m01_rdata), .M01_AXI_rresp(m01_rresp), .M01_AXI_rlast(m01_rlast),
    .M01_AXI_rvalid(m01_rvalid), .M01_AXI_rready(m01_rready),
    // the burn engine's own master, driven as single-beat AXI4
    .S01_AXI_awaddr(s01_awaddr), .S01_AXI_awlen(8'd0), .S01_AXI_awsize(3'b010),
    .S01_AXI_awburst(2'b01), .S01_AXI_awlock(1'b0), .S01_AXI_awcache(4'b0011),
    .S01_AXI_awprot(3'd0), .S01_AXI_awqos(4'd0),
    .S01_AXI_awvalid(s01_awvalid), .S01_AXI_awready(s01_awready),
    .S01_AXI_wdata(s01_wdata), .S01_AXI_wstrb(s01_wstrb), .S01_AXI_wlast(1'b1),
    .S01_AXI_wvalid(s01_wvalid), .S01_AXI_wready(s01_wready),
    .S01_AXI_bresp(s01_bresp), .S01_AXI_bvalid(s01_bvalid), .S01_AXI_bready(s01_bready),
    .S01_AXI_araddr(s01_araddr), .S01_AXI_arlen(8'd0), .S01_AXI_arsize(3'b010),
    .S01_AXI_arburst(2'b01), .S01_AXI_arlock(1'b0), .S01_AXI_arcache(4'b0011),
    .S01_AXI_arprot(3'd0), .S01_AXI_arqos(4'd0),
    .S01_AXI_arvalid(s01_arvalid), .S01_AXI_arready(s01_arready),
    .S01_AXI_rdata(s01_rdata), .S01_AXI_rresp(s01_rresp), .S01_AXI_rlast(),
    .S01_AXI_rvalid(s01_rvalid), .S01_AXI_rready(s01_rready)
  );

  // ---- the responder, on the free-running oscillator ------------------------------------------
  wire clk;
  // DDR4 at the proven 750 ps setup -- dw8b custom part, declared refclk
  // 10000 ps, 749.70 ps actual = 2668 MT/s. The point is not storage: a test showed Mellanox's Flex
  // design drives 26 DDR command/address pins and ours drives none, and a test measured the
  // resulting 5.0 C gap. This makes our image do the same thing theirs does.
  //
  // Our logic runs on the MIG's extra 100 MHz MMCM output, so every existing timer keeps the rate
  // it was written for. That clock starts when the MMCM locks rather than at end-of-startup --
  // about a millisecond later, and long before the ConnectX's first I2C transaction.
  wire ddr_ui_clk, ddr_ui_rst, calib_done;
  ddr4_flex u_ddr (
    .c0_sys_clk_p            (C0_SYS_CLK_0_clk_p),
    .c0_sys_clk_n            (C0_SYS_CLK_0_clk_n),
    // sys_rst is ACTIVE HIGH and its default tie held the MIG in reset for ever --
    // init_calib_complete stuck at 0, ui_clk not running, and nothing flagged it. Drive it.
    .sys_rst                 (1'b0),
    .c0_ddr4_act_n           (C0_DDR4_0_act_n),
    .c0_ddr4_adr             (C0_DDR4_0_adr),
    .c0_ddr4_ba              (C0_DDR4_0_ba),
    .c0_ddr4_bg              (C0_DDR4_0_bg),
    .c0_ddr4_cke             (C0_DDR4_0_cke),
    .c0_ddr4_odt             (C0_DDR4_0_odt),
    .c0_ddr4_cs_n            (C0_DDR4_0_cs_n),
    .c0_ddr4_ck_t            (C0_DDR4_0_ck_t),
    .c0_ddr4_ck_c            (C0_DDR4_0_ck_c),
    .c0_ddr4_reset_n         (C0_DDR4_0_reset_n),
    .c0_ddr4_dm_dbi_n        (C0_DDR4_0_dm_n),
    .c0_ddr4_dq              (C0_DDR4_0_dq),
    .c0_ddr4_dqs_c           (C0_DDR4_0_dqs_c),
    .c0_ddr4_dqs_t           (C0_DDR4_0_dqs_t),
    .c0_init_calib_complete  (calib_done),
    .c0_ddr4_ui_clk          (ddr_ui_clk),
    .c0_ddr4_ui_clk_sync_rst (ddr_ui_rst),
    .addn_ui_clkout1         (clk),
    .c0_ddr4_aresetn         (~ddr_ui_rst),
    // AXI is present but idle: calibration, the PHY and refresh are what draw the current, and a
    // traffic generator would add a second thing to debug before the first one is known to work.
    .c0_ddr4_s_axi_awid(4'd0), .c0_ddr4_s_axi_awaddr(33'd0), .c0_ddr4_s_axi_awlen(8'd0),
    .c0_ddr4_s_axi_awsize(3'd6), .c0_ddr4_s_axi_awburst(2'b01), .c0_ddr4_s_axi_awlock(1'b0),
    .c0_ddr4_s_axi_awcache(4'd0), .c0_ddr4_s_axi_awprot(3'd0), .c0_ddr4_s_axi_awqos(4'd0),
    .c0_ddr4_s_axi_awvalid(1'b0), .c0_ddr4_s_axi_wdata(512'd0), .c0_ddr4_s_axi_wstrb(64'd0),
    .c0_ddr4_s_axi_wlast(1'b0), .c0_ddr4_s_axi_wvalid(1'b0), .c0_ddr4_s_axi_bready(1'b1),
    .c0_ddr4_s_axi_arid(4'd0), .c0_ddr4_s_axi_araddr(33'd0), .c0_ddr4_s_axi_arlen(8'd0),
    .c0_ddr4_s_axi_arsize(3'd6), .c0_ddr4_s_axi_arburst(2'b01), .c0_ddr4_s_axi_arlock(1'b0),
    .c0_ddr4_s_axi_arcache(4'd0), .c0_ddr4_s_axi_arprot(3'd0), .c0_ddr4_s_axi_arqos(4'd0),
    .c0_ddr4_s_axi_arvalid(1'b0), .c0_ddr4_s_axi_rready(1'b1),
    .c0_ddr4_s_axi_ctrl_awvalid(1'b0), .c0_ddr4_s_axi_ctrl_awaddr(32'd0),
    .c0_ddr4_s_axi_ctrl_wvalid(1'b0), .c0_ddr4_s_axi_ctrl_wdata(32'd0),
    .c0_ddr4_s_axi_ctrl_bready(1'b1), .c0_ddr4_s_axi_ctrl_arvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_araddr(32'd0), .c0_ddr4_s_axi_ctrl_rready(1'b1)
  );

  wire scl_i, sda_i, sda_oe;
  IBUF u_scl (.I(i2c_scl), .O(scl_i));
  IOBUF u_sda (.I(1'b0), .T(~sda_oe), .O(sda_i), .IO(i2c_sda));

  wire [15:0] temp_raw;
  wire [31:0] temp_dbg_unused;
  wire [7:0] drp_sel; wire [15:0] drp_val; wire drp_valid;   // 8 bits, the full DRP space
  sysmon_temp u_temp (.clk(clk), .temp_raw(temp_raw), .drp_sel(drp_sel),
                      .drp_val(drp_val), .drp_valid(drp_valid), .dbg(temp_dbg_unused));

  // The bank-90 inputs. Every one stays an input with the same pin settings as the images the
  // ConnectX accepts; their levels are readable in CR 0x02005C. F2 is the PCIe reset and is
  // buffered by the block design, not here.
  wire w_f1; IBUF u_b_f1 (.I(pin_f1), .O(w_f1));
  wire w_c3; IBUF u_b_c3 (.I(pin_c3), .O(w_c3));
  wire w_a3; IBUF u_b_a3 (.I(pin_a3), .O(w_a3));
  wire w_a4; IBUF u_b_a4 (.I(pin_a4), .O(w_a4));
  wire w_a6; IBUF u_b_a6 (.I(pin_a6), .O(w_a6));
  wire w_b4; IBUF u_b_b4 (.I(pin_b4), .O(w_b4));
  wire w_b5; IBUF u_b_b5 (.I(pin_b5), .O(w_b5));
  wire w_b6; IBUF u_b_b6 (.I(pin_b6), .O(w_b6));
  wire w_c4; IBUF u_b_c4 (.I(pin_c4), .O(w_c4));
  wire w_c5; IBUF u_b_c5 (.I(pin_c5), .O(w_c5));
  wire w_d3; IBUF u_b_d3 (.I(pin_d3), .O(w_d3));
  wire w_d5; IBUF u_b_d5 (.I(pin_d5), .O(w_d5));
  wire w_d6; IBUF u_b_d6 (.I(pin_d6), .O(w_d6));
  wire w_e1; IBUF u_b_e1 (.I(pin_e1), .O(w_e1));
  wire w_e3; IBUF u_b_e3 (.I(pin_e3), .O(w_e3));
  wire w_e5; IBUF u_b_e5 (.I(pin_e5), .O(w_e5));
  wire w_f4; IBUF u_b_f4 (.I(pin_f4), .O(w_f4));

  // E4: the acceptance waveform, replayed against F4's own edges. It is an OBUF
  // here, exactly as in the images the ConnectX accepts; `w_e4` keeps the watcher's bit position.
  wire e4_q, e4_locked;
  e4_replay u_e4 (.clk(clk), .f4_in(w_f4), .e4_out(e4_q), .locked(e4_locked));
  OBUF u_o_e4 (.I(e4_q), .O(pin_e4));
  wire w_e4 = e4_q;

  // axi_hb: the XDMA's AXI clock divided down (static = the core has no clock)
  reg [23:0] hbdiv = 24'd0; reg axi_hb = 1'b0;
  always @(posedge axi_clk) begin
    if (hbdiv == 24'd6_250_000) begin hbdiv <= 24'd0; axi_hb <= ~axi_hb; end
    else hbdiv <= hbdiv + 24'd1;
  end

  // the status bundle in CR 0x02005C, bits 28:8 (bit 28 first): F1, PERST#, C3, lnk_up, axi_hb, A6,
  // the burn engine's state (dbg_fs[0..4]), D3, the SPI sub-machine busy flag (dbg_xs[0]), D6, E1,
  // E3, E4 (our output), E5, F4, SDA, SCL
  wire [20:0] watch_pins = {w_f1, pcie_perstn, w_c3, lnk_up, axi_hb, w_a6,
                            dbg_fs[0], dbg_fs[1], dbg_fs[2], dbg_fs[3], dbg_fs[4],
                            w_d3, dbg_xs[0], w_d6, w_e1, w_e3, w_e4, w_e5, w_f4, sda_i, scl_i};

  // the writable slice of CR space -- power dial and fan tachometer -- plus the read
  // overlay that lets those registers answer instead of the captured map.
  wire [31:0] cr_wr_addr, cr_wr_data, cr_ovl_data;
  wire        cr_wr_stb, cr_ovl_hit;
  wire [15:0] cr_power;

  // c0_init_calib_complete was captured and then wired NOWHERE -- a dangling net, so
  // the only way to ask whether the memory trained was the MIG debug core over JTAG. It crosses a
  // clock boundary to get here (it is generated in ui_clk; our logic runs on the MIG's separate
  // 100 MHz MMCM output), so it gets two flops. It is a static signal that asserts once and stays,
  // which is exactly the case a two-flop synchroniser is for.
  (* ASYNC_REG = "TRUE" *) reg calib_m = 1'b0, calib_s = 1'b0;
  always @(posedge clk) begin calib_m <= calib_done; calib_s <= calib_m; end

  // declared here because cr_regs reads them; both are driven further down, by flex_hop and the
  // debug-bundle assignment
  wire e3_user_req, hop_fired, hop_fallback, hop_f1, hop_f1_blocked, hop_lnk, hop_lnk_blk, hop_wanted;
  wire [31:0] hop_bootsts, dbg_pins_w;
  cr_regs u_cr_regs (
    .clk(clk), .wr_addr(cr_wr_addr), .wr_data(cr_wr_data), .wr_stb(cr_wr_stb),
    .rd_addr(u_slave.craddr[31:0]), .hit(cr_ovl_hit), .rdata(cr_ovl_data),
    .tach_in(w_c3), .power_level(cr_power), .ddr_calib(calib_s), .bootsts(hop_bootsts), .dbg_pins(dbg_pins_w)
  );

  i2c_cr_slave u_slave (
    .clk(clk), .scl_i(scl_i), .sda_i(sda_i), .temp_raw(temp_raw),
    .drp_sel(drp_sel), .drp_val(drp_val), .drp_valid(drp_valid),
    .wr_addr(cr_wr_addr), .wr_data(cr_wr_data), .wr_stb(cr_wr_stb),
    .ovl_hit(cr_ovl_hit), .ovl_data(cr_ovl_data),
    .sda_oe(sda_oe), .dbg_state()
  );

  // ---- the load behind the power dial --------------------------------------------------
  // Without this the app's "Increase FPGA power consumption" writes a register that heats nothing.
  // 512 LFSR chains in 16 groups, gated by CR 0x24: level 0 burns none, 1023 burns all.
  wire burn_alive;
  power_burn #(.NCHAIN(512), .WIDTH(64)) u_burn (.clk(clk), .level(cr_power), .alive(burn_alive));

  // ---- dispatch: decode E3's frame code and hop when it says User ---------------
  e3_code u_e3c (.clk(clk), .e3(w_e3), .user_req(e3_user_req), .hits_o(), .frames_o());
  // Release settings of the dispatcher (the design choices are in source/docs/iprog_watchdog.md):
  //   * hop target: the User slot, 0x01000000;
  //   * TIMER_WORD 0: no configuration watchdog;
  //   * BOOTSTS gate + F1 gate: never hop again after a fallback or once User has run;
  //   * link gate: never hop once the PCIe link is up (latched early; see flex_hop);
  //   * HOP_DELAY: settle at least 200 ms (20e6 cycles) before deciding; the decision itself needs
  //     one or two 77.1 us E3 frames, and POLL keeps watching after the delay.
  wire rpt_sig = w_f1;   // F1 reporting is off; the port is unused in this configuration
  flex_hop #(.TARGET(32'h01000000), .TIMER_WORD(32'h00000000), .ARMED(1'b1), .POLL(1'b1),
             .DELAY_CYCLES(20000000),
             .HOP_ON_F1(1'b0), .HOP_ON_SILENCE(1'b0), .HOP_ON_EXT(1'b1),
             .BOOTSTS_GATE(1'b1), .BLOCK_ON_F1(1'b1), .F1_REPORT(1'b0),
             .BLOCK_ON_LNKUP(1'b1),
             .RD_REG(5'd22), .RPT_RDVAL(1'b0))
    u_hop (.clk(clk), .f1(w_f1), .i2c_act(scl_i ^ sda_i), .ext_req(e3_user_req), .rpt_i(rpt_sig), .lnk_i(lnk_up),
           .fired(hop_fired), .bootsts(hop_bootsts), .fallback_seen(hop_fallback),
           .f1_level(hop_f1), .f1_blocked(hop_f1_blocked),
           .lnk_level(hop_lnk), .lnk_blocked(hop_lnk_blk), .hop_wanted(hop_wanted));

  // everything the host needs to tell first-try from retry, in one readable word.
  // bit0 F1 (debounced)          bit1 hop suppressed by F1      bit2 hop fired
  // bit3 e3 says "boot User"     bit4 fallback seen in BOOTSTS  bits 31:8 the raw bank-90 bundle
  // bits [7:6] were spare; they now carry the link gate's state, so a run that does not hop
  // can say WHY rather than leaving it to be inferred.
  assign dbg_pins_w = {3'b000, watch_pins[20:0],
                            hop_wanted, hop_lnk_blk, hop_lnk,
                            hop_fallback, e3_user_req, hop_fired, hop_f1_blocked, hop_f1};

  // ---- the burn endpoint: BAR0+0 register, and the engine behind it ---------------------------
  wire [31:0] cmd_data;  wire cmd_valid, afull, busy, err_recov, err_fatal, full_drop;
  wire [6:0]  progress;  wire [1:0] done_cnt;

  bope_regs #(.AXI_DW(32), .AXI_IDW(1), .VERSION(16'h0264), .DEBUG_STATUS(1)) u_bope_regs (
    .aclk(axi_clk), .aresetn(axi_rstn),
    .s_awid(1'b0), .s_awaddr(m01_awaddr), .s_awlen(m01_awlen),
    .s_awvalid(m01_awvalid), .s_awready(m01_awready),
    .s_wdata(m01_wdata), .s_wstrb(m01_wstrb), .s_wlast(m01_wlast),
    .s_wvalid(m01_wvalid), .s_wready(m01_wready),
    .s_bid(), .s_bresp(m01_bresp), .s_bvalid(m01_bvalid), .s_bready(m01_bready),
    .s_arid(1'b0), .s_araddr(m01_araddr), .s_arlen(m01_arlen),
    .s_arvalid(m01_arvalid), .s_arready(m01_arready),
    .s_rid(), .s_rdata(m01_rdata), .s_rlast(m01_rlast), .s_rresp(m01_rresp),
    .s_rvalid(m01_rvalid), .s_rready(m01_rready),
    .cmd_data(cmd_data), .cmd_valid(cmd_valid), .fifo_afull(afull), .progress(progress),
    .done_cnt(done_cnt), .busy(busy), .err_recov(err_recov), .err_fatal(err_fatal),
    .dbg16(dbg16), .full_drop_o(full_drop)
  );

  bope_burn #(.FIFO_AW(14), .QSPI_BASE(32'h00040000), .PIECE(128)) u_bope_burn (
    .clk(axi_clk), .rstn(axi_rstn),
    .cmd_data(cmd_data), .cmd_valid(cmd_valid),
    .afull(afull), .progress(progress), .done_cnt(done_cnt), .busy(busy),
    .err_recov(err_recov), .err_fatal(err_fatal),
    .dbg_fs(dbg_fs), .dbg_xs(dbg_xs), .dbg16(dbg16),
    .m_awaddr(s01_awaddr), .m_awvalid(s01_awvalid), .m_awready(s01_awready),
    .m_wdata(s01_wdata), .m_wstrb(s01_wstrb), .m_wvalid(s01_wvalid), .m_wready(s01_wready),
    .m_bresp(s01_bresp), .m_bvalid(s01_bvalid), .m_bready(s01_bready),
    .m_araddr(s01_araddr), .m_arvalid(s01_arvalid), .m_arready(s01_arready),
    .m_rdata(s01_rdata), .m_rresp(s01_rresp), .m_rvalid(s01_rvalid), .m_rready(s01_rready)
  );
endmodule
