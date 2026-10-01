# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# the MIG's init_calib_complete crosses into our clock domain through the two-flop
# synchroniser in flex_burn_top (calib_m_reg -> calib_s_reg).
#
# Both clocks come out of the MIG's own MMCM -- calDone_gated_reg runs on mmcm_clkout0 (3.000 ns)
# and our logic on mmcm_clkout1 (10.000 ns) -- so they are phase-related and the timer analyses the
# crossing as an ordinary synchronous path. It reported WNS = -0.227 ns and the build MISSED TIMING.
#
# Closing that path would be the wrong fix. The signal asserts once after calibration and then never
# changes; the second flop is what handles metastability. What it needs is a timing exception.
#
# NO CONTROL FLOW HERE ON PURPose: Vivado silently ignores if/foreach in an .xdc (recorded in
# vivado-xdc-silently-skips-control-flow), so a guarded constraint would never apply and the build
# would still pass. The build's timing gate is what verifies this actually worked.
set_false_path -to [get_pins -quiet calib_m_reg/D]

# the F1_REPORT encoder can watch lnk_up, which lives in the XDMA's axi_clk domain. Its
# 2FF synchroniser must not be timed across the domains -- the calib synchroniser in this same file
# shipped a bitstream at WNS -0.227 for exactly this reason before it was cut.
set_false_path -to [get_pins -quiet u_hop/rpt_m_reg/D]
set_false_path -to [get_pins -quiet u_hop/lnk_m_reg/D]

# Status bits cross from the PCIe AXI clock into the responder's clock (the MIG's 100 MHz output) only
# to be read over I2C in CR 0x02005C: the burn engine state, lnk_up, the AXI heartbeat. They are
# asynchronous by nature and a sample a cycle late is harmless. Timed, they met setup by only 0.032 ns.
set_false_path -from [get_clocks -quiet axi_clk] -to [get_clocks -quiet -of_objects [get_nets clk]]
