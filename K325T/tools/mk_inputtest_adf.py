#!/usr/bin/env python3
"""mk_inputtest_adf.py OUT.adf -- an input test floppy for AExp (no Workbench needed).

The boot block (68000 code, assembled below) switches DMA and interrupts off and shows seven
bytes as 56 horizontal bit stripes from raster line $30 (most significant bit first; 2 lines
each + 1 black line; white = 1, blue = 0):
    0  last keyboard scan code (raw, as the keyboard sends it: bit 7 = release)
    1  JOY0DAT low byte  = port 1 (mouse) horizontal counter
    2  JOY0DAT high byte = port 1 (mouse) vertical counter
    3  JOY1DAT low byte  = port 2 (joystick): bit 1 right, bit 1 ^ bit 0 down
    4  JOY1DAT high byte = port 2: bit 1 left, bit 1 ^ bit 0 up
    5  CIA-A PRA: bit 6 = port 1 fire (left mouse button), bit 7 = port 2 fire (0 = pressed)
    6  number of keyboard bytes received (wraps); POTGOR (right / middle button) is not shown
It reads the keyboard SDR like a raw CIA reader (no handshake pulse: AExp paces on the SDR read).  Read the stripes back with
    mk_inputtest_adf.py --decode FRAME.png      (a 1280x720 capture of the 720p output)
"""
import struct, sys

FIRST4 = False          # --first4: stripes 0/3/4/5 = the first four keyboard bytes after boot


def assemble():
    """tiny two-pass assembler: items are words, ('label', name), ('bcc', opcode_hi, name),
    ('pcrel', opcode, name) (d16(pc) operand), ('dbra', reg, name)"""
    W = lambda *ws: list(ws)
    prog = []
    prog += W(0x4BF9, 0x00DF, 0xF000)            # lea $dff000,a5
    prog += W(0x49F9, 0x00BF, 0xE001)            # lea $bfe001,a4
    prog += [("pcrel", 0x47FA, "table")]         # lea table(pc),a3
    prog += [("pcrel", 0x43FA, "keyvar")]        # lea keyvar(pc),a1
    prog += W(0x2689)                            # move.l a1,(a3)    table[0] = &keyvar
    prog += [("pcrel", 0x45FA, "cntvar")]        # lea cntvar(pc),a2
    prog += W(0x274A, 0x0018)                    # move.l a2,24(a3)  table[6] = &cntvar
    if FIRST4:                                   # table[3..5] = the 2nd..4th keyboard byte
        for k, off in ((1, 12), (2, 16), (3, 20)):
            prog += W(0x41E9, k, 0x2748, off)    # lea k(a1),a0 ; move.l a0,off(a3)
    prog += W(0x3B7C, 0x7FFF, 0x009A)            # move.w #$7fff,$9a(a5)  INTENA off
    prog += W(0x3B7C, 0x7FFF, 0x0096)            # move.w #$7fff,$96(a5)  DMACON off
    prog += W(0x3B7C, 0xFF00, 0x0034)            # move.w #$ff00,$34(a5)  POTGO
    prog += W(0x422C, 0x0D00)                    # clr.b $d00(a4)    CRA: timer A stopped (it would
                                                 #   clock the serial port out in output mode), SP input
    prog += W(0x7A00)                            # moveq #0,d5
    prog += W(0x1285)                            # move.b d5,(a1)
    prog += [("label", "loop")]
    prog += W(0x102C, 0x0C00)                    # move.b $c00(a4),d0   ICR (read clears)
    prog += W(0x0800, 0x0003)                    # btst #3,d0           SP: a byte arrived
    prog += [("bcc", 0x67, "nokey")]             # beq.s nokey
    prog += W(0x1A2C, 0x0B00)                    # move.b $b00(a4),d5   SDR
    prog += W(0x4605)                            # not.b d5
    prog += W(0xE21D)                            # ror.b #1,d5          -> scan code
    if FIRST4:                                   # keep the first four bytes
        prog += W(0x7E00, 0x1E12, 0x0C07, 0x0004)    # moveq #0,d7; move.b (a2),d7; cmp.b #4,d7
        prog += [("bcc", 0x64, "skip")]              # bcc.s skip
        prog += W(0x1385, 0x7000)                    # move.b d5,0(a1,d7.w)
        prog += [("label", "skip")]
    else:
        prog += W(0x1285)                        # move.b d5,(a1)       the last byte
    prog += W(0x5212)                            # addq.b #1,(a2)       count the keyboard bytes
    # no handshake pulse: Minimig's CIA-A takes a code without it, and AExp's keyboard.vhd paces
    # its codes on the CPU's SDR read alone (a 85 us busy wait here would tear the stripes)
    prog += [("label", "nokey")]
    prog += W(0x7000)                            # moveq #0,d0
    prog += W(0x102D, 0x0006)                    # move.b 6(a5),d0      VPOS low 8 bits
    prog += W(0x0440, 0x0030)                    # sub.w #$30,d0
    prog += [("bcc", 0x65, "black")]             # bcs.s black
    prog += W(0x80FC, 0x0003)                    # divu.w #3,d0         bit stripe 0..55, line 0..2
    prog += W(0x2600)                            # move.l d0,d3
    prog += W(0x4843)                            # swap d3
    prog += W(0x0C43, 0x0002)                    # cmpi.w #2,d3         3rd line of a bit: gap
    prog += [("bcc", 0x67, "black")]             # beq.s black
    prog += W(0x0C40, 0x0038)                    # cmpi.w #56,d0
    prog += [("bcc", 0x64, "black")]             # bcc.s black
    prog += W(0x3800)                            # move.w d0,d4
    prog += W(0x0244, 0x0007)                    # andi.w #7,d4         bit (0 = MSB first)
    prog += W(0xE648)                            # lsr.w #3,d0          byte 0..6
    prog += W(0xE548)                            # lsl.w #2,d0
    prog += W(0x2073, 0x0000)                    # movea.l 0(a3,d0.w),a0
    prog += W(0x1210)                            # move.b (a0),d1
    prog += W(0x7C07)                            # moveq #7,d6
    prog += W(0x9C44)                            # sub.w d4,d6
    prog += W(0x343C, 0x000F)                    # move.w #$00f,d2      0 = blue
    prog += W(0x0D01)                            # btst d6,d1
    prog += [("bcc", 0x67, "setc")]              # beq.s setc
    prog += W(0x343C, 0x0FFF)                    # move.w #$fff,d2      1 = white
    prog += [("bcc", 0x60, "setc")]              # bra.s setc
    prog += [("label", "black")]
    prog += W(0x7400)                            # moveq #0,d2
    prog += [("label", "setc")]
    prog += W(0x3B42, 0x0180)                    # move.w d2,$180(a5)   COLOR00
    prog += [("bcc", 0x60, "loop")]              # bra.s loop
    prog += [("align4",)]
    prog += [("label", "table")]
    prog += W(0, 0, 0x00DF, 0xF00B, 0x00DF, 0xF00A, 0x00DF, 0xF00D, 0x00DF, 0xF00C,
              0x00BF, 0xE001, 0x00DF, 0xF016)
    prog += [("label", "keyvar")]
    prog += W(0, 0)
    prog += [("label", "cntvar")]
    prog += W(0)

    def layout():
        addr, labels = 12, {}
        for it in prog:
            if isinstance(it, int):
                addr += 2
            elif it[0] == "label":
                labels[it[1]] = addr
            elif it[0] == "align4":
                addr += addr % 4
            elif it[0] == "bcc":
                addr += 2
            else:
                addr += 4
        return labels
    labels = layout()
    out, addr = b"", 12
    for it in prog:
        if isinstance(it, int):
            out += struct.pack(">H", it); addr += 2
        elif it[0] == "label":
            assert labels[it[1]] == addr
        elif it[0] == "align4":
            if addr % 4:
                out += b"\0\0"; addr += 2
        elif it[0] == "bcc":
            d = labels[it[2]] - (addr + 2)
            assert -128 <= d <= 127 and d != 0, (it, d)
            out += struct.pack(">Bb", it[1], d); addr += 2
        elif it[0] in ("pcrel", "dbra"):
            d = labels[it[2]] - (addr + 2)
            out += struct.pack(">Hh", it[1], d); addr += 4
    return out

