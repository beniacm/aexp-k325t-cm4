#!/usr/bin/env python3
"""mk_agatest.py -- AGA chipset tests for the stage-3 groundwork (A1200 line), own code.

Each test takes the machine over (no OS afterwards) and shows one still picture made of a grid of
uniform blocks whose 24-bit colours follow from the AGA documentation (palette banks + LOCT,
FMODE fetch widths, HAM8, BPLCON4 bitplane XOR and sprite colour banks, sprite widths).  The
same payload runs in two ways:
  * simulation: the Verilator bench (K325T/sim/aga) injects  <test>.bin  at ORG and enters it
    through the level-3 autovector; the payload writes DONE_MAGIC to DONE_ADDR once the picture
    has been shown for 3 frames (the bench stops on it: --stop);
  * emulators / a real machine: <test>.adf, a boot block that loads the payload with
    trackdisk.device, enters supervisor mode (SuperState) and jumps to it.
check.py-style verification: --expect TEST prints the expected block colours as JSON; --check
TEST FRAME.ppm|png compares a captured frame with them (block centres found from the window
origin, which is located by the colour of block (0,0)).

Usage:
  mk_agatest.py build OUTDIR            all tests: OUTDIR/<test>.bin, .adf, .json (expected),
                                        OUTDIR/bootrom.bin (bench boot ROM that jumps to ORG)
  mk_agatest.py bootrom OUT ORG         a bench boot ROM that jumps to ORG (e.g. the DDR3 study's
                                        workload programs at 0x1E0000)
  mk_agatest.py check TEST FRAME [--xscale N]   compare a frame (PPM from the bench: 2 columns
                                        per lores pixel; PNG from FS-UAE: give --xscale)
"""
import json, os, struct, subprocess, sys, tempfile

ORG = 0x1C0000            # payload address (chip RAM, 2 MB machine)
SCREEN = 0x020000         # bitplane data (8 planes, 64-bit aligned)
COPPER = 0x1B0000         # copper list
SPRITES = 0x1A0000        # sprite data (each sprite 4 KB apart)
DONE_ADDR = 0x1FFFF0
DONE_MAGIC = 0x600DF00D

W, H = 320, 256           # lores window, 16 x 16 blocks of 20 x 16 pixels
BW, BH = 20, 16


def pal_t1(i):
    """test palette: every component has distinct high and low nibbles"""
    r = i
    g = (255 - i) ^ 0x5A
    b = (i * 37 + 11) & 0xFF
    return (r, g, b)


# ----------------------------------------------------------------------------------------------
# bitplane data generators (python): planes[p][y][byte]

def planes_from_index(idx_fn, width, nlines, nplanes=8):
    bpr = width // 8
    planes = [[bytearray(bpr) for _ in range(nlines)] for _ in range(nplanes)]
    for y in range(nlines):
        for x in range(width):
            v = idx_fn(x, y)
            for p in range(nplanes):
                if (v >> p) & 1:
                    planes[p][y][x >> 3] |= 0x80 >> (x & 7)
    return planes


def grid_index(x, y16, bw=BW):
    """block index for the 16 distinct lines: line y16 (0..15) stands for block row y16"""
    return y16 * 16 + x // bw


# ----------------------------------------------------------------------------------------------
# tests

class Test:
    def __init__(self, name, desc):
        self.name, self.desc = name, desc
        self.width = W            # pixels per line (640 for hires)
        self.hires = False
        self.bplcon0 = 0x0211     # 8 planes, COLOR, ECSENA
        self.fmode = 0
        self.ddfstrt, self.ddfstop = 0x38, 0xD0
        self.bplcon4 = 0x0011
        self.palette = [pal_t1(i) for i in range(256)]
        self.idx_fn = lambda x, y16: grid_index(x, y16)
        self.ham8 = None          # list of 16 lines of 8-bit pixel values (HAM8 test)
        self.copper_extra = []    # (line, [(reg, value)]) inserted at that line
        self.sprites = None       # sprite test description
        self.expect = None        # dict (bx,by) -> rgb, or list per block row of colours

    def fetch_bytes_per_line(self):
        return self.width // 8


