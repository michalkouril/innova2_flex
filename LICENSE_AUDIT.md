# Licence audit — innova2_flex (2026-09-28, public/private split 2026-09-29, inn2f r2 2026-09-30)

Every file in this repository, classified by provenance. Classes and what they mean are at the end.

**Provenance notes:** only the DDR4 MIG's configuration (`source/ip/ddr4_flex_ip/ddr4_flex/ddr4_flex.xci`) ships
here. Vivado's generated MIG output is AMD "confidential and proprietary" and is kept in the maintainers' private copy,
which is what makes a byte-exact rebuild possible. This repository's build regenerates the MIG from the .xci, which
gives a functionally equivalent image that is not byte-identical. The repository contains no AMD-proprietary file. The BOPE protocol comes from Mellanox's burn_app.c / mlx_fpga_bope.c (dual GPL-2.0 / OpenIB BSD).

| file | class | licence evidence in the file |
|---|---|---|
| `.gitignore` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `EVIDENCE.md` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `LICENSE` | Licence text | Apache License; Apache License to your work, attac; Apache License to your work.; Copyrigh |
| `LICENSES/Apache-2.0.txt` | Licence text | Apache License; Apache License to your work, attac; Apache License to your work.; Copyrigh |
| `LICENSES/LicenseRef-AMD-IP.txt` | Licence text | — |
| `LICENSES/Linux-OpenIB.txt` | Licence text | COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER; copyright notice,; copyright  |
| `LICENSE_AUDIT.md` | Ours | Apache License  /; Apache License;; Apache License to your work.; Copy; Apache License; Ap |
| `NOTICE` | Ours | BSD licence; Copyright 2018 Mellanox Technologies Ltd., dual GPL-2.0 / OpenIB.org BSD; use |
| `README.md` | Ours | — |
| `REUSE.toml` | Ours | CopyrightText = ["2026 the innova2 contributors", "Advanced Micro Devices, Inc."]; Copyrig |
| `SHA256SUMS` | Ours | — |
| `images/inn2f_r2.bit` | Vivado-built binary containing AMD IP | binary |
| `images/inn2f_r2_primary.mcs` | Vivado-built binary containing AMD IP | binary |
| `images/inn2f_r2_primary.prm` | Vivado-built binary containing AMD IP | — |
| `images/inn2f_r2_secondary.mcs` | Vivado-built binary containing AMD IP | binary |
| `images/inn2f_r2_secondary.prm` | Vivado-built binary containing AMD IP | — |
| `images/inn2f_r2_split_primary.bin` | Vivado-built binary containing AMD IP | binary |
| `images/inn2f_r2_split_primary.prm` | Vivado-built binary containing AMD IP | — |
| `images/inn2f_r2_split_secondary.bin` | Vivado-built binary containing AMD IP | binary |
| `images/inn2f_r2_split_secondary.prm` | Vivado-built binary containing AMD IP | — |
| `source/board/custom_parts_mt40a1g16knr075_dw8b.csv` | Hardware facts / third-party data | — |
| `source/build/build.sh` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/build/build_flexburn.tcl` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/build/mk_flex_mcs.tcl` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/calib_sync.xdc` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/ddr4_72bit_gen.xdc` | Hardware facts / third-party data | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/flex_pins.xdc` | Hardware facts / third-party data | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/flexburn_cfgrate.xdc` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/flexburn_userid.xdc` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/innova2_pinfacts.xdc` | Hardware facts / third-party data | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/pcie_x8_lanes.xdc` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/spi1_rescue.xdc` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/constraints/static_pins.xdc` | Hardware facts / third-party data | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/docs/boot_chain.md` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/docs/ddr4.md` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/docs/ddr_health_map.md` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/docs/iprog_watchdog.md` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/docs/modern_drivers.md` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/host/bar_probe.py` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/host/bope_probe.py` | Derived from Mellanox (GPL-2.0 / OpenIB BSD) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/host/cr_read.py` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/host/fpga_image_sel.py` | Derived from Mellanox (GPL-2.0 / OpenIB BSD) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/host/fpga_jtag_grant.py` | Derived from Mellanox (GPL-2.0 / OpenIB BSD) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/host/fpga_query.py` | Derived from Mellanox (GPL-2.0 / OpenIB BSD) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/host/fpga_reload.py` | Derived from Mellanox (GPL-2.0 / OpenIB BSD) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/host/rawspi.py` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/ip/ddr4_flex_ip/ddr4_flex/ddr4_flex.xci` | Ours, tool-generated | — |
| `source/rtl/bope_burn.v` | Derived from Mellanox (GPL-2.0 / OpenIB BSD) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/rtl/bope_regs.v` | Derived from Mellanox (GPL-2.0 / OpenIB BSD) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/rtl/cr_map_gen.v` | Mellanox data (captured) | CopyrightText: 2026 the innova2 contributors; CopyrightText: Mellanox Technologies Ltd.; S |
| `source/rtl/cr_regs.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/rtl/e3_code.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/rtl/e4_replay.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/rtl/flex_burn_top.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/rtl/flex_hop.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/rtl/i2c_cr_slave.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/rtl/power_burn.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/rtl/sysmon_temp.v` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/qspi_flash_model.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/tb_bope_burn.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/tb_bope_regs.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/tb_cr_regs.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/tb_cr_write.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/tb_e3_code.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/tb_e3_code_noise.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `source/sim/tb_e4_replay.sv` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |
| `test/flex_acceptance.py` | Ours | CopyrightText: 2026 the innova2 contributors; SPDX-License-Identifier: Apache-2.0 |

## Classes

* **Ours** (40 files): Written in this project. Apache-2.0, (c) 2026 the innova2 contributors (SPDX header or REUSE.toml).
* **Licence text** (4 files): Verbatim licence text (SPDX licence list, or our LicenseRef explanation). Not a work of ours to license.
* **Vivado-built binary containing AMD IP** (9 files): Bitstreams and flash images synthesised by Vivado: they contain AMD IP cores (XDMA/PCIe, MIG, AXI Quad SPI, SmartConnect, ...) under AMD's IP licence terms.
* **Hardware facts / third-party data** (5 files): Pin locations or memory-part timings (Micron data in AMD's MIG CSV format). Facts; note the source.
* **Derived from Mellanox (GPL-2.0 / OpenIB BSD)** (7 files): Ours, but register maps / protocol / ioctl numbers transcribed from Mellanox sources that are dual GPL-2.0 or OpenIB BSD. Ship the BSD notice + attribution.
* **Ours, tool-generated** (1 files): Produced by Vivado/our scripts from our own design or measurements; no third-party text. Apache-2.0 via REUSE.toml.
* **Mellanox data (captured)** (1 files): Register values read from a running Mellanox Flex image and reproduced verbatim. Facts, not code, but the vendor's values: attribution; owner's call.
