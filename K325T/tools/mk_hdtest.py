#!/usr/bin/env python3
"""mk_hdtest.py OUTDIR [--data-kb N] [--write-kb N] -- a disk read/write test for the A1200 hard disk
(own code): OUTDIR/hdtest (AmigaDOS executable) and OUTDIR/data1 (its read pattern).

hdtest, started from the startup-sequence, loops for ever:
  1. reads data1 (64 KB chunks) and checks every long: long at byte offset o = o ^ $A5C33C5A;
  2. writes out1 (--write-kb, default 512 KB) with long = o ^ $A5C33C5A ^ (pass * $01010101), closes it,
     reads it back and checks it the same way;
  3. reports: the result mailbox $C0-$FF (the K325T board snoops it; the bench dumps it) and one line
     on its CLI window (for the emulator reference):
       $C0 $48445431 ("HDT1")     $C4 pass                  $C8 read errors (longs, all passes)
       $CC write/read-back errors $D0 data1 bytes (last)    $D4 out1 bytes (last pass)
       $D8 read time  (ticks 1/50 s, last pass)             $DC write time (ticks)
       $E0 read-back time (ticks) $E4 last DOS error (IoErr) $E8 first bad offset (read)
       $EC $600DF00D after each complete pass
  Errors stop nothing (the next pass runs); a DOS error (Open/Read/Write failing) is counted in
  $E4 and the pass is skipped after a 1 s Delay.
DOS requesters are switched off for hdtest (pr_WindowPtr = -1), so a failing disk shows up in $E4.
The program is position-independent (one code hunk, no relocations), 68000 code, uses exec + dos only.
"""
import argparse, os, struct, subprocess, sys, tempfile

