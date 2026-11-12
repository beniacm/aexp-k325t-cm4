#!/usr/bin/env python3
"""mk_hdf.py -- an Amiga hard disk image (RDB + FFS partitions), own code.

For the A1200's IDE port (Gayle, Kickstart 3.1's scsi.device): an RDB disk that Kickstart mounts and
boots without any file from the disk's own filesystem (the ROM FFS, dostype DOS\\3 = international
FFS).  The same file is a "hardfile with RDB" for FS-UAE / WinUAE (the emulator reference).

  mk_hdf.py OUT.hdf [--size 512M] [--dh0-mb 64] [--dh0 DIR] [--dh1 DIR] [--run NAME] [--stack N]
                    [--label0 NAME] [--label1 NAME] [--sparse]
  mk_hdf.py --verify IMG.hdf [--dh0 DIR] [--dh1 DIR]     read back: RDB, partitions, every directory,
                                                       file contents (against DIR), checksums, bitmap

Geometry: 16 heads x 63 sectors (1008 blocks a cylinder); cylinders = image blocks // 1008 (512 MB:
1040 cylinders = 1,048,320 blocks; the last 256 blocks of the file lie outside the geometry and are
never used).  Cylinder 0 holds the RDB (RDSK at block 0, PART blocks at 1 and 2).  DH0 (bootable,
boot priority 0) from cylinder 1, --dh0-mb in size; DH1 the rest (not bootable).  Both FFS
(DOS\\3), 512-byte blocks, 2 reserved blocks, root block in the middle as AmigaDOS puts it, bitmap
blocks + bitmap extension blocks for any size.  --run NAME writes s/startup-sequence on DH0
("stack N", "NAME"); otherwise DIR may bring its own s/startup-sequence.
Files are copied with their names as on the host (directories become user directories); dates =
2026-11-12.  --sparse writes the image as a sparse file (the empty blocks are not stored).
"""
import argparse, os, struct, sys

BS = 512
HEADS, SECS = 16, 63
CYLB = HEADS * SECS
T_HEADER, T_LIST, T_DATA = 2, 16, 8
ST_ROOT, ST_USERDIR, ST_FILE = 1, 2, -3 & 0xFFFFFFFF
HT = 72
DAYS = 17847        # 2026-11-12 in AmigaDOS days since 1978-01-01
DOS3 = 0x444F5303


def be(a):
    return struct.pack(">%dI" % len(a), *[x & 0xFFFFFFFF for x in a])


def longs(blk):
    return list(struct.unpack(">128I", blk))


def hdr_cksum(l):
    """header-type blocks: long 5 so that the sum of all 128 longs is 0"""
    l[5] = 0
    l[5] = -sum(l) & 0xFFFFFFFF
    return l


def bm_cksum(l):
    l[0] = 0
    l[0] = -sum(l) & 0xFFFFFFFF
    return l


def rdb_cksum(l, n, at=2):
    l[at] = 0
    l[at] = -sum(l[:n]) & 0xFFFFFFFF
    return l


def hashname(name):
    """international hash (DOS\\3): upper case including 224..254 except 247"""
    def up(c):
        if 97 <= c <= 122 or (224 <= c <= 254 and c != 247):
            return c - 32
        return c
    b = name.encode("latin-1")
    h = len(b)
    for c in b:
        h = (h * 13 + up(c)) & 0x7FF
    return h % HT


def set_name(l, name):
    b = name.encode("latin-1")[:30]
    raw = bytes([len(b)]) + b
    raw += b"\0" * (32 - len(raw))
    l[108:116] = list(struct.unpack(">8I", raw))


def get_name(l):
    raw = struct.pack(">8I", *l[108:116])
    return raw[1:1 + raw[0]].decode("latin-1")


