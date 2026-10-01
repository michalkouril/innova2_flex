# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# the SECOND flash chip's pins for the rescue image.
# Five pins: D0-D3 + CS on user I/O. There is no sck_1 --
# both devices share CCLK through the IP's internal STARTUPE3.
# No if/foreach here: control flow in an .xdc is silently ignored by Vivado. The existence check
# lives in build_flash_rescue.tcl, which fails the build unless all five ports are placed.
set_property PACKAGE_PIN AM12 [get_ports spi1_io0_io]
set_property PACKAGE_PIN AN12 [get_ports spi1_io1_io]
set_property PACKAGE_PIN AR13 [get_ports spi1_io2_io]
set_property PACKAGE_PIN AR12 [get_ports spi1_io3_io]
set_property PACKAGE_PIN AV11 [get_ports spi1_ss_io]
set_property IOSTANDARD LVCMOS18 [get_ports spi1_*]
