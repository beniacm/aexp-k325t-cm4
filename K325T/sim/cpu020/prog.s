| prog.s -- test program for tb_cpu020.sv (cpu_wrapper with fx68k or TG68K + fast RAM).
| Runs from the "ROM" at $F80000; the test bench's chip memory has the reset vectors.
| Assemble: m68k-linux-gnu-as -m68020 [--defsym CPU020=1] [--defsym Z3=1]  (see run.sh)
| Result: $1000.l = failure bits (0 = all passed), then $600D (pass) or $BADx (an exception) to
| $1004.w; every write to $1008.w is a time stamp the bench prints.

        .text
rom:    bra.w   start

start:  lea     0x8.w,%a0                   | vectors 2..63 -> trap
        move.w  #61,%d0
        lea     trap(%pc),%a1
vec:    move.l  %a1,(%a0)+
        dbra    %d0,vec
        moveq   #0,%d7                      | failure bits
        move.w  #1,0x1008.w                 | time stamp 1: start

| autoconfig the fast RAM board (cpu_wrapper's Zorro II or III board)
.ifdef Z3
        move.w  #0x4000,0xe80044            | Zorro III: base $40000000 (register $44)
        move.l  #0x40000000,%a5
.else
        move.b  #0x20,0xe80048              | Zorro II: base $200000 (register $48)
        move.l  #0x200000,%a5
.endif

| bit 0: 1024 longwords, written then read back (address XOR pattern)
        move.l  %a5,%a0
        move.w  #1023,%d0
w1:     move.l  %a0,%d1
        eor.l   #0x5aa5c33c,%d1
        move.l  %d1,(%a0)+
        dbra    %d0,w1
        move.l  %a5,%a0
        move.w  #1023,%d0
r1:     move.l  %a0,%d1
        eor.l   #0x5aa5c33c,%d1
        cmp.l   (%a0)+,%d1
        bne.s   f0
        dbra    %d0,r1
        bra.s   t1
f0:     bset    #0,%d7

| bit 1: byte and word writes into a longword, read back as a longword
t1:     lea     0x1000(%a5),%a0
        move.l  #0x11223344,(%a0)
        move.b  #0xaa,1(%a0)
        move.b  #0xbb,2(%a0)
        move.w  #0xccdd,4(%a0)
        move.b  #0xee,5(%a0)
        cmp.l   #0x11aabb44,(%a0)
        bne.s   f1
        cmp.w   #0xccee,4(%a0)
        beq.s   t2
f1:     bset    #1,%d7

| bit 2: a routine copied into fast RAM and run from there; time stamps around 2048 DBRA
| from ROM and from fast RAM
t2:     move.w  #2,0x1008.w
        bsr     loop
        move.w  #3,0x1008.w
        lea     loop(%pc),%a0
        lea     0x2000(%a5),%a1
        moveq   #(loopend-loop)/2-1,%d0
cp:     move.w  (%a0)+,(%a1)+
        dbra    %d0,cp
        move.w  #4,0x1008.w
        jsr     0x2000(%a5)
        move.w  #5,0x1008.w
        cmp.l   #0x5555,%d2
        beq.s   t3
        bset    #2,%d7
t3:

.ifdef CPU020
| bit 3: MULU.L 32x32 -> 64
        move.l  #0x9abcdef0,%d1
        move.l  #0x12345678,%d3
        mulu.l  %d1,%d2:%d3
        cmp.l   #0x0b00ea4e,%d2
        bne.s   f3
        cmp.l   #0x242d2080,%d3
        beq.s   t4
f3:     bset    #3,%d7
| bit 4: DIVU.L 64 / 32
t4:     move.l  #0x00000123,%d2
        move.l  #0x456789ab,%d3
        divu.l  %d1,%d2:%d3
        cmp.l   #0x1e1,%d3
        bne.s   f4
        cmp.l   #0x8888a8bb,%d2
        beq.s   t5
f4:     bset    #4,%d7
| bit 5: BFEXTU from fast RAM, EXTB.L
t5:     lea     0x3000(%a5),%a0
        move.l  #0x12345678,(%a0)
        bfextu  (%a0){#4:#12},%d0
        cmp.l   #0x234,%d0
        bne.s   f5
        move.l  #0xf0,%d0
        extb.l  %d0
        cmp.l   #0xfffffff0,%d0
        beq.s   t6
f5:     bset    #5,%d7
| bit 6: scaled index (d8,An,Xn.L*4) and MULS.L 64-bit signed
t6:     lea     tab(%pc),%a0
        moveq   #3,%d1
        move.l  (0,%a0,%d1.l*4),%d0
        cmp.l   #0xcafef00d,%d0
        bne.s   f6
        moveq   #-5,%d3
        move.l  #0x10000001,%d1
        muls.l  %d1,%d2:%d3
        cmp.l   #0xffffffff,%d2
        bne.s   f6
        cmp.l   #0xaffffffb,%d3
        beq.s   t7
f6:     bset    #6,%d7
| bit 7: MOVEC VBR: a TRAP #0 through a vector table moved into fast RAM
t7:     lea     0x4000(%a5),%a0
        lea     trap0(%pc),%a1
        move.l  %a1,0x80(%a0)
        movec   %a0,%vbr
        moveq   #0,%d0
        trap    #0
        sub.l   %a0,%a0
        movec   %a0,%vbr
        cmp.l   #0x7a7a,%d0
        beq.s   t8
        bset    #7,%d7
t8:
.endif
        move.l  %d7,0x1000.w
        move.w  #0x600d,0x1004.w
hang:   bra.s   hang

trap0:  move.l  #0x7a7a,%d0
        rte

trap:   move.w  #0xbad0,0x1004.w
        bra.s   trap

| 2048 x DBRA, d2 = $5555 at the end (position independent)
loop:   move.w  #2047,%d1
l1:     dbra    %d1,l1
        move.l  #0x5555,%d2
        rts
loopend:
        .even
tab:    .long   0, 1, 2, 0xcafef00d
