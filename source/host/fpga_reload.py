#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 the innova2 contributors
# SPDX-FileCopyrightText: Mellanox Technologies Ltd.
#
# SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

"""IOCTL_FPGA_RELOAD / RESET / LOAD -- the SDK entry points nothing in the vendor app calls.

From the vendor's own tools_chardev.h:
    IOCTL_FPGA_LOAD    _IOW('m', 0x81, enum mlx_accel_fpga_image)   -> 0x40046D81
    IOCTL_FPGA_RESET    _IO('m', 0x82)                              -> 0x00006D82
    IOCTL_FPGA_RELOAD   _IO('m', 0x88)                              -> 0x00006D88
    IOCTL_FPGA_CAP     _IOR('m', 0x85, uint32_t[0x40])              -> 0x81006D85
'm' is 0x6D. _IO has no size or direction bits; _IOW('m',n,4) = 0x40046D<n> (the form 544 derived
for IMAGE_SEL and which works).

WHY: every image switch costs a cold power cycle today, and cold cycles are what took Host B off
the network twice. If the ConnectX can reconfigure the FPGA from flash on command, that cost goes
away -- and with it the main hazard in this whole workflow.

  usage: fpga_reload.py <node> reload|reset|load <image>|cap
"""
import array, fcntl, os, struct, sys

IOCTL_FPGA_LOAD   = 0x40046D81
IOCTL_FPGA_RESET  = 0x00006D82
IOCTL_FPGA_RELOAD = 0x00006D88
IOCTL_FPGA_CAP    = 0x81006D85          # _IOR('m',0x85,uint32_t[0x40]) -> size 0x100
IMAGES = {"user": 0, "factory": 1, "flex": 1, "failover": 2, "flex3": 3}

node, cmd = sys.argv[1], sys.argv[2]
fd = os.open(node, os.O_RDWR)
try:
    if cmd == "reload":
        r = fcntl.ioctl(fd, IOCTL_FPGA_RELOAD, 0)
        print("RELOAD returned %d" % r)
    elif cmd == "reset":
        r = fcntl.ioctl(fd, IOCTL_FPGA_RESET, 0)
        print("RESET returned %d" % r)
    elif cmd == "load":
        img = IMAGES[sys.argv[3]]
        r = fcntl.ioctl(fd, IOCTL_FPGA_LOAD, img)
        print("LOAD(%s=%d) returned %d" % (sys.argv[3], img, r))
    elif cmd == "cap":
        buf = array.array("I", [0] * 0x40)
        fcntl.ioctl(fd, IOCTL_FPGA_CAP, buf, True)
        words = buf.tolist()
        print("CAP 64 words:")
        for i in range(0, 64, 8):
            print("  %02X: %s" % (i, " ".join("%08X" % w for w in words[i:i+8])))
        if all(w == 0 for w in words):
            print("  (all zero -- either unimplemented or genuinely empty)")
    else:
        print(__doc__); sys.exit(1)
except OSError as e:
    print("%s FAILED: errno %d (%s)" % (cmd.upper(), e.errno, e.strerror))
    sys.exit(2)
finally:
    os.close(fd)
