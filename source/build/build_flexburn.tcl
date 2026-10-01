# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# FLEX REPLACEMENT IMAGE **WITH THE VENDOR BURN ENDPOINT** -- derived from
# build_flexrepl.tcl, which is itself the flash-rescue block design plus our responder.
#
# What is new here:
#   * the endpoint advertises 15b3:0264 with a 2 MB BAR0, which is what the Innova2 Flex Open app
#     and its bope driver filter on, and what the vendor's own Flex image presents;
#   * the control fabric gains a second master and a second slave, so the host reaches our BOPE
#     register at BAR0+0 while the burn engine drives the flash controller at 0x40000;
#   * the top is flex_burn_top: responder + E4 acceptance waveform + E3 dispatch + the burn engine.
#
# The link stays X4 Gen1 on GTY quad 127. That is not a compromise for this card -- a test measured
# only four of the eight internal lanes linking on Host C's card, which is exactly why the vendor's
# x8 image shows no endpoint there while ours will.
#
# The PCIe + dual-quad-SPI block design below is the flash-rescue one VERBATIM, because it is the
# only configuration on this card proven to train a link. What is added is a hand-written
# top, flex_burn_top.v, which instantiates that block design alongside the I2C CR responder and the
# boot-capture instruments -- so the image both LINKS and ANSWERS.
#
# Original header follows.
# FLASH RESCUE IMAGE.
#
# Purpose: a design that can be JTAG-loaded onto a card whose flash cannot be written by any other
# route, and which then exposes the QSPI controller over PCIe so xbflash can reprogram the flash.
#
# The two hard requirements, both learned the hard way:
#  1. **The BAR footprint must match whatever booted from FLASH**, because the BIOS sizes the bridge
#     windows at boot and a rescan cannot enlarge them (loading a User image with larger BARs over JTAG
#     succeeded but its BARs could not be assigned -- "no space", windows [disabled]). The card in
#     question booted a test image that asks for exactly ONE 32 MB BAR0, so this design copies
#     that image's XDMA configuration verbatim: AXI_Bridge, X2, 2.5_GT/s, 62.5 MHz, 64-bit,
#     device_id 9038, pf0_bar0 32 Megabytes. Same footprint -> the existing assignment stays valid
#     and only the FPGA's own config space needs writing back with setpci.
#  2. **Both flash chips must be reachable**, so the axi_quad_spi is configured dual-quad and its
#     SPI_1 interface is brought out to AM12/AN12/AR13/AR12 + AV11, without which
#     only half of a striped x8 image is written.
#
# Deliberately minimal: no DDR, no DFX partition, no BIST, no ICAP. Those are what make the tester
# static slow to build and none of them matter for writing flash.
# package-relative: this file lives in <pkg>/source/build
set PKG  [file normalize [file join [file dirname [info script]] ..]]
set ROOT $PKG
set PART xcku15p-ffve1517-2-i
set PRJ  $::env(FLEX_BUILD_DIR)/prj
set OUT  $::env(FLEX_BUILD_DIR)/out

proc chk {what body} {
  if {[catch {uplevel 1 $body} e]} { puts "RESCUE *** $what FAILED: [string range $e 0 400]"; exit 1 }
  puts "RESCUE ok: $what"
}

create_project flexburn $PRJ -part $PART -force
create_bd_design flexburn_bd

# ---------------------------------------------------------------- PCIe, based on a working User image
create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_0
set x [get_bd_cells /xdma_0]
chk "xdma config" {
  set_property -dict [list \
    CONFIG.mode_selection {Advanced} \
    CONFIG.functional_mode {AXI_Bridge} \
    CONFIG.pl_link_cap_max_link_width $::env(LINKW) \
    CONFIG.pl_link_cap_max_link_speed {2.5_GT/s} \
    CONFIG.axisten_freq $::env(AXIF) \
    CONFIG.axi_data_width {64_bit} \
    CONFIG.vendor_id {15B3} \
    CONFIG.pf0_device_id {0264} \
    CONFIG.pf0_class_code_base {02} \
    CONFIG.pf0_class_code_sub {00} \
    CONFIG.pf0_class_code_interface {00} \
    CONFIG.pf0_subsystem_vendor_id {15B3} \
    CONFIG.pf0_subsystem_id {0264} \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {2} \
    CONFIG.xdma_num_usr_irq {1} \
    CONFIG.en_axi_slave_if {false} ] $x }
