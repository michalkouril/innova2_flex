#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 the innova2 contributors
#
# SPDX-License-Identifier: Apache-2.0
"""flex_acceptance.py -- burn the Flex image inn2f r2 into a card's Flex slot and prove the card accepts it.

Run on the host, as root, one stage at a time; a COLD power cycle separates the stages that need one.

  pre         both flash chips answer; what the Flex slot holds now (the rollback image); Factory scan. Read-only.
  burn        (after pre)  writes the Flex slot (0x03000000) -- skipped when it already holds inn2f r2 -- then reads
              samples back (must match inn2f r2 exactly) and checks Factory is unchanged.
  select-flex / select-user   schedule the image for the next COLD cycle.
  check-flex  (after a cold boot with Flex selected)  the ConnectX ACCEPTS the image (status=0), the burn endpoint
              15b3:0264 is present, identity registers read inn2f r2's values (USERCODE 0xDD500132, identity 0xDD02),
              FPGA temperature is plausible.
  check-user  (after a cold boot with User selected)  the Flex image hands over: the ConnectX reports the User image
              running with status 0, and the User image's PCIe function(s) appear on the card.

  flex_acceptance.py <stage> [--cx5 <ConnectX BDF>] [--card <flash BDF>] [--bar N] [--bar-offset X] [--yes]
                             [--xbflash <path>]

Only pre and burn touch the flash, through an AXI Quad SPI controller that reaches both chips. They need a design
running on the FPGA that exposes one to the host; --card names that PCI function. The burn endpoint of inn2f r2
itself (15b3:0264, controller at BAR0 + 0x40000) is found automatically, for reinstalling or updating a card that
already has it; for a User image with such a controller pass --card, --bar and --bar-offset. Writing uses
xbflash.qspi from the XRT tools package. A card with neither -- the vendor Flex, or a User image without flash
access -- is installed over JTAG instead; the select- and check- stages work either way.

Write the Flex slot only on a card with a working JTAG cable: if the ConnectX rejects the new image, JTAG is the way
back. Each check prints `CHECK <name> PASS|FAIL <detail>`; each stage ends with `ACCEPTANCE-<stage> PASS|FAIL`.
State (the rollback identification, Factory scans) is kept in /var/tmp/innova2_flex_accept/<cx5 bdf>/.
On a host with several cards, the FPGA functions are taken from the card behind --cx5 (the ConnectX and the FPGA share
the on-card switch), and a --card on a different card is refused.
"""
import glob, os, re, struct, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
MCS = {k: os.path.join(REPO, "images", "inn2f_r2_%s.mcs" % k) for k in ("primary", "secondary")}
IDENT = {0x900000: 0x0000DD02, 0x900004: 0x30092026, 0x900008: 0x00192544}   # version, date, time (inn2f r2)
SAMPLES = (0x03200000, 0x03600000)          # deep inside the Flex payload (0x03000000 .. 0x0372A61B)
SAMPLE_LEN = 0x4000
XRT_BIN = "/opt/xilinx/xrt/bin"
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(ok)
    print("CHECK %-22s %s %s" % (name, "PASS" if ok else "FAIL", detail), flush=True)
    return ok


def devs(vendor, device=None):
    out = []
    for d in glob.glob("/sys/bus/pci/devices/*"):
        try:
            if open(d + "/vendor").read().strip() == vendor and device in (None, open(d + "/device").read().strip()):
                out.append(os.path.basename(d))
        except OSError:
            pass
    return sorted(out)


def pci_id(b):
    d = "/sys/bus/pci/devices/" + b
    return "%s:%s" % (open(d + "/vendor").read().strip()[2:], open(d + "/device").read().strip()[2:])


def driver(b):
    l = "/sys/bus/pci/devices/%s/driver" % b
    return os.path.basename(os.path.realpath(l)) if os.path.exists(l) else None


