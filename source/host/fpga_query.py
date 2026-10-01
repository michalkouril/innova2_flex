#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 the innova2 contributors
# SPDX-FileCopyrightText: Mellanox Technologies Ltd.
#
# SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

"""Read the ConnectX's LIVE view of the FPGA.

`dmesg | grep "FPGA: Status"` is printed once at driver load, so it answers "what was the verdict at
boot" and nothing else. IOCTL_FPGA_QUERY is the same query the vendor app makes every time it draws
its menu, so it answers "what does the ConnectX think RIGHT NOW" -- which is the difference between
a latched verdict and a live one, and therefore between a 40-minute flash cycle per experiment and
a 3-minute JTAG load.

    struct mlx_accel_fpga_query { u8 admin_image; u8 oper_image; u8 status; }   (tools_chardev.h:49)
    #define IOCTL_FPGA_QUERY _IOR('m', 0x84, struct mlx_accel_fpga_query)

    usage: fpga_query.py <node>
"""
import array, fcntl, os, struct, sys

IMAGES = {0: "USER", 1: "FACTORY", 2: "FACTORY_FAILOVER", 3: "FLEX"}
STATUS = {0: "SUCCESS", 1: "FAILURE", 2: "IN_PROGRESS", 3: "DISCONNECTED"}
def _only_node():
    """The FPGA-tools node of the one card on this host; refuses to guess when there are several."""
    import glob
    n = sorted(glob.glob("/dev/*.0_mlx5_fpga_tools"))
    if len(n) != 1:
        sys.exit("give the node explicitly, e.g. /dev/<ConnectX BDF>_mlx5_fpga_tools -- found: %s" % (" ".join(n) or "none"))
    return n[0]
node = sys.argv[1] if len(sys.argv) > 1 else _only_node()
# _IOR('m',0x84,size): the size field is the struct's, and the app declares it two ways in the same
# header, so try the plausible sizes rather than hard-coding one and mis-reporting a failure as data.
for size in (12, 3, 4, 8):
    req = (2 << 30) | (size << 16) | (0x6D << 8) | 0x84
    # Poison the buffer so the driver's actual write extent is visible. It accepts an ioctl size of
    # 8 and, as with IOCTL_FPGA_CAP, may write further than it was asked to -- and `status`
    # is the third word, past 8 bytes. Guessing how much came back is how reported SUCCESS in
    # a FAILURE state.
    buf = array.array("B", [0xEE] * 64)
    fd = os.open(node, os.O_RDONLY)
    try:
        fcntl.ioctl(fd, req, buf, True)
    except OSError as e:
        print("  size=%d req=0x%08X -> %s" % (size, req, e.strerror)); continue
    finally:
        os.close(fd)
    # the struct is three C ENUMS -- 4 bytes each, little-endian -- not three bytes.
    # Reading buf[0..2] printed the low byte of word0, the low byte of word1, and a zero it called
    # "status=SUCCESS" in a boot dmesg reported as FAILURE. Unpack words, and never name a field the
    # driver did not return: it accepts size 8 and gives back TWO words, so status is absent there.
    written = 0
    while written < 64 and buf[written] != 0xEE:
        written += 1
    # a zero byte inside a written word looks like poison-free; round up to whole words and keep
    # scanning while any of the next 4 bytes differs from poison
    nw = 0
    while (nw + 1) * 4 <= 64 and any(buf[nw * 4 + k] != 0xEE for k in range(4)):
        nw += 1
    words = struct.unpack_from("<%dI" % nw, buf, 0) if nw else ()
    print("  (ioctl size=%d; driver wrote %d word(s))" % (size, nw))
    if nw < 2:
        print("  *** fewer than 2 words returned -- not enough to report anything"); continue
    a, o = words[0], words[1]
    st = words[2] if len(words) > 2 else None
    print("FPGA-QUERY admin=%d(%s) oper=%d(%s) status=%s   [ioctl size=%d, %d words returned: %s]"
          % (a, IMAGES.get(a, "?"), o, IMAGES.get(o, "?"),
             "%d(%s)" % (st, STATUS.get(st, "?")) if st is not None
             else "NOT RETURNED at this ioctl size -- use dmesg or a larger size",
             size, len(words), list(words)))
    break
