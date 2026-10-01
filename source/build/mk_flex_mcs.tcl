# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# Guard-aware MCS for the FLEX slot.
#   vivado -mode batch -source mk_flex_mcs.tcl -tclargs <bitfile> <outprefix>
#
# THE ADDRESS. Flex is at PER-DEVICE 0x03000000 -- confirmed in Mellanox's completeimage0/1 (data
# 0x03000000..0x03DFFFFF, sync at 0x03000050), by a measurement of the slot, and by the Factory image's own header which
# carries WBSTAR 03000000 + CMD IPROG.
#
# WHY TWO STEPS. `-interface SPIx8` HALVES the requested address and Vivado models only 32 MB per
# device, so per-device 0x03000000 is not expressible that way at all:
#   write_cfgmem -interface SPIx8 -size 64 "up 0x05FFE000"
#     -> ERROR: [Writecfgmem 68-4] ... cannot fit in memory of size 67108864 bytes
# That ceiling is very likely how 530 came to accept 0x01800000 as "the correct per-device offset".
# So: (1) let SPIx8 do the x8 nibble split at address 0, giving one .bin per device -- the same
# "slot-relative" form the bope burn path consumes; (2) re-emit each .bin with `-interface SPIx1`,
# which does NO halving, at the literal per-device address. Same technique as the Factory repair.
#
# The declared address is FLEX-0x1000 = 0x02FFF000, so xbflash's unconditional +0x1000 payload shift
# lands byte 0 of the image at exactly 0x03000000. The sacrificial guard subsector then sits at
# 0x02FFF000, in the zero region between the User image and Flex (Mellanox's images are all-zero
# from 0x00E00000 to 0x02FFFFFF).
set BIT [lindex $argv 0]
set OUT [lindex $argv 1]
if {$BIT eq "" || $OUT eq ""} { puts "RESULT *** usage: mk_flex_mcs.tcl <bitfile> <outprefix>"; exit 1 }
if {![file exists $BIT]} { puts "RESULT *** no such bitstream: $BIT"; exit 1 }

# Step 1: the x8 split, slot-relative.
write_cfgmem -format bin -interface SPIx8 -size 64 -loadbit "up 0x00000000 $BIT" -force ${OUT}_split
foreach h {primary secondary} {
  if {![file exists ${OUT}_split_${h}.bin]} { puts "RESULT *** split did not produce ${h}"; exit 1 }
  puts "RESULT split $h = [file size ${OUT}_split_${h}.bin] bytes"
}

# Step 2: place each device's half at the literal per-device address. SPIx1 => no halving.
foreach {h out} {primary _primary secondary _secondary} {
  write_cfgmem -format mcs -interface SPIx1 -size 64 \
    -loaddata "up 0x02FFF000 ${OUT}_split_${h}.bin" -force ${OUT}${out}
}
foreach p [list ${OUT}_primary.prm ${OUT}_secondary.prm] {
  set fh [open $p r]; set txt [read $fh]; close $fh
  if {![regexp {(0x[0-9A-Fa-f]{8})\s+(0x[0-9A-Fa-f]{8})} $txt -> a1 a2]} {
    puts "RESULT *** $p has no address record"; exit 1 }
  puts "RESULT [file tail $p] declares $a1 .. $a2  -> payload [format 0x%08X [expr {$a1 + 0x1000}]] .. [format 0x%08X [expr {$a2 + 0x1000}]]"
  if {$a1 != 0x02FFF000} { puts "RESULT *** declared base $a1 != 0x02FFF000 (FLEX-0x1000) -- REFUSING"; exit 1 }
  if {[expr {$a2 + 0x1000}] > 0x03DFFFFF} { puts "RESULT *** payload runs past the Flex slot -- REFUSING"; exit 1 }
}
puts "MK-FLEX-MCS-DONE"