# The IP silently COERCES illegal combinations, so read back rather than trust the set.
# select_quad MUST name the quad holding lane 0. AH36 = GTYE4_CHANNEL_X0Y0 = GTY bank 127;
# the eight CX5 lanes span quads 127-128. Inherited from the User image's configuration as GTY_Quad_130 -- the
# shipping-Alveo value -- which is why every design here trains x4 while Mellanox's gets x8.
# GT selection is a DEPENDENT pair and must be set after the main dict, in order: enabling the
# override first, then the quad. Folded into the dict above it fails the whole set_property.
# setting vendor_id RESETS pf0_device_id to that vendor's default -- asked 0264, got 9014.
# The build gate caught it, which is the whole reason these are read back. Identity fields are a
# DEPENDENT set and have to be applied after the main dict, vendor first, then device and subsystem.
# OUR X4 CONFIG NEVER TRAINS. Measured on Host B, whose card links x8 under the vendor image:
# the core is clocked (AXI heartbeat toggling from ~560 ms) and the ConnectX released PERSTn at
# ~510 ms, but user_lnk_up stayed LOW, and a secondary bus reset did not change it. So copy the
# placement and lane settings from a working User image's own XDMA configuration,
# which enumerates on both cards, and change only what has to change: AXI_Bridge, the identity, the
# BAR and the width. `lane_order {Bottom}` is the one that was never set here and inverts the
# lane-to-channel mapping if wrong -- exactly a link that clocks and never trains.
# ask the core WHY. enable_ltssm_dbg exposes ltssm_state -- the link training state machine's
# own state. Detect means no receiver was seen on the lanes at all; Polling means the partner is
# there and training fails; L0 means it trained. user_lnk_up cannot tell those apart, and that is
# exactly the difference between "wrong lanes" and "wrong speed or config".
chk "ltssm debug" { set_property CONFIG.enable_ltssm_dbg {true} $x }
chk "shipping lane settings" {
  set_property CONFIG.en_gt_selection {false} $x
  set_property CONFIG.pcie_blk_locn {X0Y2} $x
  set_property CONFIG.lane_order {Bottom} $x
  set_property CONFIG.enable_lane_reversal {false} $x
  set_property CONFIG.sys_reset_polarity {ACTIVE_LOW} $x }

# IDENTITY GOES LAST: the IP recomputes pf0_device_id whenever a structural property changes
# -- setting vendor_id alone moved it to 9014, and setting it before select_quad let the quad change
# move it again. Twice the gate caught a build that would have enumerated as the wrong device and
# been invisible to the burn utility, which filters on exactly 15b3:0264.
chk "identity" {
  set_property CONFIG.vendor_id {15B3} $x
  set_property CONFIG.pf0_device_id {0264} $x
  set_property CONFIG.pf0_subsystem_vendor_id {15B3} $x
  set_property CONFIG.pf0_subsystem_id {0264} $x
  set_property CONFIG.pf0_class_code_base {02} $x
  set_property CONFIG.pf0_class_code_sub {00} $x
  set_property CONFIG.pf0_class_code_interface {00} $x }


# ADVERTISE WHAT WE CAN ACTUALLY TRAIN. Every design here has advertised LnkCap x8 and
# trained x4, which lspci calls "(downgraded)" -- a degraded link is exactly what a supervisor's
# health check would flag, and Mellanox's Flex image reads "x8 (ok)". Probing the IP shows quad 127,
# where this board's lane 0 physically is, caps at X4 from either PCIe block (X8 is only offered
# anchored at quad 128+, i.e. channels the board does not wire to the ConnectX). So ask for X4 and
# match it: LnkCap x4 / LnkSta x4 = "(ok)". `en_gt_selection` is what makes select_quad stick at all.
# the app's two transports BOTH filter on 15b3:0264 ("Morse device"), so a coerced ID is not
# a cosmetic difference -- it is the difference between a burn endpoint and an invisible one.
foreach {p want} [list pl_link_cap_max_link_speed {2.5_GT/s} pl_link_cap_max_link_width $::env(LINKW) \
                       lane_order {Bottom} pcie_blk_locn {X0Y2} pf0_bar0_size {2} \
                       vendor_id {15B3} pf0_device_id {0264} pf0_class_code {020000} \
                       pf0_subsystem_vendor_id {15B3} pf0_subsystem_id {0264}] {
  set got [get_property -quiet CONFIG.$p $x]
  puts "RESCUE xdma $p = $got"
  if {$got ne $want} { puts "RESCUE *** COERCED to '$got', asked '$want'"; exit 1 } }
