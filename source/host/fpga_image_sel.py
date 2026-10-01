#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 the innova2 contributors
# SPDX-FileCopyrightText: Mellanox Technologies Ltd.
#
# SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

"""Select the Innova2 boot image WITHOUT the flex app.

The flex app is unusable when the running FPGA image does not answer the ConnectX CR read at
0x90006C -- it dies with `ConnectX read error addr_lo 0x90006C: Input/output error` before printing
a menu, so there is no way to select another image through it. That is precisely the state a failed
Flex-slot experiment leaves the card in.

But the selection itself needs none of that. From the vendor source (fpga_access.c:536):

    void set_fpga_image(enum mlx_accel_fpga_image image) {
        ioctl(g_ctx.i2c_fd, IOCTL_FPGA_IMAGE_SEL, image);
    }

with, from tools_chardev.h and accel_sdk.h:

    #define IOCTL_FPGA_IMAGE_SEL _IOW('m', 0x83, enum mlx_accel_fpga_image)
    MLX_ACCEL_IMAGE_USER = 0, MLX_ACCEL_IMAGE_FACTORY = 1

so it is one ioctl on the mlx5_fpga_tools node, handled entirely by the ConnectX-5 -- the FPGA is
not involved. _IOW('m',0x83,4) = (1<<30)|(4<<16)|(0x6D<<8)|0x83 = 0x40046D83. The app passes the
image by VALUE (not a pointer) despite the _IOW encoding, so this does the same.

    usage: fpga_image_sel.py <node> user|flex
           e.g. fpga_image_sel.py /dev/0000:0f:00.0_mlx5_fpga_tools user

Takes effect on the next COLD cycle, exactly like the flex app's menu item.
"""
import fcntl, os, sys

IOCTL_FPGA_IMAGE_SEL = 0x40046D83
# the enum has FOUR images, the vendor app only ever sends two.
#   MLX_ACCEL_IMAGE_USER=0  FACTORY=1  FACTORY_FAILOVER=2  FLEX=3
# The app's scheduled-image label table has only entries 0 and 1, and it labels 1
# "Innova2 Flex Image" -- while the RUNNING-image table calls 1 "Innova2 Factory Image" and 3
# "Innova2 Flex Image". So the menu item "Set Innova2_Flex image active" actually schedules
# FACTORY(1), and FLEX(3) is never selectable through the app. Expose all four.
IMAGES = {"user": 0, "factory": 1, "flex": 1, "failover": 2, "flex3": 3}

if len(sys.argv) != 3 or sys.argv[2] not in IMAGES:
    print(__doc__); sys.exit(1)
node, which = sys.argv[1], sys.argv[2]
if not os.path.exists(node):
    print("*** %s does not exist -- modprobe mlx5_fpga_tools first" % node); sys.exit(1)

fd = os.open(node, os.O_RDWR)
try:
    fcntl.ioctl(fd, IOCTL_FPGA_IMAGE_SEL, IMAGES[which])
    print("IMAGE-SEL OK: scheduled '%s' (value %d) on %s" % (which, IMAGES[which], node))
    print("              takes effect on the next COLD cycle")
finally:
    os.close(fd)
