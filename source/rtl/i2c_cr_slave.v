// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// i2c_cr_slave -- answer the ConnectX-5 on the FPGA management bus, the way the Flex image does.
//
// WHY THIS EXISTS.  The CX5 is the I2C MASTER and expects a SLAVE at 7-bit 0x40 (capture
// #4 settled the direction: the master probes an empty bus and the slave APPEARS partway through as
// the FPGA finishes configuring).  When no slave answers, mlx5_core reports
//     FPGA: Status 1        (= MLX5_FPGA_STATUS_FAILURE, from the driver's own enum)
// and innova2_flex_app dies with
//     ConnectX read error addr_lo 0x90006C: Input/output error
// 0x90006C is `fpga_type` in our decoded map.  So the card that will not answer is failing exactly
// the read this module implements.
//
// WIRE PROTOCOL (corrected -- the two words are an ADDRESS, not data+opcode):
//   READ :  S 0x80 [addr_hi BE32][addr_lo BE32]  Sr 0x81 [data BE32] N P     (8 written, 4 read)
//   WRITE:  S 0x80 [addr_hi BE32][addr_lo BE32][data BE32] P                 (12 written, 0 read)
//
// HAZARDS THIS OBEYS (lists four; three are structural and handled here):
//  1. SDA MUST BE BIDIRECTIONAL and OPEN-DRAIN.  We drive a 0 only by enabling an output whose
//     value is constant 0; every other instant the pad is released.  A stuck-low SDA hangs the
//     CX5's master, so `sda_oe` is cleared on STOP, on address mismatch, and by the watchdog.
//  2. ANSWERING PARTIALLY IS WORSE THAN NOT ANSWERING -- the CX5 firmware has isr_fpga_i2c_failure
//     and an FPGA watchdog.  So this is READ-ONLY bring-up: identity registers answer, writes are
//     ACKed and DISCARDED, and every unmapped address returns the vendor's own 0x8BADF00D sentinel.
//     Discarding writes is safe *because* of that sentinel: fpga_field_write is a read-modify-write,
//     so a discarded write is read back as 0x8BADF00D, and the two app poll loops that consume such
//     a readback both terminate on it (see cr_read below).  The app's gate -- fpga_type at 0x90006C
//     -- is a pure read, so nothing it needs depends on a write sticking.
//  3. NEVER STRETCH SCL.  This module never drives SCL at all -- it is an input here.  A slave that
//     holds SCL low is indistinguishable from a dead bus.
//  4. WATCHDOG.  If SCL stays low longer than ~2 ms the master is gone or wedged; release SDA and
//     resynchronise.  Without this, one desync could leave SDA held low for ever.
//
// Everything is in the `clk` domain (the 100 MHz board oscillator, which free-runs regardless of
// PCIe) with two-flop synchronisers on SCL/SDA.  I2C is ~100 kHz so oversampling is ample.
// =================================================================================================
module i2c_cr_slave #(
  parameter [6:0]  I2C_ADDR    = 7'h40,
  // UNUSED: the identity block (0x900000-0x900008) is answered from cr_map_gen.v, not from these.
  parameter [31:0] IMAGE_VER   = 32'h0000DD02,  // 0x900000 image_version -- app prints it
  parameter [31:0] IMAGE_DATE  = 32'h28092026,  // 0x900004 BCD DDMMYYYY
  parameter [31:0] IMAGE_TIME  = 32'h00083000,  // 0x900008 BCD 00HHMMSS
  parameter [31:0] FPGA_DEVICE = 32'h00000004,  // 0x90000C read FIRST at boot
  parameter [31:0] ADABE_VER   = 32'h0000000A,  // 0x900010 read FIRST at boot
  parameter [31:0] FPGA_TYPE   = 32'h00000002,  // 0x90006C the gate innova2_flex_app reads
  parameter integer WDT_CYCLES = 200000         // ~2 ms at 100 MHz
)(
  input  wire clk,
  input  wire scl_i,      // from the pad (input only -- we never drive SCL)
  input  wire sda_i,      // from the pad
  input  wire [15:0] temp_raw,  // live SYSMONE4 die temperature, raw ADC code (see sysmon_temp.v)
  // the vendor's aliased sensor page IS the SYSMON DRP file at 0x400 + 4*addr -- verified by
  // decoding the captured constants and comparing against a live JTAG read of this card's SYSMON
  // (VCCINT/VCCAUX/VCCBRAM agreed to ~2 mV). So serve it from THIS card's sensors where we have a
  // reading, and fall through to the captured map where we do not.
  output wire [7:0]  drp_sel,
  input  wire [15:0] drp_val,
  input  wire        drp_valid,
  // writes are no longer discarded. Bytes 8..11 of a WRITE transaction are the data
  // word; this hands the completed {address, data} pair to cr_regs, which owns the few registers
  // the app actually writes. Everything else still falls through to the captured map, so the 8634
  // addresses that answered before answer identically.
  output reg  [31:0] wr_addr,
  output reg  [31:0] wr_data,
  output reg         wr_stb,
  input  wire        ovl_hit,      // cr_regs claims this address...
  input  wire [31:0] ovl_data,     // ...and this is its value
  output wire sda_oe,     // 1 = drive the pad LOW (open-drain); 0 = release
  output wire [7:0] dbg_state
);
  // ---- synchronise the bus -----------------------------------------------------------------
  (* ASYNC_REG="TRUE" *) reg s1=1'b1, s2=1'b1, d1=1'b1, d2=1'b1;
  reg s3=1'b1, d3=1'b1;
  always @(posedge clk) begin
    s1<=scl_i; s2<=s1; s3<=s2;
    d1<=sda_i; d2<=d1; d3<=d2;
  end
  wire scl_rise =  s2 & ~s3;
  wire scl_fall = ~s2 &  s3;
  // START/STOP are SDA edges while SCL is HIGH
  wire start_cond = s2 & s3 & ~d2 &  d3;   // SDA 1->0 while SCL high
  wire stop_cond  = s2 & s3 &  d2 & ~d3;   // SDA 0->1 while SCL high

  // ---- watchdog: SCL stuck low means the master is gone; never hold SDA ---------------------
  reg [17:0] wdt = 18'd0;
  wire wdt_fire = (wdt == WDT_CYCLES[17:0]);
  always @(posedge clk) begin
    if (s2) wdt <= 18'd0;              // SCL high -- bus alive
    else if (!wdt_fire) wdt <= wdt + 18'd1;
  end

  // ---- slave FSM ---------------------------------------------------------------------------
  // Bit timing is explicit: bcnt counts SCL PERIODS within a byte, 0..7 are the data bits and
  // PERIOD 8 IS THE ACK SLOT.  A bit is sampled on the rising edge of its period; every decision
  // and every shift happens on the falling edge that ENDS a period.  The first version set and
  // cleared an `ack_drive` flag across states and got the slot off by one edge -- the testbench
  // caught it (address byte ACKed, the eight CR-address bytes not).
  localparam ST_IDLE=2'd0, ST_ADDR=2'd1, ST_RX=2'd2, ST_TX=2'd3;
  reg [1:0]  st    = ST_IDLE;
  reg [3:0]  bcnt  = 4'd0;
  reg [7:0]  sh    = 8'd0;
  reg [3:0]  bytn  = 4'd0;      // byte index within the transaction (0..7 = the CR address)
  reg        rd_xfer = 1'b0;
  reg [63:0] craddr = 64'd0;
  reg [31:0] wsh   = 32'd0;      // data bytes of a WRITE, assembled MSB first
  reg [31:0] shout  = 32'd0;    // MSB-first transmit register (4 bytes = one CR word)
  reg        ack_lo = 1'b0;     // drive SDA low for OUR ack, during period 8

  // UNIMPLEMENTED = 0x8BADF00D, NOT ZERO.   read Mellanox's own Flex image over CR space:
  // every word of 0x900014..0x900070 except the gate returns 0x8BADF00D, and so does 0x900028 in low
  // CR space.  It is their "address not implemented" sentinel, so returning it is what the real
  // image does -- and it means we need not model the address space at all, only the few registers
  // that matter.  The earlier default of 0 was a guess and was wrong.
  //
  // It is also, by luck, the SAFE default.  Two app loops poll a register until a bit changes:
  //     fan   : while (fpga_field_read(tacho_test_done /*0x420 bit0*/) == 0)
  //     bist  : while (fpga_field_read(bist_status     /*0x20004 [3:2]*/) == 1)
  // 0x8BADF00D has bit0 = 1 and bits[3:2] = 3, so both loops TERMINATE against the sentinel instead
  // of hanging.  Returning 0 would have hung the fan poll for ever.  Neither result is meaningful,
  // which is the honest outcome for a register this image does not implement -- we are not faking a
  // passing DDR BIST.
  // ---- CR read data -------------------------------------------------------------------------
  // the map used to be 19 addresses hand-copied from the vendor app's #define table.
  // `cr_sweep.py` asked the hardware about the address SPACE instead of about that list, and
  // Mellanox's Flex image answered 8634 addresses -- a whole aliased sensor block, a BIST block, a
  // fan block, two identical units at 0x40000/0x50000, another at 0x60000, and two signature words
  // (0x68 = 0xA5A5A5A5, 0x6C = 0x01234567) that no header mentions. cr_map_gen.v is GENERATED from
  // that capture by a generator script (not included), which replays its own output against every captured
  // address and refuses to emit unless all 8634 match.
  wire [31:0] cr_map_d;
  cr_map u_cr_map (.a(craddr[31:0]), .d(cr_map_d));

  // The die temperature is the ONE value that must not be a captured constant: the
  // sentinel decodes to 197 C through fpga_get_therm and a supervisor should fail a card reporting
  // that -- but a frozen plausible constant is the same lie with better manners. Report SYSMONE4.
  // Page offset 0x400 inside the aliased 0x8000-0xFFFF block is fpga_temperature.
  wire in_sensor_page = (craddr[31:16] == 16'h0000) && (craddr[15:12] >= 4'h8);
  wire cr_is_temp = in_sensor_page && (craddr[11:0] == 12'h400);
  // the DRP window is 0x400..0x7FC -> DRP 0x00..0xFF, not just 0x400..0x4FC.
  //
  // And it is decoded on craddr[10:0], not craddr[11:0], because the 4 KB page is TWO ALIASED 2 KB
  // HALVES -- measured: the vendor capture's 0x000-0x7FF and 0x800-0xFFF agree on 69 of 78 shared
  // offsets, and the 9 that differ are live sensor words read a moment apart. Decoding on [10:0]
  // makes 0xC00-0xFFF answer live too, for free, instead of from the captured table.
  wire cr_is_drp  = in_sensor_page && craddr[10] && (craddr[1:0] == 2'b00) && drp_valid;
  assign drp_sel  = craddr[9:2];
  // Priority: temperature (live), then anything cr_regs owns, then the captured map.
  // Priority: live temperature, then any live DRP word, then the writable registers, then the map.
  wire [31:0] cr_value = cr_is_temp ? {16'h0000, temp_raw}
                       : cr_is_drp  ? {16'h0000, drp_val}
                       : ovl_hit    ? ovl_data
                                    : cr_map_d;

  // COUNT BITS ON THE SAMPLING EDGE, NOT THE FALLING EDGE.  A START is followed immediately by
  // the falling edge that opens the first data period; counting falling edges consumed that one,
  // so every byte came in one bit short (sh = byte>>1, address 0x80 read as 0x20 -> never matched).
  // The testbench trace showed it directly: FALL bcnt=0->1 before the first RISE.
  // Now: bcnt = number of data bits received/sent so far, advanced where the bit is transferred;
  // `in_ack` marks the 9th period, which belongs to the acknowledge and to nobody's bit count.
  reg in_ack = 1'b0;

  always @(posedge clk) begin
    wr_stb <= 1'b0;                                   // one cycle per completed write
    if (wdt_fire || stop_cond) begin
      st <= ST_IDLE; ack_lo <= 1'b0; bcnt <= 4'd0; bytn <= 4'd0; in_ack <= 1'b0;
    end else if (start_cond) begin
      // craddr is DELIBERATELY preserved -- the read half arrives as a repeated START and asks
      // for the address sent before it.
      st <= ST_ADDR; bcnt <= 4'd0; ack_lo <= 1'b0; sh <= 8'd0; in_ack <= 1'b0;
    end else begin
      // ---------------- sampling edge ----------------
      if (scl_rise) begin
        if ((st == ST_ADDR || st == ST_RX) && !in_ack && bcnt < 4'd8) begin
          sh   <= {sh[6:0], d2};
          bcnt <= bcnt + 4'd1;
        end else if (st == ST_TX && in_ack) begin
          if (d2) st <= ST_IDLE;                  // master NACKed -> transfer over
        end
      end
      // ---------------- edge that ends a period ----------------
      if (scl_fall) begin
        if (st == ST_ADDR || st == ST_RX) begin
          if (!in_ack && bcnt == 4'd8) begin
            in_ack <= 1'b1;                       // the 9th period is the ACK slot
            if (st == ST_ADDR) begin
              if (sh[7:1] == I2C_ADDR) begin
                ack_lo  <= 1'b1;
                rd_xfer <= sh[0];
                if (sh[0]) shout <= cr_value;
              end else begin
                ack_lo <= 1'b0; st <= ST_IDLE; in_ack <= 1'b0;   // not us: off the bus
              end
            end else begin
              ack_lo <= 1'b1;                     // ACK every byte written to us
              if (bytn <= 4'd7) craddr <= {craddr[55:0], sh};
              else if (bytn <= 4'd11) wsh <= {wsh[23:0], sh};   // bytes 8..11 are the data word
              bytn <= bytn + 4'd1;
              // The 12th byte completes a WRITE (8 address + 4 data). Commit on its ACK rather
              // than on STOP: the CX5 sometimes leaves the bus idle before the stop, and a pulse
              // tied to STOP would land after the app has already moved on.
              if (bytn == 4'd11) begin
                wr_addr <= craddr[31:0];
                wr_data <= {wsh[23:0], sh};
                wr_stb  <= 1'b1;
              end
            end
          end else if (in_ack) begin
            in_ack <= 1'b0; ack_lo <= 1'b0; bcnt <= 4'd0;
            if (st == ST_ADDR) begin
              st   <= rd_xfer ? ST_TX : ST_RX;
              bytn <= 4'd0;
            end
          end
        end else if (st == ST_TX) begin
          if (in_ack) begin
            in_ack <= 1'b0; bcnt <= 4'd0;         // master ACKed -> send the next byte
          end else begin
            shout <= {shout[30:0], 1'b0};
            bcnt  <= bcnt + 4'd1;
            if (bcnt == 4'd7) in_ack <= 1'b1;     // 8 bits sent; next period is master's ack
          end
        end
      end
    end
  end

  // Open drain: drive LOW for an ACK, or while transmitting a 0.  Released otherwise.
  assign sda_oe = ack_lo | ((st == ST_TX) & ~in_ack & ~shout[31]);
  assign dbg_state = {rd_xfer, bytn[2:0], 2'b00, st};
endmodule