# Reported, not gated: the IP is free to pick any legal AXI pairing for Gen1 x8.
set AXIFREQ [get_property -quiet CONFIG.axisten_freq $x]
puts "RESCUE xdma axisten_freq = $AXIFREQ (chosen by the IP)"
puts "RESCUE xdma axi_data_width = [get_property -quiet CONFIG.axi_data_width $x]"

create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 refclk_buf
set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells /refclk_buf]
chk "refclk->sys_clk_gt" { connect_bd_net [get_bd_pins /refclk_buf/IBUF_OUT]      [get_bd_pins /xdma_0/sys_clk_gt] }
chk "refclk->sys_clk"    { connect_bd_net [get_bd_pins /refclk_buf/IBUF_DS_ODIV2] [get_bd_pins /xdma_0/sys_clk] }

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 irq_tie
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {1}] [get_bd_cells /irq_tie]
chk "usr_irq tie" { connect_bd_net [get_bd_pins /irq_tie/dout] [get_bd_pins /xdma_0/usr_irq_req] }

# ---------------------------------------------------------------- control fabric
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_ctrl
# Two masters and two slaves: the host (through the BAR) and the burn engine both need the flash
# controller, and the host additionally needs our BOPE register at BAR0 + 0.
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {2}] [get_bd_cells /sc_ctrl]
chk "xdma->sc"     { connect_bd_intf_net [get_bd_intf_pins /xdma_0/M_AXI_B] [get_bd_intf_pins /sc_ctrl/S00_AXI] }
chk "sc aclk"      { connect_bd_net [get_bd_pins /xdma_0/axi_aclk]    [get_bd_pins /sc_ctrl/aclk] }
chk "sc aresetn"   { connect_bd_net [get_bd_pins /xdma_0/axi_aresetn] [get_bd_pins /sc_ctrl/aresetn] }

# SPI clock. C_SCK_RATIO is FORCED to 2 in dual-quad + STARTUP mode, so SCK = ext_spi_clk / 2.
# 20 MHz -> 10 MHz SCK, the setting proven in our User images; the 62.5 MHz control clock
# would give 31 MHz, which is not worth risking on a board whose trace delays we do not have.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_spi
chk "clk_wiz_spi cfg" {
  set_property -dict [list CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {20.000} \
                           CONFIG.PRIM_SOURCE {No_buffer} \
                           CONFIG.PRIM_IN_FREQ $AXIFREQ \
                           CONFIG.RESET_PORT {resetn} CONFIG.RESET_TYPE {ACTIVE_LOW}] [get_bd_cells /clk_wiz_spi] }
chk "spi clk in"  { connect_bd_net [get_bd_pins /xdma_0/axi_aclk]    [get_bd_pins /clk_wiz_spi/clk_in1] }
chk "spi clk rst" { connect_bd_net [get_bd_pins /xdma_0/axi_aresetn] [get_bd_pins /clk_wiz_spi/resetn] }
chk "sc aclk1"    { connect_bd_net [get_bd_pins /clk_wiz_spi/clk_out1] [get_bd_pins /sc_ctrl/aclk1] }

# ---------------------------------------------------------------- the flash controller
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi mgmt_flash
set q [get_bd_cells /mgmt_flash]
# Single -dict: set one at a time and C_DUAL_QUAD_MODE silently stays 0 because it depends on
# C_NUM_SS_BITS=2 and quad mode already being in force.
chk "qspi cfg" {
  set_property -dict [list \
    CONFIG.C_SPI_MODE {2} CONFIG.C_NUM_SS_BITS {2} CONFIG.C_SPI_MEMORY {2} \
    CONFIG.C_DUAL_QUAD_MODE {1} CONFIG.C_USE_STARTUP {1} CONFIG.C_USE_STARTUP_INT {1} \
    CONFIG.C_FIFO_DEPTH {256} CONFIG.C_TYPE_OF_AXI4_INTERFACE {0} CONFIG.C_XIP_MODE {0} ] $q }