def expected_grid(t, xorval=None, xor_from_row=16):
    e = {}
    for by in range(16):
        for bx in range(16):
            i = by * 16 + bx
            if xorval is not None and by >= xor_from_row:
                i ^= xorval
            e[(bx, by)] = t.palette[i]
    return e


def make_tests():
    tests = []
    t = Test("pal256", "8 bitplanes lores FMODE 0, 256 colours written through BPLCON3 banks 0-7 "
             "with LOCT (24-bit values with distinct low nibbles)")
    t.expect = expected_grid(t)
    tests.append(t)
    for fm, stop in ((1, 0xC8), (2, 0xC8), (3, 0xB8)):
        t = Test("fmode%d" % fm, "as pal256 with FMODE=%d (%d-bit bitplane fetches), DDFSTOP $%02X"
                 % (fm, 64 if fm == 3 else 32, stop))
        t.fmode, t.ddfstop = fm, stop
        t.expect = expected_grid(t)
        tests.append(t)
    t = Test("ddf3c", "as fmode3 with DDFSTRT $3C / DDFSTOP $BC (start 4 CCK after the 32-CCK fetch "
             "grid): the picture must move 8 lores pixels right against fmode3 (origin delta)")
    t.fmode, t.ddfstrt, t.ddfstop = 3, 0x3C, 0xBC
    t.expect = expected_grid(t)
    tests.append(t)
    t = Test("hires8f3", "8 bitplanes HIRES FMODE=3 (640 pixels, blocks of 40 hires pixels)")
    t.width, t.hires, t.fmode = 640, True, 3
    t.bplcon0 = 0x8211
    t.ddfstrt, t.ddfstop = 0x38, 0xC8
    t.idx_fn = lambda x, y16: grid_index(x, y16, 40)
    t.expect = expected_grid(t)
    tests.append(t)
    t = Test("xor", "pal256 with BPLCON4 BPLAM = $A5 from block row 8 on (copper): colour = "
             "palette[index XOR $A5]")
    t.copper_extra = [(0x2C + 8 * 16, [(0x10C, 0xA511)])]
    t.expect = expected_grid(t, 0xA5, 8)
    tests.append(t)
    tests.append(make_ham8())
    for sw in (16, 32, 64):
        tests.append(make_sprites(sw))
    return tests


def make_ham8():
    """HAM8: planes 1-2 = control (00 palette 0-63 by the 6 data bits, 01 blue, 10 red, 11 green;
    the data bits replace the upper 6 bits of the component, the lower 2 bits stay)"""
    t = Test("ham8", "HAM8, 8 planes lores FMODE 3: per block a palette pixel then blue/red/green "
             "modifications; expected colours computed from the AGA HAM8 rules")
    t.bplcon0 = 0x0A11
    t.fmode, t.ddfstop = 3, 0xB8
    # 64 base colours with distinct low bits in every component
    t.palette = [pal_t1(i) for i in range(256)]
    lines = []
    exp = {}
    for by in range(16):
        line = []
        for bx in range(16):
            base = (by * 16 + bx * 5) & 63
            b6 = (bx * 7 + by * 3) & 63
            r6 = (bx * 11 + by * 5 + 1) & 63
            g6 = (bx * 13 + by * 9 + 2) & 63
            px = [(base << 2) | 0, (b6 << 2) | 1, (r6 << 2) | 2, (g6 << 2) | 3]
            px += [px[-1]] * (BW - 4)
            line += px
            pr, pg, pb = t.palette[base]
            seq = [(pr, pg, pb), (pr, pg, (b6 << 2) | (pb & 3)),
                   ((r6 << 2) | (pr & 3), pg, (b6 << 2) | (pb & 3)),
                   ((r6 << 2) | (pr & 3), (g6 << 2) | (pg & 3), (b6 << 2) | (pb & 3))]
            exp[(bx, by)] = seq[3]
            exp[(bx, by, 'seq')] = seq
        lines.append(line)
    t.ham8 = lines
    t.idx_fn = lambda x, y16: lines[y16][x]
    t.expect = exp
    return t


