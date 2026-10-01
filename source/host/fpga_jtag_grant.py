#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 the innova2 contributors
# SPDX-FileCopyrightText: Mellanox Technologies Ltd.
#
# SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

"""Grant/revoke JTAG access on the Innova2 WITHOUT the flex app.

Companion to fpga_image_sel.py. The flex app is the only documented way to enable JTAG access, and
it is unusable whenever the running FPGA image does not answer the ConnectX CR read at 0x90006C --
which is exactly the state an impersonation experiment produces. Without a grant there is no JTAG,
and without JTAG there is no way back. This closes that gap.

From the vendor source (fpga_access.c):
    void set_fpga_connectdisconnect(enum mlx5_fpga_connect connect) {
        ioctl(g_ctx.i2c_fd, IOCTL_FPGA_CONNECT, &connect);   /* NOTE: by POINTER */
    }
and tools_chardev.h (the Linux branch, the same one whose _IOW form was confirmed working by
fpga_image_sel.py):
    #define IOCTL_FPGA_CONNECT _IOWR('m', 0x87, enum mlx5_fpga_connect*)
    MLX5_FPGA_CONNECT_QUERY = 0, MLX5_FPGA_CONNECT_DISCONNECT = 0x9, MLX5_FPGA_CONNECT_CONNECT = 0xA
_IOWR('m',0x87,8) = (3<<30)|(8<<16)|(0x6D<<8)|0x87 = 0xC0086D87.

"disconnect" is what the menu calls "Enable JTAG Access - no thermal status": it detaches the
ConnectX management path so JTAG can drive the device. "connect" re-attaches it.

    usage: fpga_jtag_grant.py <node> query|disconnect|connect
"""
import array, fcntl, os, sys

IOCTL_FPGA_CONNECT = 0xC0086D87
OPS = {"query": 0, "disconnect": 0x9, "connect": 0xA}
NAMES = {0: "query/none", 0x9: "DISCONNECTED (JTAG access enabled)", 0xA: "CONNECTED (managed)"}

if len(sys.argv) != 3 or sys.argv[2] not in OPS:
    print(__doc__); sys.exit(1)
node, op = sys.argv[1], sys.argv[2]
if not os.path.exists(node):
    print("*** %s does not exist -- modprobe mlx5_fpga_tools first" % node); sys.exit(1)

buf = array.array("i", [OPS[op]])
fd = os.open(node, os.O_RDWR)
try:
    fcntl.ioctl(fd, IOCTL_FPGA_CONNECT, buf, True)   # _IOWR: the driver writes back
    print("JTAG-GRANT %-10s -> returned %d (%s)" % (op, buf[0], NAMES.get(buf[0], "?")))
finally:
    os.close(fd)
