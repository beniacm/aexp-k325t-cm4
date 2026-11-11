#!/usr/bin/env python3
"""mk_kbdtest_adf.py OUT.adf -- keyboard test floppy for AExp through the Kickstart's own
keyboard.device (no Workbench needed).

The boot block opens keyboard.device (on a copy of the boot IORequest), installs a small copper
list (no bitplanes) and then loops on KBD_READEVENT: the raw key code of every key event
(ie_Code: bit 7 = release) is shown as 8 horizontal bit stripes from raster line $40 (most
significant bit first; 4 lines per bit + 2 black; white = 1, blue = 0).  The copper keeps the
stripes on screen while the CPU waits in DoIO.  Decode a 1280x720 capture of the 720p output:
    mk_kbdtest_adf.py --decode FRAME.png
"""
import struct, sys

Y0, STEP = 0x40, 6                       # first stripe line, lines per bit (4 on + 2 gap)


def assemble():
    W = lambda *ws: list(ws)
    p = []
    p += [("pcrel", 0x47FA, "kbreq")]            # lea kbreq(pc),a3
    p += W(0x700B)                               # moveq #11,d0
    p += [("label", "cp")]
    p += W(0x26D9)                               # move.l (a1)+,(a3)+   copy the IOStdReq (48 bytes)
    p += [("dbra", 0x51C8, "cp")]                # dbra d0,cp
    p += [("pcrel", 0x43FA, "kbreq")]            # lea kbreq(pc),a1
    p += [("pcrel", 0x41FA, "kbname")]           # lea kbname(pc),a0
    p += W(0x7000, 0x7200)                       # moveq #0,d0 ; moveq #0,d1
    p += W(0x4EAE, 0xFE44)                       # jsr OpenDevice(a6)
    p += [("pcrel", 0x49FA, "coplist")]          # lea coplist(pc),a4
    p += W(0x23CC, 0x00DF, 0xF080)               # move.l a4,$dff080    COP1LC
    p += W(0x33C0, 0x00DF, 0xF088)               # move.w d0,$dff088    COPJMP1
    p += [("label", "loop")]
    p += [("pcrel", 0x43FA, "kbreq")]            # lea kbreq(pc),a1
    p += W(0x337C, 0x0009, 0x001C)               # move.w #9,28(a1)     KBD_READEVENT
    p += [("pcrel", 0x41FA, "ievent")]           # lea ievent(pc),a0
    p += W(0x2348, 0x0028)                       # move.l a0,40(a1)     io_Data
    p += W(0x237C, 0x0000, 0x0016, 0x0024)       # move.l #22,36(a1)    io_Length
    p += W(0x4EAE, 0xFE38)                       # jsr DoIO(a6)
    p += [("pcrel", 0x303A, "ievent6")]          # move.w ievent+6(pc),d0   ie_Code
    p += [("pcrel", 0x41FA, "copval")]           # lea copval(pc),a0
    p += W(0x7407)                               # moveq #7,d2
    p += [("label", "bl")]
    p += W(0x0500)                               # btst d2,d0
    p += [("bcc", 0x67, "zero")]                 # beq.s zero
    p += W(0x30BC, 0x0FFF)                       # move.w #$fff,(a0)
    p += [("bcc", 0x60, "nx")]                   # bra.s nx
    p += [("label", "zero")]
    p += W(0x30BC, 0x000F)                       # move.w #$00f,(a0)
    p += [("label", "nx")]
    p += W(0x41E8, 0x0010)                       # lea 16(a0),a0
    p += [("dbra", 0x51CA, "bl")]                # dbra d2,bl
    p += [("bcc", 0x60, "loop")]                 # bra.s loop
    p += [("align4",)]
    p += [("label", "coplist")]
    p += W(0x0100, 0x0200)                       # BPLCON0 = colour on, no bitplanes
    for i in range(8):
        y = Y0 + i * STEP
        p += W((y << 8) | 0x01, 0xFFFE, 0x0180)  # WAIT line y ; MOVE COLOR00,
        if i == 0:
            p += [("label", "copval")]
        p += W(0x000F)                           #   value (patched by the CPU)
        p += W(((y + 4) << 8) | 0x01, 0xFFFE, 0x0180, 0x0000)   # gap: black
    p += W(0xFFFF, 0xFFFE)
    p += [("label", "ievent")]
    p += W(0, 0, 0)
    p += [("label", "ievent6")]
    p += W(0, 0, 0, 0, 0, 0, 0, 0)               # rest of the InputEvent (22 bytes)
    p += [("label", "kbname")]
    p += [("bytes", b"keyboard.device\0")]
    p += [("align4",)]
    p += [("label", "kbreq")]
    p += [("bytes", bytes(48))]
    return p


def layout_and_emit(prog):
    def size(it, addr):
        if isinstance(it, int):
            return 2
        k = it[0]
        if k == "label":
            return 0
        if k == "align4":
            return addr % 4
        if k == "bcc":
            return 2
        if k == "bytes":
            return len(it[1])
        return 4
    labels, addr = {}, 12
    for it in prog:
        if not isinstance(it, int) and it[0] == "label":
            labels[it[1]] = addr
        addr += size(it, addr)
    out, addr = b"", 12
    for it in prog:
        if isinstance(it, int):
            out += struct.pack(">H", it)
        elif it[0] == "align4":
            out += b"\0" * (addr % 4)
        elif it[0] == "bcc":
            d = labels[it[2]] - (addr + 2)
            assert -128 <= d <= 127 and d != 0, (it, d)
            out += struct.pack(">Bb", it[1], d)
        elif it[0] in ("pcrel", "dbra"):
            out += struct.pack(">Hh", it[1], labels[it[2]] - (addr + 2))
        elif it[0] == "bytes":
            out += it[1]
        addr += size(it, addr)
    return out


def bootblock():
    b = bytearray(1024)
    b[0:4] = b"DOS\0"
    b[8:12] = struct.pack(">I", 880)
    c = layout_and_emit(assemble())
    assert 12 + len(c) <= 1024
    b[12:12 + len(c)] = c
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", b[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    b[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)
    return bytes(b)


def decode(png):
    """8 bit stripes, 4 + 2 lines each = 15 output rows per bit at 720p; returns the code"""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    w, h = im.size
    band = range(w // 4, 3 * w // 4, 8)
    def px(y):
        p = [im.getpixel((x, y)) for x in band]
        return tuple(sum(c[i] for c in p) / len(p) for i in range(3))
    y0 = next(y for y in range(h) if max(px(y)) > 100)
    bits = "".join("1" if min(px(int(y0 + 15 * k + 5))) > 128 else "0" for k in range(8))
    return int(bits, 2), y0


if __name__ == "__main__":
    if sys.argv[1] == "--decode":
        v, y0 = decode(sys.argv[2])
        print("key code $%02x (%s, $%02x) first stripe row %d" % (v, "release" if v & 0x80 else "press",
                                                                    v & 0x7F, y0))
        sys.exit(0)
    open(sys.argv[1], "wb").write(bootblock() + bytes(901120 - 1024))
    print("wrote", sys.argv[1])
