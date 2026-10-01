// SPDX-FileCopyrightText: 2026 the innova2 contributors
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
// the responder used to ACK a write and throw it away. This drives a REAL 12-byte I2C write
// transaction at it -- address bytes then data bytes, exactly the shape the ConnectX sends -- and
// then reads the same address back through the overlay. Testing cr_regs alone would not catch the
// byte that matters: whether bytes 8..11 are assembled in the right order and committed once.
module tb_cr_write;
  reg clk = 0; always #5 clk = ~clk;                 // 100 MHz
  reg  m_scl = 1, m_sda_oe = 0;                      // master, open drain
  wire dut_sda_oe;
  wire sda = (m_sda_oe | dut_sda_oe) ? 1'b0 : 1'b1;  // wired-AND with pull-up
  wire scl = m_scl;

  wire [31:0] wr_addr, wr_data, ovl_data; wire wr_stb, ovl_hit; wire [15:0] power;
  cr_regs #(.CLK_HZ(1000)) u_regs (
    .clk(clk), .wr_addr(wr_addr), .wr_data(wr_data), .wr_stb(wr_stb),
    .rd_addr(u_dut.craddr[31:0]), .hit(ovl_hit), .rdata(ovl_data),
    .tach_in(1'b0), .power_level(power));

  i2c_cr_slave u_dut (
    .clk(clk), .scl_i(scl), .sda_i(sda), .temp_raw(16'h1234),
    // tie the live-sensor port off so this test exercises the map/overlay path only;
    // leaving it unconnected makes drp_valid X and the priority mux indeterminate.
    .drp_sel(), .drp_val(16'd0), .drp_valid(1'b0),
    .wr_addr(wr_addr), .wr_data(wr_data), .wr_stb(wr_stb),
    .ovl_hit(ovl_hit), .ovl_data(ovl_data),
    .sda_oe(dut_sda_oe), .dbg_state());

  localparam integer Q = 2500;                        // ~100 kHz bit period quarter
  task i2c_start; begin m_sda_oe = 0; #Q; m_scl = 1; #Q; m_sda_oe = 1; #Q; m_scl = 0; #Q; end endtask
  task i2c_stop;  begin m_sda_oe = 1; #Q; m_scl = 1; #Q; m_sda_oe = 0; #Q; end endtask
  task i2c_wbyte(input [7:0] b, output ack);
    integer i;
    begin
      for (i = 7; i >= 0; i = i - 1) begin
        m_sda_oe = ~b[i];  #Q; m_scl = 1; #(2*Q); m_scl = 0; #Q;
      end
      m_sda_oe = 0; #Q; m_scl = 1; #Q; ack = ~sda; #Q; m_scl = 0; #Q;   // slave pulls low to ACK
    end
  endtask
  task i2c_rbyte(input ack_it, output [7:0] b);
    integer i;
    begin
      b = 0; m_sda_oe = 0;
      for (i = 7; i >= 0; i = i - 1) begin
        #Q; m_scl = 1; #Q; b[i] = sda; #Q; m_scl = 0; #Q;
      end
      m_sda_oe = ack_it; #Q; m_scl = 1; #(2*Q); m_scl = 0; #Q; m_sda_oe = 0;
    end
  endtask

  integer errs = 0; reg a; reg [7:0] d0, d1, d2, d3;
  reg seen_stb; reg [31:0] seen_addr, seen_data;
  always @(posedge clk) if (wr_stb) begin seen_stb <= 1'b1; seen_addr <= wr_addr; seen_data <= wr_data; end

  initial begin
    seen_stb = 0; #20000;
    // ---- WRITE 0x00000024 = 0x00000300 (the app's "power = 768") ----
    i2c_start;
    i2c_wbyte(8'h80, a); if (!a) begin $display("FAIL no ACK for the slave address"); errs=errs+1; end
    i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a);  // addr_hi
    i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h24, a);  // addr_lo
    i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h03, a); i2c_wbyte(8'h00, a);  // data
    i2c_stop;
    #20000;
    if (!seen_stb) begin $display("FAIL no write strobe -- the data bytes went nowhere"); errs=errs+1; end
    else if (seen_addr !== 32'h00000024) begin $display("FAIL write address %08x", seen_addr); errs=errs+1; end
    else if (seen_data !== 32'h00000300) begin $display("FAIL write data %08x, want 00000300", seen_data); errs=errs+1; end
    else $display("PASS a 12-byte write reaches the register file with address and data intact");
    if (power !== 16'd768) begin $display("FAIL power_level %0d", power); errs=errs+1; end

    // ---- READ it back: address phase, repeated START, four data bytes ----
    i2c_start;
    i2c_wbyte(8'h80, a);
    i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a);
    i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h00, a); i2c_wbyte(8'h24, a);
    i2c_start;
    i2c_wbyte(8'h81, a); if (!a) begin $display("FAIL no ACK for the read address"); errs=errs+1; end
    i2c_rbyte(1'b1, d0); i2c_rbyte(1'b1, d1); i2c_rbyte(1'b1, d2); i2c_rbyte(1'b0, d3);
    i2c_stop;
    if ({d0,d1,d2,d3} !== 32'h00000300) begin
      $display("FAIL read back %02x%02x%02x%02x, want 00000300", d0,d1,d2,d3); errs=errs+1;
    end else $display("PASS the written value reads back over I2C through the overlay");

    $display("CR-WRITE-TB %s (%0d errors)", errs ? "FAIL" : "PASS", errs);
    $finish;
  end
  initial begin #50_000_000; $display("CR-WRITE-TB FAIL (timeout)"); $finish; end
endmodule

// The captured map is 8634 addresses of generated Verilog and none of it is under test here; a stub
// keeps the compile quick and makes "fell through to the map" visible as the sentinel.
module cr_map (input wire [31:0] a, output wire [31:0] d);
  assign d = 32'h8BADF00D;
endmodule