def fpga_funcs(cx5):
    """Every PCI function on the card of cx5 that is not the ConnectX: whatever the running FPGA image exposes."""
    alld = [os.path.basename(d) for d in glob.glob("/sys/bus/pci/devices/*")]
    return [b for b in on_card(alld, cx5) if not open("/sys/bus/pci/devices/%s/vendor" % b).read().strip() == "0x15b3"
            or pci_id(b) == "15b3:0264"]


def spi_env(card, bar, bar_off):
    return dict(os.environ, BDF=card, RAWSPI_BAR=str(bar), RAWSPI_BAR_OFFSET=hex(bar_off))


def xbflash_path(given):
    for p in ([given] if given else []) + [os.path.join(XRT_BIN, "xbflash.qspi")] + \
             [os.path.join(d, "xbflash.qspi") for d in os.environ.get("PATH", "").split(":")]:
        if p and os.access(p, os.X_OK):
            return p
    sys.exit("*** xbflash.qspi not found (XRT tools); pass --xbflash <path>")


def one(lst, what, given):
    if given:
        return given if given.count(":") == 2 else "0000:" + given
    if len(lst) != 1:
        sys.exit("*** %s: found %s -- choose one explicitly" % (what, lst or "none"))
    return lst[0]


def on_card(lst, cx5):
    """The functions in lst that sit on the same Innova-2 card as ConnectX cx5: a card's FPGA and ConnectX share the
    on-card switch, i.e. the sysfs path two levels above each function. Needed on hosts with more than one card."""
    up = lambda b: os.path.dirname(os.path.dirname(os.path.realpath("/sys/bus/pci/devices/" + b)))
    return [b for b in lst if up(b) == up(cx5)]


def node_for(cx5):
    n = "/dev/%s_mlx5_fpga_tools" % cx5
    if not os.path.exists(n):
        for mod in ("innova2_areg", "mlx5_fpga_tools"):
            subprocess.run(["modprobe", mod], capture_output=True)
            time.sleep(2)
            if os.path.exists(n):
                break
    if not os.path.exists(n):
        sys.exit("*** %s missing: load the vendor mlx5_fpga_tools module (or innova2_areg)" % n)
    return n


def query(cx5):
    out = subprocess.run([sys.executable, os.path.join(REPO, "source/host/fpga_query.py"), node_for(cx5)],
                         capture_output=True, text=True).stdout
    m = re.search(r"FPGA-QUERY admin=(\d+)\S* oper=(\d+)\S* status=(\d+)", out)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else None


def cr_read(cx5, addr):
    fd = os.open(node_for(cx5), os.O_RDONLY)
    try:
        os.lseek(fd, addr, os.SEEK_SET)
        b = os.read(fd, 4)
        return struct.unpack(">I", b)[0] if len(b) == 4 else None
    except OSError:
        return None
    finally:
        os.close(fd)


def mcs_window(path, start, length):
    """Bytes [start, start+length) of an Intel-hex MCS (0xFF where the file has no data)."""
    buf = bytearray(b"\xff" * length)
    base = 0
    with open(path) as f:
        for line in f:
            if not line.startswith(":"):
                continue
            n, a, t = int(line[1:3], 16), int(line[3:7], 16), int(line[7:9], 16)
            if t == 4:
                base = int(line[9:13], 16) << 16
            elif t == 0:
                addr = base + a
                if addr + n <= start or addr >= start + length:
                    continue
                data = bytes.fromhex(line[9:9 + 2 * n])
                for i, v in enumerate(data):
                    if start <= addr + i < start + length:
                        buf[addr + i - start] = v
    return bytes(buf)


def flex_slot_matches(env):
    """Fraction of sampled Flex-slot bytes equal to inn2f r2 (1.0 = identical), read through the card's SPI."""
    good = tot = 0
    for off in SAMPLES:
        chips = []
        for c in (0, 1):
            o = "%s/c%d_%08x.bin" % (W, c, off)
            subprocess.run([sys.executable, os.path.join(REPO, "source/host/rawspi.py"), "dump", str(c), "%08x" % off,
                            "%x" % SAMPLE_LEN, o], capture_output=True, env=env)
            chips.append(open(o, "rb").read() if os.path.exists(o) else b"")
        # xbflash applies a +0x1000 shift to MCS addresses (the MCS is declared at 0x02FFF000)
        ref = [mcs_window(MCS[k], off - 0x1000, SAMPLE_LEN) for k in ("primary", "secondary")]
        m = lambda a, b: sum(x == y for x, y in zip(a, b))
        good += max(m(chips[0], ref[0]) + m(chips[1], ref[1]), m(chips[0], ref[1]) + m(chips[1], ref[0]))
        tot += 2 * SAMPLE_LEN
    return good / tot if tot else 0.0


