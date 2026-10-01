#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

"""is anything on the AXI side answering the BAR?

Reads a few 32-bit words straight out of resource0 with ctypes (never mmap slicing -- that issues
each store twice on this platform). Offset 0 is our BOPE register; 0x40000 is the AXI Quad SPI,
a slave nobody here wrote, which makes it the control: if BOTH read 0xffffffff the fabric is mute,
if only offset 0 does then the register block is at fault.
  usage: bar_probe.py <bdf>
"""
import ctypes, mmap, os, sys
bdf = sys.argv[1]

def enable_device(bdf):
    """The BAR only answers once PCI memory decode is on. No driver binds 15b3:0264 here, so Linux
    never called pci_enable_device() and Memory Space stayed clear -- every read came back
    0xffffffff and the card looked mute. The vendor's own bope driver does this for us; standing in
    for it means doing it ourselves."""
    import subprocess
    p = "/sys/bus/pci/devices/%s/enable" % bdf
    try:
        open(p, "w").write("1")
    except Exception:
        subprocess.run(["sh", "-c", "echo 1 > %s" % p], check=False)
    cmd = subprocess.run(["setpci", "-s", bdf, "COMMAND"], capture_output=True, text=True).stdout.strip()
    if cmd:
        v = int(cmd, 16)
        if not (v & 0x2):
            subprocess.run(["setpci", "-s", bdf, "COMMAND=%04x" % (v | 0x2)], check=False)
        cmd = subprocess.run(["setpci", "-s", bdf, "COMMAND"], capture_output=True, text=True).stdout.strip()
    print("  COMMAND now 0x%s  (bit1 = memory space)" % cmd)
enable_device(bdf)
path = "/sys/bus/pci/devices/%s/resource0" % bdf
print("  %s: %d bytes" % (path, os.path.getsize(path)))
fd = os.open(path, os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x41000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0)
base = ctypes.addressof(ctypes.c_char.from_buffer(m))
def rd(off): return ctypes.c_uint32.from_address(base + off).value
for off, what in ((0x00000, "BOPE status (inn2f builds put the burn engine state in the low half: 0 = idle)"),
                  (0x00004, "BOPE +4 (same register, aliased)"),
                  (0x40064, "QSPI SPISR  (control: written by nobody here)"),
                  (0x40070, "QSPI SPISSR (0x3 = both chip selects released)")):
    print("  BAR0+0x%05X = 0x%08X   %s" % (off, rd(off), what))