SRC = r"""
        .text
start:  lea     vars(%pc),%a4
        move.l  4.w,%a6
        sub.l   %a1,%a1
        jsr     -294(%a6)               | FindTask(0)
        move.l  %d0,%a0
        moveq   #-1,%d0
        move.l  %d0,184(%a0)            | pr_WindowPtr = -1: DOS errors come back as IoErr, no requester
        lea     dosname(%pc),%a1
        moveq   #36,%d0
        jsr     -552(%a6)               | OpenLibrary("dos.library", 36)
        move.l  %d0,dosbase-vars(%a4)
        beq     exit
        move.l  #65536,%d0
        moveq   #1,%d1                  | MEMF_PUBLIC
        jsr     -198(%a6)               | AllocMem
        move.l  %d0,buf-vars(%a4)
        beq     exit
        move.l  dosbase-vars(%a4),%a6
        jsr     -60(%a6)                | Output()
        move.l  %d0,out-vars(%a4)
        lea     0xc0.w,%a3              | the result mailbox
        move.l  #0x48445431,(%a3)
        clr.l   4(%a3)
        clr.l   8(%a3)
        clr.l   12(%a3)
        clr.l   0x24(%a3)
        clr.l   0x2c(%a3)
pass:
        | ---- 1. read data1, check
        bsr     tick
        move.l  %d0,t0-vars(%a4)
        lea     n_data1(%pc),%a0
        move.l  %a0,%d1
        move.l  #1005,%d2               | MODE_OLDFILE
        jsr     -30(%a6)                | Open
        move.l  %d0,fh-vars(%a4)
        beq     doserr
        moveq   #0,%d7                  | byte offset
        moveq   #0,%d6                  | seed mask: 0
rd1:    move.l  fh-vars(%a4),%d1
        move.l  buf-vars(%a4),%d2
        move.l  #65536,%d3
        jsr     -42(%a6)                | Read
        tst.l   %d0
        bmi     doserr_c
        beq.s   rd1e
        bsr     check                   | d0 bytes at buf, offset d7, mask d6 -> errors added to 8(a3)
        bra.s   rd1
rd1e:   move.l  fh-vars(%a4),%d1
        jsr     -36(%a6)                | Close
        move.l  %d7,0x10(%a3)
        bsr     tick
        sub.l   t0-vars(%a4),%d0
        move.l  %d0,0x18(%a3)
        | ---- 2. write out1 with this pass's mask, read it back
        move.l  4(%a3),%d6
        mulu    #0x0101,%d6
        move.l  %d6,%d0
        swap    %d0
        or.l    %d0,%d6                 | pass * $01010101 (pass < 256)
        bsr     tick
        move.l  %d0,t0-vars(%a4)
        lea     n_out1(%pc),%a0
        move.l  %a0,%d1
        move.l  #1006,%d2               | MODE_NEWFILE
        jsr     -30(%a6)
        move.l  %d0,fh-vars(%a4)
        beq     doserr
        moveq   #0,%d7
wr1:    bsr     fill                    | 64 KB of pattern at buf for offset d7, mask d6
        move.l  fh-vars(%a4),%d1
        move.l  buf-vars(%a4),%d2
        move.l  #65536,%d3
        jsr     -48(%a6)                | Write
        cmp.l   #65536,%d0
        bne     doserr_c
        add.l   #65536,%d7
        cmp.l   #WRITE_BYTES,%d7
        blo.s   wr1
        move.l  fh-vars(%a4),%d1
        jsr     -36(%a6)
        move.l  %d7,0x14(%a3)
        bsr     tick
        sub.l   t0-vars(%a4),%d0
        move.l  %d0,0x1c(%a3)
        bsr     tick
        move.l  %d0,t0-vars(%a4)
        lea     n_out1(%pc),%a0
        move.l  %a0,%d1
        move.l  #1005,%d2
        jsr     -30(%a6)
        move.l  %d0,fh-vars(%a4)
        beq     doserr
        moveq   #0,%d7
        move.l  8(%a3),-(%sp)           | errors of the read-back go to $CC, not $C8
rd2:    move.l  fh-vars(%a4),%d1
        move.l  buf-vars(%a4),%d2
        move.l  #65536,%d3
        jsr     -42(%a6)
        tst.l   %d0
        bmi.s   rd2x
        beq.s   rd2e
        bsr     check
        bra.s   rd2
rd2x:   move.l  (%sp)+,8(%a3)
        bra     doserr_c
rd2e:   move.l  8(%a3),%d0
        sub.l   (%sp),%d0
        add.l   %d0,12(%a3)
        move.l  (%sp)+,8(%a3)
        cmp.l   #WRITE_BYTES,%d7
        beq.s   1f
        addq.l  #1,12(%a3)              | short file
1:      move.l  fh-vars(%a4),%d1
        jsr     -36(%a6)
        bsr     tick
        sub.l   t0-vars(%a4),%d0
        move.l  %d0,0x20(%a3)
        addq.l  #1,4(%a3)
        move.l  #0x600df00d,0x2c(%a3)
        bsr     report
        bra     pass

doserr_c:
        move.l  fh-vars(%a4),%d1
        jsr     -36(%a6)
doserr: jsr     -132(%a6)               | IoErr
        move.l  %d0,0x24(%a3)
        moveq   #50,%d1
        jsr     -198(%a6)               | Delay(50)
        bra     pass

| check: d0 = bytes at buf; long at offset o must be o ^ $A5C33C5A ^ d6; d7 += d0
check:  movem.l %d1-%d3/%a0,-(%sp)
        move.l  buf-vars(%a4),%a0
        move.l  %d0,%d3
        lsr.l   #2,%d3
        subq.l  #1,%d3
        bmi.s   3f
1:      move.l  %d7,%d1
        eor.l   #0xA5C33C5A,%d1
        eor.l   %d6,%d1
        cmp.l   (%a0)+,%d1
        beq.s   2f
        tst.l   8(%a3)
        bne.s   4f
        move.l  %d7,0x28(%a3)           | first bad offset
4:      addq.l  #1,8(%a3)
2:      addq.l  #4,%d7
        subq.l  #1,%d3
        bpl.s   1b
3:      movem.l (%sp)+,%d1-%d3/%a0
        rts

| fill: 64 KB at buf for offsets d7 .. d7+65535, mask d6 (d7 unchanged)
fill:   movem.l %d1-%d3/%a0,-(%sp)
        move.l  buf-vars(%a4),%a0
        move.l  %d7,%d2
        move.w  #16383,%d3
1:      move.l  %d2,%d1
        eor.l   #0xA5C33C5A,%d1
        eor.l   %d6,%d1
        move.l  %d1,(%a0)+
        addq.l  #4,%d2
        dbra    %d3,1b
        movem.l (%sp)+,%d1-%d3/%a0
        rts

| tick: d0 = minutes * 3000 + ticks (DateStamp)
tick:   movem.l %d1-%d3/%a0-%a1,-(%sp)
        lea     ds(%pc),%a0
        move.l  %a0,%d1
        jsr     -192(%a6)               | DateStamp
        lea     ds(%pc),%a0
        move.l  4(%a0),%d0
        mulu    #3000,%d0
        add.l   8(%a0),%d0
        movem.l (%sp)+,%d1-%d3/%a0-%a1
        rts

| report: one line "HDT pass PPPPPPPP rderr XXXXXXXX wrerr XXXXXXXX ticks RRRRRRRR WWWWWWWW BBBBBBBB\n"
report: movem.l %d0-%d7/%a0-%a2,-(%sp)
        lea     line(%pc),%a0
        move.l  4(%a3),%d0
        lea     9(%a0),%a1
        bsr     hex8
        move.l  8(%a3),%d0
        lea     24(%a0),%a1
        bsr     hex8
        move.l  12(%a3),%d0
        lea     39(%a0),%a1
        bsr     hex8
        move.l  0x18(%a3),%d0
        lea     54(%a0),%a1
        bsr     hex8
        move.l  0x1c(%a3),%d0
        lea     63(%a0),%a1
        bsr     hex8
        move.l  0x20(%a3),%d0
        lea     72(%a0),%a1
        bsr     hex8
        move.l  out-vars(%a4),%d1
        beq.s   1f
        move.l  %a0,%d2
        moveq   #81,%d3
        jsr     -48(%a6)                | Write(Output(), line, 81)
1:      movem.l (%sp)+,%d0-%d7/%a0-%a2
        rts

hex8:   moveq   #7,%d2
1:      rol.l   #4,%d0
        move.b  %d0,%d1
        and.b   #15,%d1
        add.b   #48,%d1
        cmp.b   #57,%d1
        bls.s   2f
        addq.b  #7,%d1
2:      move.b  %d1,(%a1)+
        dbra    %d2,1b
        rts

exit:   moveq   #20,%d0
        rts

        .balign 4
vars:
dosbase: .long  0
buf:    .long   0
out:    .long   0
fh:     .long   0
t0:     .long   0
ds:     .long   0,0,0
dosname: .asciz "dos.library"
n_data1: .asciz "data1"
n_out1: .asciz  "out1"
line:   .ascii  "HDT pass 00000000 rderr 00000000 wrerr 00000000 ticks 00000000 00000000 00000000\n"
        .balign 4
"""