foreach p {C_SPI_MODE C_NUM_SS_BITS C_SPI_MEMORY C_DUAL_QUAD_MODE C_USE_STARTUP C_SCK_RATIO} {
  puts "RESCUE qspi $p = [get_property -quiet CONFIG.$p $q]" }
if {[get_property CONFIG.C_DUAL_QUAD_MODE $q] != 1} {
  puts "RESCUE *** C_DUAL_QUAD_MODE did not take -- would address only one of the two chips"; exit 1 }
chk "sc->qspi"    { connect_bd_intf_net [get_bd_intf_pins /sc_ctrl/M00_AXI] [get_bd_intf_pins /mgmt_flash/AXI_LITE] }
chk "qspi aclk"   { connect_bd_net [get_bd_pins /xdma_0/axi_aclk]      [get_bd_pins /mgmt_flash/s_axi_aclk] }
chk "qspi arstn"  { connect_bd_net [get_bd_pins /xdma_0/axi_aresetn]   [get_bd_pins /mgmt_flash/s_axi_aresetn] }
chk "qspi extclk" { connect_bd_net [get_bd_pins /clk_wiz_spi/clk_out1] [get_bd_pins /mgmt_flash/ext_spi_clk] }

# ---------------------------------------------------------------- external ports
chk "ext pcie"   { make_bd_intf_pins_external -name pci_express_x8 [get_bd_intf_pins /xdma_0/pcie_mgt] }
chk "ext refclk" { make_bd_intf_pins_external -name pcie_refclk    [get_bd_intf_pins /refclk_buf/CLK_IN_D] }
chk "ext perstn" { make_bd_pins_external      -name pcie_perstn    [get_bd_pins /xdma_0/sys_rst_n] }
# The SECOND flash chip. Without this the IP's SPI_1 dangles and slave select 1 reaches
# nothing -- exactly the defect that made every xbflash write only half a striped image.
chk "ext spi1"   { make_bd_intf_pins_external -name spi1 [get_bd_intf_pins /mgmt_flash/SPI_1] }
# M01 carries BAR0 + 0 out to bope_regs; S01 brings the burn engine's own master in. Both live in
# the XDMA's AXI clock domain, so that clock and its reset come out too.
chk "ext m01" { make_bd_intf_pins_external -name M01_AXI [get_bd_intf_pins /sc_ctrl/M01_AXI] }
chk "ext s01" { make_bd_intf_pins_external -name S01_AXI [get_bd_intf_pins /sc_ctrl/S01_AXI] }
# make_bd_pins_external SILENTLY DOES NOTHING for a pin that already drives something -- it
# reported ok and created no port, and the failure only surfaced two steps later as "set_property
# expects at least one object". Create the port and connect it explicitly instead.
# the endpoint did not enumerate on Host C's card. Before blaming the link, ask the core:
# user_lnk_up is the XDMA's own view, readable over JTAG with no PCIe at all.
chk "ext lnkup" { create_bd_port -dir O user_lnk_up
                  connect_bd_net [get_bd_pins /xdma_0/user_lnk_up] [get_bd_ports user_lnk_up] }
# The pin is cfg_ltssm_state, not ltssm_state. The gate caught the guess, which is what it is for:
# a silently missing debug port would have produced six constant bits and a confident wrong reading.
set ltp [get_bd_pins -quiet /xdma_0/cfg_ltssm_state]
if {$ltp eq ""} { puts "RESCUE *** no cfg_ltssm_state pin -- enable_ltssm_dbg did not take"; exit 1 }
set ltw [get_property LEFT $ltp]
puts "RESCUE cfg_ltssm_state is \[$ltw:0\]"
if {$ltw != 5} { puts "RESCUE *** cfg_ltssm_state is \[$ltw:0\], the top wires \[5:0\]"; exit 1 }
chk "ext ltssm" { create_bd_port -dir O -from $ltw -to 0 ltssm_state
                  connect_bd_net $ltp [get_bd_ports ltssm_state] }
