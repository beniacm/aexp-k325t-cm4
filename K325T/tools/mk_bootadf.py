#!/usr/bin/env python3
"""mk_bootadf.py -- a bootable FFS floppy (ADF) that starts an AmigaDOS executable, own code.

For file-based A1200 releases (single executables, hard-disk installs that fit a disk) on a machine
without Workbench files: the disk holds the files, s/startup-sequence and (unless --no-chiprev)
setchiprev (tools/mk_setchiprev.py: graphics.library SetChipRev(best), what SetPatch does for AGA
demos).  Kickstart 2.0 and later boot it (FFS in ROM); the startup-sequence uses ROM-resident
commands only.

  mk_bootadf.py OUT.adf FILE... [--run NAME] [--label NAME] [--no-chiprev] [--stack N]
                                  [--assign NAME]   (the disk's volume name, for "NAME:" paths)

--run: the file to start (default: the first FILE).  The volume name (--label, default the run
file's name) lets programs that open "LABEL:" find their files (Psychedelic: --label psychedelic).
Checks: total size against the 1758 free blocks; the result is read back and verified (directory,
file contents, checksums).
"""
import os, struct, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

NBLK = 1760
ROOT = 880
BS = 512
T_HEADER, T_LIST = 2, 16
ST_ROOT, ST_USERDIR, ST_FILE = 1, 2, -3 & 0xFFFFFFFF
HT = 72

BOOT_SRC = r"""
        .text
        lea     dosname(%pc),%a1
        jsr     -96(%a6)                | FindResident("dos.library")
        tst.l   %d0
        beq.s   1f
        move.l  %d0,%a0
        move.l  22(%a0),%a0             | RT_INIT: the DOS boot entry
        moveq   #0,%d0
        rts
1:      moveq   #-1,%d0
        rts
dosname: .asciz "dos.library"
        .balign 2
"""


def bootcode():
    with tempfile.TemporaryDirectory() as d:
        open(d + "/b.s", "w").write(BOOT_SRC)
        subprocess.check_call(["m68k-linux-gnu-as", "-m68000", "-o", d + "/b.o", d + "/b.s"])
        subprocess.check_call(["m68k-linux-gnu-objcopy", "-O", "binary", d + "/b.o", d + "/b.bin"])
        return open(d + "/b.bin", "rb").read()


def hashname(name):
    h = len(name)
    for c in name.upper().encode("latin-1"):
        h = (h * 13 + c) & 0x7FF
    return h % HT


def cksum(blk):
    s = sum(struct.unpack(">128I", bytes(blk))) & 0xFFFFFFFF
    return (-s) & 0xFFFFFFFF


class Disk:
    def __init__(self):
        self.img = bytearray(NBLK * BS)
        self.used = {0, 1, ROOT, ROOT + 1}
        self.next = ROOT + 2

    def alloc(self):
        for _ in range(NBLK):
            b = self.next
            self.next = self.next + 1 if self.next + 1 < NBLK else 2
            if b not in self.used:
                self.used.add(b)
                return b
        raise SystemExit("disk full")

    def blk(self, n):
        return memoryview(self.img)[n * BS:(n + 1) * BS]

    def put(self, n, off, fmt, *v):
        struct.pack_into(fmt, self.img, n * BS + off, *v)

    def seal(self, n, off=20):
        self.put(n, off, ">I", 0)
        self.put(n, off, ">I", cksum(self.blk(n)))

    def name(self, n, s):
        b = s.encode("latin-1")[:30]
        self.img[n * BS + 0x1B0] = len(b)
        self.img[n * BS + 0x1B1:n * BS + 0x1B1 + len(b)] = b

    def link(self, parent, n, nm):
        """put header n into parent's hash table (chain on collision)"""
        h = hashname(nm)
        cur = struct.unpack_from(">I", self.img, parent * BS + 24 + 4 * h)[0]
        self.put(n, 0x1F0, ">I", cur)
        self.put(parent, 24 + 4 * h, ">I", n)

    def mkdir(self, parent, nm):
        n = self.alloc()
        self.put(n, 0, ">IIII", T_HEADER, n, 0, 0)
        self.name(n, nm)
        self.put(n, 0x1F4, ">I", parent)
        self.put(n, 0x1FC, ">I", ST_USERDIR)
        self.link(parent, n, nm)
        return n

    def mkfile(self, parent, nm, data):
        hdr = self.alloc()
        nblocks = (len(data) + BS - 1) // BS
        datab = [self.alloc() for _ in range(nblocks)]
        for i, b in enumerate(datab):
            chunk = data[i * BS:(i + 1) * BS]
            self.img[b * BS:b * BS + len(chunk)] = chunk
        # header + extension blocks, 72 pointers each, stored from the end of the table
        groups = [datab[i:i + HT] for i in range(0, max(len(datab), 1), HT)] or [[]]
        owners = [hdr] + [self.alloc() for _ in groups[1:]]
        for gi, (blk, grp) in enumerate(zip(owners, groups)):
            if gi == 0:
                self.put(blk, 0, ">IIII", T_HEADER, blk, len(grp), 0)
                self.put(blk, 16, ">I", datab[0] if datab else 0)
                self.put(blk, 0x144, ">I", len(data))
                self.name(blk, nm)
                self.put(blk, 0x1F4, ">I", parent)
            else:
                self.put(blk, 0, ">IIII", T_LIST, blk, len(grp), 0)
                self.put(blk, 0x1F4, ">I", hdr)
            for k, d in enumerate(grp):
                self.put(blk, 24 + 4 * (HT - 1 - k), ">I", d)
            self.put(blk, 0x1F8, ">I", owners[gi + 1] if gi + 1 < len(owners) else 0)
            self.put(blk, 0x1FC, ">I", ST_FILE)
        self.link(parent, hdr, nm)
        return hdr, owners

    def finish(self, label, sealed):
        # root
        self.put(ROOT, 0, ">IIII", T_HEADER, 0, 0, HT)
        self.put(ROOT, 0x138, ">i", -1)              # bitmap valid
        self.put(ROOT, 0x13C, ">I", ROOT + 1)        # bitmap block
        self.name(ROOT, label)
        self.put(ROOT, 0x1FC, ">I", ST_ROOT)
        for n in sealed:
            self.seal(n)
        self.seal(ROOT)
        # bitmap: blocks 2..1759, 1 = free
        bm = bytearray(BS)
        bits = [0 if b in self.used else 1 for b in range(2, NBLK)]
        words = []
        for i in range(0, len(bits), 32):
            w = 0
            for j, bit in enumerate(bits[i:i + 32]):
                w |= bit << j
            words.append(w)
        for i, w in enumerate(words):
            struct.pack_into(">I", bm, 4 + 4 * i, w)
        struct.pack_into(">I", bm, 0, cksum(bm))
        self.img[(ROOT + 1) * BS:(ROOT + 2) * BS] = bm
        # boot block (FFS, DOS\1)
        bb = bytearray(1024)
        bb[0:4] = b"DOS\x01"
        struct.pack_into(">I", bb, 8, ROOT)
        code = bootcode()
        bb[12:12 + len(code)] = code
        s = 0
        for i in range(0, 1024, 4):
            s += struct.unpack_from(">I", bb, i)[0]
            if s > 0xFFFFFFFF:
                s = (s & 0xFFFFFFFF) + 1
        struct.pack_into(">I", bb, 4, (~s) & 0xFFFFFFFF)
        self.img[0:1024] = bb


