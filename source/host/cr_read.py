#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

"""Read ConnectX->FPGA CR space directly. Same path the vendor app uses:
lseek to the CR address on /dev/<bdf>_mlx5_fpga_tools, read 4 bytes big-endian.
READ-ONLY. Only works while oper_image != User (measured)."""
import os, struct, sys
def _only_node():
    """The FPGA-tools node of the one card on this host; refuses to guess when there are several."""
    import glob
    n = sorted(glob.glob("/dev/*.0_mlx5_fpga_tools"))
    if len(n) != 1:
        sys.exit("give the node explicitly, e.g. /dev/<ConnectX BDF>_mlx5_fpga_tools -- found: %s" % (" ".join(n) or "none"))
    return n[0]
dev = sys.argv[1] if len(sys.argv) > 1 else _only_node()
fd = os.open(dev, os.O_RDONLY)
def rd(a):
    try:
        os.lseek(fd, a, os.SEEK_SET); b = os.read(fd, 4)
        return struct.unpack(">I", b)[0] if len(b) == 4 else None
    except OSError:
        return None
RANGES = [("identity", 0x900000, 0x900074, 4), ("fan/tacho", 0x400, 0x424, 4),
          ("mailbox/power", 0x00, 0x30, 4), ("bist", 0x20000, 0x20040, 4),
          ("temp", 0x8400, 0x8404, 4)]
for name, lo, hi, step in RANGES:
    print("== %s  0x%X-0x%X ==" % (name, lo, hi))
    for a in range(lo, hi, step):
        v = rd(a)
        print("   0x%06X = %s" % (a, "EIO" if v is None else "0x%08X" % v))
os.close(fd)