chk "ext aclk"  { create_bd_port -dir O -type clk axi_aclk
                  connect_bd_net [get_bd_pins /xdma_0/axi_aclk] [get_bd_ports axi_aclk] }
chk "ext arstn" { create_bd_port -dir O -type rst axi_aresetn
                  connect_bd_net [get_bd_pins /xdma_0/axi_aresetn] [get_bd_ports axi_aresetn] }
# An external AXI port defaults to 100 MHz and to no clock association, and the BD then refuses to
# validate ("FREQ_HZ does not match"). Both ports live in the XDMA's AXI domain -- say so.
set AXIHZ [expr {int([get_property -quiet CONFIG.axisten_freq $x] * 1000000)}]
# make_bd_*_external may append a suffix, so find the ports rather than assume their names --
# assuming cost a build here ("set_property expects at least one object").
set P_M01 [get_bd_intf_ports -quiet *M01*]
set P_S01 [get_bd_intf_ports -quiet *S01*]
set P_CLK [get_bd_ports -quiet *axi_aclk*]
puts "RESCUE external ports: M01='$P_M01' S01='$P_S01' clk='$P_CLK'"
puts "RESCUE all bd intf ports : [get_bd_intf_ports -quiet *]"
if {$P_M01 eq "" || $P_S01 eq "" || $P_CLK eq ""} { puts "RESCUE *** external AXI ports not found"; exit 1 }
chk "ext axi clocking" {
  set_property CONFIG.FREQ_HZ $AXIHZ $P_M01
  set_property CONFIG.FREQ_HZ $AXIHZ $P_S01
  set_property CONFIG.FREQ_HZ $AXIHZ $P_CLK
  set_property CONFIG.ASSOCIATED_BUSIF "[get_property NAME $P_M01]:[get_property NAME $P_S01]" $P_CLK }

# ---------------------------------------------------------------- address map
assign_bd_address -quiet
set seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces /xdma_0/M_AXI_B] -filter {NAME =~ *mgmt_flash*}]
if {$seg eq ""} { set seg [lindex [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces /xdma_0/M_AXI_B]] 0] }
if {$seg eq ""} { puts "RESCUE *** no address segment for mgmt_flash"; exit 1 }
chk "qspi @0x40000" { set_property OFFSET 0x00040000 $seg; set_property RANGE 64K $seg }
# The BOPE register must land at BAR0 + 0 exactly: the driver and the sysfs path both dereference
# `base_virt` with no offset. A segment placed anywhere else is an endpoint the app writes
# into empty space, with no error anywhere.
foreach sp {/xdma_0/M_AXI_B /S01_AXI} {
  foreach sg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $sp]] {
    set nm [get_property NAME $sg]
    if {[string match *M01* $nm] || [string match *Reg* $nm]} { }
    puts "RESCUE seg ($sp) $nm off=[get_property OFFSET $sg] range=[get_property RANGE $sg]"
  }
}
set r0 [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces /xdma_0/M_AXI_B] -filter {NAME =~ *M01*}]
if {$r0 ne ""} { set_property OFFSET 0x00000000 $r0; set_property RANGE 4K $r0
                 puts "RESCUE bope_regs segment at [get_property OFFSET $r0]" }
# The burn engine addresses the flash controller at 0x40000 (QSPI_BASE in bope_burn.v). Its own
# address space must agree, or every SPI register write lands in a decode hole and the engine sits
# waiting for a WIP bit that never clears.
set r1 [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces /S01_AXI] -filter {NAME =~ *mgmt_flash*}]
if {$r1 eq ""} { puts "RESCUE *** the burn engine has no path to mgmt_flash"; exit 1 }
set_property OFFSET 0x00040000 $r1; set_property RANGE 64K $r1
puts "RESCUE burn-engine view of mgmt_flash at [get_property OFFSET $r1]"
foreach sg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces /S01_AXI]] {
  puts "RESCUE seg (S01) [get_property NAME $sg] off=[get_property OFFSET $sg]" }

if {[catch {validate_bd_design} e]} { puts "RESCUE *** validate: [string range $e 0 600]"; exit 1 }
puts "RESCUE validate OK"
save_bd_design
set_property synth_checkpoint_mode None [get_files flexburn_bd.bd]
generate_target all [get_files flexburn_bd.bd]
set wrapper [make_wrapper -files [get_files flexburn_bd.bd] -top -force]
add_files -norecurse $wrapper

