// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// sysmon_temp -- read the KU15P die temperature from SYSMONE4 over DRP.
//
// WHY CR 0x8400 MUST CARRY A REAL VALUE: the app computes
//     degC = (raw*508)>>16 - 279
// so the "unimplemented" sentinel 0x8BADF00D gives 197 C and a stuck 0 gives -279 C. Both are
// implausible enough to fail a supervisor's health check, which is the suspected cause of the
// ConnectX marking our flashed Flex image FAILED at boot.
//
// v2. v1 shipped with `SYSMONE4 instances = 1` passing in the build gate and STILL
// returned 0 on hardware: the primitive was instantiated but never answered, DRDY never asserted,
// and the FSM sat in S_WAIT for ever. Presence is not function. Four changes:
//   1. RESET is PULSED at start-up instead of being tied low for ever. SYSMONE4 needs a reset
//      before its sequencer runs; v1 never gave it one.
//   2. S_WAIT TIMES OUT and retries. A single missed DRDY can no longer wedge the reader
//      permanently -- the failure becomes transient rather than terminal.
//   3. INIT_40/41/42 are set EXPLICITLY (continuous sequencer, temperature channel, DCLK/8)
//      rather than relying on defaults that evidently did not start a conversion.
//   4. DIAGNOSTICS are exported so the next hardware read says WHY rather than just "0".
//      Without this, each iteration costs a full build + JTAG + read cycle to learn nothing.
// =================================================================================================
// v3 -- SWEEP THE WHOLE DRP FILE, not just temperature.
//
// The vendor's aliased sensor page at CR 0x8400 turns out to BE the SYSMON DRP register file, one
// 32-bit word per DRP address at 0x400 + 4*addr. Decoding the captured constants and comparing them
// against a live JTAG read of this card's SYSMON settled it:
//     +0x400 (DRP 0x00) 0x9D1E -> 34.0 C     live TEMPERATURE 28.7 C
//     +0x404 (DRP 0x01) 0x4879 -> 0.849 V    live VCCINT      0.847 V
//     +0x408 (DRP 0x02) 0x9B3B -> 1.819 V    live VCCAUX      1.816 V
//     +0x418 (DRP 0x06) 0x4874 -> 0.849 V    live VCCBRAM     0.847 V
// Voltages agree to ~2 mV; the 5 C temperature difference is the vendor-vs-ours thermal gap.
//
// So the page can be answered from this card's own sensors instead of replayed from another card's
// capture. This sweeps DRP 0x00..0x3F continuously into a small file that i2c_cr_slave reads.
module sysmon_temp (
  input  wire        clk,
  output reg  [15:0] temp_raw,   // DRP 0x00 raw ADC code, as CR 0x8400 carries it
  input  wire [7:0]  drp_sel,    // which DRP address the CR responder is being asked for
  output wire [15:0] drp_val,    // its most recent value (0 until first swept)
  output wire        drp_valid,  // that address has been read at least once
  output wire [31:0] dbg         // {drdy_cnt[7:0], timeout_cnt[7:0], state[7:0], 6'b0, rst_done, drdy}
);
  // the file covers the WHOLE 8-bit DRP space, not just 0x00-0x3F.
  //
  // The sensor page is 0x400 + 4*drp_addr, and the vendor capture makes that plain: 0x500 decodes
  // to DRP 0x40-0x7F and holds SYSMONE4's CONFIGURATION and alarm-threshold registers (0x500=0x2000
  // is Config Reg 0, 0x520=0x0900 the sequencer channel list, 0x540 onwards the alarm limits), and
  // 0x600/0x700 are DRP 0x80-0xFF, which read 0xFFFF because they are unimplemented. All of it is
  // the Xilinx SYSMON block's own register file -- OUR part has the same one -- so sweeping the
  // full range replaces ~75 captured constants with live readings from this die. What is left in
  // the table for this page is 3 words at page offsets 0x004/0x008/0x060.
  //
  // Values will NOT match the vendor's here, and that is the point: DRP 0x40-0x43 report the
  // configuration WE set (INIT_40/41/42) and 0x50-0x6B our alarm limits. The page stops being a
  // replay of their SYSMON and becomes a readout of ours.
  reg [15:0] drp_file [0:255];
  reg [255:0] drp_seen = 256'd0;
  reg [7:0]  sweep = 8'd0;
  assign drp_val   = drp_file[drp_sel];
  assign drp_valid = drp_seen[drp_sel];
  integer i_init;
  initial for (i_init = 0; i_init < 256; i_init = i_init + 1) drp_file[i_init] = 16'd0;
  // ---- start-up reset pulse: hold RESET high a while after configuration, then release --------
  reg [9:0] rst_ct   = 10'd0;
  reg       rst_done = 1'b0;
  reg       sysmon_rst = 1'b1;
  always @(posedge clk) begin
    if (!rst_done) begin
      rst_ct <= rst_ct + 10'd1;
      if (rst_ct == 10'd511) begin sysmon_rst <= 1'b0; end
      if (rst_ct == 10'd1023) begin rst_done <= 1'b1; end
    end
  end

  reg        den = 1'b0;
  reg [1:0]  st  = 2'd0;
  reg [11:0] wct = 12'd0;
  reg [7:0]  drdy_cnt = 8'd0, to_cnt = 8'd0;
  wire [15:0] do_bus;
  wire        drdy;

  localparam S_IDLE=2'd0, S_REQ=2'd1, S_WAIT=2'd2, S_HOLD=2'd3;

  always @(posedge clk) begin
    if (!rst_done) begin
      st <= S_IDLE; den <= 1'b0; wct <= 12'd0;
    end else begin
      case (st)
        S_IDLE: begin den <= 1'b1; st <= S_REQ; wct <= 12'd0; end
        S_REQ:  begin den <= 1'b0; st <= S_WAIT; wct <= 12'd0; end
        S_WAIT: begin
          if (drdy) begin
            drp_file[sweep] <= do_bus;          // every address lands in the file
            drp_seen[sweep] <= 1'b1;
            sweep <= sweep + 8'd1;                   // next address on the next pass
            if (sweep == 8'd0) temp_raw <= do_bus;   // 0x00 alone feeds the dedicated output;
                                                     // without this guard temp_raw would carry
                                                     // whichever address was swept last
            if (drdy_cnt != 8'hFF) drdy_cnt <= drdy_cnt + 8'd1;
            st <= S_HOLD; wct <= 12'd0;
          end else if (wct == 12'hFFF) begin
            // TIMEOUT. v2 "gave up and retried" -- but it retried THE SAME ADDRESS, because `sweep`
            // only advances inside the drdy branch above. Any DRP address that never asserts DRDY
            // therefore parked the sweep on itself for ever, and every value already in the file
            // froze at whatever it last held.
            //
            // That is not a theory: read CR 0x8400 thirteen times over 240 s and then
            // seven times over 120 s and got bit-identical samples every time (0x9BBF, then 0x9B73),
            // while a JTAG read of the SAME SYSMON registers returned 28.7 C against our pinned
            // 31.56 C -- the registers had moved on, our copy had not. A frozen sensor that reports
            // a BELIEVABLE number is the worst failure available here: it invalidated this session's
            // thermal comparison, the 5 C vendor gap and the power-dial A/B, all of
            // which read like measurements at the time.
            //
            // So: advance on timeout too. A silent address then costs one slot in the file instead
            // of the whole instrument.
            if (to_cnt != 8'hFF) to_cnt <= to_cnt + 8'd1;
            sweep <= sweep + 8'd1;
            st <= S_IDLE;
          end else wct <= wct + 12'd1;
        end
        S_HOLD: if (wct == 12'hFFF) st <= S_IDLE; else wct <= wct + 12'd1;
      endcase
    end
  end

  assign dbg = {drdy_cnt, to_cnt, 6'b0, st, 6'b0, rst_done, drdy};

  // INIT_40 : CFG0 -- channel 0x00 (temperature), no averaging
  // INIT_41 : CFG1 -- sequencer bits[15:12] = 0x2 (continuous), alarms disabled
  // INIT_42 : CFG2 -- DCLK divider = 8 (100 MHz / 8 = 12.5 MHz ADCCLK, inside the 26 MHz limit)
  //
  // INIT_48/INIT_49: THE SEQUENCER'S CHANNEL LIST. Leaving these out is what
  // made every temperature this project ever read a frozen number. INIT_41 selects continuous
  // SEQUENCE mode, and the sequence is whatever SEQ0/SEQ1 enable -- which defaulted to nothing.
  // The ADC converted once in default mode at power-up, DRP 0x00 latched a believable value, and
  // then nothing ever updated it again.
  //
  // HOW IT WAS FINALLY PINNED DOWN, after one wrong fix: the max/min registers, which hardware
  // maintains on EVERY conversion, were still at their power-on defaults --
  //     DRP 0x00 (current) = 0x9CC4   DRP 0x20 (max) = 0x0000   DRP 0x24 (min) = 0xFFFF
  // A cycling ADC cannot leave max at 0x0000 and min at 0xFFFF. That is proof from our own CR path
  // with no external tool involved. (The earlier JTAG comparison was NOT proof: Vivado's
  // refresh_hw_sysmon appears to set the SYSMON up for its own read, so its 28.7 C was a freshly
  // triggered conversion and said nothing about our configuration. It sent me to the wrong fix.)
  //
  // Those two registers are also the cheapest liveness check there is -- max==0x0000 and
  // min==0xFFFF means the sensor is dead, whatever DRP 0x00 happens to say.
  //   INIT_48 = bit0 calibration | bit8 temperature | bit9 VCCINT | bit10 VCCAUX | bit14 VCCBRAM
  //   INIT_49 = the VAUXP/N auxiliary channels -- none are wired on this card
  SYSMONE4 #(
    .INIT_40 (16'h0000),
    .INIT_41 (16'h2000),
    .INIT_42 (16'h0800),
    .INIT_48 (16'h4701),
    .INIT_49 (16'h0000),
    .SIM_MONITOR_FILE ("design.txt")
  ) u_sysmon (
    .DCLK   (clk),
    .DEN    (den),
.DADDR  (sweep),            // the full 8-bit DRP space, not just 0x00-0x3F
    .DI     (16'h0000),
    .DWE    (1'b0),
    .DO     (do_bus),
    .DRDY   (drdy),
    .RESET  (sysmon_rst),
    .VP     (1'b0),
    .VN     (1'b0),
    .CONVSTCLK (1'b0),
    .I2C_SCLK  (1'b1),
    .I2C_SDA   (1'b1)
  );
endmodule
