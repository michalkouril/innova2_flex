// SPDX-FileCopyrightText: 2026 the innova2 contributors
// SPDX-FileCopyrightText: Mellanox Technologies Ltd.
//
// SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

`timescale 1ns/1ps
// =================================================================================================
// bope_burn -- the burn engine behind BAR0+0: parse the vendor app's chunk protocol and write what
// it sends into the config flash.
//
// PROTOCOL (from burn_app.c):
//     0xc001babe  SYNC | 0x60000000 DDR_OFFSET | flash_offset (bit31 = the OTHER chip)
//     | part_img_size (bytes) | size/4 data words
//   then the app polls the status word until mb_progress falls and mb_status_done has INCREMENTED.
//
// DDR_OFFSET IS ACCEPTED AND IGNORED. Mellanox stage each chunk in DDR and then move it to flash;
// the app never reads that memory back, it only watches the status word. Streaming FIFO -> flash
// removes the MIG from this design entirely, and with it the DDR-marginality hazard that cost a
// card in 418.
//
// FLASH COMMANDS are the ones rawspi.py has used on these chips all project: 0x06 WREN,
// 0x05 RDSR (bit0 WIP, bit1 WEL), 0x12 PAGE PROGRAM 4-byte, plus 0xDC SECTOR ERASE 64K 4-byte,
// which rawspi deliberately lacks because it only ever clears bits.
//
// PROGRAM IN 128-BYTE PIECES, not 256: the AXI Quad SPI FIFO is 256 entries and a page program
// costs 5 command bytes plus data, so a full page would overflow it by five bytes -- the kind of
// off-by-a-header that writes 251 correct bytes and drops the rest without saying so.
// =================================================================================================
module bope_burn #(
  parameter integer FIFO_AW   = 14,               // 16384 dwords = 64 KB
  parameter [31:0]  QSPI_BASE = 32'h00040000,
  // this used to be compared against a count of POLL ITERATIONS, each of which is a whole
  // SPI transaction -- 200 million of them is not a timeout, it is forever. Count CYCLES.
  parameter [31:0]  WIP_LIMIT = 32'd125000000,    // 1 s at 125 MHz -> fatal (a page program is
                                                  // sub-millisecond; a sector erase under a second)
  // a bus access that never completes must be an ERROR, not a hang. On hardware the engine
  // sat at busy=1 with progress 0 and no error for as long as the app cared to poll, because the
  // AXI-Lite helper below waits on bus_done with nothing watching it. An engine that reports a
  // fault is debuggable; one that stops answering looks identical to a dead card.
  parameter [31:0]  BUS_LIMIT = 32'd12500000,     // 100 ms at 125 MHz
  parameter [31:0]  OP_LIMIT  = 32'd375000000,    // 3 s at 125 MHz: longer than any single erase
  // SETTLE. The controller runs its shift engine on ext_spi_clk (20 MHz here, SCK = 10 MHz),
  // while these writes arrive on the 125 MHz AXI clock roughly 40 ns apart -- inside a single
  // SPI-domain cycle. rawspi.py issues the same sequence from the host with microseconds between
  // writes and works; ours stalled with SR=0x20, i.e. data sitting in BOTH FIFOs and the engine not
  // clocking. Control writes (FIFO reset, slave select, inhibit release) need time to cross into
  // the slower domain before the next one lands.
  parameter [15:0]  SETTLE    = 16'd500,             // 4 us at 125 MHz = 80 SPI-clock cycles
  parameter integer PIECE     = 128
)(
  input  wire        clk,
  input  wire        rstn,
  input  wire [31:0] cmd_data,
  input  wire        cmd_valid,
  output wire        afull,
  output reg  [6:0]  progress,
  output reg  [1:0]  done_cnt,
  output reg         busy,
  output reg         err_recov,
  output reg         err_fatal,
  output wire [4:0]  dbg_fs,            // which state the sequencer is in, for the JTAG watcher
  output wire [4:0]  dbg_xs,
  output wire [15:0] dbg16,            // {fs, last SPI byte received, xs} for the status word
  output reg  [31:0] m_awaddr,  output reg m_awvalid, input wire m_awready,
  output reg  [31:0] m_wdata,   output reg [3:0] m_wstrb, output reg m_wvalid, input wire m_wready,
  input  wire [1:0]  m_bresp,   input wire m_bvalid,  output reg m_bready,
  output reg  [31:0] m_araddr,  output reg m_arvalid, input wire m_arready,
  input  wire [31:0] m_rdata,   input wire [1:0] m_rresp, input wire m_rvalid, output reg m_rready
);
  localparam [31:0] R_CR = 32'h60, R_SR = 32'h64, R_DTR = 32'h68, R_DRR = 32'h6C, R_SSR = 32'h70;
  localparam [31:0] CR_SPE=32'h002, CR_MASTER=32'h004, CR_TXRST=32'h020, CR_RXRST=32'h040,
                    CR_MANSS=32'h080, CR_INHIBIT=32'h100;
  localparam [31:0] CR_IDLE = CR_MASTER|CR_MANSS|CR_INHIBIT|CR_SPE;
  localparam [31:0] CR_RUN  = CR_MASTER|CR_MANSS|CR_SPE;
  localparam SR_RXEMPTY = 0, SR_TXEMPTY = 2;
  localparam [7:0] C_WREN=8'h06, C_RDSR=8'h05, C_PP4=8'h12, C_SE4=8'hDC;

  // ---------------- command parser --------------------------------------------------------------
  localparam [2:0] P_SYNC=0, P_DDR=1, P_OFF=2, P_SIZE=3, P_DATA=4;
  reg [2:0]  pst = P_SYNC;
  reg [31:0] chunk_off, chunk_size, words_left;
  reg        chunk_go;

  (* ram_style = "block" *) reg [31:0] fifo [0:(1<<FIFO_AW)-1];
  reg [FIFO_AW:0] wptr, rptr;
  wire [FIFO_AW:0] used = wptr - rptr;
  wire fifo_empty = (used == 0);
  assign afull = (used > (( 1 << FIFO_AW) - 8192));

  always @(posedge clk) begin
    if (!rstn) begin pst <= P_SYNC; chunk_go <= 1'b0; wptr <= 0; words_left <= 0; end
    else begin
      chunk_go <= 1'b0;
      if (cmd_valid) begin
        case (pst)
          P_SYNC: if (cmd_data == 32'hC001BABE) pst <= P_DDR;
          P_DDR:  pst <= P_OFF;
          P_OFF:  begin chunk_off <= cmd_data; pst <= P_SIZE; end
          P_SIZE: begin
                    chunk_size <= cmd_data;
                    words_left <= (cmd_data + 32'd3) >> 2;
                    chunk_go   <= (cmd_data != 0);
                    pst        <= (cmd_data == 0) ? P_SYNC : P_DATA;
                  end
          P_DATA: begin
                    if (used < (1 << FIFO_AW)) begin
                      fifo[wptr[FIFO_AW-1:0]] <= cmd_data;
                      wptr <= wptr + 1'b1;
                    end
                    words_left <= words_left - 1'b1;
                    if (words_left == 32'd1) pst <= P_SYNC;
                  end
          default: pst <= P_SYNC;
        endcase
      end
    end
  end

  // ---------------- AXI4-Lite master ------------------------------------------------------------
  reg        bus_req, bus_wr, bus_done;
  reg [31:0] bus_addr, bus_wdat, bus_rdat;
  reg [7:0]  sr_last;          // last STATUS register value read from the SPI controller.
                               // The engine sits in X_POLL waiting for TXEMPTY; either the transfer
                               // is not running or the bit is not where this code thinks it is, and
                               // rx_last cannot tell those apart -- sr_last can. Declared with the
                               // bus helper that writes it, not with the sequencer that shows it.
  reg [1:0]  bs;
  wire       bus_idle = (bs == 2'd0) && !bus_req;   // level, not pulse -- see the note above
  reg [31:0] bus_wdt;
  reg        bus_timeout;
  always @(posedge clk) begin
    if (!rstn) begin
      m_awvalid<=0; m_wvalid<=0; m_bready<=0; m_arvalid<=0; m_rready<=0; bs<=0; bus_done<=0;
      m_wstrb<=4'hF; bus_wdt<=32'd0; bus_timeout<=1'b0;
    end else begin
      bus_done <= 1'b0;
      // watchdog: any transaction that outlives BUS_LIMIT is abandoned and reported
      if (bs == 2'd0) bus_wdt <= 32'd0;
      else if (bus_wdt >= BUS_LIMIT) begin
        bus_wdt <= 32'd0; bus_timeout <= 1'b1;
        m_awvalid<=1'b0; m_wvalid<=1'b0; m_bready<=1'b0; m_arvalid<=1'b0; m_rready<=1'b0;
        bs <= 2'd0; bus_done <= 1'b1;         // release the sequencer; err_fatal is set below
      end else bus_wdt <= bus_wdt + 32'd1;
      case (bs)
        2'd0: if (bus_req) begin
                if (bus_wr) begin
                  m_awaddr<=bus_addr; m_awvalid<=1'b1; m_wdata<=bus_wdat; m_wstrb<=4'hF;
                  m_wvalid<=1'b1; m_bready<=1'b1; bs<=2'd1;
                end else begin
                  m_araddr<=bus_addr; m_arvalid<=1'b1; m_rready<=1'b1; bs<=2'd2;
                end
              end
        2'd1: begin
                if (m_awvalid && m_awready) m_awvalid<=1'b0;
                if (m_wvalid  && m_wready)  m_wvalid <=1'b0;
                if (m_bvalid  && m_bready)  begin m_bready<=1'b0; bus_done<=1'b1; bs<=2'd0; end
              end
        2'd2: begin
                if (m_arvalid && m_arready) m_arvalid<=1'b0;
                if (m_rvalid  && m_rready)  begin
                  bus_rdat<=m_rdata; m_rready<=1'b0; bus_done<=1'b1; bs<=2'd0;
                  if (bus_addr == QSPI_BASE + R_SR) sr_last <= m_rdata[7:0];
                end
              end
        default: bs<=2'd0;
      endcase
    end
  end

  // ---------------- SPI transaction engine ------------------------------------------------------
  // Stage bytes in tx_buf, set want_read and after_xfer, jump to X_PRE1. The sequence is
  // rawspi.xfer() step for step: reset FIFOs, push, assert SS, release inhibit, wait TXEMPTY,
  // inhibit, deassert SS, drain RX.
  localparam [4:0] X_IDLE=0, X_PRE1=1, X_PRE2=2, X_PUSH=3, X_SS=4, X_RUN=5, X_POLL=6, X_STOP=7,
                   X_DESEL=8, X_DRAIN=9, X_RD=10, X_WAIT=11;
  localparam [4:0] F_IDLE=0,  F_START=1, F_ERASE1=2, F_ERASE2=3, F_PROG1=4, F_PROG2=5,
                   F_WIP1=6,  F_WIP2=7,  F_ADV=8,    F_FIN=9,    F_FAIL=10, F_WAITDATA=11;

  reg [4:0]  xs, fs, after_xfer, wip_ret;
  assign dbg_fs = fs;          // declared here, where fs exists -- Verilog has no forward references
  assign dbg_xs = xs;
  reg        want_read;
  reg [8:0]  tx_n, tx_i;
  // every transaction state used to wait on the one-cycle `bus_done` PULSE. Inserting a
  // settle delay made that pulse arrive while the machine was parked in X_WAIT, so the next state
  // waited for an event that had already happened -- the whole sequence stalled in simulation
  // before it could stall on hardware. Wait on a LEVEL instead: the bus helper being idle means the
  // previous access has retired, whether that was this cycle or fifty cycles ago.
  reg [15:0] settle_n;                 // counts down the pause after a control write
  reg [4:0]  settle_ret;               // where to go once it expires
  reg [9:0]  drain_n;                // the drain loop had NO bound. rawspi.py gives up after
                                     // 4096 reads ("RX FIFO will not drain"); the RTL spun for ever,
                                     // which is how the engine came to sit in WIP1 with no error and
                                     // no progress. A loop that cannot end is not a wait, it is a hang.
  reg [7:0]  tx_buf [0:271];
  reg [7:0]  rx_last;
  assign dbg16 = {fs, sr_last, xs[2:0]};
  reg [31:0] addr, left, wipct, acc, tot;
  reg        slave, need_erase;
  reg [8:0]  piece, pbytes;
  reg [31:0] hold;
  reg [1:0]  hbyte;
  reg        prog_rst;              // combinational: 'the sequencer wants progress back at zero'
  reg [31:0] op_wdt;                 // cycles since the sequencer last changed state
  reg [4:0]  fs_prev;
  reg [16:0] acc_inc;               // combinational temp: percent-credits produced THIS cycle.
                                    // It is a variable, not state: F_ADV sets it with a blocking
                                    // assignment and the single `acc` update below consumes it in
                                    // the same evaluation. Two non-blocking owners of `acc` is what
                                    // the first version had, and the later one silently won.
  reg        pop_req;

  wire [8:0] to_page_end = 9'd256 - addr[7:0];
  wire [8:0] piece_len   = (left < {23'd0, to_page_end}) ?
                             ((left < PIECE) ? left[8:0] : PIECE[8:0]) :
                             ((to_page_end < PIECE[8:0]) ? to_page_end : PIECE[8:0]);

  integer i;
  always @(posedge clk) begin
    if (!rstn) begin
      xs<=X_IDLE; fs<=F_IDLE; busy<=1'b0; done_cnt<=2'd0; progress<=7'd0;
      err_fatal<=1'b0; err_recov<=1'b0; rptr<=0; bus_req<=1'b0; acc<=0; tot<=0;
      tx_n<=0; tx_i<=0; want_read<=1'b0; wipct<=0; op_wdt<=0; fs_prev<=F_IDLE; drain_n<=0;
      settle_n<=0; settle_ret<=X_IDLE;
    end else begin
      bus_req <= 1'b0;
      acc_inc = 17'd0;
      // one tick per CLOCK while a write-in-progress poll is outstanding
      if (fs == F_WIP1 || fs == F_WIP2) wipct <= wipct + 32'd1;
      prog_rst = 1'b0;

      // ---- the SPI transaction sub-machine ----
      case (xs)
        X_PRE1: begin bus_req<=1'b1; bus_wr<=1'b1; bus_addr<=QSPI_BASE+R_CR;
                      bus_wdat<=CR_IDLE|CR_TXRST|CR_RXRST; xs<=X_PRE2; end
        X_WAIT: if (settle_n == 16'd0) xs <= settle_ret; else settle_n <= settle_n - 16'd1;
        X_PRE2: if (bus_idle) begin bus_req<=1'b1; bus_wr<=1'b1; bus_addr<=QSPI_BASE+R_CR;
                      bus_wdat<=CR_IDLE; tx_i<=9'd0;
                      settle_n<=SETTLE; settle_ret<=X_PUSH; xs<=X_WAIT; end
        X_PUSH: if (bus_idle) begin
                  if (tx_i == tx_n) begin
                    bus_req<=1'b1; bus_wr<=1'b1; bus_addr<=QSPI_BASE+R_SSR;
                    bus_wdat<=~(32'd1 << slave); xs<=X_SS;
                  end else begin
                    bus_req<=1'b1; bus_wr<=1'b1; bus_addr<=QSPI_BASE+R_DTR;
                    bus_wdat<={24'd0, tx_buf[tx_i]}; tx_i<=tx_i+1'b1;
                  end
                end
        X_SS:   if (bus_idle) begin bus_req<=1'b1; bus_wr<=1'b1; bus_addr<=QSPI_BASE+R_CR;
                      bus_wdat<=CR_RUN; settle_n<=SETTLE; settle_ret<=X_RUN; xs<=X_WAIT; end
        X_RUN:  if (bus_idle) begin bus_req<=1'b1; bus_wr<=1'b0; bus_addr<=QSPI_BASE+R_SR;
                      xs<=X_POLL; end   // the settle above already gave the transfer time to start
        X_POLL: if (bus_idle) begin
                  if (bus_rdat[SR_TXEMPTY]) begin
                    bus_req<=1'b1; bus_wr<=1'b1; bus_addr<=QSPI_BASE+R_CR; bus_wdat<=CR_IDLE;
                    xs<=X_STOP;
                  end else begin bus_req<=1'b1; bus_wr<=1'b0; bus_addr<=QSPI_BASE+R_SR; end
                end
        X_STOP: if (bus_idle) begin bus_req<=1'b1; bus_wr<=1'b1; bus_addr<=QSPI_BASE+R_SSR;
                      bus_wdat<=32'hFFFFFFFF; settle_n<=SETTLE; settle_ret<=X_DESEL; xs<=X_WAIT; end
        X_DESEL:if (bus_idle) begin bus_req<=1'b1; bus_wr<=1'b0; bus_addr<=QSPI_BASE+R_SR;
                      drain_n<=10'd0; xs<=X_DRAIN; end
        X_DRAIN:if (bus_idle) begin
                  if (bus_rdat[SR_RXEMPTY] || drain_n >= 10'd600) begin xs<=X_IDLE; fs<=after_xfer; end
                  else begin bus_req<=1'b1; bus_wr<=1'b0; bus_addr<=QSPI_BASE+R_DRR;
                             drain_n<=drain_n+10'd1; xs<=X_RD; end
                end
        X_RD:   if (bus_idle) begin rx_last<=bus_rdat[7:0];
                      bus_req<=1'b1; bus_wr<=1'b0; bus_addr<=QSPI_BASE+R_SR; xs<=X_DRAIN; end
        default: ;
      endcase

      // Global watchdog. wipct only ticks in the WIP states and is only CHECKED when the SPI
      // sub-machine is idle, so a stall anywhere else was invisible. This one watches the whole
      // sequencer: if nothing changes for OP_LIMIT cycles the chunk is abandoned and reported.
      fs_prev <= fs;
      if (fs != fs_prev || fs == F_IDLE || fs == F_WAITDATA) op_wdt <= 32'd0;
      else if (op_wdt >= OP_LIMIT) begin
        err_fatal <= 1'b1; busy <= 1'b0; prog_rst = 1'b1; fs <= F_IDLE; xs <= X_IDLE; op_wdt <= 32'd0;
      end else op_wdt <= op_wdt + 32'd1;

      // a bus timeout ends the chunk: the flash state is unknown from here, so saying "done" would
      // be a lie the app would act on.
      if (bus_timeout) begin
        err_fatal <= 1'b1; busy <= 1'b0; prog_rst = 1'b1; fs <= F_IDLE; xs <= X_IDLE;
      end

      // ---- the flash sequencer ----
      if (xs == X_IDLE && !bus_timeout) begin
        case (fs)
          F_IDLE: begin
            prog_rst = 1'b1;
            if (chunk_go) begin
              slave<=chunk_off[31]; addr<={1'b0,chunk_off[30:0]}; left<=chunk_size; tot<=chunk_size;
              busy<=1'b1; acc<=32'd0; need_erase<=1'b1; err_recov<=1'b0; fs<=F_START;
            end
          end
          F_START: begin
            if (left == 32'd0) fs <= F_FIN;
            else if (need_erase) fs <= F_ERASE1;
            else if (used >= ((piece_len + 9'd3) >> 2)) fs <= F_PROG1;   // enough words buffered
            else fs <= F_WAITDATA;
          end
          F_WAITDATA: if (used >= ((piece_len + 9'd3) >> 2)) fs <= F_PROG1;

          // ---- erase the sector this address sits in ----
          F_ERASE1: begin
            tx_buf[0] <= C_WREN; tx_n <= 9'd1; want_read <= 1'b0;
            after_xfer <= F_ERASE2; xs <= X_PRE1;
          end
          F_ERASE2: begin
            tx_buf[0] <= C_SE4;
            tx_buf[1] <= addr[31:24]; tx_buf[2] <= addr[23:16];
            tx_buf[3] <= addr[15:8];  tx_buf[4] <= addr[7:0];
            tx_n <= 9'd5; want_read <= 1'b0;
            after_xfer <= F_WIP1; wip_ret <= F_START; need_erase <= 1'b0;
            wipct <= 32'd0; xs <= X_PRE1;
          end

          // ---- program one piece ----
          F_PROG1: begin
            tx_buf[0] <= C_WREN; tx_n <= 9'd1; want_read <= 1'b0;
            after_xfer <= F_PROG2; xs <= X_PRE1;
            piece <= piece_len; pbytes <= 9'd0; hbyte <= 2'd0;
          end
          F_PROG2: begin
            // stage command + address, then pull `piece` bytes out of the FIFO, LSB first, which is
            // the order the app's 32-bit words carry file bytes on x86.
            if (pbytes == 9'd0) begin
              tx_buf[0] <= C_PP4;
              tx_buf[1] <= addr[31:24]; tx_buf[2] <= addr[23:16];
              tx_buf[3] <= addr[15:8];  tx_buf[4] <= addr[7:0];
            end
            if (pbytes == piece) begin
              tx_n <= 9'd5 + piece; want_read <= 1'b0;
              after_xfer <= F_WIP1; wip_ret <= F_ADV; wipct <= 32'd0; xs <= X_PRE1;
            end else begin
              if (hbyte == 2'd0) begin
                hold  <= fifo[rptr[FIFO_AW-1:0]];
                rptr  <= rptr + 1'b1;
                tx_buf[9'd5 + pbytes] <= fifo[rptr[FIFO_AW-1:0]][7:0];
                hbyte <= 2'd1;
              end else begin
                tx_buf[9'd5 + pbytes] <= (hbyte == 2'd1) ? hold[15:8] :
                                         (hbyte == 2'd2) ? hold[23:16] : hold[31:24];
                hbyte <= (hbyte == 2'd3) ? 2'd0 : hbyte + 1'b1;
              end
              pbytes <= pbytes + 1'b1;
            end
          end

          // ---- wait for the write-in-progress bit to clear ----
          F_WIP1: begin
            // TWO bytes, not one. rawspi.rdsr() sends 0x05 and then a DUMMY byte, because SPI is
            // full duplex: the flash can only shift its status out while the master keeps clocking.
            // Sending the command alone clocked nothing back, so `rx_last` held whatever the bus
            // idled at -- 0xFF -- whose bit 0 reads as "write in progress, still busy". The engine
            // then waited out its whole watchdog on EVERY piece, which is the ~7.5 s per 128 bytes
            // seen on hardware.
            tx_buf[0] <= C_RDSR; tx_buf[1] <= 8'h00; tx_n <= 9'd2; want_read <= 1'b1;
            after_xfer <= F_WIP2; xs <= X_PRE1;
          end
          F_WIP2: begin
            if (!rx_last[0]) fs <= wip_ret;
            else if (wipct > WIP_LIMIT) begin err_fatal <= 1'b1; fs <= F_FAIL; end
            else fs <= F_WIP1;
          end

          // ---- advance, and decide whether the next piece opens a new sector ----
          F_ADV: begin
            addr <= addr + piece;
            left <= (left > {23'd0, piece}) ? left - {23'd0, piece} : 32'd0;
            need_erase <= (((addr + piece) & 32'h0000FFFF) == 32'd0);
            // progress without a divider: 100 credits per byte, spent by the block below.
            // NOTE both used to assign `acc` in the same always block, so whichever ran second
            // silently threw the other away -- a progress bar that would have stuck at 0 or never
            // advanced. One owner, one adder input.
            acc_inc = piece * 9'd100;
            fs  <= F_START;
          end

          F_FIN: begin
            busy <= 1'b0; prog_rst = 1'b1; done_cnt <= done_cnt + 1'b1; fs <= F_IDLE;
          end
          F_FAIL: begin busy <= 1'b0; prog_rst = 1'b1; fs <= F_IDLE; end
          default: fs <= F_IDLE;
        endcase
      end

      // progress accumulator: ONE owner of `acc`. Credits arrive on acc_add, one subtract per clock
      // turns them into percent.
      // ONE owner each for `acc` and `progress`. Both used to be assigned from two places in this
      // block -- the sequencer and this accumulator -- and the later assignment silently won, which
      // is how progress came to read 86 on an idle engine in simulation.
      if (prog_rst) begin
        acc <= 32'd0; progress <= 7'd0;
      end else if (busy && tot != 0 && (acc + {15'd0, acc_inc}) >= tot && progress < 7'd100) begin
        acc <= acc + {15'd0, acc_inc} - tot; progress <= progress + 1'b1;
      end else acc <= acc + {15'd0, acc_inc};
    end
  end
endmodule
