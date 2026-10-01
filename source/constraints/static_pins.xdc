# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# Static (non-DDR) pin constraints for the Flex image.
# pcie_perstn and the PCIe reference clock (AB27/AB28 = MGTREFCLK0 P/N of GTY quad 128, X0Y1), the same
# pins the card's other PCIe images use.
# Only the RX P pins are given a PACKAGE_PIN: that fixes each GTY channel, and the tool derives
# the matching RXN/TXP/TXN of the same channel.  This is the same set the card's other PCIe images use.

set_property PACKAGE_PIN F2 [get_ports pcie_perstn]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_perstn]
set_property PULLTYPE PULLUP [get_ports pcie_perstn]
set_false_path -from [get_ports pcie_perstn]

set_property PACKAGE_PIN AB27 [get_ports pcie_refclk_clk_p]
set_property PACKAGE_PIN AB28 [get_ports pcie_refclk_clk_n]

# PCIe LANE PINS ARE NOT SET HERE.  They come from constraints/pcie_x8_lanes.xdc (GTXDC in build/build.sh).
#
# WHY: an XDC file is not a Tcl script.  Vivado's XDC parser silently SKIPS control flow --
#   CRITICAL WARNING: [Designutils 20-1307] Command 'lsort' is not supported in the xdc
#   constraint file.  ... Command 'if' is not supported ...
# -- so a lane loop written here does nothing, the ports come out unconstrained, and the tool
# picks GTY channels the board does not wire.  It builds cleanly and the card does not link.
# MEASURED: that is exactly what happened on the first Gen1 x2 attempt.
# Plain set_property lines below are fine; anything conditional belongs in impl_config.tcl.

# 100 MHz PCIe reference clock
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_clk_p]
