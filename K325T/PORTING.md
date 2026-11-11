# AExp on the QMTech XC7K325T + CM4 carrier: feasibility and porting notes

Target: the QMTech XC7K325T "CM4" carrier (Kintex-7 `xc7k325tffg676-1`) with a Rockchip
module in its CM4 socket (Radxa CM3 on the bench board, Luckfox Core3566 on the first
board). SD card, keyboard, joysticks and mouse are not wired to the FPGA: the module serves
them over one SPI link (`rk_bridge`, see the harness repository `mega65-k325t-cm4`). The
C64MEGA65 core was ported to this board before (`c64mega65`, branch `qmtech-k325t-cm4`,
directory `K325T/`); AExp is built on the same MiSTer2MEGA65 (M2M) framework, so this port
follows that recipe file for file.

Upstream: sy2002/AExp V1 (2026-07-26), M2M V2.0.1 with six AExp framework extensions
(interlace, core-io hook, screen-center, osm-hotkey, osm-scale, raw-joyports).

## What AExp needs, and where it comes from on the K325T

| need (upstream, MEGA65 R3-R6) | K325T | source |
|---|---|---|
| 100 MHz board clock `clk_i` | 50 MHz crystal (F22) -> MMCM x24/12 = 100.000 MHz (exact ratio) | C64 port's top (`top_qmtech_k325t_cm4.tpl.vhd`) |
| Amiga core clock 28.375 MHz (`CORE/vhdl/clk.vhd`, two MMCMs + BUFGMUX for the HDMI flicker-free dither) | unchanged; VCO 1135 / 1137.5 MHz is inside the Kintex-7 -1 range (600-1200 MHz) | upstream, untouched |
| Chip RAM 512 KB, Slow RAM 512 KB, Kickstart 256 KB: **block RAM** inside `CORE/vhdl/mega65.vhd` | the same block RAM (the XC7K325T has 445 RAMB36 against the 200T's 365) | upstream, untouched |
| HyperRAM 8 MB (Avalon-MM): ascal HDMI frame buffer, ADF floppy image staging (word 0x200000) | DDR3 MT41K128M16 (256 MB) via MIG + `avm_mig.vhd`, framework generic `G_EXT_HR` | C64 port |
| HDMI (TMDS from the framework) | J11 Sipeed DVI Pmod; green and clock pairs have P/N swapped: `G_TMDS_INVERT => "1010"` | C64 port |
| analog VGA / 15 kHz RGB, audio DAC | not present (audio on HDMI only) | -- |
| SD card (FAT32, `/amiga/kick.rom`, ADFs, settings) | `sd_emu` (SPI-mode SDHC) on the framework's back-slot bus, sectors from the module's `/root/m65/card.img` (m65io) | mega65-core `sd_emu.vhdl`, `rk_bridge.vhdl` |
| MEGA65 keyboard (serial matrix link) | `m65kbd_emu.vhd` answers the link from the bridge's key matrix (USB keyboard on the module, m65d) | C64 port |
| joysticks (DB9, raw lines since AExp's `raw-joyports`) | bridge joyA / joyB (USB pads, m65d) | C64 port |
| mouse: a real Amiga quadrature mouse on DB9 port 1 (userio.v counts the transitions; right/middle button on the pot lines, read through the paddle sampler) | **new**: `amiga_mouse.vhd` turns two position counters + buttons from the bridge (INPUT bytes 13..16, the C64 core's POT bytes) into quadrature transitions on port 1's direction lines, left button on fire, right / middle on POTX / POTY | new |
| RTC (MEGA65 I2C RTC -> Amiga $DC0000 clock, `doc/RTC.md`) | no I2C buses: `G_NO_I2C` (transfers NACK, the clock is never set); the Amiga clock reads as not set | C64 port (generic); an RTC from the module is possible later |
| QNICE UART | bridge monitor channel (TCP 4510 on the module) | C64 port |
| configuration flash, core switching | bridge flash pass-through (0x50) + `rk_iprog` (0x60), core id in STATUS byte 52: **3 = Amiga** | C64 port, new id |

M2M version: AExp's M2M (V2.0.1 + AExp extensions) and the C64 fork's M2M (C64MEGA65 V5.2)
differ only by the AExp extensions; the R6 top (`top_mega65-r6.vhd`) differs by four extra
signals (interlace field, OSM hotkey). The C64 port's three framework patches
(`G_EXT_HR`, `G_TMDS_INVERT`, `G_NO_I2C` in `framework.vhd`, `av_pipeline.vhd`,
`digital_pipeline.vhd`) applied with offsets only, and `gen_top.py` (which builds the board
top from the R6 top) works unchanged.

## Is the port cycle-equivalent to upstream?

Yes for everything the emulated Amiga can observe, by construction:

- **Amiga memory**: chip RAM, slow RAM and Kickstart stay in block RAM, served by
  upstream's unchanged `mega65.vhd` (1-cycle latency on minimig's SRAM-style port, read mux
  registered). No DDR3 is on the Amiga's memory path, so every CPU and DMA access answers in
  the same 28 MHz cycle as on a MEGA65.
- **Clocks and enables**: `clk.vhd`, `main.vhd` (fx68k phase enables, amiga_clk, video CE)
  and the whole Minimig tree are not modified. The core clock is generated from a 100 MHz
  clock exactly as upstream; only the 100 MHz itself comes from a 50 MHz crystal through an
  MMCM (an exact x2 ratio; absolute accuracy = crystal tolerance, ppm level, as on a MEGA65).
  The HDMI flicker-free option (upstream default ON) dithers the core clock between 28.375
  and 28.4375 MHz to lock to 50.000 Hz HDMI exactly as upstream (its control loop runs in the
  memory clock domain, here MIG ui_clk = 100 MHz like the HyperRAM clock); switch it off in
  the menu for a constant 28.375 MHz.
- **What DDR3 replaces**: only the two HyperRAM clients. (a) The ascal scaler's frame buffer:
  decoupled from the core by ascal's own FIFOs and frame buffering (same as upstream, where
  the HyperRAM latency also differs from frame to frame). (b) The ADF image store, read by
  `adf_track_engine` through avm_cache + avm_fifo. Paula's disk DMA runs on its own timing;
  the engine streams MFM to it with flow control (status bit 8), so the memory latency only
  decides whether the engine's data are there in time. DDR3 through `avm_mig` has a longer
  first-word latency than HyperRAM (tens of 100 MHz cycles, i.e. well under 1 us, refresh
  included) while Paula takes one 16-bit MFM word every 32 us (DD: 2 us per bit cell); the
  margin is more than an order of magnitude even before the engine's own buffering. Trackloader demos are the test (see below).
- **Inputs**: keyboard and joystick reach the core through the same M2M paths
  (`m2m_keyb`, debouncer = 2-FF synchroniser); USB latency on the module adds milliseconds
  (like any real key press, not cycle-relevant). The mouse produces real quadrature
  transitions (1 us apart) that userio.v counts exactly as from a DB9 mouse.

Not equivalent: no analog VGA / 15 kHz output, no audio DAC (HDMI audio only), no RTC.

## Resource estimate (and the result)

Upstream R6: 363.5 of 365 RAMB36 (320 for the Amiga memory). The K325T adds the bridge
(~5 RAMB36: SD read cache, sector buffers, UART FIFOs) and the MIG (no BRAM): about
370 / 445 RAMB36. LUTs: the C64 port uses 30 k of 204 k; AExp (fx68k + Minimig OCS +
framework) is in the same range. Clocking: 7 of 10 MMCMs (board, MIG, 2x clk_m2m,
video_out, 2x AExp clk), 2 PLLs (MIG), about 16 of 32 BUFG.

Built (Radxa CM3 variant, Vivado 2025.2.1): 32,640 LUTs (16 %), 25,845 registers, **380.5 of
445 RAMB36** (85.5 %), 64 DSP48; bitstream ~6.4 MB (compressed), fits an 8 MB flash slot.

## Risks

- Timing: upstream's margin is thin on the Artix-7 200T -2 (+0.39 ns, mostly the
  HyperRAM PHY, which is gone here). The Kintex-7 -1 is faster, but the 320 Amiga BRAM tiles
  spread over a larger die; the QNICE kick-ROM port (falling edge, 10 ns) is the known
  critical path.
  Result: met on the first clean run (WNS +0.114 ns, WHS +0.054 ns); the only violations on
  the way were the new mouse lines into M2M's joystick synchronisers (asynchronous by design,
  now false paths by cell) and the button levels (now a 2-FF synchroniser in the core clock).