def verify(img, files):
    """read the directory back: every file found by name through the hash table, contents equal"""
    def rd(n, off, fmt="I"):
        return struct.unpack_from(">" + fmt, img, n * BS + off)[0]
    def lookup(parent, nm):
        n = rd(parent, 24 + 4 * hashname(nm))
        while n:
            ln = img[n * BS + 0x1B0]
            if img[n * BS + 0x1B1:n * BS + 0x1B1 + ln].decode("latin-1").upper() == nm.upper():
                return n
            n = rd(n, 0x1F0)
        return 0
    for n in range(NBLK):
        t = rd(n, 0)
        if n >= 2 and t in (T_HEADER, T_LIST):
            assert cksum(img[n * BS:(n + 1) * BS]) == 0, "checksum of block %d" % n
    for path, data in files:
        parent = ROOT
        parts = path.split("/")
        for p in parts[:-1]:
            parent = lookup(parent, p)
            assert parent, path
        h = lookup(parent, parts[-1])
        assert h, path
        size = rd(h, 0x144)
        out = bytearray()
        blk = h
        while blk:
            cnt = rd(blk, 8)
            for k in range(cnt):
                d = rd(blk, 24 + 4 * (HT - 1 - k))
                out += img[d * BS:(d + 1) * BS]
            blk = rd(blk, 0x1F8)
        assert bytes(out[:size]) == data, path


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        sys.exit(__doc__)
    def opt(k, default=None):
        if k in a:
            i = a.index(k); v = a[i + 1]; del a[i:i + 2]; return v
        return default
    run = opt("--run"); label = opt("--label"); stack = opt("--stack", "40000")
    chiprev = "--no-chiprev" not in a
    a = [x for x in a if x != "--no-chiprev"]
    out, files = a[0], a[1:]
    run = run or os.path.basename(files[0])
    label = label or os.path.splitext(run)[0][:30]
    d = Disk()
    contents = []
    sealed = []
    sdir = d.mkdir(ROOT, "s")
    sealed.append(sdir)
    seq = "stack %s\n" % stack
    if chiprev:
        import mk_setchiprev
        b = mk_setchiprev.build()
        h, o = d.mkfile(ROOT, "setchiprev", b); sealed += o; contents.append(("setchiprev", b))
        seq += "setchiprev\n"
    for f in files:
        b = open(f, "rb").read()
        nm = os.path.basename(f)
        h, o = d.mkfile(ROOT, nm, b); sealed += o; contents.append((nm, b))
    seq += run + "\n"
    h, o = d.mkfile(sdir, "startup-sequence", seq.encode()); sealed += o
    contents.append(("s/startup-sequence", seq.encode()))
    d.finish(label, sealed)
    verify(d.img, contents)
    open(out, "wb").write(d.img)
    print("%s: %d files, %d of %d blocks used, volume %s, runs %s" % (out, len(contents), len(d.used), NBLK, label, run))


if __name__ == "__main__":
    main()
