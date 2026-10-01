#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 the innova2 contributors
# SPDX-FileCopyrightText: Mellanox Technologies Ltd.
#
# SPDX-License-Identifier: Apache-2.0 AND Linux-OpenIB

"""Drive the BOPE endpoint the way innova2_flex_app does.

Everything here mirrors burn_app.c: one 32-bit register at BAR0+0, writes push, reads return the
status word. CTYPES ONLY -- python's mmap slice assignment goes through glibc memcpy, which on this
platform issues the store TWICE (measured). Into a FIFO that is not a
cosmetic bug: every duplicated word would be an extra byte in the image.

  usage: bope_probe.py <bdf> status|pcitest|burn <chip> <hexaddr> <file>
"""
import ctypes, mmap, os, struct, sys, time


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

class Bope:
    def __init__(self, bdf):
        enable_device(bdf)
        self.fd = os.open("/sys/bus/pci/devices/%s/resource0" % bdf, os.O_RDWR | os.O_SYNC)
        self.map = mmap.mmap(self.fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0)
        self.base = ctypes.addressof(ctypes.c_char.from_buffer(self.map))
    def wr(self, v):  ctypes.c_uint32.from_address(self.base).value = v & 0xFFFFFFFF
    def rd(self):     return ctypes.c_uint32.from_address(self.base).value

FS = {0:"IDLE",1:"START",2:"ERASE1",3:"ERASE2",4:"PROG1",5:"PROG2",6:"WIP1",7:"WIP2",
      8:"ADV",9:"FIN",10:"FAIL",11:"WAITDATA"}
XS = {0:"idle",1:"pre1",2:"pre2",3:"push",4:"ss",5:"run",6:"poll",7:"stop"}

def dbg(s):
    """In a DEBUG_STATUS build the version field carries {fs[4:0], last SPI byte, xs[2:0]}."""
    v = s & 0xFFFF
    sr = (v >> 3) & 0xFF
    flags = "".join(n for b, n in ((0, "RXE"), (1, "RXF"), (2, "TXE"), (3, "TXF")) if sr & (1 << b))
    return "fs=%-8s SR=0x%02X[%s] xs=%s" % (FS.get(v >> 11, v >> 11), sr, flags or "-", XS.get(v & 7, v & 7))

def fields(s):
    return dict(version=s & 0xFFFF, progress=(s >> 16) & 0x7F, done=(s >> 23) & 3,
                fatal=(s >> 25) & 1, busy=(s >> 26) & 1, pcie_test=(s >> 27) & 1,
                recov=(s >> 28) & 1, afull=(s >> 29) & 1)

def show(b, tag):
    s = b.rd()
    f = fields(s)
    print("  %-14s raw=%08x [%s] progress=%3d done=%d busy=%d pcie_test=%d afull=%d err=%d/%d"
          % (tag, s, dbg(s), f['progress'], f['done'], f['busy'], f['pcie_test'],
             f['afull'], f['recov'], f['fatal']))
    return f

def pcitest(b):
    ok = True
    for val, want in ((0x01234567, 0), (0xA5A5A5A5, 1), (0x01234567, 0)):
        b.wr(val); time.sleep(0.01)
        got = fields(b.rd())['pcie_test']
        print("    write %08x -> pcie_test %d (want %d) %s" % (val, got, want, "ok" if got == want else "WRONG"))
        ok &= (got == want)
    return ok

def burn(b, chip, addr, data):
    CHUNK = 64 * 1024
    done0 = fields(b.rd())['done']
    sent = 0
    for off in range(0, len(data), CHUNK):
        part = data[off:off + CHUNK]
        if len(part) % 4:
            part += b"\xff" * (4 - len(part) % 4)
        flash_off = (addr + off) | (0x80000000 if chip else 0)
        b.wr(0xC001BABE); b.wr(0x60000000); b.wr(flash_off); b.wr(len(part))
        for i in range(0, len(part), 4):
            # the app stalls while buffer_almost_full is set; so do we, or words are dropped
            guard = 0
            while fields(b.rd())['afull']:
                time.sleep(0.001); guard += 1
                if guard > 20000: print("    *** afull never cleared"); return False
            b.wr(struct.unpack("<I", part[i:i+4])[0])
            sent += 4
        # watch the engine while it works: a state trace beats a single "it failed" line
        t0 = time.time(); want = (done0 + 1) & 3; seen = {}; last_print = 0
        while True:
            f = fields(b.rd())
            if f['fatal']: print("    *** engine reported a fatal error"); return False
            if f['done'] == want and not f['busy']: break
            d = dbg(b.rd())
            seen[d.split()[0]] = seen.get(d.split()[0], 0) + 1
            if time.time() - last_print > 2.0:
                print("      [%5.1fs] %s progress=%d" % (time.time() - t0, d, f['progress']))
                last_print = time.time()
            if time.time() - t0 > 60:
                print("    *** chunk never completed; states seen: %s" % seen); return False
            time.sleep(0.005)
        done0 = want
        print("    chunk at 0x%08X chip %d: %d bytes, done counter now %d" % (addr + off, chip, len(part), want))
    return True

if __name__ == "__main__":
    bdf, cmd = sys.argv[1], sys.argv[2]
    b = Bope(bdf)
    if cmd == "status":
        show(b, "status")
    elif cmd == "pcitest":
        show(b, "before")
        ok = pcitest(b)
        show(b, "after")
        print("  PCI-TEST %s" % ("PASS" if ok else "FAIL"))
        sys.exit(0 if ok else 1)
    elif cmd == "burn":
        chip, addr, path = int(sys.argv[3]), int(sys.argv[4], 16), sys.argv[5]
        data = open(path, "rb").read()
        show(b, "before burn")
        ok = burn(b, chip, addr, data)
        show(b, "after burn")
        print("  BURN %s" % ("PASS" if ok else "FAIL"))
        sys.exit(0 if ok else 1)