# ---------------------------------------------------------------- our top, above the block design
# The DDR4 MIG. It owns the reference oscillator pair AP24/AP25 (ddr4_72bit_gen.xdc claims them).
set mig $PKG/ip/ddr4_flex_ip/ddr4_flex
if {[file exists $mig/ddr4_flex.dcp]} {
  # maintainers' copy: the exact generated MIG output (AMD-proprietary, not in the public repo) -> byte-exact build
  read_ip $mig/ddr4_flex.xci
  puts "RESCUE MIG: generated output products present -- byte-exact reproduction of the shipped image"
} else {
  # public repo: only the .xci ships. Regenerate in the build directory, never in the source tree, keeping the
  # .xci -> ../../../board/<parts csv> relative path intact (a copy at another depth silently drops the DDR4 bank
  # groups from the custom part and fails much later as a misleading I/O-standard error).
  set w $::env(FLEX_BUILD_DIR)/migsrc
  file delete -force $w
  file mkdir $w/ip/ddr4_flex_ip/ddr4_flex
  file copy $PKG/board $w/board
  file copy $mig/ddr4_flex.xci $w/ip/ddr4_flex_ip/ddr4_flex/
  read_ip $w/ip/ddr4_flex_ip/ddr4_flex/ddr4_flex.xci
  set_property generate_synth_checkpoint false [get_files ddr4_flex.xci]
  generate_target all [get_ips ddr4_flex]
  # gate: the regenerated pin constraints must carry the DDR4 bank-group pins (the known-good output has 7 lines)
  set px $w/ip/ddr4_flex_ip/ddr4_flex/par/ddr4_flex.xdc
  set bg 0
  if {[file exists $px]} { set f [open $px]; set bg [regexp -all -nocase {c0_ddr4_bg} [read $f]]; close $f }
  if {$bg == 0} { puts "RESCUE *** regenerated MIG has no bank-group pins ($px): custom-parts path not resolved"; exit 1 }
  puts "RESCUE MIG: regenerated from the .xci (bank-group pin lines: $bg) -- a functionally equivalent image, NOT byte-identical to"
  puts "RESCUE      the shipped one: run test/flex_acceptance.py on a JTAG-cabled card before relying on it"
}
puts "RESCUE DDR4 MIG added (dw8b part, tCK 750, refclk 10000)"
add_files -norecurse [list $PKG/rtl/power_burn.v $PKG/rtl/cr_map_gen.v $PKG/rtl/i2c_cr_slave.v $PKG/rtl/sysmon_temp.v \
                           $PKG/rtl/e4_replay.v $PKG/rtl/e3_code.v \
                           $PKG/rtl/cr_regs.v \
                           $PKG/rtl/flex_hop.v \
                           $PKG/rtl/bope_regs.v $PKG/rtl/bope_burn.v \
                           $PKG/rtl/flex_burn_top.v]
add_files -fileset constrs_1 -norecurse [list $PKG/constraints/static_pins.xdc $PKG/constraints/spi1_rescue.xdc \
                                              $::env(GTXDC) \
                                              $PKG/constraints/calib_sync.xdc \
                                              $PKG/constraints/flexburn_cfgrate.xdc]
add_files -fileset constrs_1 -norecurse [list $PKG/constraints/flexburn_userid.xdc $PKG/constraints/flex_pins.xdc \
                                              $PKG/constraints/ddr4_72bit_gen.xdc]
# The GT LOCs must be applied at IMPLEMENTATION, not synthesis: the GTYE4_CHANNEL cells only exist
# in the post-synth netlist.
# pcie_x8_lanes.xdc constrains PORTS, which exist at synthesis, so it needs no exclusion.