class FFS:
    """one FFS partition of n blocks, written into a bytearray view at block offset base"""

    def __init__(self, img, base, n, label):
        self.img, self.base, self.n = img, base, n
        self.root = (n - 1 + 2) // 2
        self.free = bytearray(b"\1") * n            # 1 = free; blocks 0, 1 are the reserved boot blocks
        self.free[0] = self.free[1] = 0
        self.nbm = (n - 2 + 4063) // 4064            # bitmap blocks (127 longs x 32 bits each)
        self.nbmext = max(0, (self.nbm - 25 + 126) // 127)
        self.label = label
        self.blocks = {}                             # block -> list of 128 longs (header/bitmap blocks)
        self.data = {}                               # block -> bytes (data blocks)
        self.take(self.root)
        # bitmap blocks right after the root, extension blocks after them (as the format command does)
        self.bm = [self.take(self.root + 1 + i) for i in range(self.nbm)]
        self.bmext = [self.take(self.root + 1 + self.nbm + i) for i in range(self.nbmext)]
        self.nextfree = 2
        r = [0] * 128
        r[0], r[3], r[78] = T_HEADER, HT, 0xFFFFFFFF
        for i, b in enumerate(self.bm[:25]):
            r[79 + i] = b
        r[104] = self.bmext[0] if self.bmext else 0
        r[105:108] = [DAYS, 0, 0]       # root alteration date (0x1A4)
        r[118:121] = [DAYS, 0, 0]       # volume alteration date (0x1D8)
        r[121:124] = [DAYS, 0, 0]       # volume creation date (0x1E4)
        set_name(r, label)
        r[127] = ST_ROOT
        self.blocks[self.root] = r

    def take(self, b):
        assert self.free[b], b
        self.free[b] = 0
        return b

    def alloc(self):
        while self.nextfree < self.n and not self.free[self.nextfree]:
            self.nextfree += 1
        if self.nextfree >= self.n:
            sys.exit("partition full")
        b = self.nextfree
        self.free[b] = 0
        return b

    def link(self, parent, blk, name):
        """insert blk into parent's hash table (chain at the end, as AmigaDOS keeps chains sorted by
        block number: new blocks have higher numbers here)"""
        p = self.blocks[parent]
        h = hashname(name)
        if p[6 + h] == 0:
            p[6 + h] = blk
            return
        c = p[6 + h]
        while self.blocks[c][124]:
            c = self.blocks[c][124]
        self.blocks[c][124] = blk

    def mkdir(self, parent, name):
        b = self.alloc()
        d = [0] * 128
        d[0], d[1] = T_HEADER, b
        d[105:108] = [DAYS, 0, 0]
        set_name(d, name)
        d[125], d[127] = parent, ST_USERDIR
        self.blocks[b] = d
        self.link(parent, b, name)
        return b

    def addfile(self, parent, name, content, protect=0):
        hb = self.alloc()
        nblk = (len(content) + BS - 1) // BS
        dblocks = [self.alloc() for _ in range(nblk)]
        for i, db in enumerate(dblocks):
            chunk = content[i * BS:(i + 1) * BS]
            self.data[db] = chunk + b"\0" * (BS - len(chunk))
        # header + extension blocks, 72 pointers each, stored from index 77 downwards
        chunks = [dblocks[i:i + HT] for i in range(0, len(dblocks), HT)] or [[]]
        h = [0] * 128
        h[0], h[1] = T_HEADER, hb
        h[2] = len(chunks[0])
        h[4] = dblocks[0] if dblocks else 0
        for i, db in enumerate(chunks[0]):
            h[77 - i] = db
        h[80], h[81] = protect, len(content)   # 0x140 protection, 0x144 byte size
        h[105:108] = [DAYS, 0, 0]
        set_name(h, name)
        h[125], h[127] = parent, ST_FILE
        self.blocks[hb] = h
        prev = h
        for ch in chunks[1:]:
            eb = self.alloc()
            e = [0] * 128
            e[0], e[1], e[2] = T_LIST, eb, len(ch)
            for i, db in enumerate(ch):
                e[77 - i] = db
            e[125], e[127] = hb, ST_FILE
            self.blocks[eb] = e
            prev[126] = eb
            prev = e
        self.link(parent, hb, name)
        return hb

    def addtree(self, parent, path):
        for name in sorted(os.listdir(path)):
            p = os.path.join(path, name)
            if os.path.isdir(p):
                self.addtree(self.mkdir(parent, name), p)
            else:
                self.addfile(parent, name, open(p, "rb").read())

    def write(self):
        img, o = self.img, self.base * BS
        img[o:o + 4] = struct.pack(">I", DOS3)               # boot block 0: the dostype
        # bitmap: bit (b - 2) of the map, 1 = free
        bits = self.free[2:]
        for i, bb in enumerate(self.bm):
            l = [0] * 128
            for w in range(127):
                v = 0
                start = (i * 127 + w) * 32
                seg = bits[start:start + 32]
                for k, f in enumerate(seg):
                    if f:
                        v |= 1 << k
                l[1 + w] = v
            self.blocks[bb] = bm_cksum(l)
        for i, eb in enumerate(self.bmext):
            l = [0] * 128
            part = self.bm[25 + i * 127:25 + (i + 1) * 127]
            for k, b in enumerate(part):
                l[k] = b
            l[127] = self.bmext[i + 1] if i + 1 < len(self.bmext) else 0
            self.blocks[eb] = l
        for b, l in self.blocks.items():
            if b in self.bm or b in self.bmext:
                blk = be(l)
            else:
                blk = be(hdr_cksum(list(l)))
            img[o + b * BS:o + (b + 1) * BS] = blk
        for b, d in self.data.items():
            img[o + b * BS:o + (b + 1) * BS] = d


def rdb(img, cyls, parts):
    """parts: list of (name, lowcyl, highcyl, bootable)"""
    r = [0] * 128
    r[0:6] = [0x5244534B, 64, 0, 7, BS, 0x7]
    r[6:16] = [0xFFFFFFFF, 1, 0xFFFFFFFF, 0xFFFFFFFF] + [0xFFFFFFFF] * 6
    r[16:21] = [cyls, SECS, HEADS, 1, cyls]
    r[24:27] = [cyls, cyls, 3]
    r[32:39] = [0, CYLB - 1, 1, cyls - 1, CYLB, 0, len(parts)]
    for i, s in enumerate((b"AEXP    ", b"HARDFILE        ", b"1.0 ")):
        o = (40, 42, 46)[i]
        r[o:o + len(s) // 4] = list(struct.unpack(">%dI" % (len(s) // 4), s))
    img[0:BS] = be(rdb_cksum(r, 64))
    for i, (name, lo, hi, boot) in enumerate(parts):
        p = [0] * 128
        p[0:6] = [0x50415254, 64, 0, 7, (2 + i) if i + 1 < len(parts) else 0xFFFFFFFF, 1 if boot else 0]
        nb = name.encode()
        raw = bytes([len(nb)]) + nb
        raw += b"\0" * (32 - len(raw))
        p[9:17] = list(struct.unpack(">8I", raw))
        env = [16, 128, 0, HEADS, 1, SECS, 2, 0, 0, lo, hi, 30, 0, 0x1FE00, 0x7FFFFFFE,
               0 if boot else 0xFFFFFF80, DOS3]       # boot pri 0 / -128
        p[32:32 + len(env)] = env
        img[(1 + i) * BS:(2 + i) * BS] = be(rdb_cksum(p, 64))


def parse_size(s):
    m = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30}
    return int(s[:-1]) * m[s[-1].upper()] if s[-1].upper() in m else int(s)


def build(a):
    size = parse_size(a.size)
    nblk = size // BS
    cyls = nblk // CYLB
    dh0c = max(2, a.dh0_mb * (1 << 20) // BS // CYLB)
    if 1 + dh0c >= cyls:
        sys.exit("disk too small")
    parts = [("DH0", 1, dh0c, True), ("DH1", dh0c + 1, cyls - 1, False)]
    img = bytearray(size)
    rdb(img, cyls, parts)
    for i, (name, lo, hi, boot) in enumerate(parts):
        fs = FFS(img[0:0], 0, (hi - lo + 1) * CYLB, (a.label0, a.label1)[i])
        fs.img = img
        fs.base = lo * CYLB
        src = (a.dh0, a.dh1)[i]
        if src:
            fs.addtree(fs.root, src)
        if i == 0 and a.run:
            s = fs.mkdir(fs.root, "s") if not (src and os.path.isdir(os.path.join(src, "s"))) else None
            if s is None:
                sys.exit("--run with a DIR that has its own s/: put the startup-sequence there")
            fs.addfile(s, "startup-sequence", ("stack %d\n%s\n" % (a.stack, a.run)).encode())
        fs.write()
    with open(a.out, "wb") as f:
        if a.sparse:
            step = 1 << 16
            for o in range(0, size, step):
                c = img[o:o + step]
                if any(c):
                    f.seek(o)
                    f.write(c)
            f.truncate(size)
        else:
            f.write(img)
    print("%s: %d blocks, %d cylinders x %d heads x %d sectors; DH0 cyl 1-%d (%d MB), DH1 cyl %d-%d (%d MB)"
          % (a.out, nblk, cyls, HEADS, SECS, dh0c, dh0c * CYLB * BS >> 20, dh0c + 1, cyls - 1,
             (cyls - 1 - dh0c) * CYLB * BS >> 20))
    return img


# ---------------------------------------------------------------- read back
def verify(path, dirs):
    img = open(path, "rb").read()
    bad = []
    def blk(b):
        return img[b * BS:(b + 1) * BS]
    r = longs(blk(0))
    assert r[0] == 0x5244534B, "no RDSK"
    if sum(r[:64]) & 0xFFFFFFFF:
        bad.append("RDSK checksum")
    cyls, secs, heads = r[16], r[17], r[18]
    pb, parts = r[7], []
    while pb != 0xFFFFFFFF:
        p = longs(blk(pb))
        if p[0] != 0x50415254 or sum(p[:64]) & 0xFFFFFFFF:
            bad.append("PART %d" % pb)
        raw = struct.pack(">8I", *p[9:17])
        parts.append((raw[1:1 + raw[0]].decode(), p[32 + 9], p[32 + 10], p[5] & 1, p[32 + 16]))
        pb = p[4]
    out = ["RDB %d cyl x %d heads x %d sec" % (cyls, heads, secs)]
    for pi, (name, lo, hi, boot, dt) in enumerate(parts):
        base, n = lo * heads * secs, (hi - lo + 1) * heads * secs
        root = (n + 1) // 2
        def pblk(b):
            return longs(img[(base + b) * BS:(base + b + 1) * BS])
        rl = pblk(root)
        if rl[0] != T_HEADER or rl[127] != ST_ROOT or sum(rl) & 0xFFFFFFFF:
            bad.append("%s root" % name)
        used = set([0, 1, root])
        # bitmap
        bmb = [x for x in rl[79:104] if x]
        e = rl[104]
        while e:
            el = pblk(e)
            used.add(e)
            bmb += [x for x in el[:127] if x]
            e = el[127]
        freebits = []
        for b in bmb:
            used.add(b)
            l = pblk(b)
            if sum(l) & 0xFFFFFFFF:
                bad.append("%s bitmap %d" % (name, b))
            for w in l[1:]:
                freebits += [(w >> k) & 1 for k in range(32)]
        nfiles = [0]
        def walk(dirblk, hostdir):
            dl = pblk(dirblk)
            for h in dl[6:78]:
                while h:
                    l = pblk(h)
                    used.add(h)
                    if sum(l) & 0xFFFFFFFF:
                        bad.append("%s header %d" % (name, h))
                    nm = get_name(l)
                    if l[127] == ST_USERDIR:
                        walk(h, os.path.join(hostdir, nm) if hostdir else None)
                    else:
                        size = l[81]
                        data, x = [], l
                        while True:
                            cnt = x[2]
                            for i in range(cnt):
                                db = x[77 - i]
                                used.add(db)
                                data.append(img[(base + db) * BS:(base + db + 1) * BS])
                            if not x[126]:
                                break
                            used.add(x[126])
                            x = pblk(x[126])
                        content = b"".join(data)[:size]
                        nfiles[0] += 1
                        if hostdir and os.path.exists(os.path.join(hostdir, nm)):
                            if open(os.path.join(hostdir, nm), "rb").read() != content:
                                bad.append("%s file %s differs" % (name, nm))
                    h = l[124]
        walk(root, dirs[pi] if pi < len(dirs) else None)
        nfree = sum(freebits[:n - 2])
        # every used block must be marked used in the bitmap, every unused one free
        for b in used:
            if b >= 2 and freebits[b - 2]:
                bad.append("%s block %d used but free in the bitmap" % (name, b))
        if nfree != n - 2 - len([b for b in used if b >= 2]):
            bad.append("%s bitmap count: %d free, %d expected" % (name, nfree, n - 2 - len([b for b in used if b >= 2])))
        out.append("%s cyl %d-%d %s %s %d files, %d blocks used, root %d, %d bitmap blocks" % (
            name, lo, hi, "boot" if boot else "-", struct.pack(">I", dt), nfiles[0], len(used), root, len(bmb)))
    return out, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?")
    ap.add_argument("--size", default="512M")
    ap.add_argument("--dh0-mb", type=int, default=64)
    ap.add_argument("--dh0"); ap.add_argument("--dh1")
    ap.add_argument("--run"); ap.add_argument("--stack", type=int, default=16384)
    ap.add_argument("--label0", default="AExpHD0"); ap.add_argument("--label1", default="AExpHD1")
    ap.add_argument("--sparse", action="store_true")
    ap.add_argument("--verify")
    a = ap.parse_args()
    if a.verify:
        out, bad = verify(a.verify, [a.dh0, a.dh1])
        print("\n".join(out))
        print("errors: %d%s" % (len(bad), (": " + "; ".join(bad[:10])) if bad else ""))
        sys.exit(1 if bad else 0)
    if not a.out:
        sys.exit(__doc__)
    build(a)
    out, bad = verify(a.out, [a.dh0, a.dh1])
    print("\n".join(out))
    print("verify: %d errors%s" % (len(bad), (": " + "; ".join(bad[:10])) if bad else ""))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