- MIG UI rules: `avm_mig` carries the two fixes of the C64 port (write data before command;
  no new command with a read's last beat), proven with the C64 core's REU and CRT loader.
- The Kickstart ROM is the user's: never in git; `/amiga/kick.rom` on the card only.

## Upstream files changed (minimal, generic-gated, defaults = upstream behaviour)

- `M2M/vhdl/framework.vhd`, `M2M/vhdl/av_pipeline/av_pipeline.vhd`,
  `M2M/vhdl/av_pipeline/digital_pipeline.vhd`: the C64 port's `G_EXT_HR`, `G_TMDS_INVERT`,
  `G_NO_I2C` (identical patch).
- `.gitignore`: the generated Vivado project `CORE/CORE-K325T.*`.

Everything else is in `K325T/`.

# Phase 2: the best Amiga this FPGA can carry (study, 2026-11-11)

Goal (the user's words): "the amiga core is meant for the smaller fpga, once it succeeds, use the
fpga capacity to get the best possible version".  The A500 configuration above stays the default
and must keep passing its demo regression (`tools/aexp_demo_test.py`).

Room on the XC7K325T next to the A500 port: ~171 k LUTs, 64.5 RAMB36 (380.5 / 445 used),
256 MB DDR3 (the M2M "HyperRAM" bus uses a few MB of it: ascal frame buffer, ADF image).

## 1. What AExp removed or froze relative to MiSTer's Minimig-AGA

Compared: AExp's submodule `CORE/Minimig_MiSTerMEGA65` (branch develop, 7 AExp commits on top
of MiSTer release 20260603, merge base `eb7a26e`) with MiSTer-devel/Minimig-AGA_MiSTer
(read-only clone in `ext/Minimig-AGA_MiSTer`, master `7d5d3c2`; the newer upstream adds a
68030/MMU, Action Replay, A2065 changes -- not in AExp's base).  MiSTer's top `Minimig.sv`
(SDRAM + DDR3 controllers, fastchip/RTG/Akiko/CDTV, audio filters, video mixer, HPS file I/O) is
not part of AExp at all; AExp instantiates `minimig.v` + `cpu_wrapper.v` from `main.vhd`.

| feature (MiSTer) | in AExp | RTL state |
|---|---|---|
| chipset OCS / ECS / AGA / A1000 / NTSC (`0xF3` "XXXGEANT") | OCS PAL A500 fixed by `amiga_config.vhd` | **all in the bitstream** (runtime register `chipset_config`; only `chip48` = AGA 64-bit fetch tied 0 in `minimig_m65.v`) |
| CPU 68000 / 68010 / 68020 (TG68K) + turbo chip/kick, CPU caches (`0xF4`) | fx68k 68000 only | TG68K instance **commented out** in `cpu_wrapper.v` (sources kept in `rtl/tg68k`), outputs tied; turbo/cache logic self-disables with cpucfg=00 |
| SDRAM/DDR3 CPU port (`ramsel`, `sdram_ctrl`, `ddram_ctrl`, `cpu_cache_new`) | none | `ramsel` **tied 0**, address mapping commented out; controllers not ported |
| chip RAM 0.5-2 MB (`0xF5` CC) | 512 KB | runtime config; **BRAM sized 512 KB** in `mega65.vhd` |
| slow RAM 0-1.5 MB (`0xF5` SS) | 512 KB or none (OSM toggle) | runtime config; BRAM 512 KB |
| fast RAM Zorro II 2/4/8 MB, Zorro III 256/384 MB (`0xF5` FF) | none | autoconfig logic **kept** in `cpu_wrapper.v`, self-disabled (fastramcfg=000); no memory behind it |
| Kickstart 256 KB / 512 KB / 1 MB (`$E00000` ext) | 256 KB | gary/bankmapper decode all sizes; **BRAM 256 KB**, address bit 18 ignored (F8/FC mirror) |
| floppies 1-4, normal/turbo speed (`0xF7`) | df0, normal | Paula supports 4 drives + turbo; the host side (`adf_track_engine`, mount wrapper, firmware) is **single-drive** |
| IDE / Gayle, 4 HDF (`0xF8`) | none | `gayle.v` + `ide.v` **in the tree, disabled** (ide_config=0); the host side (MiSTer's HPS serves the sectors) is missing |
| RTG, Akiko (CD32 C2P), CDTV, A2065 Ethernet, Toccata, MT32-pi, shared folder | none | top-level parts of `Minimig.sv` not ported; Toccata **commented out** in `minimig.v` |
| HRTmon / Action Replay cart | off | `cart.v` present, needs a ROM image upload (not done) |
| RTC ($DC0000) | from the MEGA65 I2C RTC via M2M | present; on the K325T `G_NO_I2C` (no RTC chip) |
| audio: A500 LED filter, A1200 filter, Paula PWM volume | raw Paula | MiSTer's filters live in `Minimig.sv` (not ported); AExp removed its "Audio improvements" item |
| video: scandoubler, scanlines, scaler | M2M (ascal + filters, 15 kHz analog) | MiSTer's video mixer replaced by the framework |

So the chipset and the memory decode are complete; what is missing is memory (sizes), the CPU
alternatives and all host-side services (more drives, IDE, RTG).

## 2. Memory architecture on this board

- **Block RAM**: 445 RAMB36 = 1.95 MB raw.  The A500 uses 320 (chip 512 KB = 128, slow 512 KB
  = 128, Kickstart 256 KB = 64); framework, QNICE (32), ascal, FIFOs, MIG adapter and the
  Rockchip bridge use 60.5.  At most ~384 tiles (1.5 MB) can be Amiga memory.
- **Chip RAM must stay in block RAM.**  minimig has one SRAM-style memory port shared by the
  CPU and all DMA, time-multiplexed on the 7.09 MHz bus: the address appears at the start of a
  bus cycle (4 ticks of 28 MHz) and the data is consumed in its second half, i.e. 70-105 ns
  later, on every slot, with no wait mechanism for DMA.  The MIG's read latency is ~20-30 cycles
  of its 100 MHz UI clock in the best case, plus refresh (tRFC 160 ns every 7.8 us), ZQ
  calibration and the CDC: several hundred ns, variable.  MiSTer gets chip RAM from SDRAM with a
  controller locked to the 7 MHz cycle (fixed CAS timing, refresh in fixed slots); a DDR3
  equivalent would need a self-written PHY with bounded latency -- not a realistic increment.
  The same holds for slow RAM (on the chip bus in an A500, contended like chip RAM) and for
  the Kickstart ROM (served on the same port in minimig's CPU slots).
- Consequence: chip + slow + Kickstart <= 1.5 MB of block RAM.  Chosen layout (384 tiles):
  chip 512 KB + slow 512 KB + Kickstart 512 KB, where the slow-RAM tiles double as the upper
  512 KB of chip RAM in the "1 MB chip" configuration.  2 MB chip (A1200) does not fit.
- **What can go to DDR3**: memory only the CPU sees and that a real machine may stretch with
  wait states: **fast RAM** (Zorro II on a 68000 = an A590/A2091-style card; the 68000 waits
  on /DTACK exactly as on a real card, MiSTer does the same with `ramready`), and RTG/CPU
  caches in MiSTer's design.  The ADF images already live there.
- **Cycle equivalence**: everything on the chip bus (chip, slow, Kickstart, custom chips, CIAs)
  stays cycle-equivalent in every configuration (block RAM, unchanged minimig timing).  Fast RAM
  in DDR3 and any 68020 are "accelerated machine" by nature: their timing is that of an
  expansion card, not of an A500, and varies with DDR3 refresh.

## 3. Increments, ranked (value to the user vs risk), and the decision for each

| # | increment | value | risk / cost | decision |
|---|---|---|---|---|
| 1 | Kickstart 512 KB (2.04, 3.1 for A500/A600) | high: KS 3.1 is the common A500 upgrade | +64 RAMB36 (444.5 / 445); the QNICE port of the Kickstart BRAM is already the design's critical path (route 8.8 ns of the 10 ns half cycle with 64 tiles): needs a pipelined write port | **now**; ROM size detected from the image's first word (`$1111` = 256 KB, `$1114` = 512 KB); 256 KB ROMs keep the F8/FC mirror |
| 2 | ECS chipset (8372A/8373) | medium: KS 2+/3.1 ECS modes, productivity/super-hires, 1 MB chip | none: config bit 3 of `0xF3`, RTL already synthesised | **now**, menu OCS / ECS |
| 3 | 1 MB chip RAM | medium (A500+ layout) | the slow-RAM BRAM becomes chip RAM 512 KB-1 MB; slow RAM then off | **now**, menu radio 512K+512K slow / 512K / 1M chip (forces ECS) |
| 4 | fast RAM 2/4/8 MB (Zorro II, autoconfig) in DDR3 | high for Workbench/WHDLoad-style software, more free memory | restore `ramsel`/DTACK stretching for `sel_zram` only; DDR3 latency through the M2M Avalon port (shared with ascal + ADF): measure; no BRAM left for a cache (LUT RAM only) | **next**, if 1-3 are solid |
| 5 | 68020 (TG68K) | medium (with fast RAM) | the instance and its chip-bus FSM (negedge) come back; MiSTer's turbo modes need its SDRAM CPU cache; not cycle-exact by nature | later / leave: little gain without fast RAM, a 68000 A500 is the target |
| 6 | 2-4 floppy drives | medium (multi-disk games without swapping) | Paula is ready, but the host service is df0-only: track engine, mount wrapper, firmware, menu, DDR3 windows | leave (study in `doc/developers/research_df1.md`) |
| 7 | HDF / IDE (Gayle) | high with an OS install | the HPS side of MiSTer (sector service) must be written for QNICE or the module | leave: large |
| 8 | AGA (A1200, kick40068) | high | needs 2 MB chip RAM (512 RAMB36: does not fit) and the 32/64-bit chip bus | leave: not possible in block RAM, chip RAM cannot be in DDR3 deterministically |
| 9 | RTC from the module | low-medium (dates in KS 2+/Workbench) | the M2M RTC is set by the QNICE firmware from I2C; a module-fed clock needs a new rk_bridge command (shared with the MEGA65 and C64 cores) and firmware or HDL to load it | leave |
| 10 | turbo floppy, NTSC, A1000 mode, audio filters | low | turbo needs engine validation; NTSC needs a 28.636 MHz clock + 60 Hz modes | leave |

Menu entries come with each increment.  Every increment: build (`K325T/build.sh radxacm3`,
timing met), JTAG test, demo regression in the default A500 configuration, commit, then flash
slot 1 only after JTAG verification.

## 4. Results (2026-11-11, Radxa CM3 board, verified over JTAG, then flash slot 1)

**Increment 1 -- Kickstart 512 KB, ECS, 1 MB chip** (commit "phase 2 (1/2)").  Timing met
(WNS +0.194 ns), 436 / 445 block RAM tiles (Vivado moved ascal's polyphase line buffers to
LUT RAM, functionally the same), 39.6 k LUTs.  The 128-tile Kickstart needed a pipelined
QNICE port (see `mega65.vhd`).  Checked with `tools/mk_sysinfo_adf.py` (boot-block SysInfo):
KS 1.3 / 2.04 (37.132) / 3.1 (40.10) boot; OCS: VPOSR `$8000`, no DENISEID; ECS: VPOSR
`$A000` (8372A PAL), DENISEID `$FC`; memory lists 512K+512K, 512K, 1M chip (the SysInfo screen
itself at `$0F0000`, so bitplane and copper DMA read the upper half).

**Increment 2 -- Zorro II fast RAM 2/4/8 MB in DDR3** (commit "phase 2 (2/2)").  Timing met
(WNS +0.350 ns, WHS +0.050 ns), 436 RAMB36 (no new block RAM), 44.2 k LUTs (10.2 k LUT RAM:
the cache 2 x 8K x 8 + 1K x 11 tags, the ascal line buffers).
`amiga_fastram.vhd` + `sim/tb_amiga_fastram.vhd` (random 68000 cycles incl. byte writes with
the real S2/S4 strobe timing, an Avalon model with random latency, random memory-side resets).
Two bugs found on the board and then reproduced in the testbench before fixing: writes were
latched at /AS instead of /UDS,/LDS (no byte enables), and a framework reset during a line
fill acknowledged the fill without data.  KS 1.3 and 3.1 find the board ($200020-$A00000,
8191 KB); a write/read pattern over all 8 MB passes; a DBRA loop from fast RAM takes the same
45 raster lines as from chip RAM (cache hits, no wait states), 2048 longword reads take 71
lines from fast vs 65 from chip (line fills).

**Cycle equivalence of the default (A500) configuration**: the chip-bus memory path is
unchanged by construction (256 KB ROM: address bit 18 forced 0 = the old mirror; slow-RAM
decode unchanged when "1M Chip" is off; config words identical; with fast RAM off
`z2ram_ena` never sets, so `ramsel` = 0 and cpu_wrapper's /AS and /DTACK are the old ones).
Measured: the SysInfo values are identical to the V1 core's (increment 1: the capture is
byte-identical; same raster-line timings in all builds); the five demos run through in the
default configuration.  Sampled demo frames are byte-identical between V1 and the new core at
some sample points (Batman after Eon: 12 of 44, SOTA increment 1: 7 of 14), but two V1 runs
agree only as often (Batman: 8 of 44): the menu-driven mount (keys over the network) starts
each demo with a jitter of frames, so frame md5s support, but cannot prove, equivalence.  The floppy image's DDR3 reads: with fast RAM on they pass one more Avalon arbiter (fast RAM
is the third master); with fast RAM off a static select connects them directly as in V1 (a
first build without the bypass shifted SOTA's timeline: SOTA loads while it plays, so the
disk-read latency is visible in when its parts start -- also in V1, where ascal shares the
memory; the bypass restores V1's path exactly).

**Full reset = cold boot**: in V1 the M2M full reset (reset held > 1.5 s) ran the cold-boot
scrub of `$4` by side effect (the Slow RAM menu bit drops while QNICE reloads the settings).
The phase-2 topology vector does not change at that moment, so the first builds warm-booted
after a full reset, and Batman Rises hung after Eon (V1 ran it: same card, same order).
`amiga_cold_boot` now cold-boots on the M2M reset explicitly; Ctrl+Alt+Del (core reset) stays
a warm reset as in V1.

Left (reasons in section 3): 68020, more floppy drives, IDE/HDF, AGA, RTC from the module,
turbo floppy, NTSC, audio filters.

**Reproducibility** (2026-11-11): a fresh clone of this branch + `git submodule update --init`
+ the QNICE tool build + `K325T/build.sh radxacm3` applied the Minimig patch ("patch applied"),
built the same firmware ROM and a bitstream identical to the flashed one except 3 bytes of
the .bit header (build time); same timing (WNS +0.350 ns).  Flash slot 1 holds this core
since 2026-11-11 (slot 0 read back unchanged before/after; cold start, core switching both
ways, MEGA65 smoke test passed).
