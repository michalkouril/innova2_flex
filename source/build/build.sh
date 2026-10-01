#!/bin/bash

# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0

# Build the Innova-2 Flex image from this source tree.   Needs Vivado 2023.2 (xcku15p support); ~1 hour.
#
#   source/build/build.sh [output dir]        default: ./flex_build
#
# Produces <out>/flex_<usercode>.bit and the per-chip images (<out>/flex_<usercode>_{primary,secondary}.mcs,
# guard-aware for xbflash, and _split_*.bin for the BOPE burn). The design has a single configuration: DDR4 on, the
# early-latched link gate on, no watchdog.
set -eu
PKG=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
OUTD=$(mkdir -p "${1:-flex_build}" && cd "${1:-flex_build}" && pwd)
export FLEX_BUILD_DIR=$OUTD LINKW=X4 AXIF=125 GTXDC=$PKG/constraints/pcie_x8_lanes.xdc
V=${VIVADO:-vivado}
mkdir -p "$OUTD/out"
( cd "$OUTD" && env -u LD_LIBRARY_PATH "$V" -mode batch -nojournal -nolog -source "$PKG/build/build_flexburn.tcl" ) > "$OUTD/build.log" 2>&1 || true
if grep -qE "^RESCUE \*\*\*|^ERROR:" "$OUTD/build.log"; then grep -E "^RESCUE \*\*\*|^ERROR:" "$OUTD/build.log" | head -5; echo "BUILD FAILED (log: $OUTD/build.log)"; exit 1; fi
grep -E "^RESCUE timing gate" "$OUTD/build.log" | tail -1
U=$(strings -a "$OUTD/out/flex_burn_q127x4.bit" | grep -oE "UserID=[0-9A-Fa-f]{8}" | head -1 | cut -d= -f2 | tr 'A-Z' 'a-z')
cp -a "$OUTD/out/flex_burn_q127x4.bit" "$OUTD/flex_$U.bit"
( cd "$OUTD" && env -u LD_LIBRARY_PATH "$V" -mode batch -nojournal -nolog -source "$PKG/build/mk_flex_mcs.tcl" -tclargs "flex_$U.bit" "flex_$U" ) > "$OUTD/mcs.log" 2>&1
grep -q "MK-FLEX-MCS-DONE" "$OUTD/mcs.log" || { echo "*** MCS generation failed (log: $OUTD/mcs.log)"; exit 1; }
echo "built $OUTD/flex_$U.bit (USERCODE $U) + MCS"
