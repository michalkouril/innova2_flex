# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# configuration clock rate.
#
# This build never set CONFIGRATE, so the image loaded at the DEFAULT rate, while sibling scripts in
# this repo -- rescue2mp_flash_bitstream.tcl, tester_flash_bitstream.tcl, i2c_verify_impl.tcl -- all
# use 127.5 MHz on the same parts. Load time is what blows Factory's 0.67 s post-fallback watchdog
# Measured: the device retries every 0.70 s because a 14 MB payload does not finish in time, and our
# image is therefore never reloaded to intervene.
#
# The configuration watchdog cannot be cancelled from the fabric (it runs only while no design is
# loaded) and a longer value cannot be pre-armed (every header rewrites TIMER at its own start), so
# this is the ONE lever we control: load fast enough that the fallback succeeds by itself.
#
# NO CONTROL FLOW HERE -- Vivado silently skips if/foreach in an .xdc
# (vivado-xdc-silently-skips-control-flow). The build gate verifies the property actually took.
set_property BITSTREAM.CONFIG.CONFIGRATE 127.5 [current_design]
