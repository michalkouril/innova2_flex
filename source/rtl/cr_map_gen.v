// SPDX-FileCopyrightText: 2026 the innova2 contributors
// SPDX-FileCopyrightText: Mellanox Technologies Ltd.
//
// SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

`timescale 1ns/1ps
// GENERATED from a sweep of the register (CR) space of Mellanox's Flex image -- DO NOT EDIT BY HAND.
// 8634 addresses answered. (The sweep and generator scripts are not included in this repository.)
//
// WHY THIS IS GENERATED. The map it replaces had 19 entries hand-copied from the vendor app's
// #define table, so it could only ever contain registers someone already knew to look for. Asking
// the hardware about the address SPACE instead of about the list returned 8634 answering addresses.
// The generator replays this output against every captured address and refuses to write unless all
// of them match, so a transcription error cannot reach the bitstream.
//
// 0x00008000-0x0000FFFF is ONE 4 KB block ALIASED eight times -- verified, not assumed: the 0x8000
// page replays against 0x9000..0xFFFF with only live sensor words differing. Decoded on a[11:0],
// which is what makes 32 KB of address space cost 157 entries instead of 8192.
//
// Everything outside a listed region still returns 0x8BADF00D. That default is load-bearing: the
// vendor returns it too, and two app poll loops (fan tacho 0x420 bit0, BIST 0x20004[3:2]) TERMINATE
// against it where a 0 would hang them for ever.
//
// The die temperature at page offset 0x400 is OVERRIDDEN with the live SYSMONE4 reading by
// i2c_cr_slave -- a captured constant there would be the mistake in a new costume.
module cr_map (
  input  wire [31:0] a,
  output reg  [31:0] d
);
  always @* begin
    if (a[31:16] == 16'h0000 && a[15:12] >= 4'h8) begin
      case (a[11:0])
        12'h004: d = 32'h000001C8;
        12'h008: d = 32'h00000102;
        12'h060: d = 32'h00000032;
        12'h400: d = 32'h00009D1E;
        12'h404: d = 32'h00004879;
        12'h408: d = 32'h00009B3B;
        12'h418: d = 32'h00004874;
        12'h420: d = 32'h0000FFCC;
        12'h424: d = 32'h0000FFC2;
        12'h428: d = 32'h0000FFC3;
        12'h434: d = 32'h0000000A;
        12'h438: d = 32'h0000000D;
        12'h43C: d = 32'h00000008;
        12'h480: d = 32'h00009F04;
        12'h490: d = 32'h00009BC4;
        12'h494: d = 32'h0000FFFF;
        12'h498: d = 32'h0000FFFF;
        12'h49C: d = 32'h0000FFFF;
        12'h4B0: d = 32'h0000FFFF;
        12'h4B4: d = 32'h0000FFFF;
        12'h4B8: d = 32'h0000FFFF;
        12'h4C0: d = 32'h000000FE;
        12'h4C4: d = 32'h000000FE;
        12'h4C8: d = 32'h000000FA;
        12'h4CC: d = 32'h00000014;
        12'h4D0: d = 32'h00000C65;
        12'h4D4: d = 32'h000018DE;
        12'h4E0: d = 32'h00000005;
        12'h4E4: d = 32'h00009B32;
        12'h4E8: d = 32'h00000006;
        12'h4EC: d = 32'h0000A029;
        12'h4F0: d = 32'h00001481;
        12'h4FC: d = 32'h00000001;
        12'h500: d = 32'h00002000;
        12'h504: d = 32'h0000219C;
        12'h508: d = 32'h00000A00;
        12'h50C: d = 32'h0000208F;
        12'h514: d = 32'h0000C210;
        12'h520: d = 32'h00000900;
        12'h540: d = 32'h0000C467;
        12'h544: d = 32'h00004E81;
        12'h548: d = 32'h0000A147;
        12'h54C: d = 32'h0000CBF3;
        12'h550: d = 32'h0000AB2F;
        12'h554: d = 32'h00004963;
        12'h558: d = 32'h00009555;
        12'h55C: d = 32'h0000C972;
        12'h560: d = 32'h00004E81;
        12'h564: d = 32'h00005555;
        12'h568: d = 32'h00009999;
        12'h56C: d = 32'h00006AAA;
        12'h570: d = 32'h00004963;
        12'h574: d = 32'h00005111;
        12'h578: d = 32'h000091EB;
        12'h57C: d = 32'h00006666;
        12'h580: d = 32'h00009A74;
        12'h584: d = 32'h00004DA6;
        12'h588: d = 32'h00009A74;
        12'h58C: d = 32'h00009A74;
        12'h5A0: d = 32'h000098BF;
        12'h5A4: d = 32'h00004BF2;
        12'h5A8: d = 32'h000098BF;
        12'h5AC: d = 32'h000098BF;
        12'h6A0: d = 32'h0000FFFF;
        12'h6A4: d = 32'h0000FFFF;
        12'h6A8: d = 32'h0000FFFF;
        12'h6AC: d = 32'h0000FFFF;
        12'h6B0: d = 32'h0000FFFF;
        12'h6B4: d = 32'h0000FFFF;
        12'h724: d = 32'h0000FFFF;
        12'h740: d = 32'h00000001;
        12'h75C: d = 32'h00000001;
        12'h7A0: d = 32'h0000FFFF;
        12'h7A4: d = 32'h0000FFFF;
        12'h7A8: d = 32'h0000FFFF;
        12'h7AC: d = 32'h0000FFFF;
        12'h7B0: d = 32'h0000FFFF;
        12'h7B4: d = 32'h0000FFFF;
        12'h804: d = 32'h000001C8;
        12'h808: d = 32'h00000102;
        12'h860: d = 32'h00000032;
        12'hC00: d = 32'h00009D7A;
        12'hC04: d = 32'h00004879;
        12'hC08: d = 32'h00009B3B;
        12'hC0C: d = 32'h00000007;
        12'hC18: d = 32'h00004874;
        12'hC20: d = 32'h0000FFD2;
        12'hC24: d = 32'h0000FFBC;
        12'hC28: d = 32'h0000FFD0;
        12'hC34: d = 32'h0000000A;
        12'hC38: d = 32'h0000000D;
        12'hC3C: d = 32'h00000008;
        12'hC80: d = 32'h00009F04;
        12'hC90: d = 32'h00009BC4;
        12'hC94: d = 32'h0000FFFF;
        12'hC98: d = 32'h0000FFFF;
        12'hC9C: d = 32'h0000FFFF;
        12'hCB0: d = 32'h0000FFFF;
        12'hCB4: d = 32'h0000FFFF;
        12'hCB8: d = 32'h0000FFFF;
        12'hCC0: d = 32'h000000FC;
        12'hCC4: d = 32'h000000FE;
        12'hCC8: d = 32'h000000F9;
        12'hCCC: d = 32'h00000008;
        12'hCD0: d = 32'h00000C67;
        12'hCD4: d = 32'h000018E0;
        12'hCE0: d = 32'h00000005;
        12'hCE4: d = 32'h00009B32;
        12'hCE8: d = 32'h00000006;
        12'hCEC: d = 32'h0000A029;
        12'hCF0: d = 32'h00001481;
        12'hCFC: d = 32'h00000001;
        12'hD00: d = 32'h00002000;
        12'hD04: d = 32'h0000219C;
        12'hD08: d = 32'h00000A00;
        12'hD0C: d = 32'h0000208F;
        12'hD14: d = 32'h0000C210;
        12'hD20: d = 32'h00000900;
        12'hD40: d = 32'h0000C467;
        12'hD44: d = 32'h00004E81;
        12'hD48: d = 32'h0000A147;
        12'hD4C: d = 32'h0000CBF3;
        12'hD50: d = 32'h0000AB2F;
        12'hD54: d = 32'h00004963;
        12'hD58: d = 32'h00009555;
        12'hD5C: d = 32'h0000C972;
        12'hD60: d = 32'h00004E81;
        12'hD64: d = 32'h00005555;
        12'hD68: d = 32'h00009999;
        12'hD6C: d = 32'h00006AAA;
        12'hD70: d = 32'h00004963;
        12'hD74: d = 32'h00005111;
        12'hD78: d = 32'h000091EB;
        12'hD7C: d = 32'h00006666;
        12'hD80: d = 32'h00009A74;
        12'hD84: d = 32'h00004DA6;
        12'hD88: d = 32'h00009A74;
        12'hD8C: d = 32'h00009A74;
        12'hDA0: d = 32'h000098BF;
        12'hDA4: d = 32'h00004BF2;
        12'hDA8: d = 32'h000098BF;
        12'hDAC: d = 32'h000098BF;
        12'hEA0: d = 32'h0000FFFF;
        12'hEA4: d = 32'h0000FFFF;
        12'hEA8: d = 32'h0000FFFF;
        12'hEAC: d = 32'h0000FFFF;
        12'hEB0: d = 32'h0000FFFF;
        12'hEB4: d = 32'h0000FFFF;
        12'hF24: d = 32'h0000FFFF;
        12'hF40: d = 32'h00000001;
        12'hF5C: d = 32'h00000001;
        12'hFA0: d = 32'h0000FFFF;
        12'hFA4: d = 32'h0000FFFF;
        12'hFA8: d = 32'h0000FFFF;
        12'hFAC: d = 32'h0000FFFF;
        12'hFB0: d = 32'h0000FFFF;
        12'hFB4: d = 32'h0000FFFF;
        default: d = 32'h00000000;   // the block answers everywhere: zero, not sentinel
      endcase
    end else if (a >= 32'h00000030 && a <= 32'h00000064) d = 32'h00000000;
    else if (a >= 32'h00000100 && a <= 32'h00000148) d = 32'h00000000;
    else if (a >= 32'h00000200 && a <= 32'h00000218) d = 32'h00000000;
    else if (a >= 32'h00000410 && a <= 32'h00000420) d = 32'h00000000;
    else if (a >= 32'h00020008 && a <= 32'h00020024) d = 32'h00000000;
    else if (a >= 32'h00020060 && a <= 32'h000200E4) d = 32'h00000000;
    else if (a >= 32'h00020410 && a <= 32'h000204FC) d = 32'hDEADDEAD;
    else if (a >= 32'h00020508 && a <= 32'h0002057C) d = 32'hDEADDEAD;
    else if (a >= 32'h00020584 && a <= 32'h000205BC) d = 32'hDEADDEAD;
    else if (a >= 32'h000205C8 && a <= 32'h000205FC) d = 32'hDEADDEAD;
    else if (a >= 32'h00020608 && a <= 32'h0002067C) d = 32'hDEADDEAD;
    else if (a >= 32'h00020684 && a <= 32'h000206BC) d = 32'hDEADDEAD;
    else if (a >= 32'h000206C8 && a <= 32'h000207FC) d = 32'hDEADDEAD;
    else if (a >= 32'h00040000 && a <= 32'h0004000C) d = 32'h00000000;
    else if (a >= 32'h00040024 && a <= 32'h0004003C) d = 32'h00000000;
    else if (a >= 32'h00050000 && a <= 32'h0005000C) d = 32'h00000000;
    else if (a >= 32'h00050024 && a <= 32'h0005003C) d = 32'h00000000;
    else if (a >= 32'h00060008 && a <= 32'h0006001C) d = 32'h00000000;
    else begin
      case (a)
        32'h00000000: d = 32'h00000000;
        32'h00000004: d = 32'h00000000;
        32'h00000008: d = 32'h00000000;
        32'h0000000C: d = 32'h00000001;
        32'h00000010: d = 32'h00000002;
        32'h00000014: d = 32'h00000000;
        32'h00000018: d = 32'h00000000;
        32'h0000001C: d = 32'h00000000;
        32'h00000020: d = 32'h00000007;
        32'h00000024: d = 32'h00000000;
        32'h0000002C: d = 32'h00000005;
        32'h00000068: d = 32'hA5A5A5A5;
        32'h0000006C: d = 32'h01234567;
        32'h00000070: d = 32'h00000000;
        32'h0000014C: d = 32'h00000001;
        32'h00000300: d = 32'h000002EB;
        32'h00000304: d = 32'h00000000;
        32'h00000400: d = 32'h00000064;
        32'h00000404: d = 32'h00000020;
        32'h00000408: d = 32'h00000001;
        32'h0000040C: d = 32'h00000064;
        32'h00020000: d = 32'h00000000;
        32'h00020004: d = 32'h00000008;
        32'h00020028: d = 32'h00000010;
        32'h0002002C: d = 32'h00000001;
        32'h00020030: d = 32'h00000001;
        32'h00020034: d = 32'h00000000;
        32'h00020038: d = 32'h00000001;
        32'h00020040: d = 32'h00000001;
        32'h00020044: d = 32'h00000000;
        32'h00020048: d = 32'h00000000;
        32'h0002004C: d = 32'hFFFFFFFF;
        32'h00020050: d = 32'h000003F0;
        32'h00020054: d = 32'h00000001;
        32'h00020100: d = 32'h00000017;
        32'h00020108: d = 32'h08000000;
        32'h0002010C: d = 32'h00000000;
        32'h00020110: d = 32'h08000000;
        32'h00020114: d = 32'h00000000;
        32'h00020118: d = 32'h00000000;
        32'h00020400: d = 32'h00000000;
        32'h00020404: d = 32'h00000000;
        32'h00020408: d = 32'h00000001;
        32'h0002040C: d = 32'h00000000;
        32'h00020500: d = 32'h00000000;
        32'h00020504: d = 32'h00000000;
        32'h00020580: d = 32'h00000000;
        32'h000205C0: d = 32'h00000000;
        32'h000205C4: d = 32'h00000000;
        32'h00020600: d = 32'h00000000;
        32'h00020604: d = 32'h00000000;
        32'h00020680: d = 32'h00000000;
        32'h000206C0: d = 32'h00000000;
        32'h000206C4: d = 32'h00000000;
        32'h00040010: d = 32'h00000005;
        32'h00040014: d = 32'h00000001;
        32'h00040018: d = 32'h00000000;
        32'h0004001C: d = 32'h00000000;
        32'h00040020: d = 32'h00000004;
        32'h00040100: d = 32'h00000000;
        32'h00050010: d = 32'h00000005;
        32'h00050014: d = 32'h00000001;
        32'h00050018: d = 32'h00000000;
        32'h0005001C: d = 32'h00000000;
        32'h00050020: d = 32'h00000004;
        32'h00060000: d = 32'h00000001;
        32'h00060004: d = 32'h01000000;
        32'h00060020: d = 32'hFFFFFF9B;
        32'h00060024: d = 32'h00000001;
        32'h00060028: d = 32'h00000001;
        32'h0006002C: d = 32'h00000000;
        32'h00060030: d = 32'h00000000;
        32'h00060034: d = 32'h0C400080;
        32'h00060038: d = 32'h00000000;
        32'h0006003C: d = 32'h00000001;
        32'h00060040: d = 32'h00000000;
        32'h00060044: d = 32'h3C000000;
        32'h00060048: d = 32'h00000000;
        32'h0006004C: d = 32'h00000000;
        // IDENTITY BLOCK -- ours, not the vendor's (inn2f r2, 2026-09-30, USERCODE 0xDD500132). The captured
        // vendor values were 0x000000C1 / 0x27112018 / 0x00115632. These table entries are what the ConnectX
        // and innova2_app read; i2c_cr_slave's IMAGE_* parameters are NOT used.
        32'h00900000: d = 32'h0000DD02;     // image_version
        32'h00900004: d = 32'h30092026;     // image_date, BCD DDMMYYYY
        32'h00900008: d = 32'h00192544;     // image_time, BCD 00HHMMSS
        32'h0090000C: d = 32'h00000004;
        32'h00900010: d = 32'h0000000A;
        32'h0090006C: d = 32'h00000002;
        default: d = 32'h8BADF00D;
      endcase
    end
  end
endmodule
