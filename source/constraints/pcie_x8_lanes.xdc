# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# PCIe lane pins for the x8 Flex replacement.
# lanes 4-7 removed -- the link is now a declared x4 on quad 127 (channels X0Y0..X0Y3).
#
# Only the RX P pin of each lane is constrained: that fixes the GTY channel, and the tool derives
# the matching RXN/TXP/TXN. These are the same pins the card's other PCIe images use.
#
# This REPLACES pcie_gt_rescue.xdc, which LOC'd exactly two GTYE4_CHANNELs for the x2 rescue design.
# Both approaches fix the quad; only this one scales to eight lanes. is the reason either is
# needed at all: unconstrained, Vivado picked GTYE4_CHANNEL_X0Y14/X0Y15, the design configured
# fine, and the link silently never trained.
set_property PACKAGE_PIN AH36 [get_ports {pci_express_x8_rxp[0]}]
set_property PACKAGE_PIN AG38 [get_ports {pci_express_x8_rxp[1]}]
set_property PACKAGE_PIN AF36 [get_ports {pci_express_x8_rxp[2]}]
set_property PACKAGE_PIN AE38 [get_ports {pci_express_x8_rxp[3]}]