def make_sprites(sw):
    """8 sprites of width sw (FMODE sprite bits), each 16 lines high, on its own block row
    pair; pixels show colours 1,2,3 in runs of 4.  BPLCON4: ESPRM = 4 (even sprites use colours
    64-79), OSPRM = 9 (odd sprites 144-159).  Bitplanes: 1 plane, all zero (colour 0)."""
    t = Test("spr%d" % sw, "8 sprites %d pixels wide (FMODE sprite field %s), BPLCON4 ESPRM=4 "
             "OSPRM=9" % (sw, {16: "00", 32: "01", 64: "11"}[sw]))
    t.fmode = {16: 0, 32: 4, 64: 12}[sw]
    t.bplcon0 = 0x1201        # 1 plane
    t.bplcon4 = 0x0049
    t.idx_fn = lambda x, y16: 0
    pal = [(0x10, 0x20, 0x30)] * 256
    pal = list(pal)
    for i in range(256):
        pal[i] = pal_t1(i)
    pal[0] = (0x10, 0x20, 0x30)
    t.palette = pal
    spr = []
    exp = {}
    for n in range(8):
        vstart = 0x2C + 8 + n * 30
        hstart = 0x80 + n * 4             # lores pixel units (SPRxPOS H8..H1, CTL H0)
        pix = [1 + ((x // 4) % 3) for x in range(sw)]
        spr.append((vstart, hstart, pix))
        base = (64 if n % 2 == 0 else 144) + (n // 2) * 4
        exp[n] = dict(vstart=vstart, hstart=hstart, width=sw,
                      colours=[pal[base + c] for c in (1, 2, 3)])
    t.sprites = spr
    t.expect = exp
    return t


# ----------------------------------------------------------------------------------------------
# assembly

def words_asm(label, data_bytes, align=8):
    out = ["        .balign %d" % align, label + ":"]
    for i in range(0, len(data_bytes), 16):
        chunk = data_bytes[i:i + 16]
        out.append("        .byte " + ",".join("0x%02x" % b for b in chunk))
    return "\n".join(out)


def build_asm(t):
    bpr = t.width // 8
    # full planes (256 lines; every line of a block row is the row's line), modulo 0, the copper
    # sets the pointers once per frame (re-pointing per block row costs 16 copper MOVEs in the
    # horizontal blank, which does not fit before DDFSTRT with 8-plane FMODE 1/3 fetches)
    planes = planes_from_index(t.idx_fn, t.width, 16)
    psize = bpr * 256
    blob = bytearray(8 * psize)
    for p in range(8):
        for y in range(256):
            o = p * psize + y * bpr
            blob[o:o + bpr] = planes[p][y // 16]
    pal_words = []
    for i, (r, g, b) in enumerate(t.palette):
        hi = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        lo = ((r & 15) << 8) | ((g & 15) << 4) | (b & 15)
        pal_words.append((hi, lo))
    # copper list
    cop = []
    def move(reg, val): cop.extend([reg & 0x1FE, val & 0xFFFF])
    def wait(line):
        if line >= 256 and not getattr(wait, "pal", False):
            cop.extend([0xFFDF, 0xFFFE]); wait.pal = True
        cop.extend([((line & 0xFF) << 8) | 0xDF, 0xFFFE])   # end of the line (hblank)
    wait.pal = False
    move(0x108, 0); move(0x10A, 0)
    move(0x10C, t.bplcon4)          # BPLCON4 back to the test's value every frame
    if t.sprites:
        for n in range(8):
            a = SPRITES + n * 0x1000
            move(0x120 + 4 * n, a >> 16); move(0x122 + 4 * n, a & 0xFFFF)
    for p in range(8):
        a = SCREEN + p * psize
        move(0xE0 + 4 * p, a >> 16); move(0xE2 + 4 * p, a & 0xFFFF)
    for line, regs in sorted(t.copper_extra):
        wait(line - 1)
        for reg, val in regs:
            move(reg, val)
    cop.extend([0xFFFF, 0xFFFE])
    cop_b = b"".join(struct.pack(">H", w) for w in cop)
    # sprite data
    spr_b = bytearray()
    if t.sprites:
        sw = len(t.sprites[0][2])
        nw = sw // 16                       # words per data row (1, 2, 4)
        spr_b = bytearray(8 * 0x1000)
        for n, (vstart, hstart, pix) in enumerate(t.sprites):
            vstop = vstart + 16
            pos = ((vstart & 0xFF) << 8) | ((hstart >> 1) & 0xFF)
            ctl = ((vstop & 0xFF) << 8) | ((vstart >> 8) & 1) << 2 | ((vstop >> 8) & 1) << 1 | (hstart & 1)
            a = bytearray()
            # control words: pos, (nw-1 dummies), ctl, (nw-1 dummies)
            a += struct.pack(">H", pos) + b"\0\0" * (nw - 1)
            a += struct.pack(">H", ctl) + b"\0\0" * (nw - 1)
            da = 0; db = 0
            for x, c in enumerate(pix):
                if c & 1: da |= 1 << (sw - 1 - x)
                if c & 2: db |= 1 << (sw - 1 - x)
            row = da.to_bytes(sw // 8, "big") + db.to_bytes(sw // 8, "big")
            for _ in range(16):
                a += row
            a += b"\0" * (2 * sw // 8)        # end: pos = ctl = 0
            spr_b[n * 0x1000:n * 0x1000 + len(a)] = a
    diwstrt, diwstop = 0x2C81, 0x2CC1
    s = []
    s.append(r"""
        .text
        .equ    CUSTOM, 0xdff000
start:  move.w  #0x2700,%%sr
        lea     0x1fff00,%%sp
        lea     CUSTOM,%%a6
        move.w  #0x7fff,0x9a(%%a6)
        move.w  #0x7fff,0x9c(%%a6)
        move.w  #0x7fff,0x96(%%a6)
        move.l  #0,0x%(done)x                | done marker cleared
| copy bitplane data, copper list and sprites to their places
        lea     blob(%%pc),%%a0
        lea     0x%(screen)x,%%a1
        move.l  #(%(blobn)d/4)-1,%%d0
1:      move.l  (%%a0)+,(%%a1)+
        subq.l  #1,%%d0
        bpl.s   1b
        lea     coplst(%%pc),%%a0
        lea     0x%(copper)x,%%a1
        move.w  #(%(copn)d/2)-1,%%d0
2:      move.w  (%%a0)+,(%%a1)+
        dbra    %%d0,2b
""" % dict(done=DONE_ADDR, screen=SCREEN, copper=COPPER, copn=len(cop_b), blobn=len(blob)))
    if t.sprites:
        s.append(r"""
        lea     sprdat(%%pc),%%a0
        lea     0x%(spr)x,%%a1
        move.w  #(0x8000/4)-1,%%d0
3:      move.l  (%%a0)+,(%%a1)+
        dbra    %%d0,3b
""" % dict(spr=SPRITES))
    s.append(r"""
| palette: 256 entries, BPLCON3 bank (bits 15-13), high nibbles first, then LOCT=1 low nibbles
        lea     palw(%%pc),%%a0
        moveq   #0,%%d1                     | bank
4:      move.w  %%d1,%%d2
        ror.w   #3,%%d2                     | bank -> bits 15..13
        or.w    #0x0c00,%%d2
        move.w  %%d2,0x106(%%a6)            | BPLCON3 bank, LOCT=0
        lea     0x180(%%a6),%%a1
        moveq   #31,%%d0
5:      move.w  (%%a0),(%%a1)+              | high nibbles
        addq.l  #4,%%a0
        dbra    %%d0,5b
        lea     -128(%%a0),%%a0
        or.w    #0x0200,%%d2
        move.w  %%d2,0x106(%%a6)            | LOCT=1
        lea     0x180(%%a6),%%a1
        moveq   #31,%%d0
6:      move.w  2(%%a0),(%%a1)+             | low nibbles
        addq.l  #4,%%a0
        dbra    %%d0,6b
        addq.w  #1,%%d1
        cmp.w   #8,%%d1
        bne.s   4b
        move.w  #0x0c00,0x106(%%a6)         | BPLCON3 bank 0
| display
        move.w  #0x%(bplcon0)04x,0x100(%%a6)
        move.w  #0,0x102(%%a6)
        move.w  #0x0024,0x104(%%a6)         | BPLCON2: sprites in front
        move.w  #0x%(bplcon4)04x,0x10c(%%a6)
        move.w  #0x%(fmode)04x,0x1fc(%%a6)
        move.w  #0x%(diwstrt)04x,0x8e(%%a6)
        move.w  #0x%(diwstop)04x,0x90(%%a6)
        move.w  #0x%(ddfstrt)04x,0x92(%%a6)
        move.w  #0x%(ddfstop)04x,0x94(%%a6)
        move.l  #0x%(copper)x,0x80(%%a6)
        move.w  #0,0x88(%%a6)
        move.w  #0x83%(dmaspr)s0,0x96(%%a6)          | DMAEN, BPLEN, COPEN (+SPREN)
| wait 3 frames (VPOSR/VHPOSR polling), then signal done; keep running
        moveq   #3,%%d3
7:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0               | line 0x130
        bne.s   7b
8:      move.l  4(%%a6),%%d0
        and.l   #0x1ff00,%%d0
        cmp.l   #0x13000,%%d0
        beq.s   8b
        dbra    %%d3,7b
        move.l  #0x%(magic)x,0x%(done)x
9:      bra.s   9b
""" % dict(bplcon0=t.bplcon0, bplcon4=t.bplcon4, fmode=t.fmode, diwstrt=diwstrt, diwstop=diwstop,
           ddfstrt=t.ddfstrt, ddfstop=t.ddfstop, copper=COPPER, magic=DONE_MAGIC, done=DONE_ADDR,
           dmaspr="a" if t.sprites else "8"))
    s.append(words_asm("palw", b"".join(struct.pack(">HH", h, l) for h, l in pal_words), 4))
    s.append(words_asm("coplst", cop_b, 4))
    if t.sprites:
        s.append(words_asm("sprdat", spr_b, 4))
    s.append(words_asm("blob", blob, 8))
    return "\n".join(s) + "\n"


def assemble(src, org):
    with tempfile.TemporaryDirectory() as d:
        open(d + "/t.s", "w").write(src)
        subprocess.check_call(["m68k-linux-gnu-as", "-m68020", "-o", d + "/t.o", d + "/t.s"])
        subprocess.check_call(["m68k-linux-gnu-ld", "-e", hex(org), "-Ttext=" + hex(org),
                               "--oformat", "binary", "-o", d + "/t.bin", d + "/t.o"])
        return open(d + "/t.bin", "rb").read()


BOOT = r"""
| boot block: load the payload (sectors 2..) with the boot IORequest (A1), enter supervisor mode,
| take the machine and copy the payload to ORG, jump there.
        .text
        .ascii  "DOS"
        .byte   0
        .long   0                           | checksum (patched)
        .long   880
        move.l  %%a1,%%a5                   | IOStdReq
        move.l  #%(size)d,%%d0
        move.l  #0x10002,%%d1               | MEMF_CHIP | MEMF_CLEAR
        jsr     -198(%%a6)                  | AllocMem
        tst.l   %%d0
        beq.s   fail
        move.l  %%d0,%%a4
        move.l  %%a5,%%a1
        move.w  #2,28(%%a1)                 | CMD_READ
        move.l  %%a4,40(%%a1)               | io_Data
        move.l  #%(size)d,36(%%a1)          | io_Length
        move.l  #1024,44(%%a1)              | io_Offset
        jsr     -456(%%a6)                  | DoIO
        move.l  %%a5,%%a1
        move.w  #9,28(%%a1)                 | TD_MOTOR off
        clr.l   36(%%a1)
        jsr     -456(%%a6)
        jsr     -150(%%a6)                  | SuperState
        move.w  #0x2700,%%sr
        move.w  #0x7fff,0xdff09a
        move.w  #0x7fff,0xdff096
        move.l  %%a4,%%a0
        lea     0x%(org)x,%%a1
        move.l  #(%(size)d/4)-1,%%d0
1:      move.l  (%%a0)+,(%%a1)+
        subq.l  #1,%%d0
        bpl.s   1b
        jmp     0x%(org)x
fail:   moveq   #-1,%%d0
        rts
"""


BOOTROM = r"""
| minimal boot ROM (replaces the Kickstart in the simulation bench): reset SSP/PC, overlay off,
| jump to the payload that the bench preloaded at ORG.  Own code, 256 KB image.
        .text
        .long   0x001fff00                  | SSP
        .long   0x00f80010                  | PC
        .long   0,0
        move.b  #3,0xbfe201                 | CIA-A DDRA: OVL, LED outputs
        move.b  #2,0xbfe001                 | OVL = 0 (chip RAM at 0), LED off
        jmp     0x%(org)x
"""


def make_bootrom(org=ORG):
    code = assemble(BOOTROM % dict(org=org), 0xF80000)
    return code + bytes(0x40000 - len(code))


def make_adf(payload):
    size = (len(payload) + 511) & ~511
    src = BOOT % dict(size=size, org=ORG)
    bb = bytearray(assemble(src, 0))
    assert len(bb) <= 1024, len(bb)
    bb += bytes(1024 - len(bb))
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", bb[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s + 1) & 0xFFFFFFFF
    struct.pack_into(">I", bb, 4, (~s) & 0xFFFFFFFF)
    adf = bytearray(901120)
    adf[0:1024] = bb
    adf[1024:1024 + len(payload)] = payload
    return bytes(adf)


def expect_json(t):
    out = {"name": t.name, "desc": t.desc, "hires": t.hires}
    if t.sprites:
        out["sprites"] = t.expect
    else:
        out["blocks"] = {"%d,%d" % k: v for k, v in t.expect.items() if len(k) == 2}
        if t.ham8:
            out["ham_seq"] = {"%d,%d" % k[:2]: v for k, v in t.expect.items() if len(k) == 3}
    return out


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "bootrom.bin"), "wb").write(make_bootrom())
    for t in make_tests():
        payload = assemble(build_asm(t), ORG)
        open(os.path.join(outdir, t.name + ".bin"), "wb").write(payload)
        open(os.path.join(outdir, t.name + ".adf"), "wb").write(make_adf(payload))
        json.dump(expect_json(t), open(os.path.join(outdir, t.name + ".json"), "w"), indent=1)
        print("%-9s %6d bytes  %s" % (t.name, len(payload), t.desc))


# ----------------------------------------------------------------------------------------------
# checking a frame

def load_frame(fn):
    try:
        from PIL import Image
    except ImportError:
        sys.exit("needs PIL: run with /usr/bin/python3")
    im = Image.open(fn).convert("RGB")
    return im


def check(name, fn, xscale=2, yscale=1, outdir=None):
    """xscale = frame columns per LORES pixel (bench: 2), yscale = rows per line"""
    exp = json.load(open(os.path.join(outdir, name + ".json"))) if outdir else None
    im = load_frame(fn)
    Wd, Hd = im.size
    px = im.load()
    res = {"test": name, "frame": fn}
    if "blocks" in exp:
        blocks = {tuple(map(int, k.split(","))): tuple(v) for k, v in exp["blocks"].items()}
        bwc = BW * xscale            # block width in columns (lores px); hires: same width
        # window origin: block (0,0) has colour 0 = the border colour, so find the first run of
        # block (1,0)'s colour (scan order) and step one block back
        c10 = blocks[(1, 0)]
        org = None
        for y in range(Hd):
            for x in range(int(bwc), int(Wd - bwc)):
                if px[x, y] == c10 and px[int(x + bwc / 2), y] == c10 and px[x - 1, y] != c10:
                    # HAM8: the block's settled colour starts at its 4th pixel
                    org = (x - bwc - (3 * xscale if "ham_seq" in exp else 0), y); break
            if org: break
        if not org:
            res["error"] = "block (1,0) colour %s not found" % (c10,)
            return res
        ok = bad = 0
        mism = []
        for (bx, by), c in sorted(blocks.items()):
            # sample the block's right half (HAM: settled colour) at mid height
            x = int(org[0] + bx * bwc + bwc * 0.75)
            y = int(org[1] + by * 16 * yscale + 8 * yscale)
            if x >= Wd or y >= Hd:
                mism.append(((bx, by), "outside")); bad += 1; continue
            got = px[x, y]
            if got == c:
                ok += 1
            else:
                bad += 1
                if len(mism) < 12:
                    mism.append(((bx, by), "exp %02x%02x%02x got %02x%02x%02x" % (c + got)))
        res.update(origin=org, ok=ok, bad=bad, mismatches=mism)
        if "ham_seq" in exp:
            sbad = 0; smism = []
            for k, seq in exp["ham_seq"].items():
                bx, by = map(int, k.split(","))
                for i, c in enumerate(seq):
                    x = int(org[0] + bx * bwc + (i + 0.5) * xscale)
                    y = int(org[1] + by * 16 * yscale + 8 * yscale)
                    got = px[x, y]
                    if tuple(c) != got:
                        sbad += 1
                        if len(smism) < 8:
                            smism.append((k, i, "exp %02x%02x%02x got %02x%02x%02x" % (tuple(c) + got)))
            res.update(ham_pixel_bad=sbad, ham_mismatches=smism)
    else:
        # sprites: for each sprite find the run of its first colour, check width and colour order
        sres = []
        for n, s in sorted(exp["sprites"].items(), key=lambda a: int(a[0])):
            cols = [tuple(c) for c in s["colours"]]
            found = None
            for y in range(Hd):
                row = [px[x, y] for x in range(Wd)]
                xs = [x for x in range(Wd) if row[x] in cols]
                if xs:
                    found = (y, xs[0], xs[-1], row)
                    break
            if not found:
                sres.append((int(n), "not found")); continue
            y, x0, x1, row = found
            width_px = (x1 - x0 + 1) / xscale
            seq = []
            for x in range(x0, x1 + 1):
                c = row[x]
                if not seq or seq[-1][0] != c:
                    seq.append([c, 0])
                seq[-1][1] += 1
            exp_seq_cols = [cols[(i // 4) % 3] for i in range(0, s["width"], 4)]
            got_cols = [tuple(c) for c, _ in seq]
            # height: rows that contain the colour at x0
            hgt = 0
            yy = y
            while yy < Hd and px[x0 + int(xscale / 2), yy] == row[x0 + int(xscale / 2)]:
                hgt += 1; yy += 1
            sres.append(dict(n=int(n), line=y, x0=x0, width=width_px, exp_width=s["width"],
                             height=hgt / yscale, colours_ok=got_cols == exp_seq_cols,
                             runs=len(seq)))
        res["sprites"] = sres
        res["ok"] = sum(1 for r in sres if isinstance(r, dict) and r["colours_ok"]
                        and abs(r["width"] - r["exp_width"]) < 1 and abs(r["height"] - 16) < 1)
        res["bad"] = 8 - res["ok"]
    return res


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "build":
        build(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "bootrom":      # bootrom OUT ORG
        open(sys.argv[2], "wb").write(make_bootrom(int(sys.argv[3], 0)))
    elif len(sys.argv) >= 4 and sys.argv[1] == "check":
        xs = 2
        if "--xscale" in sys.argv:
            xs = float(sys.argv[sys.argv.index("--xscale") + 1])
        ys = 1
        if "--yscale" in sys.argv:
            ys = float(sys.argv[sys.argv.index("--yscale") + 1])
        d = os.path.dirname(os.path.abspath(sys.argv[3]))
        if "--dir" in sys.argv:
            d = sys.argv[sys.argv.index("--dir") + 1]
        print(json.dumps(check(sys.argv[2], sys.argv[3], xs, ys, d), default=str))
    else:
        print(__doc__)
