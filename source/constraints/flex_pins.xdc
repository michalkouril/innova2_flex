# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# Pins and bitstream settings for the Flex image (bank 90 and the configuration options).
#
# Not here: the reference oscillator pair AP24/AP25, which the MIG's pinout (ddr4_72bit_gen.xdc) claims,
# and F2 (`pcie_perstn`), constrained in static_pins.xdc.

# I2C management bus to the ConnectX-5. bank 90, HDIO, 3.3 V.
set_property PACKAGE_PIN D2 [get_ports i2c_scl]
set_property PACKAGE_PIN D1 [get_ports i2c_sda]
set_property IOSTANDARD LVCMOS33 [get_ports {i2c_scl i2c_sda}]
# Board pull-ups; do NOT add internal pulls that would fight the ConnectX.
set_property PULLTYPE NONE [get_ports {i2c_scl i2c_sda}]

# DDR reference oscillator -- free-running, so the responder keeps answering with no PCIe clock.
# (sysclk pins omitted: with DDR4 the MIG owns AP24/AP25 -- see ddr4_72bit_gen.xdc)

# I2C is ~100 kHz sampled by a 100 MHz clock; asynchronous by nature, must not be timed.
set_false_path -from [get_ports i2c_scl]
set_false_path -from [get_ports i2c_sda]
set_false_path -to   [get_ports i2c_sda]

# bank-90 watch pins -- INPUT ONLY, never driven (F2 is absent here; see the header).
set_property PACKAGE_PIN F1 [get_ports pin_f1]
set_property PACKAGE_PIN C3 [get_ports pin_c3]
set_property PACKAGE_PIN A3 [get_ports pin_a3]
set_property PACKAGE_PIN A4 [get_ports pin_a4]
set_property PACKAGE_PIN A6 [get_ports pin_a6]
set_property PACKAGE_PIN B4 [get_ports pin_b4]
set_property PACKAGE_PIN B5 [get_ports pin_b5]
set_property PACKAGE_PIN B6 [get_ports pin_b6]
set_property PACKAGE_PIN C4 [get_ports pin_c4]
set_property PACKAGE_PIN C5 [get_ports pin_c5]
set_property PACKAGE_PIN D3 [get_ports pin_d3]
set_property PACKAGE_PIN D5 [get_ports pin_d5]
set_property PACKAGE_PIN D6 [get_ports pin_d6]
set_property PACKAGE_PIN E1 [get_ports pin_e1]
set_property PACKAGE_PIN E3 [get_ports pin_e3]
set_property PACKAGE_PIN E4 [get_ports pin_e4]
set_property PACKAGE_PIN E5 [get_ports pin_e5]
set_property PACKAGE_PIN F4 [get_ports pin_f4]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_f1 pin_c3 pin_a3 pin_a4 pin_a6 pin_b4 pin_b5 pin_b6 pin_c4 pin_c5 pin_d3 pin_d5 pin_d6 pin_e1 pin_e3 pin_e4 pin_e5 pin_f4}]
set_false_path -from [get_ports {pin_f1 pin_c3 pin_a3 pin_a4 pin_a6 pin_b4 pin_b5 pin_b6 pin_c4 pin_c5 pin_d3 pin_d5 pin_d6 pin_e1 pin_e3 pin_e4 pin_e5 pin_f4}]

# ---- BOOT FROM FLASH. This image lives in the Flex slot, so these are not optional. ----
# Matched to every image that boots on this card (Mellanox Factory and Flex, and the User images we tested).
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH     8       [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR   YES     [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE    YES     [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE       127.5   [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN DISABLE [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK   DISABLE [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN ENABLE  [current_design]
set_property BITSTREAM.CONFIG.NEXT_CONFIG_REBOOT DISABLE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN        PULLUP  [current_design]
# The Flex slot is 16 MB per device; an uncompressed xcku15p bitstream is ~36 MB. Every shipping
# image on this card is compressed.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# the pull settings the ACCEPTED images carry (tuned so bank 90 reads as the
# vendor's does). This file predates them -- it was written for the PCIe experiment, before
# acceptance was understood -- and a Flex image that differs from the accepted configuration is a
# variable we do not want in the same build as a new PCIe endpoint.
set_property PULLTYPE PULLUP   [get_ports pin_a3]
set_property PULLTYPE PULLUP   [get_ports pin_a4]
set_property PULLTYPE PULLUP   [get_ports pin_b4]
set_property PULLTYPE PULLUP   [get_ports pin_b5]
set_property PULLTYPE PULLUP   [get_ports pin_d5]
set_property PULLTYPE PULLUP   [get_ports pin_e1]
set_property PULLTYPE PULLDOWN [get_ports pin_f1]
# E4 is an OUTPUT in flex_burn_top (the acceptance waveform), so it needs the outbound exception;
# the inbound one above simply matches nothing for it.
set_false_path -to [get_ports pin_e4]