def both_chips(env):
    """Both flash chips answer JEDEC RDID through the card's SPI controller with Micron's 20 BB 20."""
    p = subprocess.run([sys.executable, os.path.join(REPO, "source/host/rawspi.py"), "rdid"], capture_output=True,
                       text=True, env=env)
    ids = dict(re.findall(r"slave(\d) RDID: ([0-9a-f]+)", p.stdout))
    return all(ids.get(c, "").startswith("20bb20") for c in "01"), " ".join("chip%s=%s" % kv for kv in sorted(ids.items())) \
        or (p.stderr.strip().splitlines() or ["no answer"])[-1]


def factory_scan(env, name):
    """Factory region fingerprint through the DIRECT SPI path (rawspi on the card's SPI controller): 16 x 64 KB per chip across
    0x0..0xFFFFFF. Not XRT's flash read path (/dev/xfpga): after xbflash writes the Flex region it reads back zeros
    (measured), which once turned an intact Factory into a false 'changed'."""
    import hashlib
    res = {}
    for c in (0, 1):
        for off in range(0, 0x1000000, 0x100000):
            o = "%s/%s_c%d_%08x.bin" % (W, name, c, off)
            subprocess.run([sys.executable, os.path.join(REPO, "source/host/rawspi.py"), "dump", str(c), "%08x" % off,
                            "10000", o], capture_output=True, env=env)
            if not os.path.exists(o):
                return None
            b = open(o, "rb").read()
            res[(c, off)] = hashlib.sha1(b).hexdigest() if len(b) == 0x10000 else None
            os.remove(o)
    open(os.path.join(W, name), "w").write("".join("%d 0x%08x %s\n" % (c, off, h) for (c, off), h in sorted(res.items())))
    return res if all(res.values()) else None


