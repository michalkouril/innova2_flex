// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// cr_regs -- the WRITABLE part of the ConnectX CR space, and the fan tachometer behind it.
//
// Until now i2c_cr_slave ACKed writes and threw them away, which was the right call for read-only
// bring-up: a discarded write reads back as the vendor's 0x8BADF00D sentinel and the app's poll
// loops terminate on it. But three menu items in innova2_flex_app are WRITES, so they cannot work
// against a responder that forgets:
//
//   "Increase FPGA power consumption"   fpga_power   0x24, bits [15:0]   (read back masked to 0x3FF)
//   fan speed measurement               tacho_test_start_stop_n 0x41C bit0
//                                       tacho_test_done         0x420 bit0
//                                       tacho_counters          0x418 = {seconds[7:0], pulses[23:0]}
//                                       tacho_frequency_usec    0x40C [19:0]
//                                       tacho_polarity          0x410 bit0
//                                       fan_speed               0x414 [6:0]
//
// THE FAN SEQUENCE, from fpga_access.c:fpga_get_fan_rpm() -- this is the contract, not a guess:
//     write start_stop_n = 1 ; sleep(3) ; write start_stop_n = 0 ; poll done ; read counters
//     rpm = (pulses/2) * 60 / seconds
// So the register must COUNT while the flag is 1, latch seconds alongside pulses, and raise `done`
// when the flag falls. Reporting a plausible constant would repeat an earlier mistake -- a lie with
// better manners -- so the pulses come from a real pin and the app's arithmetic is left alone.
//
// WHICH PIN. Not documented anywhere we have. C3 is the only bank-90 input whose measured activity
// looks like a tachometer: 4,322 transitions in 10 s, i.e. ~216 pulses/s, which through the
// app's own formula is ~6,500 RPM -- a plausible blower. It is a CANDIDATE, so it is a parameter,
// and if the number the app prints is nonsense the pin is what to change, not the arithmetic.
// =================================================================================================
module cr_regs #(
  parameter integer CLK_HZ = 100000000
)(
  input  wire        clk,
  // write port from the I2C responder
  input  wire [31:0] wr_addr,
  input  wire [31:0] wr_data,
  input  wire        wr_stb,
  // read overlay: hit=1 means THIS block owns the address and `rdata` is the answer
  input  wire [31:0] rd_addr,
  output reg         hit,
  output reg  [31:0] rdata,
  // the tachometer input (a candidate pin, see above) and the power dial
  input  wire        tach_in,
  output wire [15:0] power_level,
  // the MIG's init_calib_complete, already synchronised to clk by the caller.
  // A test measured where Mellanox's own Flex reports this -- CR 0x020054 reads 1 on a card whose
  // memory trained and 0 on one whose did not -- so answer at THAT address rather than inventing a
  // private one. A host that already knows how to grade a vendor card then grades ours unchanged.
  input  wire        ddr_calib,
  // the latched BOOTSTS word from flex_hop, so the gate can be VERIFIED from the host
  // rather than inferred from behaviour. 0x020058 is ours, not the vendor's -- both cards read 0
  // there in the sweep, so nothing real is being masked.
  input  wire [31:0] bootsts,
  // the hop state and the bank-90 pin levels (see flex_burn_top), readable on any boot where this
  // image is resident
  input  wire [31:0] dbg_pins
);
  localparam [31:0] A_POWER = 32'h00000024, A_TFREQ = 32'h0000040C, A_TPOL = 32'h00000410,
                    A_FSPD  = 32'h00000414, A_TCNT  = 32'h00000418, A_TSTART = 32'h0000041C,
                    A_TDONE = 32'h00000420, A_CALIB = 32'h00020054,
                    A_BSTS  = 32'h00020058, A_PINS = 32'h0002005C;

  reg [15:0] power   = 16'd0;
  reg [19:0] tfreq   = 20'd0;
  reg        tpol    = 1'b0;
  reg [6:0]  fanspd  = 7'd0;
  reg        running = 1'b0, done = 1'b0;
  reg [23:0] pulses  = 24'd0;
  reg [7:0]  seconds = 8'd0;
  reg [23:0] cnt_lat = 24'd0;
  reg [7:0]  sec_lat = 8'd0;

  assign power_level = power;

  // tach edge detect, polarity-selected. Two flops first: this pin is asynchronous to our clock and
  // a metastable sample here would show up as phantom fan pulses.
  reg t1 = 1'b0, t2 = 1'b0, t3 = 1'b0;
  always @(posedge clk) begin t1 <= tach_in; t2 <= t1; t3 <= t2; end
  wire tach_edge = tpol ? (~t2 & t3) : (t2 & ~t3);

  reg [31:0] sec_div = 32'd0;

  always @(posedge clk) begin
    if (wr_stb) begin
      case (wr_addr)
        A_POWER:  power  <= wr_data[15:0];
        A_TFREQ:  tfreq  <= wr_data[19:0];
        A_TPOL:   tpol   <= wr_data[0];
        A_FSPD:   fanspd <= wr_data[6:0];
        A_TSTART: begin
                    if (wr_data[0] && !running) begin          // start: a fresh measurement
                      running <= 1'b1; done <= 1'b0;
                      pulses  <= 24'd0; seconds <= 8'd0; sec_div <= 32'd0;
                    end else if (!wr_data[0] && running) begin // stop: latch and report done
                      running <= 1'b0; done <= 1'b1;
                      cnt_lat <= pulses; sec_lat <= seconds;
                    end
                  end
        A_TDONE:  if (wr_data[0] == 1'b0) done <= 1'b0;        // the app never clears it; be tidy
        default: ;
      endcase
    end
    if (running) begin
      if (tach_edge && pulses != 24'hFFFFFF) pulses <= pulses + 24'd1;
      if (sec_div == CLK_HZ - 1) begin
        sec_div <= 32'd0;
        if (seconds != 8'hFF) seconds <= seconds + 8'd1;
      end else sec_div <= sec_div + 32'd1;
    end
  end

  // read overlay. Everything not listed here falls through to the captured map, so the 8634
  // addresses that already answer keep answering exactly as before.
  always @(*) begin
    hit   = 1'b1;
    case (rd_addr)
      A_POWER:  rdata = {16'd0, power};
      A_TFREQ:  rdata = {12'd0, tfreq};
      A_TPOL:   rdata = {31'd0, tpol};
      A_FSPD:   rdata = {25'd0, fanspd};
      // while a measurement runs, report the live counters; afterwards, the latched pair the app
      // is about to divide. seconds in [31:24], pulses in [23:0] -- fpga_get_fan_rpm's own split.
      A_TCNT:   rdata = running ? {seconds, pulses} : {sec_lat, cnt_lat};
      A_TSTART: rdata = {31'd0, running};
      A_TDONE:  rdata = {31'd0, done};
      // Read-only, and 0 in a build with no MIG -- which is the truth there, not a placeholder.
      // NOTE: the captured map this overlays came from Host A's card, whose DDR is
      // defective, so the REPLAYED neighbours of this address (0x020004 status, 0x020108 sized
      // capacity) still carry that card's zeros. Only 0x020054 is live.
      A_CALIB:  rdata = {31'd0, ddr_calib};
      // bit1 is 0_FALLBACK: 1 means this configuration arrived via a fallback and the hop was
      // suppressed. A host reading 0x00000002 here knows the gate did its job.
      A_BSTS:   rdata = bootsts;
      // bit0 F1, bit1 hop-blocked-by-F1, bit2 hop fired, bit3 e3 user_req, then the raw watch bundle
      A_PINS:   rdata = dbg_pins;
      default:  begin rdata = 32'h8BADF00D; hit = 1'b0; end
    endcase
  end
endmodule
