<!--
SPDX-FileCopyrightText: 2026 the innova2 contributors

SPDX-License-Identifier: Apache-2.0
-->

# Running the Innova2 app when the drivers no longer know about FPGAs

Written 2026-09-15. Question: how much of `innova2_flex_app` can be made to work on a
modern kernel whose `mlx5_core` has no Innova2/FPGA support, **ideally as a supplemental module with
the shipping drivers untouched**?

Short answer: **all of it, and most of it needs no kernel code at all.** Everything the app asks the
kernel for reduces to three ConnectX *access registers*, and access registers are reachable from user
space today. The burn path doesn't involve the kernel in the first place.

## What the app actually needs, and where each need lands

Read from the OFED 5.2 source (`drivers/net/ethernet/mellanox/mlx5/fpga/tools_char.c` and
`.../mlx5/core/fpga/cmd.c`), not inferred:

| app call | ioctl | kernel function | firmware path |
|---|---|---|---|
| `get_fpga_state` | QUERY 0x84 | `mlx5_fpga_query` | ACCESS_REG **FPGA_CAP 0x4022** |
| capabilities | CAP 0x85 | `mlx5_fpga_get_cap` | cached FPGA_CAP |
| `set_fpga_image` | IMAGE_SEL 0x83 | `mlx5_fpga_flash_select` | **FPGA_CTRL 0x4023**, op `FLASH_SELECT=3` |
| (unused by the app) | LOAD 0x81 | `mlx5_fpga_load` | FPGA_CTRL op `LOAD=1` |
| (unused) | RESET 0x82 | `mlx5_fpga_ctrl_op` | FPGA_CTRL op `RESET=2` |
| `set_fpga_connectdisconnect` | CONNECT 0x87 | `mlx5_fpga_connectdisconnect` | FPGA_CTRL ops `CONNECT=0xA` / `DISCONNECT=0x9` |
| sensors | TEMPERATURE 0x86 | `mlx5_fpga_temperature` | sensor register |
| `fpga_crspace_read/write` | (read/write on the node) | `mlx5_fpga_access_reg` | **FPGA_ACCESS_REG 0x4024** |

That last row is the important one: **the whole CR space -- identity, temperature, the power dial,
fan/tacho, BIST -- is one access register**, `0x4024`, carrying `{size, address[63:0], data[]}`.

Two things are NOT in this table because they never touch the kernel's FPGA support:

* **The burn path.** BAR0+0 of the `15b3:0264` function, reached either by the out-of-tree `bope`
  driver or by `--enable_sysfs`, which just mmaps `resource0`. Our own `source/host/bope_probe.py` does
  exactly this and burned 8 KB byte-exact. The only subtlety: no driver binds `0264`, so
  nothing calls `pci_enable_device` and the BAR reads `0xffffffff` until memory decode is turned on
  (`echo 1 > .../enable`, or COMMAND bit 1).
* **JTAG access** is FPGA_CTRL `CONNECT`/`DISCONNECT` -- in the table above, so it comes along free.

## Three ways to do it, cheapest first

**1. User space only, no kernel module.** Access registers are ordinary `MLX5_CMD_OP_ACCESS_REG`
firmware commands, and two user-space transports already exist:

* **MFT** (`mlxreg`): **verified working today** on Host C with the FPGA-aware driver irrelevant --
  `mlxreg -d 0000:08:00.0 --reg_id 0x4022 --reg_len 256 --get` returns live FPGA_CAP data
  (`0x02000000 ... 0xa1010000`). `mlxreg` does not know these registers by name (`--show_reg
  FPGA_CAP` fails), so they must be driven by raw id + payload.
* **DEVX** (rdma-core, `mlx5dv_devx_general_cmd`): lets a process issue ACCESS_REG directly. Needs
  `mlx5_ib` and `CAP_NET_RAW`, and is the cleanest programmatic route.

Then the app is modified in exactly one place: `fpga_access.c`'s ioctl/read/write wrappers become
calls to a small transport shim. Nothing else in the app changes, and no kernel code is written.

**2. Supplemental kernel module, shipping drivers untouched.** If user space is blocked (no MFT, no
DEVX permission), a small out-of-tree module can re-create the chardev with the *same ioctl numbers*
so the **unmodified** binary works. It needs only `mlx5_core_access_reg()`, which is
`EXPORT_SYMBOL_GPL` -- a module can get the `mlx5_core_dev` via the auxiliary bus and issue the three
registers itself. This is the "supplemental module, drivers unchanged" shape you asked about, and it
is perhaps 300 lines: chardev + ioctl switch + three register helpers.

**3. Port our own tooling.** `fpga_image_sel.py`, `fpga_query.py`, `fpga_jtag_grant.py` and
`cr_read.py` already replace the app's menu items for our purposes; they'd need the same transport
swap as option 1. This is the least work and the least compatibility -- it does not run the vendor's
binary.

## What is verified, and what is not

* **Verified:** the ACCESS_REG transport works from user space with no FPGA-aware driver
  (`mlxreg --reg_id 0x4022`, live data). The burn path works with no driver at all.
  The register ids and CTRL opcodes above are read from the OFED source, not guessed.
* **Not yet verified:** a CR-space read through `0x4024` from user space. `mlxreg`'s generic
  `--indexes` form was rejected (`ME_ICMD_OPERATIONAL_ERROR`) because it lacks this register's
  layout, and the test must anyway be run with the card **not** on its User image -- the ConnectX
  refuses CR space when `oper_image == User` (measured).
  The decisive test is cheap and has a known answer: with the card in Flex, read CR `0x900004` and
  expect the BCD build stamp `0x27112018`, which `cr_read.py` returns through the old driver today.

## Caveats worth writing down

* FPGA_CTRL writes are powerful: image select, load, reset and the JTAG grant all live there. A
  user-space shim inherits every hazard the ioctls have, including the ones that cost us machines
  (image select takes effect on a COLD cycle; reconfiguration is reboot-class on Host C).
* `RELOAD` (0x88) and `CAP` (0x85) are **ENOTTY on the shipping 5.8 driver** while `LOAD` is EBUSY
  and `RESET` is EINVAL -- so a shim built on FPGA_CTRL may actually expose *more* than the
  current driver does. Whether the firmware honours LOAD/RESET in a given state is a separate
  question from whether the transport reaches it.
* Modern firmware may gate these registers. Before building anything, run the known-answer CR test
  above on the target firmware version.