def main():
    global W
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); return 0
    stage = a[0]
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a else d
    if os.geteuid() != 0:
        sys.exit("*** run as root")
    cx5 = one(devs("0x15b3", "0x1017") and [d for d in devs("0x15b3", "0x1017") if d.endswith(".0")]
              or [n.split("/")[-1].split("_")[0] for n in glob.glob("/dev/*.0_mlx5_fpga_tools")], "ConnectX", opt("--cx5"))
    W = "/var/tmp/innova2_flex_accept/%s" % cx5
    os.makedirs(W, exist_ok=True)
    print("=== flex_acceptance %s  ConnectX %s  image inn2f r2  state %s" % (stage, cx5, W), flush=True)

    if stage in ("pre", "burn"):
        card = one(on_card(devs("0x15b3", "0x0264"), cx5),
                   "burn endpoint 15b3:0264 (else pass --card) on the card of %s" % cx5, opt("--card"))
        if not on_card([card], cx5):
            sys.exit("*** %s is not on the same card as ConnectX %s -- refusing" % (card, cx5))
        bar, bar_off = int(opt("--bar", "0")), int(opt("--bar-offset", "0x40000"), 0)
        env = spi_env(card, bar, bar_off)
        q = query(cx5)
        check("connectx-query", q is not None and q[2] == 0, "admin/oper/status=%s  flash via %s (%s) BAR%d+0x%x"
              % (q, card, pci_id(card), bar, bar_off))
        ok, ids = both_chips(env)
        check("both-flash-chips", ok, ids)
        if not all(RESULTS):
            print("ACCEPTANCE-%s FAIL (nothing written)" % stage); return 1
        if stage == "pre":
            f = flex_slot_matches(env)
            open(os.path.join(W, "flex_before.txt"), "w").write("%.4f\n" % f)
            check("flex-slot-identified", True, "matches inn2f r2: %.2f %%%s" % (100 * f, "" if f < 1 else " (already installed)"))
            fs = factory_scan(env, "factory_before.txt")
            check("factory-scan", bool(fs), "%d x 64 KB samples (direct SPI)" % len(fs or {}))
        else:
            before = factory_scan(env, "factory_before_burn.txt")
            f0 = flex_slot_matches(env)
            if f0 >= 1.0:
                check("flex-slot-written", True, "already inn2f r2 -- nothing written")
            else:
                if "--yes" not in a and input("Write the Flex slot of %s with inn2f r2? [y/N] " % card).strip().lower() not in ("y", "yes"):
                    print("aborted, nothing written"); return 1
                p = subprocess.run(["env", "FLASH_VIA_USER=1", xbflash_path(opt("--xbflash")), "--primary",
                                    os.path.basename(MCS["primary"]), "--secondary", os.path.basename(MCS["secondary"]),
                                    "--card", card, "--bar", str(bar), "--bar-offset", hex(bar_off), "--force"],
                                   cwd=os.path.dirname(MCS["primary"]), capture_output=True, text=True)
                check("xbflash-write", p.returncode == 0, (p.stdout + p.stderr).strip().splitlines()[-1] if (p.stdout + p.stderr).strip() else "")
                f1 = flex_slot_matches(env)
                check("flex-readback", f1 >= 1.0, "matches inn2f r2: %.2f %%" % (100 * f1))
            after = factory_scan(env, "factory_after_burn.txt")
            d = sum(1 for k in before if before[k] != after.get(k)) if before and after else -1
            check("factory-unchanged", d == 0, "%d of %d blocks differ" % (d, len(before or {})))
    elif stage in ("select-flex", "select-user"):
        which = stage.split("-")[1]
        p = subprocess.run([sys.executable, os.path.join(REPO, "source/host/fpga_image_sel.py"), node_for(cx5), which],
                           capture_output=True, text=True)
        check("image-select-" + which, p.returncode == 0 and "IMAGE-SEL OK" in p.stdout, p.stdout.strip().splitlines()[0] if p.stdout else p.stderr.strip())
        print("Next: COLD power cycle (power off, then on), then run check-%s." % which)
    elif stage == "check-flex":
        q = query(cx5)
        check("connectx-accepts", q is not None and q[1] == 1 and q[2] == 0,
              "admin=%s oper=%s status=%s (expect oper=1 status=0; status=1 = REJECTED)" % q if q else "no query")
        be = on_card(devs("0x15b3", "0x0264"), cx5)
        check("burn-endpoint", len(be) == 1, "15b3:0264 %s" % be)
        got = {r: cr_read(cx5, r) for r in IDENT}
        check("identity", all(got[r] == IDENT[r] for r in IDENT), " ".join("0x%06X=%s" % (r, "EIO" if v is None else "0x%08X" % v) for r, v in got.items()))
        t = cr_read(cx5, 0x8400)
        c = ((t & 0xFFFF) * 508 >> 16) - 279 if t is not None else None
        check("fpga-temperature", c is not None and 10 <= c <= 95, "%s C" % c)
    elif stage == "check-user":
        q = query(cx5)
        check("connectx-user", q is not None and q[0] == 0 and q[1] == 0 and q[2] == 0, "admin/oper/status=%s" % (q,))
        f = fpga_funcs(cx5)
        check("user-image-on-pcie", len(f) > 0 and "15b3:0264" not in map(pci_id, f),
              " ".join("%s=%s(%s)" % (b, pci_id(b), driver(b) or "no driver") for b in f) or "no FPGA function on the card")
    else:
        sys.exit("*** unknown stage %s (see --help)" % stage)
    ok = all(RESULTS)
    print("ACCEPTANCE-%s %s" % (stage, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


W = None
if __name__ == "__main__":
    sys.exit(main())