# The CR map is GENERATED from a register capture (the generator is not included). A truncated or empty regeneration
# would synthesise cleanly and answer the sentinel to everything -- i.e. silently undo the whole
# point -- so check two constants that only exist in a real capture before building against it.
set fh [open $PKG/rtl/cr_map_gen.v r]; set mapsrc [read $fh]; close $fh
foreach {want what} {A5A5A5A5 signature-0x68 01234567 signature-0x6C DEADDEAD bist-buffer} {
  if {![string match "*$want*" $mapsrc]} { puts "IFLEX *** cr_map_gen.v lacks $what -- regenerate it"; exit 1 }
}
puts "IFLEX cr_map entries = [regexp -all {: d = 32'h} $mapsrc]"
update_compile_order -fileset sources_1
set_property top flex_burn_top [current_fileset]
if {[get_property top [current_fileset]] ne "flex_burn_top"} {
  puts "RESCUE *** top is [get_property top [current_fileset]], not flex_burn_top"; exit 1 }

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  puts "RESCUE *** impl failed: [get_property STATUS [get_runs impl_1]]"; exit 1 }
open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "RESCUE TIMING WNS=$wns"
puts "RESCUE TIMING WHS=$whs"
puts "RESCUE DRC errors=[get_msg_config -count -severity ERROR]"
# this build PRINTED WNS and then shipped the bitstream regardless. A design that misses
# timing can configure, answer I2C and still fail intermittently in ways that look like hardware --
# which has happened before. Refuse it here, and name
# the path, so the next person does not have to go digging in the routed report.
foreach {nm sl} [list setup $wns hold $whs] {
  if {$sl < 0} {
    puts "RESCUE *** TIMING FAILED: $nm slack $sl ns"
    foreach pth [get_timing_paths -max_paths 3 -nworst 1 -setup -quiet] {
      puts "RESCUE ***   [get_property SLACK $pth] ns  [get_property STARTPOINT_PIN $pth] -> [get_property ENDPOINT_PIN $pth]" }
    exit 1 } }
puts "RESCUE timing gate passed (WNS $wns / WHS $whs)"
# calib_sync.xdc constrains calib_m_reg/D by name. If synthesis ever renames or absorbs that flop
# the constraint silently matches nothing (get_pins -quiet), and the only symptom would be the
# timing failure above with no hint as to why. Say so plainly instead.
set csync [llength [get_pins -quiet calib_m_reg/D]]
puts "RESCUE calib synchroniser pins matched by calib_sync.xdc = $csync"
# the axi_clk -> responder-clock false path in calib_sync.xdc finds the responder clock through net `clk`
set rclk [get_clocks -quiet -of_objects [get_nets clk]]
puts "RESCUE responder clock = $rclk"
if {$rclk eq ""} { puts "RESCUE *** no clock on net clk -- the status-crossing false path matched nothing"; exit 1 }
if {$csync != 1} {
  puts "RESCUE *** calib_m_reg/D not found -- calib_sync.xdc constrained NOTHING; fix the name"; exit 1 }

# ---- gates. Every one of these has cost a build or a flash cycle before. ----
# five spi1 pins, placed, or the image can only reach one of the two flash chips.
set spip [lsort [get_ports -quiet spi1_*]]
puts "RESCUE spi1 ports: [llength $spip] -> $spip"
if {[llength $spip] != 5} { puts "RESCUE *** expected 5 spi1_* ports"; exit 1 }
# the wrong GT quad builds cleanly and never links -- which is the ONE thing this image is for.
foreach ref {PCIE40E4 GTYE4_CHANNEL} {
  foreach c [get_cells -hier -quiet -filter "REF_NAME == $ref"] {
    puts "RESCUE   $ref at [get_property -quiet LOC [get_cells $c]]" } }
set gtl {}
foreach c [get_cells -hier -quiet -filter {REF_NAME == GTYE4_CHANNEL}] { lappend gtl [get_property LOC [get_cells $c]] }
set gtl [lsort $gtl]
puts "RESCUE GT channels: $gtl"
# the expected channel set follows the link width, because the profile is now selectable.
set want_gt [expr {$::env(LINKW) eq "X2" ? [list GTYE4_CHANNEL_X0Y0 GTYE4_CHANNEL_X0Y1] : \
                                           [list GTYE4_CHANNEL_X0Y0 GTYE4_CHANNEL_X0Y1 GTYE4_CHANNEL_X0Y2 GTYE4_CHANNEL_X0Y3]}]