def build(write_kb):
    src = SRC.replace("WRITE_BYTES", str(write_kb * 1024))
    with tempfile.TemporaryDirectory() as d:
        open(d + "/s.s", "w").write(src)
        subprocess.check_call(["m68k-linux-gnu-as", "-m68000", "-o", d + "/s.o", d + "/s.s"])
        subprocess.check_call(["m68k-linux-gnu-objcopy", "-O", "binary", d + "/s.o", d + "/s.bin"])
        code = open(d + "/s.bin", "rb").read()
    code += b"\0" * (-len(code) % 4)
    n = len(code) // 4
    return (struct.pack(">IIIII", 0x3F3, 0, 1, 0, 0) + struct.pack(">I", n) +
            struct.pack(">II", 0x3E9, n) + code + struct.pack(">I", 0x3F2))


def data(nbytes):
    return b"".join(struct.pack(">I", (o ^ 0xA5C33C5A) & 0xFFFFFFFF) for o in range(0, nbytes, 4))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--data-kb", type=int, default=1024)
    ap.add_argument("--write-kb", type=int, default=512)
    a = ap.parse_args()
    if a.write_kb % 64:
        sys.exit("--write-kb must be a multiple of 64")
    os.makedirs(a.outdir, exist_ok=True)
    exe = build(a.write_kb)
    open(os.path.join(a.outdir, "hdtest"), "wb").write(exe)
    open(os.path.join(a.outdir, "data1"), "wb").write(data(a.data_kb * 1024))
    print("hdtest %d bytes, data1 %d KB, out1 %d KB" % (len(exe), a.data_kb, a.write_kb))