def bootblock():
    b = bytearray(1024)
    b[0:4] = b"DOS\0"
    b[8:12] = struct.pack(">I", 880)
    c = assemble()
    b[12:12 + len(c)] = c
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", b[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    b[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)
    return bytes(b)

NAMES = ["key", "joy0dat_lo(mouse x)", "joy0dat_hi(mouse y)", "joy1dat_lo", "joy1dat_hi",
         "ciaa_pra", "kbd_bytes"]

def decode(png):
    """the 56 bit stripes from a 1280x720 capture of the 720p output (2.5 output rows per
    Amiga line, so a bit is 7.5 rows): find the first stripe, then sample each bit's middle,
    averaged over the middle half of the picture; white = 1, blue = 0"""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    w, h = im.size
    band = range(w // 4, 3 * w // 4, 8)
    def px(y):
        p = [im.getpixel((x, y)) for x in band]
        return tuple(sum(c[i] for c in p) / len(p) for i in range(3))
    y0 = next(y for y in range(h) if max(px(y)) > 100)
    bits = []
    for k in range(56):
        r, g, b = px(int(y0 + 7.5 * k + 2.5))
        bits.append("1" if min(r, g, b) > 128 else "0")
    vals = [int("".join(bits[i:i + 8]), 2) for i in range(0, 56, 8)]
    return vals, y0

if __name__ == "__main__":
    if "--first4" in sys.argv:
        FIRST4 = True
        NAMES[:] = ["kbd1", "joy0dat_lo(mouse x)", "joy0dat_hi(mouse y)", "kbd2", "kbd3", "kbd4",
                    "kbd_bytes"]
    if sys.argv[1] == "--decode":
        v, n = decode(sys.argv[2])
        print(" ".join("%s=%02x" % (k, x) for k, x in zip(NAMES, v)), "(first stripe at row %d)" % n)
        sys.exit(0)
    open(sys.argv[1], "wb").write(bootblock() + bytes(901120 - 1024))
    print("wrote", sys.argv[1])