if {$gtl ne $want_gt} { puts "RESCUE *** GT channels are $gtl, expected $want_gt"; exit 1 }
puts "RESCUE GT placement OK"
# no SYSMONE4 -> CR 0x8400 reports -279 C.
set nsys [llength [get_cells -hier -filter {REF_NAME == SYSMONE4 || PRIMITIVE_TYPE =~ *SYSMONE4*}]]
puts "RESCUE SYSMONE4 instances = $nsys"
if {$nsys < 1} { puts "RESCUE *** no SYSMONE4"; exit 1 }
# every bank-90 pin keeps its direction and placement (E4 is the only output)
set nwatch 0
foreach prt [get_ports -quiet pin_*] {
  incr nwatch
  set want [expr {[get_property NAME $prt] eq "pin_e4" ? "OUT" : "IN"}]
  if {[get_property -quiet DIRECTION $prt] ne $want} {
    puts "RESCUE *** [get_property NAME $prt] is [get_property DIRECTION $prt], want $want"; exit 1 }
  if {[get_property -quiet PACKAGE_PIN $prt] eq ""} { puts "RESCUE *** [get_property NAME $prt] unplaced"; exit 1 } }
puts "RESCUE watch pins bonded = $nwatch (pin_e4 is an OUTPUT: the acceptance waveform)"
if {$nwatch != 18} { puts "RESCUE *** expected 18 pin_* ports (F2 is pcie_perstn now), got $nwatch"; exit 1 }
# the dispatcher is what makes this a Flex image rather than a card that boots nothing.
set nic [llength [get_cells -hier -filter {REF_NAME == ICAPE3}]]
puts "RESCUE ICAPE3 instances = $nic"
if {$nic != 1} { puts "RESCUE *** ICAPE3 count $nic, want exactly 1"; exit 1 }
set ne4 [llength [get_cells -hier -filter {NAME =~ *u_e4*}]]
puts "RESCUE e4_replay cells = $ne4"
if {$ne4 < 1} { puts "RESCUE *** no e4_replay -- the image would be REJECTED "; exit 1 }
# The responder's own pads; the reference oscillator arrives as the MIG's port.
foreach p [list i2c_scl i2c_sda C0_SYS_CLK_0_clk_p pcie_perstn] {
  set prt [get_ports -quiet $p]
  if {$prt eq ""} { puts "RESCUE *** port $p missing"; exit 1 }
  puts "RESCUE port $p pin=[get_property PACKAGE_PIN $prt] std=[get_property IOSTANDARD $prt] dir=[get_property DIRECTION $prt]" }
# This image BOOTS FROM FLASH, unlike the rescue image it is derived from. Wrong settings here
# produce a slot that never configures and a card in FACTORY_FAILOVER.
# CONFIGRATE was never set here, so this image loaded at the DEFAULT rate while
# sibling scripts in this repo (rescue2mp_flash_bitstream, tester_flash_bitstream, i2c_verify_impl)
# all use 127.5 MHz. Load time is what blows Factory's 0.67 s post-fallback watchdog, and
# load time is set by this property -- so this is the one lever we control that could let the
# fallback SUCCEED on its own, with no Factory write and no gate.
foreach {prop want} {BITSTREAM.CONFIG.SPI_BUSWIDTH 8 BITSTREAM.CONFIG.SPI_32BIT_ADDR YES \
                     BITSTREAM.CONFIG.SPI_FALL_EDGE YES BITSTREAM.GENERAL.COMPRESS TRUE \
                     BITSTREAM.CONFIG.CONFIGRATE 127.5} {
  set got [get_property -quiet $prop [current_design]]
  puts "RESCUE $prop = $got"
  if {$got ne $want} { puts "RESCUE *** $prop is '$got', expected '$want'"; exit 1 } }

file mkdir $OUT
file copy -force $PRJ/flexburn.runs/impl_1/flex_burn_top.bit $OUT/flex_burn_q127x4.bit
puts "RESCUE bitstream -> $OUT/flex_burn_q127x4.bit"
# NB: markers must be matched with ^ by anything waiting on this log. Vivado echoes each script
# line as it runs, so the literal text "RESCUE ***" and "RESCUE-DONE" appear inside echoed comments
# long before they are printed -- a waiter grepping for them unanchored declares the build finished
# during elaboration.
puts "RESCUE-DONE"
