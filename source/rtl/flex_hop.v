// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// =================================================================================================
// flex_hop -- perform the Flex -> User transition from inside the Flex image, via ICAPE3.
//
// WHY. attributed the hop to the ConnectX because Mellanox's Flex image carries
// no IPROG *configuration packet*. But eliminated the last channel the ConnectX could have
// commanded it on: it drives no bank-90 pin, issues no I2C at boot, and does not clock the JTAG TAP
// (TCK counter read 2 at boot against 162,097 under a positive control). So the hop is most likely
// done by the Flex image itself at RUNTIME through ICAPE3 -- which leaves no trace in the bitstream,
// which is exactly why the sweep found nothing.
//
// This also explains the operational cost we have been paying all session: with our image in the
// Flex slot, selecting User lands in FACTORY_FAILOVER and needs a JTAG rescue plus a 16 MB
// restore. Not because the User slot is broken -- it is byte-perfect -- but because nothing ever
// performs the hop.
//
// HONEST CAVEAT ON THE TRIGGER. F1 is the only pin the ConnectX is known to drive, so it is the
// natural selector -- but in every capture we have it reads 1 whether User or Flex is scheduled
//. So this trigger is NOT known to discriminate. It is parameterised for that reason, and
// the experiment is what settles it: schedule User, and see whether the card reaches Oper image 0.
//
// The ICAP bit convention (it cost this project a long hunt):
// ICAPE3.I takes each byte BIT-REVERSED, byte lanes in place. Getting it wrong makes the ICAP
// silently inert -- it accepts the words and does nothing.
// =================================================================================================
module flex_hop #(
  parameter [31:0]  TARGET       = 32'h01000000,  // per-device address of the User slot
  parameter         HOP_WHEN_F1  = 1'b1,          // hop when f1 equals this
  parameter integer DELAY_CYCLES = 20000000,      // ~200 ms at 100 MHz: let the board settle first
  parameter         ARMED        = 1'b1,
  // POLL keeps WATCHING F1 instead of deciding once. The one-shot version sampled at
  // t+200 ms and latched "stay" forever -- which was harmless while every image of ours was
  // REJECTED and F1 sat at 1 from the start, and became fatal the moment got us
  // ACCEPTED: the ConnectX then says "stay" (F1=0) and, if it ever raises the request later, a
  // one-shot has already stopped looking. Mellanox's Flex is accepted AND hops when User is
  // selected, so the request must arrive at some point; watching costs nothing and cannot miss it.
  parameter         POLL         = 1'b1,
  // the SILENCE trigger. A test measured the asymmetry that F1 never showed: with Flex
  // scheduled the ConnectX POLLS our CR space over I2C (82 STARTs in one boot window, our responder
  // answering); with User scheduled it issues NOTHING AT ALL -- no I2C, no pin change anywhere.
  // Silence is therefore the signal, and it needs no channel we do not already have.
  //
  // Note it must be "no activity EVER", not "activity then silence": in the User case the ConnectX
  // never starts, so a "stopped talking" detector would sit waiting forever for a first byte.
  // Any I2C edge sets a sticky inhibit; absence for SILENCE_CYCLES after the settle delay hops.
  parameter         HOP_ON_SILENCE = 1'b0,
  parameter integer SILENCE_CYCLES = 40000000,    // 400 ms at 100 MHz
  // the trigger that is actually MEASURED to discriminate. A test decoded the ConnectX's
  // E3 frame: one long pulse per frame means stay, long + a short partner means boot User. e3_code
  // does the decode; this just consumes its verdict. HOP_ON_F1 exists so that trigger can be turned
  // off -- a test showed F1 reads 0 in every Flex-slot condition, so leaving it armed alongside
  // would mean never hopping, and leaving HOP_WHEN_F1 at 0 would mean hopping instantly.
  parameter         HOP_ON_F1  = 1'b1,
  parameter         HOP_ON_EXT = 1'b0,
  // ARM THE CONFIGURATION WATCHDOG BEFORE HOPPING.
  //
  // On 2026-09-15 this hop killed the host. The card was scheduled to User, the User slot held an
  // image that would not configure, and our IPROG landed on it with no watchdog armed: DONE stayed
  // 0 for ever, the FPGA presented nothing coherent on PCIe, and Host C hung in POST on every boot
  // afterwards -- unrecoverable without JTAG, because changing the image selection needs a booted
  // host. The ConnectX reported oper=2(FACTORY_FAILOVER) status=1(FAILURE) and that was that.
  //
  // Mellanox's golden image never takes that risk. Read straight out of factory_destriped.bin:
  //     AA995566  20000000 20000000
  //     30022001  40100000      <- TIMER (register 17), bit30 = TIMER_CFG_MON, count 0x100000
  //     30020001  03000000      <- WBSTAR = the Flex slot
  //     30008001  0000000F      <- CMD = IPROG
  // It arms the watchdog FIRST, then hops. If the image it jumps to fails to configure in time the
  // device falls back to address 0, whose header sends it to the Flex slot -- so a bad target
  // costs a delay, not a dead card. We do exactly the same thing here.
  //
  // bit30 is what enables the monitor; set TIMER_WORD to 32'h00000000 to build without a watchdog.
  // The sequence LENGTH does not change either way, so there is no conditional packet to get wrong.
  parameter [31:0]  TIMER_WORD = 32'h40100000,
  // DO NOT RE-HOP AFTER A FALLBACK.
  //
  // armed the watchdog, which stopped a bad User image from hanging the host. But it did not
  // make the card come to rest in Flex, and the reason is this module. The ConnectX's image
  // selection is latched in ITS nvram, so after a fallback E3 is still saying "boot User" -- and a
  // dispatcher that only looks at E3 will hop straight back into the image that just failed:
  //     User fails -> watchdog -> fallback to 0x0 -> Factory header IPROGs to Flex -> we run ->
  //     E3 still says User -> we hop -> User fails -> ...
  // Measured symptom: FALLBACK=1 with DONE=0 and USERCODE=ffffffff, i.e. caught mid-lap.
  //
  // E3 cannot break that loop -- the ConnectX has not changed its mind. The only state that
  // survives reconfiguration and says "this configuration arrived via a fallback" is the FPGA's own
  // BOOTSTS register, so read it and refuse to hop when bit1 (0_FALLBACK) is set. The card then
  // comes to rest in Flex, with a live endpoint, and the host can change the selection.
  parameter         BOOTSTS_GATE = 1'b1,
  // BLOCK the hop when F1 reads 1.
  //
  // The premise, which is the user's and is worth testing: the User attempt itself -- or a second
  // configuration of Flex after the fallback -- may leave F1 high, giving us a signal that
  // distinguishes "first try" from "we already tried and it failed". BOOTSTS demonstrably does not
  // distinguish them (two different gates, byte-identical 0x0000070d).
  //
  // Polarity is chosen so the gate is INERT unless F1 actually goes high: every Flex-slot
  // measurement we have reads F1 = 0, so a normal boot is untouched. If F1 turned out
  // to read 1 normally this would make the User image unbootable, which is why the same build also
  // reports F1 at CR 0x02005C -- check that on a normal boot BEFORE trusting this.
  parameter         BLOCK_ON_F1 = 1'b1,
  // DO NOT HOP ONCE THE HOST HAS TRAINED THE LINK.
  //
  // A test showed the host wedges because the FPGA RECONFIGURES DURING POST, not because the User
  // image is broken: a GOOD User image wedged Host A when a delay bug pushed its hop to ~47 s, with DONE=1
  // and a healthy design running. We then measured lnk_up at both dispatcher runs, same rig,
  // same break:
  //     run 1   4.4 s   lnk_up LOW at both samples   -- the host has not trained us yet
  //     run 2  31.2 s   lnk_up HIGH throughout       -- the host already has
  // So the link flag separates the safe hop from the fatal one exactly, and gating on it needs no
  // state that survives reconfiguration -- which is what makes it cheaper than a flash latch and
  // why it does not require writing NOR on every boot.
  //
  // This is not a proxy for the hazard. Reconfiguring after the host has enumerated us IS the
  // hazard, so this measures the thing itself.
  parameter         BLOCK_ON_LNKUP = 1'b0,
  // SAMPLE THE LINK ONCE, EARLY, AND GATE ON THAT.
  //
  // The gate must distinguish "we are the first load of this power-on" from "the ConnectX has
  // reloaded us after a failed User attempt". A test measured what makes that possible:
  //
  //   run 1 (first load)   link trains 820-920 ms AFTER we configure -- so at 50 ms it is DOWN
  //   run 2 (CX5 reload)   happens ~31 s in, long after the host trained -- so it is UP from the
  //                        moment we configure (measured: its link-up level at configuration reads 1)
  //
  // So an EARLY sample separates them cleanly, where a live one does not: evaluated continuously
  // under POLL, the gate would also see run 1's link come up at 820 ms and block a hop that E3 only
  // requests later. Latching at 50 ms freezes the answer while it still means "first load".
  //
  // 50 ms is comfortably clear of both ends: the stability filter settles in 0.65 ms, and the
  // earliest link training ever observed is 820 ms, 16x later.
  parameter integer LNK_LATCH_CYCLES = 5000000,   // 50 ms at 100 MHz
  // WHICH configuration register the startup readback fetches.
  //
  // 22 = BOOTSTS, which is what the gates use. 16 = WBSTAR, the warm-boot start address -- the
  // register that says WHERE the next IPROG will land. deduced from timing that the
  // retry loop cannot have been re-loading Flex (configuration takes ~150 ms and the laps were
  // 663 ms, so Flex would have succeeded on lap 1), leaving "it keeps re-attempting the broken
  // target" as the explanation. If WBSTAR still holds OUR hop target when our image runs again
  // after a reload, that is the mechanism, measured rather than inferred.
  //
  // Type-1 read header = 0x28000000 | (reg << 13) | count:  reg 22 -> 0x2802C001, reg 16 -> 0x28020001.
  parameter [4:0]   RD_REG = 5'd22,
  // report the READBACK VALUE through the settle delay instead of a sampled pin, so it is
  // readable when the host is wedged. Bits [25:24] are enough to tell the slots apart:
  //     WBSTAR 0x01000000 -> 01 -> 200+400      =  600 ms   (User: our hop target persisted)
  //     WBSTAR 0x03000000 -> 11 -> 200+400+800  = 1400 ms   (Flex: Factory re-set it)
  parameter         RPT_RDVAL = 1'b0,
  // REPORT F1 THROUGH THE ONE CHANNEL THAT SURVIVES A WEDGED HOST.
  //
  // F1 has only ever been sampled by boundary scan on a card that had come to REST (
  // Flex running -> 0, User running -> 1). Nobody has read it during the SECOND Flex run after a
  // failed User attempt, because that run lasts 300 ms and the host is wedged before anything can
  // ask. If F1 does carry "how many times round we are", the whole failsafe needs no flash writes
  // at all -- so it has to be measured, not inferred from the BLOCK_ON_F1 gate's behaviour.
  //
  // The readout rides on the settle delay, because the E4 marker is already driven and already
  // captured: the burst lasts from configuration until the IPROG, so its LENGTH is this delay.
  // Sample F1 early and again at the normal decision point, then add 400 ms per bit:
  //     200 ms = low,low   600 ms = early only   1000 ms = late only   1400 ms = both
  // Distinct at 500 kHz, and it also shows whether F1 CHANGES during the run rather than only its
  // final level. Nothing is gated on it -- the hop still fires, so both runs are still observed.
  //
  // With F1_REPORT=0 this is constant-false and S_WAIT is bit-identical to before.
  parameter         F1_REPORT = 1'b0,
  parameter integer F1_EARLY_CYCLES = 5000000,    // 50 ms at 100 MHz
  parameter integer F1_BIT_CYCLES   = 40000000    // 400 ms per reported bit
)(
  input  wire clk,
  input  wire f1,
  input  wire i2c_act,                // any SCL/SDA edge -- "the ConnectX is talking to us"
  input  wire ext_req,                // decoded "boot User" request, e.g. from e3_code
  // the signal the F1_REPORT encoder reports. Separate from `f1` because `f1` also feeds the
  // BLOCK_ON_F1 gate -- the reporter must be able to watch something else (PCIe lnk_up) without
  // changing what the gate sees. Ignored entirely when F1_REPORT = 0.
  input  wire rpt_i,
  // the PCIe link-up flag, for the gate below. Separate from rpt_i, which is a REPORTING
  // input and may be muxed to something else -- a gate must never depend on what we happen to be
  // observing this build.
  input  wire lnk_i,
  output wire fired,
  output wire [31:0] bootsts,         // latched BOOTSTS, for the host to read back
  output wire        fallback_seen,   // bit1 of it: this configuration came from a fallback
  output wire        f1_level,        // debounced F1, for the host to read back
  output wire        f1_blocked,      // 1 = a hop was suppressed because F1 was high
  // the same observability for the link gate. concluded "the gate blocked the
  // good-path hop" from the ABSENCE of a hop, with nothing reporting why -- and then measured
  // the link rising 660 ms after the decision point, which makes that conclusion unsupportable.
  // Report the gate's own inputs so the next run says what happened instead of being interpreted.
  output wire        lnk_level,       // the debounced link flag, as the gate sees it
  output wire        lnk_blocked,     // LATCHED: a hop was triggered and the link gate refused it
  output wire        hop_wanted       // LATCHED: a trigger fired but the hop did not happen
);
  function [7:0] brev8; input [7:0] b; integer i;
    begin for (i=0;i<8;i=i+1) brev8[i] = b[7-i]; end
  endfunction
  function [31:0] icap_swz; input [31:0] w;      // per-byte bit reversal, byte lanes unchanged
    begin icap_swz = {brev8(w[31:24]), brev8(w[23:16]), brev8(w[15:8]), brev8(w[7:0])}; end
  endfunction

  // f1 through a synchroniser, then a stability filter: a hop must not be triggered by a glitch,
  // because it is irreversible until the next power cycle.
  reg f1_m = 1'b0, f1_s = 1'b0, f1_stable = 1'b0;
  reg [15:0] f1_ct = 16'd0;
  always @(posedge clk) begin
    f1_m <= f1; f1_s <= f1_m;
    if (f1_s == f1_stable) f1_ct <= 16'd0;
    else if (f1_ct == 16'hFFFF) begin f1_stable <= f1_s; f1_ct <= 16'd0; end
    else f1_ct <= f1_ct + 16'd1;
  end

  // lnk_i crosses from the XDMA's axi_clk, so it gets the same treatment as the others.
  reg lnk_m = 1'b0, lnk_s = 1'b0, lnk_stable = 1'b0;
  reg [15:0] lnk_ct = 16'd0;
  always @(posedge clk) begin
    lnk_m <= lnk_i; lnk_s <= lnk_m;
    if (lnk_s == lnk_stable) lnk_ct <= 16'd0;
    else if (lnk_ct == 16'hFFFF) begin lnk_stable <= lnk_s; lnk_ct <= 16'd0; end
    else lnk_ct <= lnk_ct + 16'd1;
  end

  // the reported signal gets the same synchroniser + stability filter as f1: it may come from
  // another clock domain (lnk_up is in the XDMA's axi_clk), and a glitch would mis-encode the read.
  reg rpt_m = 1'b0, rpt_s = 1'b0, rpt_stable = 1'b0;
  reg [15:0] rpt_ct = 16'd0;
  always @(posedge clk) begin
    rpt_m <= rpt_i; rpt_s <= rpt_m;
    if (rpt_s == rpt_stable) rpt_ct <= 16'd0;
    else if (rpt_ct == 16'hFFFF) begin rpt_stable <= rpt_s; rpt_ct <= 16'd0; end
    else rpt_ct <= rpt_ct + 16'd1;
  end

  // sticky "the ConnectX spoke to us at least once", and a silence counter that it freezes
  reg        act_m = 1'b0, act_s = 1'b0, act_d = 1'b0, spoke = 1'b0;
  reg [31:0] quiet = 32'd0;
  always @(posedge clk) begin
    act_m <= i2c_act; act_s <= act_m; act_d <= act_s;
    if (act_s != act_d) begin spoke <= 1'b1; quiet <= 32'd0; end
    else if (!spoke && quiet != 32'hFFFFFFFF) quiet <= quiet + 32'd1;
  end
  wire silent = !spoke && (quiet >= SILENCE_CYCLES[31:0]);

  localparam [3:0] S_WAIT=0, S_DECIDE=1, S_SEQ=2, S_DONE=3, S_IDLE=4,
                   S_BRD=5, S_BTURN=6, S_BEN=7, S_BCAP=8, S_BDSY=9, S_BEND=10;
  // Start in the BOOTSTS read, not S_WAIT: the answer must be latched before any hop decision.
  reg [3:0]  st   = S_BRD;
  reg [31:0] bsts = 32'd0;
  reg        bsts_done = 1'b0;
  reg [3:0]  bwait = 4'd0;
  reg [31:0] dly  = 32'd0;
  reg        f1_early_r = 1'b0, f1_late_r = 1'b0, tgt_done = 1'b0;
  // LATCH the suppression. lnk_blocked is combinational, so a CR read minutes after boot
  // always shows 1 simply because the link is up by then -- it cannot say what was true at the
  // decision. This latches "E3 asked, the delay had elapsed, and a gate said no".
  reg        supp_lnk = 1'b0, supp_any = 1'b0;
  // the early link sample, and a flag saying it has been taken
  reg        lnk_early = 1'b0, lnk_early_done = 1'b0;
  reg [31:0] lnk_ct2 = 32'd0;
  always @(posedge clk) begin
    if (!lnk_early_done) begin
      if (lnk_ct2 >= LNK_LATCH_CYCLES[31:0]) begin
        lnk_early <= lnk_stable; lnk_early_done <= 1'b1;
      end else lnk_ct2 <= lnk_ct2 + 32'd1;
    end
  end
  reg [31:0] wait_target = DELAY_CYCLES[31:0];
  reg [3:0]  idx  = 4'd0;
  reg        csib = 1'b1, rdwrb = 1'b1, fired_r = 1'b0;
  reg [31:0] iword = 32'hFFFFFFFF;
  wire [31:0] icap_o;                  // ICAPE3 read data, driven by u_icap below

  // IPROG, in the golden image's own order: sync, TIMER, WBSTAR <- target, CMD <- IPROG(0x0F).
  //   type-1 write header = 0x30000000 | (reg << 13) | wordcount
  //   reg 17 TIMER = 0x30022001 ; reg 16 WBSTAR = 0x30020001 ; reg 4 CMD = 0x30008001
  localparam [3:0] SEQ_LAST = 4'd13;      // words 0..11 are real; 12/13 are trailing NOPs

  // Startup readback of one configuration register, selected by RD_REG.
  function [31:0] rdw; input [3:0] i;
    begin case (i)
      4'd0: rdw = 32'hFFFFFFFF;  4'd1: rdw = 32'hAA995566;  4'd2: rdw = 32'h20000000;
      // ZERO-EXTEND BEFORE SHIFTING. RD_REG is [4:0], and `RD_REG << 13` can be evaluated
      // at the operand's own 5-bit width -- every set bit shifts out and the term becomes 0, so the
      // header degrades to 0x28000001, a read of register 0 instead of the one asked for. Measured:
      // BOOTSTS read 0x00000005 in every build before this was parameterised and
      // 0x00000000 immediately after (baseline). That also explains an earlier "WBSTAR
      // reads zero" -- it was reading register 0, not WBSTAR.
      4'd3: rdw = (32'h28000000 | ({27'd0, RD_REG} << 13) | 32'd1);
      4'd4: rdw = 32'h20000000;  4'd5: rdw = 32'h20000000;
      default: rdw = 32'h20000000;
    endcase end
  endfunction
  localparam [3:0] RD_LAST = 4'd5;

  // and a clean DESYNC afterwards, so the hop sequence below starts from a known state rather than
  // inheriting whatever the readback left behind. Getting this wrong breaks the hop, which is far
  // worse than having no gate at all.
  function [31:0] dsw; input [3:0] i;
    begin case (i)
      4'd0: dsw = 32'hFFFFFFFF;  4'd1: dsw = 32'hAA995566;  4'd2: dsw = 32'h20000000;
      4'd3: dsw = 32'h30008001;  4'd4: dsw = 32'h0000000D;  4'd5: dsw = 32'h20000000;
      4'd6: dsw = 32'h20000000;
      default: dsw = 32'h20000000;
    endcase end
  endfunction
  localparam [3:0] DSY_LAST = 4'd6;
  function [31:0] seqw; input [3:0] i;
    begin case (i)
      4'd0:  seqw = 32'hFFFFFFFF;  4'd1:  seqw = 32'hAA995566;  4'd2:  seqw = 32'h20000000;
      4'd3:  seqw = 32'h30022001;  4'd4:  seqw = TIMER_WORD;    4'd5:  seqw = 32'h20000000;
      4'd6:  seqw = 32'h30020001;  4'd7:  seqw = TARGET;        4'd8:  seqw = 32'h20000000;
      4'd9:  seqw = 32'h30008001;  4'd10: seqw = 32'h0000000F;  4'd11: seqw = 32'h20000000;
      default: seqw = 32'h20000000;
    endcase end
  endfunction

  always @(posedge clk) begin
    case (st)
      // ---- read BOOTSTS once, before anything else --------------------------------
      S_BRD: begin
        if (!BOOTSTS_GATE) begin st <= S_WAIT; bsts_done <= 1'b1; end
        else if (!bsts_done && idx == 4'd0 && csib) begin      // kick the request off
          csib <= 1'b0; rdwrb <= 1'b0; iword <= rdw(4'd0);
        end else if (idx == RD_LAST) begin
          csib <= 1'b1; idx <= 4'd0; st <= S_BTURN;             // deassert before the turnaround
        end else begin
          idx <= idx + 4'd1; iword <= rdw(idx + 4'd1);
        end
      end
      S_BTURN: begin rdwrb <= 1'b1; csib <= 1'b0; bwait <= 4'd0; st <= S_BEN; end
      // ICAPE3 needs a few clocks after the turnaround before O is meaningful. Four is generous;
      // this runs once at startup and nothing is waiting on it.
      S_BEN:   if (bwait == 4'd3) st <= S_BCAP; else bwait <= bwait + 4'd1;
      S_BCAP: begin
        bsts <= icap_swz(icap_o);        // same per-byte bit reversal coming back as going in
        bsts_done <= 1'b1;
        csib <= 1'b1; rdwrb <= 1'b1; idx <= 4'd0; st <= S_BDSY;
      end
      // DESYNC, so the hop sequence starts from a known state rather than inheriting the readback's
      S_BDSY: begin
        if (idx == 4'd0 && csib) begin csib <= 1'b0; rdwrb <= 1'b0; iword <= dsw(4'd0); end
        else if (idx == DSY_LAST) begin csib <= 1'b1; rdwrb <= 1'b1; st <= S_BEND; end
        else begin idx <= idx + 4'd1; iword <= dsw(idx + 4'd1); end
      end
      S_BEND: begin idx <= 4'd0; st <= S_WAIT; end

      S_WAIT: begin
        if (F1_REPORT && dly == F1_EARLY_CYCLES[31:0]) f1_early_r <= rpt_stable;
        if (F1_REPORT && !tgt_done && dly == DELAY_CYCLES[31:0]) begin
          f1_late_r   <= rpt_stable;
          wait_target <= DELAY_CYCLES[31:0]
                       + ((RPT_RDVAL ? bsts[24] : f1_early_r) ? F1_BIT_CYCLES[31:0] : 32'd0)
                       + ((RPT_RDVAL ? bsts[25] : rpt_stable) ? (F1_BIT_CYCLES[31:0] << 1) : 32'd0);
          tgt_done    <= 1'b1;
          dly         <= dly + 32'd1;
        // >=, NOT ==. With both F1 samples low the target is DELAY_CYCLES, which dly has
        // ALREADY reached on the cycle the target is set -- and dly then increments past it, so an
        // equality compare never matches again and the counter runs to 2^32: 42.95 s at 100 MHz.
        // Measured exactly that, as a single 42.4 s marker burst instead of a 200 ms one.
        end else if (dly >= wait_target) st <= S_DECIDE;
        else dly <= dly + 32'd1;
      end
      S_DECIDE: begin
        // whatever the trigger says, do NOT hop if ANYTHING in this boot chain has
        // already gone wrong. Gating on bit1 alone was too narrow and did not save the
        // card: by the time our image runs inside a recovery chain the evidence has moved into the
        // PREVIOUS-configuration half of the word. Measured in the failed state:
        //     0_ STATUS_VALID=1 FALLBACK=0 INTERNAL_PROG=1 WATCHDOG_TIMEOUT_ERROR=1
        //     1_ STATUS_VALID=1 FALLBACK=1 INTERNAL_PROG=1
        // so bit9 carried the fallback and bit1 did not. Watch both halves, and watch the watchdog
        // bits as well as the fallback bits -- any of the four means "the User image already failed
        // once this power-on", and hopping into it again spends the device's single remaining
        // fallback and halts it with DONE=0.
        // A normal boot reads 0x00000005 (bits 0 and 2 only), so none of these four are set and the
        // good-path hop is untouched -- that is measured, not assumed (CR 0x020058).
        if (ARMED && !(BOOTSTS_GATE && (bsts[1] | bsts[3] | bsts[9] | bsts[11]))
                  && !(BLOCK_ON_F1 && f1_stable)
                  && !(BLOCK_ON_LNKUP && lnk_early)
                  && ((HOP_ON_F1 && (f1_stable == HOP_WHEN_F1))
                      || (HOP_ON_SILENCE && silent)
                      || (HOP_ON_EXT && ext_req))) begin
          st <= S_SEQ; idx <= 4'd0; csib <= 1'b0; rdwrb <= 1'b0; iword <= seqw(4'd0);
        end else begin
          // a trigger fired and a gate refused it -- record that, at the moment it mattered.
          // This is the branch that matters: `lnk_blocked` used to be combinational, so a CR read
          // minutes later always showed 1 because the link is up by then, and said nothing about
          // the decision. Latched here it means "a hop was actually wanted and suppressed".
          if (ARMED && ((HOP_ON_F1 && (f1_stable == HOP_WHEN_F1))
                        || (HOP_ON_SILENCE && silent) || (HOP_ON_EXT && ext_req))) begin
            supp_any <= 1'b1;
            if (BLOCK_ON_LNKUP && lnk_early) supp_lnk <= 1'b1;
          end
          if (!POLL) st <= S_IDLE;                   // one-shot: latch "stay", never look again
        end
        // POLL: remain in S_DECIDE and keep watching. Firing is still one-shot -- S_SEQ leads to
        // S_DONE, which never re-arms -- so this can hop at most once per configuration.
      end
      S_SEQ: begin
        if (idx == SEQ_LAST) begin csib <= 1'b1; rdwrb <= 1'b1; fired_r <= 1'b1; st <= S_DONE; end
        else begin idx <= idx + 4'd1; iword <= seqw(idx + 4'd1); end
      end
      default: ;                                     // S_DONE / S_IDLE: one-shot, never re-arms
    endcase
  end
  assign fired         = fired_r;
  assign f1_level      = f1_stable;
  assign f1_blocked    = BLOCK_ON_F1 && f1_stable;
  assign lnk_level     = lnk_early;   // the EARLY sample, which is what the gate uses
  assign lnk_blocked   = supp_lnk;     // LATCHED: a hop was wanted and the link gate refused it
  assign hop_wanted    = supp_any;     // LATCHED: a trigger fired at least once
  assign bootsts       = bsts;
  assign fallback_seen = bsts[1];      // BOOTSTS bit1 = 0_FALLBACK, the current boot

  ICAPE3 #(.ICAP_AUTO_SWITCH("DISABLE"), .SIM_CFG_FILE_NAME("NONE")) u_icap (
    .AVAIL(), .O(icap_o), .PRDONE(), .PRERROR(),
    .CLK(clk), .CSIB(csib), .I(icap_swz(iword)), .RDWRB(rdwrb)
  );
endmodule
