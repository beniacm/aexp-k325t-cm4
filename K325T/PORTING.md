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

# Stage 1 of the A1200 route: a stoppable Amiga clock (branch `a1200-ddr3`, 2026-11-11)

The A1200/DDR3 study (`ext/aexp3_a1200_ddr3_study/A1200_DDR3_STUDY.md` in the harness tree, verdict
"go with conditions") puts chip RAM and Kickstart into DDR3 behind a block-RAM cache and stops the
Amiga's clock on a cache miss.  Its condition C1 is this stage: all Amiga memory stays in block RAM
exactly as in phase 2, the stall + catch-up clock is added, ARTIFICIAL stalls are injected, and
nothing the Amiga can observe may change.  Experimental: JTAG only, never in flash.

## What was built

| file | what |
|---|---|
| `stall_clk.vhd` | replaces `CORE/vhdl/clk.vhd` in the K325T build (same entity `clk`; `gen_sources.py` swaps the file): one MMCM (VCO 1135 MHz, upstream's native leg), CLKOUT0 / 38.75 = **29.290323 MHz = 28.375 x 32/31** into a BUFG (the ungated source clock) and a **BUFGCE** (`main_clk`).  The flicker-free twin MMCM and its BUFGMUX_CTRL are gone (one MMCM fewer). |
| `stall_ctrl.vhd` | in the source clock: DDS credit in 2^-20 machine ticks, + 31/32 per source edge (or the flicker-free "fast" target x 455/454); an edge passes while the credit is >= 1 tick and no stall is requested; the BUFGCE enable is a register.  Lag cap 2^19 machine ticks (18.5 ms), the excess is forgiven and counted.  Injector (xorshift32): start probability (m+1)/2^(e+8) per source tick, duration ((dm+1) << de) + random(0 .. 2^j-1) ticks of 34.14 ns.  Monitor (snapshot): lag now / max, stall count, stalled ticks, dropped pulses, forgiven ticks, machine vsync count with its source-tick time stamp, source and machine tick counters.  Register 0 bit 1 forces the native rate (flicker-free ignored). |
| top, `gen_top.py`, `mega65.vhd` | the bridge's VIDEO register (command 0x70, unused by this core: no Linux picture) writes the controller's registers (`1rrrvvvv`; m65d only ever writes 0..3), bridge STATUS 60..71 return the selected monitor page; `mega65.vhd` passes them through and feeds the machine vsync; the flicker-free FSM is unchanged, it now selects the DDS rate |
| `m65kbd_emu`, `amiga_mouse` | stall-tolerant: keyboard frame-sync threshold 30 us (was 5 us), mouse one step per 20 us (was 1 us); see "where the study was wrong" |
| `core_k325t.xdc` | `CORE/CORE.xdc` with `main_clk` defined on the MMCM output (both buffers carry it: every controller <-> Amiga path is synchronous) |
| `sim/tb_stall_ctrl.vhd` | GHDL bench of the controller |
| `tools/stallmon.py` | on the module: `preset off/rtl/mix/burst15/budget/overload`, `set`, `clear`, `read`, `log`, `rate SECS` |
| `tools/mk_stalltest_adf.py` | boot-block machine-time test (below); `tools/frame_counter_clip.py` (dropped / repeated frames in a clip), `tools/tone_analyze.py` (recorded tone) |

Injector presets (`stallmon.py`): **rtl** 0.68 us stalls ~197 per frame (0.67 %: the study's worst
RTL workload), **mix** 0.31-2.46 us ~349 per frame (2.4 %), **burst15** 15.3 us ~20 per frame
(1.5 %), **budget** 0.68 us ~833 per frame (2.85 %), **overload** 0.68 us ~1620 per frame (5.5 %).

## Simulation

`sim/tb_stall_ctrl.vhd` (GHDL 5, the configuration written exactly as the Rockchip does, results
read back through the snapshot pages): without stalls 3,100,001 machine edges in 3,200,001 source
edges (31/32), never two drops in a row, lag 0; random stalls at four settings (0.7 us x 188/frame,
0.3-2.4 us x 340/frame, 15 us x 21/frame, 0.7 us x 811/frame): no edge passes during a stall, the
lag never exceeds the fluid debt + 1 tick, reported lag max = observed (68 / 330 / 1963 / 401
ticks), stall counts and stalled ticks equal the bench's; over the whole run (13.2 M source ticks)
machine edges = 31/32 x source edges - lag (no edge lost or invented); fast rate 1,018,046 per 2^20
(1,018,045 expected); overload: the lag stops at the cap, the excess is counted.  `TB_STALL_CTRL_PASS`.

## Timing (Radxa CM3 build, Vivado 2025.2.1, 4 jobs)

Final build (the one committed): WNS +0.182 ns, WHS +0.050 ns, all constraints met; the worst
path is in the Rockchip bridge (clk162), as in phase 2 (+0.350 ns).  `main_clk` at 34.141 ns
(29.29 MHz, was 35.165 ns): intra-clock WNS +8.906 ns (earlier stage-1 builds +6.98 to +8.44;
phase 2: +9.531 ns at 35.165 ns); worst path Paula's floppy FIFO pointer -> chip-RAM block-RAM
address, ~24.7 ns of which ~22.7 ns route (the spread of the 256 chip/slow tiles).  BUFGCE CE
(register -> CE0): data path 1.46 ns, setup slack +30.7 ns, hold slack +0.96 ns.  Controller worst
path 9.0 ns.  Utilisation: 44,365 LUTs (phase 2: 44,159), 27,958 registers, 436 / 445 RAMB36
(unchanged), 15 / 32 global buffers (2 BUFGCTRL), 5 MMCMs (phase 2: 6).  The only critical warning is the
pre-existing Vivado 12-3645 (`add_files` one file at a time in `sources.tcl`, a run-time note).

## Board results (Radxa CM3 carrier, JTAG; logs and captures in the session scratch, not in git)

Unless noted the results below come from the first stage-1 builds (keyboard / mouse emulators in
`main_clk`); the final build (emulators at 100 MHz, see below) repeated SysInfo off / mix
(identical), Kickstart 3.1 with mix (identical to phase 2: exec 40.10, the same memory list, 45 /
65 lines, screen at $050000) and the live presets on the determinism test (0 mismatches).

**Injection off = phase 2 in machine time.**  SysInfo (KS 1.3, 512K + 512K): the decoded capture is
identical to phase 2's (Agnus OCS PAL, memory list $C004E8-$C7E800 + $000420-$080000, 2048 DBRA 45
lines, 2048 longword reads 65 lines).  The source clock is exactly 31/32 machine: `stallmon rate`
over 65 s: machine clock 28,375,000.001 Hz, frame rate 49.920128 Hz (+0.00 ppm against native).

**SysInfo with every preset** (set before the full reset, so Kickstart, the boot and the
measurement all ran with stalls): rtl, mix, burst15, budget, overload -- the decoded values are
identical to injection off in all five, including the overload, where the machine ran 2.5 % slower
than real time.

**Machine-time determinism test** (`mk_stalltest_adf.py`, 976.6 Hz tone + per-frame workload):
every frame, out of STOP, the copper interrupt (line $40) starts a 4 KB blitter clear, then a 4 KB
blitter copy (A -> D, minterm alternating $F0/$0F per frame) while the CPU reads VHPOSR and the blit
destination 512 times, with 5 lores bitplanes and 2 audio channels stealing slots; the checksum of
what the CPU read changes with any lost or added bus cycle.  All frames of a run (even and odd
parity separately) must give the same checksum; the screen counts mismatches.  Two fixed points
exist after the boot (the STOP wake-up phase depends on where the takeover code met the beam):
entry $407E with checksums 27dbf6f3 / 0c253188 and entry $4080 with 4fb7cb6d / d6730798.  Phase 2
gave the first in 3 of 3 boots, stage 1 the first in 3 of 6 boots and the second in 3 of 6: the
same two families, bit for bit.  (A first version with a 998.6 Hz tone had frame-to-frame
differences on phase 2 as well: audio DMA takes slots the blitter would use, and a period not
locked to the line moves them from frame to frame; the tone now uses period 227 = one line.)
Then, with the test running, the injector was switched live through all presets (FF off: 30 s
each with audio; FF on: 120 s each with a clip; the final bitstream: 30 s each again): 53,562
frames, **0 mismatching frames**, the checksums unchanged.

| preset (FF on, 120 s) | stalls / frame | stalled | lag max | frame rate (rate window) | HDMI clip (6000 captured frames) |
|---|---|---|---|---|---|
| off | 0 | 0 | 0 | 49.999685 Hz (window started right after an overload: repayment) | all +1 |
| rtl | 195.3 | 0.667 % | 115 ticks = 4.05 us | 50.000038 Hz (+0.8 ppm) | all +1 except one dongle slip |
| mix | 348.8 | 2.41 % | 1731 = 61.0 us | 50.000070 Hz | all +1 |
| burst15 | 19.8 | 1.52 % | 4829 = 170.2 us | 50.000070 Hz | all +1 |
| budget | 833.8 | 2.85 % | 4207 = 148.3 us | 50.000131 Hz | all +1 |
| mix, 300 s | 348.9 | 2.41 % | 1748 = 61.6 us | **50.000000 Hz (+0.00 ppm)**, machine clock 28,420,399.6 Hz | - |

With flicker-free off the machine runs at exactly 49.920128 Hz under rtl (+0.00 ppm over 30 s) and
within -0.03 / -0.08 / -1.9 ppm under mix / budget / burst15 in 30 s windows (the vsync time stamps
carry the current lag, up to 130 us, so short windows scatter); the clip shows the expected
repeated frame every 12.5 s (626 captured frames), as phase 2 does without flicker-free.  The
capture dongle (MS2130, 50 fps) slips one frame now and then against the board, phase 2 too.

**Audio** (HDMI audio of the capture dongle, `sudo arecord -D hw:2,0`, 48 kHz, 20 s, flicker-free
off so that the pitch does not dither by 0.22 % once a second; `tone_analyze.py`): frequency
976.5528-976.5530 Hz in off / rtl / mix / burst15 / budget (dongle clock; phase 2: 976.5516 Hz in
another recording).  The measurement floor is high: Paula's 16-step sine has images that alias in
the 48 kHz path (harmonics -23 dB, non-harmonic residual -22.4 dB, "jitter" of 2 ms phase blocks
3.0 us RMS with injection off).  rtl: 2.96 us RMS, residual -22.4 dB (= off, its 4 us lag is below
the floor); mix 3.9 us / -21.9 dB; budget 4.2 us / -21.8 dB; burst15 8.5 us RMS (69 us max) /
-18.9 dB: the lag excursions of 15 us stalls (up to 130-170 us) are audible in principle as time
jitter of the waveform.  Not measured: a cleaner tone (no aliasing) to push the floor down.

**Overload** (5.5 % stalled, beyond the 3.1 % headroom): the lag reaches the 18.5 ms cap and
stays there (`lag_now` 524,276-524,288 ticks, `forgiven` counting: 22.8 M ticks in 30 s), the
machine runs at 27.67 MHz (-2.49 %), 48.68 frames/s; the tone drops to 952.6 Hz (-43 cents); ascal
repeats a frame about every 0.75 s (39-40 repeated frames in 30 s of clip); the machine-time test
still counts 0 mismatches and SysInfo is identical: exact in machine time, slow in real time, as the
study predicted.  After the overload the capped debt is repaid in 0.57 s (31 x 18.5 ms) at the
source rate.

## What the study got right, and where it was wrong or optimistic

Right, and now measured:
- The BUFGCE-gated clock (study option A) is invisible to the machine by construction, and the
  board agrees: SysInfo identical under all presets, 0 mismatching frames of the bus-cycle
  checksum over ~63,000 frames with live switching, phase 2's checksum family reproduced bit for bit.
- 29.290 MHz = 28.375 x 32/31 from the existing VCO, the 31/32 DDS: machine clock 28,375,000.00 Hz
  (+0.00 ppm) without stalls and with 0.67 % stalls; with flicker-free on and 2.4 % stalls the
  frame rate is 50.000000 Hz over 300 s.
- The CE decision is easy to time: register -> BUFGCE CE has +30.7 ns slack; the Amiga domain
  closes at 29.29 MHz with +8.4 ns (study: +9.5 ns at 28.44 MHz, ~38 MHz possible).
- ascal, the floppy engine (demos, below) and the fast-RAM handshake run through stalls without
  a change; ascal showed no dropped or repeated frame with flicker-free on up to 170 us of lag.
- Overload behaves as described: exact in machine time, slower in real time, frame repeats.

Wrong or optimistic:
1. **Real-time couplings outside the gated domain were missed** (section 1.3 lists only the M2M
   paths).  This port has two in the top level, both in the 100 MHz board clock: `m65kbd_emu`
   takes a kio8-high phase longer than 5 us as the keyboard link's frame sync (a stall over ~3 us
   inside one 1.6 us half period would reset its bit counter: wrong keys for a scan), and
   `amiga_mouse` makes one quadrature step per microsecond (two steps inside one stall and
   userio.v would count wrongly).  Found by reading the code, not by a failure on the board.  A
   first fix clocked both with `main_clk` (machine time); those builds showed the frozen-picture
   problem described below much more often (stuck after 3-11 full resets; with Kickstart 3.1 in 2 of
   2 boots, where SysInfo had run to its end loop behind a frozen picture), while the same design
   with the two emulators back on 100 MHz booted KS 3.1 and froze once in 25 resets, like phase 2
   (once in 33).  Why the emulators' clock changes the freeze rate is not understood (their paths
   are synchronous either way; a placement-dependent crossing inside ascal is one suspicion).
   The final build keeps them at 100 MHz and makes them stall-tolerant instead: frame-sync
   threshold 30 us (the sync pulse is ~42 us, a half period 1.6 us), one mouse step per 20 us.
2. **The catch-up headroom is not independent of flicker-free** (section 2.2): the source clock is
   fixed, so the headroom is 1 - K: 3.125 % at the native target but 2.91 % at the flicker-free
   "fast" target, which the loop selects about half of the time.  Measured with 2.85 % stalls
   (budget preset): lag max 35.7 us with flicker-free off, 148 us with it on.
3. **Lag maxima grow with the observation time and near the budget.**  The study's 2.6 us (2.7 s
   traces) became 3.6-4.05 us for the same stall rate over 30-120 s of Poisson-like arrivals; at
   2.4 % the lag reached 61 us, at 2.85 % 148 us.  The bound "lag <= the largest stall cluster" is
   right, but clusters get long when the average approaches the headroom: plan for h well above the
   expected stall fraction.
4. **Audio jitter**: at the RTL workload's rate it is below the measurement floor (as predicted);
   with 15 us stalls the waveform jitter is measurable (8.5 us RMS).  The audio FIFO of section 1.4
   becomes necessary as soon as stage 2's real stalls produce lags of tens of microseconds.
5. Minor: the study's plan keeps the native output on CLKOUT1 = /40; not needed (the DDS gives
   28.375 MHz exactly).  Pulse dropping is regular (one edge in 32), real-time jitter 34 ns.

Existing real-time couplings that stalls do not create but shift: the ADF engine serves Paula from
DDR3 in real time with flow control, so disk loading was never deterministic in machine time (V1
and phase 2 neither); fast-RAM wait states come from the DDR3 latency in real time (an expansion
card, not cycle-exact); with stalls both look slightly faster to the machine.

**Demos** (`tools/aexp_demo_test.py`, all five, final bitstream).  Injector off: Enigma, Arte and
Eon (with the disk swap) ran through; SOTA and Batman Rises showed a frozen white / black picture
from before the disk was even mounted (the frozen-picture problem of the next paragraph, right
after the demo tool's full reset); both ran when repeated (SOTA's frames at 20/30/40 s byte-identical
to a phase-2 recording, Batman's colour counts as in phase 2).  Injector **mix** (2.4 % stalled,
25 M stalls during the run, lag max 61.6 us): all five ran through, Batman including disk 2;
sampled frames byte-identical to phase-2 recordings at several points (SOTA 40 s; Batman 100 / 110 /
120 s same colour counts as phase 2's).

**A pre-existing reset problem, found on the way.**  A full M2M reset (`hold_reset`, as the demo
tool does before every demo) sometimes leaves the picture frozen at Kickstart 1.3's white boot
screen; further full resets do not clear it (a new bitstream does).  Measured with 20-second
reset loops (`aexp4_resetloop.py`, KS 1.3, no disk): stage 1 stuck after 8, 8, 3 and 25 resets
(also with the keyboard / mouse emulators back on the 100 MHz clock) and with the flicker-free rate
forced to native after 11; **phase 2 (its own bitstream over JTAG) 20 of 20, then stuck after 12**.
So it is not caused by the stoppable clock (rates 5 in ~55 resets vs 1 in 33 are not
distinguishable with these counts).  In the stuck state the machine clock and the Amiga's vsync run
(49.920128 Hz), the flicker-free loop no longer dithers (ascal's write address does not move: the
frame buffer is not being written), and the HDMI audio is silent.  With the debug pages of the
final build (`stallmon.py probe`) the frozen state was caught again (first reset after the
determinism test): **the Amiga runs** (chip/slow-RAM writes ~300,000 per second, no reset asserted,
Kickstart working out of slow RAM) while the HDMI picture stays frozen; likewise the two "Kickstart
3.1 does not boot" results of an earlier build were this freeze: the CPU was in SysInfo's final
loop.  So it is the video path (ascal's input side or its frame-buffer writes, which no M2M reset
resets: ascal's reset is only the MMCM lock), not the Amiga.  Not resolved here.

## Go / no-go for stage 2 (2 MB chip RAM through the cache on ECS / 68000)

**Go.**  The deciding facts:
- Stalls are invisible in machine time: SysInfo identical under every preset including overload;
  the bus-cycle checksum unchanged over ~63,000 frames with 0.7 us, 0.3-2.5 us and 15 us stalls at
  0.7-5.5 % of real time; phase 2's checksum family reproduced; demos run with 2.4 % stalls.
- The long-term rate is exact (31/32 to 0.00 ppm; 50.000000 Hz with flicker-free over 300 s with
  2.4 % stalls); HDMI showed no dropped or repeated frame below the headroom.
- Timing is easy: CE +30.7 ns slack, Amiga domain +8.4 ns at 29.29 MHz.
Conditions for stage 2, from what was measured here:
1. **More headroom than 3.1 %.**  With flicker-free the effective headroom is 2.9 %, and lag
   tails grow long well before the average reaches it (61 us at 2.4 %, 148 us at 2.85 %).  The
   Amiga domain has 8.4 ns of slack at 34.1 ns, so a faster source clock is cheap: e.g. VCO / 36.25
   = 31.31 MHz (h = 10 %, the study's own suggestion for random CPU reads) needs ~32 ns paths, the
   worst is 24.7 ns today (to be shown again with the cache's 64-bit data RAM).
2. **The miss decision must reach CE combinationally** (tag compare in the tick between address and
   consumer edge); here CE is a register (one tick of latency, fine for injected stalls).  The CE pin
   has 30 ns of slack, so a LUT or two in front of it is no problem.
3. **An audio FIFO** (study 1.4) as soon as real stall clusters reach tens of microseconds:
   15 us stalls already showed measurable waveform jitter.
4. **Dedicated MIG port** with priority over ascal (study C2) - not started here.
5. Everything outside `main_clk` that talks to the Amiga in real time must be listed and moved or
   decoupled (this stage found two the study missed).
Open, not caused by the stoppable clock: the frozen-picture-after-full-reset problem above (phase 2
has it too; ascal stops writing the frame buffer while the Amiga runs) should be understood before
stage 2 puts the cache on the same DDR3 that ascal uses.

Not done in this stage: the fast-RAM write/read test with the stoppable clock (the Zorro II menu
option was not switched on), a key / mouse test under 15 us stalls (the new emulator parameters
are by analysis only), a cleaner audio test signal, the stage-2 simulation groundwork.

# Stage 2 of the A1200 route (branch `a1200-ddr3`, 2026-11-11, in progress)

## A. The frozen picture after a full reset: cause and fix

**Mechanism.**  A full M2M reset (`hold_reset`, a long reset-button press, the demo tool before
every demo) asserts the framework's memory-side reset `hr_rst`: ascal, the framework's Avalon
arbiter and the FIFOs restart.  `avm_mig` (the Avalon -> MIG bridge of this port) is reset only by
"memory not ready" and kept whatever transaction it was in.  If the reset fell into a burst:
- in the middle of a **write burst** (state S_WR, waiting for the rest of the beats), the next
  master's **read** saw waitrequest low (S_WR accepted any request) and was then ignored: the
  arbiter waited for read data for ever, ascal's Avalon master was stuck, the frame buffer was no
  longer read or written (the HDMI output repeats one line buffer: the "white screen with vertical
  lines"), the flicker-free loop stopped dithering (it follows ascal's write address), QNICE's
  DDR3 accesses hung as well -- while the Amiga ran on (stage-1 probes: chip/slow-RAM writes
  ~300,000/s).  No later M2M reset could clear it (avm_mig still not reset), only a new bitstream.
- in the middle of a **read burst**, the remaining beats went to whichever master the restarted
  arbiter granted next (wrong data, or a beat count that never matches).
How often depends on how much of the time avm_mig spends inside a burst when the reset arrives:
measured 1 in 3 to 1 in 33 resets on stage-1 builds, 1 in 33 on the published phase 2.

**Fix** (`avm_mig.vhd`, new input `avm_rst` = the framework's `hr_rst`): a reset aborts the
Avalon transaction without breaking the MIG protocol -- a partly gathered write word is dropped, a
word already handed to the MIG (data + command) is completed, outstanding read words are drained
from the MIG and discarded, waitrequest stays high until the bridge is idle; and S_WR never accepts
a read.  The same change is a separate commit on `qmtech-k325t-cm4` (phase 2).

**Second mechanism: ascal's write request survived the reset.**  With the avm_mig fix the board
still froze after about 1 full reset in 20 (6 of 120, build F), but now the next full reset always
cleared it.  A debug capture on avm_mig's Avalon input (build I, `stallmon.py avm`: the open write
burst's start address, burst length, beats still missing, and when it began) caught one: 1.43 us
after the end of the memory reset a write burst of 64 words began at $4100, 8 words came, 56 never
did, and the next request (a read of 64 words) waited behind it -- 8 words are exactly one 128-bit
beat of ascal, burst length 8 x 8.  `ascal.vhd` resets its Avalon process asynchronously but the
line that clears `avl_write_i` in reset is commented out: a reset during one of ascal's write bursts
held the write request high through the reset.  The memory side (avm_decrease, the arbiter, avm_mig)
leaves reset one clock before ascal's Avalon process (its reset release is synchronised once more):
avm_decrease took the stale request as the first beat of a new burst of 8, the next clock ascal
(now in its idle state) dropped the request, and the burst never got its other 7 beats.  Fix: the
reset clears `avl_write_i` (`M2M-UPSTREAM avl-write-reset`, one line in `ascal.vhd`; also a commit
on `qmtech-k325t-cm4`).  The framework's comment in `clk_m2m.vhd` ("one side can not be reset in the
middle of e.g. a burst transaction") names the rule; the HyperRAM builds may hit the same.

**Proof on the board** (build J = both fixes, Kickstart 1.3, no disk, `hold_reset` 2.2 s, picture
captured 15 s later and classified): **160 full resets, 160 times the insert-disk screen, no
freeze**; the Avalon capture afterwards: bridge idle, every write burst complete.  Before (build F,
avm_mig fix only): 7 freezes in 141 resets; the published phase 2 froze once in 3 boots of the
determinism runs and once in 33 resets earlier.  (The freeze also cost a demo run: the reset before
Enigma.)

**Proof in simulation** (`sim/tb_avm_mig_reset.vhd`: random read / write bursts of 1-128 beats at
random addresses checked against a reference memory, a MIG native-UI model with random ready
signals and 15-60 clock read latency, resets at random moments of a transaction; the masters
abandon their transaction cleanly -- which ascal did not, see the second mechanism): the bridge as it was hangs after 16 resets ("read burst
never completed"); the fixed one runs 400 resets and 1,213 transactions (and, with `G_ARB`, 2,370
line-port lines through `mig_arb.vhd` at the same time) without a hang, a wrong word or a MIG
protocol error.

## B. A MIG port of its own, and the source clock at 31.31 MHz

`mig_arb.vhd` sits between the MIG's native UI and its two clients: the **line port** (64-byte
lines = 4 BL8 commands of 128 bits; reads return the 4 beats in order, writes take 512 bits at
once) and `avm_mig` (the framework's Avalon bus: ascal, the fast RAM, the floppy, QNICE).  The
line port goes first; the only exception is a write `avm_mig` has started (its data is in the MIG's
write FIFO and the command must follow).  In the top a small mux shares the line port between the
chip cache (first) and `lat_meter.vhd`, a latency meter (stall controller page 7, `stallmon.py lat
SECS r|w|rw`): random 64-byte reads / writes in a 1 MB area at 64 MB with a random gap of 0-1023
ui clocks; latency from the request to the last read word (writes: to the MIG taking the 4th
command); 40 ns histogram bins.

Measured (build I; ascal at 720p50 reading and writing its frame buffer all the time; 20 s per
direction, ~3.7 million lines each):

| board, load | read min / median / 99.9 % / max | write min / median / 99.9 % / max |
|---|---|---|
| Radxa rig, ascal only | 290 / 280-320 / 560-600 / 700 ns | 110 / 80-120 / 240-280 / 480 ns |
| Radxa rig, + fast RAM copy loop (8 MB Zorro II, `mk_fastload_adf.py`: 128 KB copied back and forth, the fast RAM's 16 KB cache misses all the time) | 290 / 280-320 / 560-600 / 770 ns | 110 / 80-120 / 280-320 / 510 ns |
| Luckfox rig (build L), ascal only | 290 / 280-320 / 560-600 / 700 ns | 110 / 80-120 / 240-280 / 470 ns |

The two boards (two DDR3 chips) agree to the histogram bin: the numbers are the controller's, not
the board's.  The study's latency set A (dedicated port) was 250 ns + 0-50 ns; the median read
matches, the tail does not: 0.1 % of the reads take 560-770 ns (refresh, page misses, a write in
flight on the other client).  What the Amiga waits for is longer still, because the fill engine is
simpler than the study's: the measured stall per line fill is 0.80-0.82 us for clean lines and
~1.0 us when lines are written back (the write-back goes before the read, not into a buffer),
against the study's ~0.35 us.  For the stall budget: the same miss rate costs ~2.3x the stalled
time the study assumed.  In the A500 configurations that does not matter (C: no misses in steady
state); for the A1200 stage it is the first thing to improve (critical word first, install while
the beats arrive, a write-back buffer).

**Source clock 31.31 MHz** (MMCM VCO 1135 MHz / 36.25 = 31.310345 MHz, h = 10.3 %, machine/source
= 29/32): timing met in every build of this stage (`main_clk` 31.938 ns, intra-clock WNS +2.36 ns;
whole design WNS +0.072 to +0.111 ns, the critical paths are in the MIG's ui_clk domain).
Long-term rates over 120 s windows (`stallmon.py rate 120`, build I):

| | frame rate | machine clock | machine/source |
|---|---|---|---|
| flicker-free on | 49.998854 Hz (-23 ppm vs 50 Hz; a window ends at an arbitrary dither phase) | 28,419,757 Hz | 0.907679 |
| forced native (`stallmon set mode=2`) | 49.920128 Hz (0.00 ppm vs native) | 28,375,000.000 Hz | 0.906250000 = 29/32 exactly |

## C. Chip RAM behind a cache with stall

`chip_cache.vhd` replaces the four chip / slow RAM lanes of `mega65.vhd` with the same 256 block-RAM
tiles (512 K x 16), organised as a **2-way, 8192-set cache of 64-byte lines = 1 MB**, with LUT-RAM
tags (valid, dirty, line) read asynchronously, so that a miss is known in the same source clock
tick and reaches the stall controller's CE combinationally (`miss_i`: `ce_o = ce and not miss_i`,
the tick refunded to the DDS: machine time does not move).  Port A (Amiga, source clock) reads and
writes on a hit; port B (ui_clk) installs fills and reads victims for write-back; a toggle
handshake carries the request.  Backing store: DDR3 from 64 MB (`G_DDR_BASE`), chip at 0, slow
RAM above it.

Modes, chosen at a full reset (stall controller register 7: b1 cache on, b2 2 MB chip, b3 and
register 0 b3 = shrink; `stallmon.py cache on|off [SHRINK] [chip2m]`):
- **identity (default)**: the tiles are addressed exactly as phase 2's chip and slow RAM; no tag
  lookup, `miss` is constant 0, nothing goes to DDR3.  **This is the cycle-equivalent A500 mode:
  chip and slow RAM ARE block RAM, read in one cycle as on phase 2** -- exact because it is phase
  2's memory path, shown bit for bit below.
- **cache**: chip and slow RAM in DDR3, the tiles are the cache.  Exact by a different argument: a
  miss stops the Amiga's clock before the access edge, the machine sees the data in the same
  machine cycle as from block RAM; only real time stretches.
- **shrink** 0-3 masks the set index: 8192 / 1024 / 128 / 16 sets = 1 MB / 128 KB / 16 KB / 2 KB.
- **2 MB chip** (cache mode only): the 2 MB Agnus configuration (ECS forced, `amiga_config.vhd`
  chip2m), slow RAM off; 2 MB of DDR3 compete for the 1 MB cache.

Deviations from the study, deliberate for this stage: 2-way instead of 3-way and 1 MB instead of
1.5 MB (the 256 Amiga tiles were what was free); **no prefetchers yet** (in the A500 configurations
everything fits, nothing to prefetch; they come with the A1200 chip RAM); Kickstart stays in block
RAM; write misses stall (write-allocate with fill) instead of a write-back buffer; replacement is
"the other way" (pseudo-random), not LRU.

Simulation (`sim/tb_chip_cache.vhd` with `sim/mig_model.vhd` and the real `stall_ctrl.vhd`): 100,000
random chip / slow accesses against a reference memory, identity mode and cache mode at each shrink
level: 0 wrong reads, the same 409,020 machine ticks in every run (stalls invisible), fills /
write-backs 7,084 / 323 (1 MB) up to 7,702 / 6,989 (2 KB).

**Chip RAM test on the board** (build H; `mk_chiptest_adf.py`: pattern = address xor constant over
all chip RAM from $1000 to MaxLocMem, all written before any is read, inverted every pass):

| configuration | passes | errors | fills / write-backs per 20 ms, stalled time |
|---|---|---|---|
| identity, 512 K + 512 K | 7 in 20 s | 0 | - |
| cache 1 MB | 7 in 20 s | 0 | 0 after the boot (everything resident) |
| cache 128 KB | 7 in 20 s | 0 | 115.5 / 55.8, 0.60 % |
| cache 16 KB | 7 in 20 s | 0 | 198 / 63, 0.96 % |
| cache 2 KB | 7 in 20 s | 0 | 346 / 71 |
| 2 MB chip (Kickstart 3.1, ECS), cache 1 MB | 3 in 40 s | 0 | 92 / 39, 0.47 % |
| 2 MB chip, cache 16 KB | 3 in 40 s | 0 | 197 / 3.4, 0.81 % |

The same number of passes = the same machine time.  SysInfo with 2 MB (Kickstart 3.1): "MaxLocMem
$200000 (2048 KB chip)", one MemHeader $000420-$200000, Agnus ECS, and its own screen displayed by
bitplane DMA from $1F0000 (the top of the 2 MB).  A demo that needs more than 1 MB of chip RAM was
not available on the card (the five test demos need 512 K + 512 K).

**Machine-time determinism.**  The determinism test now starts in a fixed state.  The E clock (CPU
/ 10) runs free from reset and a PAL frame is 71,051 colour clocks = 1 mod 5, so the E phase
against the beam differs from frame to frame, and the boot block used to start in a frame that
depended on how long the (real-time) disk load took: that gave the two checksum families of stage
1.  The test (`mk_stalltest_adf.py`, row 12) now waits for the frame whose E phase is 0 (a CIA
access at line $10, then the beam position mod 5) and switches the audio DMA on at the copper
interrupt; rows 10 / 11 record the beam at the start and end of the 50-frame E-clock window.
Every boot since then:

| bitstream / setting | boots | checksums even / odd | mismatching frames | entry | E-clocks in 50 frames |
|---|---|---|---|---|---|
| phase 2 (`qmtech-k325t-cm4`, 11bf756) | 2 (+1 frozen at the mount reset: the bug of A) | 27dbf6f3 / 0c253188 | 0 | $407E | 710,511-710,512 |
| phase 2 with both reset fixes (aaf096b) | 3 | same | 0 | $407E | same |
| build I, identity | 3 | same | 0 | $407E | same |
| build I, cache 1 MB | 3 | same | 0 | $407E | same |
| build I, cache 128 KB | 3 | same | 0 | $407E | same |
| build I, cache 16 KB (the machine at ~51 % of real time) | 3 | same | 0 | $407E | same |
| build I, cache 2 KB | 2 (+1 lost: the menu missed the Return key) | same | 0 | $407E | same |
| build I, 2 MB chip, cache 1 MB | 2 (+1 lost: menu) | same | 0 | $407E | same |
| build I, 2 MB chip, cache 16 KB | 3 | same | 0 | $407E | same |

One value everywhere.  The E-clock count is the window's length in colour clocks / 5 + 7.6-7.8 (the
few instructions between the beam reads and the timer start / stop).  The earlier 702,081-706,051
readings (stage 1, also on the phase-2 bitstream, and the first runs of stage 2) belong to the old
start and are not a machine effect: the E clock is a free-running /40 divider of the gated clock
(`amiga_clk.v`), nothing outside the machine clock feeds the CIAs.  The explanation that fits the
numbers (not separately proven): the old test started the copper with COPJMP1 at the takeover
moment; when that was after line $40, the copper's WAIT $40 was already past, its interrupt came
right after the INTREQ clear, the "sync" STOP woke at once and the 50-frame window started mid-frame
(short by a takeover-dependent 0.31-0.59 frame).  "Other entry positions" (0 / 127-129 / 256 by
boot) is a running count of a deterministic per-frame pattern read at slightly different frame
numbers (1,308-1,321), not a variation of the machine.

**Five demos with the chip RAM in DDR3** (build J, cache 1 MB, Kickstart 1.3, 512K + 512K,
flicker-free on; `aexp_demo_test.py`): SOTA, Enigma, Arte, Eon (2 disks) and Batman Rises (2 disks)
ran through; every sampled frame (every 10 s) differs from the one before (14, 14, 17, 32 and 41 of
44 distinct; Batman's equal ones are its waiting and black screens).  Stall statistics in 30 s
windows over the whole run: 40 windows with 0 stalls; the others hold a boot (16,383-16,385 fills
= every line once, 0.80 us each) or the 262 us flush at a full reset.  A 120 s HDMI clip of the
determinism test in cache mode (`frame_counter_clip.py`): 6000 frames, 6000 decoded, the counter
advanced by exactly 1 from each frame to the next, 0 mismatching frames.  (An earlier run on build
H lost Enigma to the reset freeze of A; not counted.)

**Audio FIFO: not built.**  In the A500 configurations the full cache holds all of chip and slow
RAM: after the boot's first touch of every line (16,384 fills = 13 ms of stall, during Kickstart's
memory clear, before any sound) there are no misses at all.  Stall clusters beyond stage 1's
inaudible level exist only with the artificial small caches (16 KB / 2 KB: the machine falls
behind real time; test settings).  The FIFO belongs to stage 3, where 2 MB chip RAM and a faster
CPU make misses normal.

**Where the stage-2 numbers come from.**  A crash of the build PC (2026-11-11 22:02) emptied /tmp,
where the raw data of part of this stage lived.  Kept on disk (`ext/aexp5_stage2/logs` in the
harness tree): the 160-reset proof of build J, the build-F loops, the build-I determinism table and
the phase-2 runs, the latency and rate measurements, the testbench logs, the Luckfox runs and the
flash-slot checks.  Reported from the numbers written down at the time only (raw logs lost): the
build-H chip-test table above, the build-J demo run and HDMI frame-counter clip, the phase-2-fix
155-reset loop, its SysInfo comparison and 3 determinism boots (the demos of the phase-2 fix and
the flash checks were run again after the crash), and the m65io monitor-client test.

## D. Resources, timing, and what stage 3 needs

Build J (all of the above with the debug captures): timing met, WNS +0.072 ns, WHS +0.027 ns.
436 / 445 block RAM tiles (no new block RAM: the cache data RAM is the former chip / slow RAM),
57.3 k LUTs (phase 2: 44.2 k), of which 16.6 k LUT RAM (most of the growth: the cache tags,
2 x 8192 x 18 bits), 34.1 k registers.

Stage 3 (AGA + 68020) needs from this stage: the cache with stall (done, exact, 2 MB chip shown);
a faster fill path (critical word first, install while the beats arrive, write-back buffer:
0.8-1.0 us per miss today); the prefetchers from the Agnus / Alice registers (not built); the
audio FIFO; and block RAM for AGA (palette, wider fetch) -- 9 tiles are left, so the Kickstart
(64 tiles today, 128 for 512 KB) should move into DDR3 behind the cache.

## E. The second board (Luckfox rig: Luckfox Core3566, Digilent JTAG, no HDMI capture)

Build L2 (`K325T/build.sh` without argument: the Luckfox pin variant of the same design, with the
result mailbox: the Amiga's writes to $C0-$FF are readable through the stall controller's page 7,
`stallmon.py mbox`; the test disks copy their result rows there).  Everything below was read
through the bridge -- the rig has no picture.  A PC-side watchdog pinged the module every 2 s
(second channel: adb over the carrier's mini-USB cable) and would have reloaded the MEGA65
bitstream over JTAG after 3 misses; it never had to.

- **DDR3 line latency** (build L): the same numbers as on the Radxa rig, to the histogram bin (B).
- **Determinism** (stalltest3.adf, Kickstart 1.3, full reset + mount per boot), 38 boots: identity
  x 8, cache 1 MB x 8, 128 KB x 7, 2 KB x 4, 2 MB chip with 1 MB / 128 KB / 2 KB cache x 4 / 3 / 4
  (six of the 128 KB boots were meant as 2 KB: `stallmon.py mbox` cleared register 0, fixed):
  every boot 27dbf6f3 / 0c253188, 0 mismatching frames, entry $407E, E-clocks 710,511-710,512 -- a
  second board and a second DDR3 chip give the same machine.  With the 2 KB cache the machine ran
  at about half of real time (~650 frames in the window instead of ~1,335): same values.
- **2 MB chip RAM test with the 2 KB cache** (Kickstart 3.1, ECS, build L; `chipt60.adf`): 187
  passes over 2 MB in 37 minutes, 0 errors; ~347 line fills and ~70-80 write-backs per 20 ms,
  1.55-1.6 % of real time stalled, 0.91 us per fill.
- **Full resets with the bus probes** (build L2, `aexp5_lf.py resets`): 100 full resets; after each
  the Avalon capture read twice, 2 s apart: never the same open write burst with beats missing
  (the frozen-bus signature), and ascal had written bursts since the reset every time: 100 / 100
  ok.  (32 more with a single read before that: no repeated state either.)
- **Soak**: 2026-11-12 01:37-07:37, the 2 MB chip RAM test with the 2 KB cache (chiptest2.adf,
  KS 3.1, build L2), read every minute through the mailbox: **1,805 passes over 2 MB in 6 hours, 0
  errors**, 346-350 line fills per 20 ms, 1.55-1.6 % stalled throughout
  (`ext/aexp5_stage2/logs/luckfox/chip2m_2k_soak.log` in the harness tree).  The PC-side watchdog
  (ping every 2 s, ssh and adb uptime every minute) saw no miss and no gap in the module's clock.

Not checkable without a picture: HDMI (ascal output, flicker-free behaviour, the frozen-picture
symptom itself -- the reset check reads the Avalon bus instead), the demos.

The Luckfox module stalled once (kernel included, 2026-11-11 21:17:03-21:53:34, monotonic clock
running, no log entries at all) while it ran the MEGA65 core, eight minutes before build L was
first loaded; not caused by this design (the FPGA drives only SPI MISO towards the module; BCM14/15,
the module's debug console, are unconstrained pins with UNUSEDPIN PULLUP in both cores, so the
console RX idles high).  That module also re-probes its empty SD slot (mmc3) twice a second.

# Stage 2b: the cache grown up (branch `a1200-ddr3`, 2026-11-12)

Bitstream of record: build P (`ext/aexp6_stage2b/aexp6_buildP_radxa.bit` in the harness tree, md5
215843c0...; commits up to 085136a): timing met, WNS +0.080 ns (MIG ui_clk), `main_clk` +1.99 ns;
438 / 445 block RAM tiles (the cache 384, the audio FIFO 2), 79.5 k LUTs of which 33.6 k LUT RAM (the
three 22-bit tag arrays, each read twice: the access and the prefetcher), 37.1 k registers.

## 1. The AGA agent's cache changes

Taken from `a1200-aga`: the data RAM 64 bits wide with the AGA `chip48` output (821c130) and the
68EC020's 32-bit write (cb0f9b1), plus a guard (12a5f16: the second word only for an even word
address; the lane was computed modulo the 64-bit group).  Not taken: f1fcf48 (chip48 into minimig,
the AGA switch) -- it depends on that branch's TG68K and Minimig patches; it also used stall register
7 bit 0, which is the statistics-clear toggle (to be moved).  tb_chip_cache in every mode, and on
the board (build N) the A500 identity mode: 27dbf6f3 / 0c253188 in every boot.

## 2. Fill path

Critical word first (mig_arb: the 4 commands of a line start with the 16-byte word of the missing
access), each word installed into the data RAM as it arrives, the tag written when the request goes
out and an access to the filling line waiting only for its own word (a Gray-coded beat count from
the ui_clk side), the dirty victim read into a write-back buffer while the MIG fetches and written
back after the fill.  **Stall per fill: 0.42 us** (chip test at 128 KB, 16 KB, 2 KB and with 2 MB
chip; was 1.04 / 0.97 / 0.91 us), mean of stall ticks over fills (the stall controller has no
per-stall histogram; the read latency median of the MIG port is 0.28-0.32 us).  With the 2 KB cache
the determinism workload runs at ~68 % of real time instead of ~51 %.

## 3. Kickstart in DDR3; the cache 3-way, 1.5 MB

The Kickstart BRAM is gone: QNICE device 0x0100 writes the ROM through a load port of the cache
(byte by byte, the QNICE held while a byte is handed over; 64-byte lines into DDR3 at backing words
1.25 M..1.5 M).  Its 128 tiles join the cache: 3 banks of 512 KB, bank = way.
- **Identity mode (A500)**: chip / slow RAM in banks 0 / 1 exactly as before (no tags, no stall);
  the Kickstart direct-mapped in bank 2, each line fetched at its first use (a stall; once per line
  after a full reset).  Same machine as phase 2: 27dbf6f3 / 0c253188 (3 boots), SysInfo with KS 1.3
  identical to phase 2's; KS 3.1 (512 KB) boots and SysInfo shows the same values in identity and
  cache mode.
- **Cache mode**: 3-way set associative, 8192 sets, 1.5 MB; replacement: an invalid way, then a
  Kickstart line (clean, cheap to fetch again -- the study's rule), else pseudo-random.
- What AGA gets: 1.5 MB / 3-way in front of 2 MB chip + 512 KB ROM -- the size the AGA model found
  sufficient with prefetchers (worst 1.13 % stalled); no further block RAM is free (7 tiles).

## 4. Prefetchers

Minimig patch 0002 exports Agnus' bus grant and the DMA slot's target register with every RAM
access; the cache derives the class (bitplane, sprite, audio, disk, copper, blitter, CPU) and the
stream (the target register; the CPU is one stream).  A stream entering a new line queues its next
line (the previous one when it walks down); queued lines are fetched when the tag port and the
engine are free and no demand miss waits.  Per class an enable bit (`stallmon.py pf MASK`) and
counters: issued, useful (first demand use), wasted (evicted unused).  Not built: the copper's
COP1LC restart and the blitter's precomputed sequence (the stream rule covers them from their second
line on).

Machine time: the determinism test at 24 KB (shrink 2) with the enables 0, 1, 2, 4, 8, 16, 32, 64
and 127: **27dbf6f3 / 0c253188, 0 mismatching frames, every combination.**

| workload, cache | prefetch | demand fills | stalled | hit rate (useful / issued) |
|---|---|---|---|---|
| chip test, 24 KB | off | 163.8 / 20 ms | 0.343 % | - |
| chip test, 24 KB | CPU only | 55.4 / 20 ms | 0.116 % | CPU 75 % |
| chip test, 24 KB | all | 3.4 / 20 ms | 0.007 % | CPU 79 % |
| five demos, 192 KB (66 windows of 20 s) | off | 123.8 / 20 ms (max 1865) | 0.259 % (max 3.9 %) | - |
| five demos, 192 KB | all | 48.2 / 20 ms (max 1230) | 0.101 % (max 2.6 %) | bitplane 96 %, sprite 89 %, audio 92 %, disk 99 %, copper 93 %, blitter 98 %, CPU 58 % |
| determinism workload, 24 KB | off / all | 14,335 / 20 ms | 30.0 % | bitplane 27 %, blitter 88 %, CPU 64 % |

The determinism workload at 24 KB thrashes (its working set is several times the cache): prefetch
cannot help there and wastes most of its bitplane fetches -- capacity misses are not what
prefetchers fix.  Where the misses are first touches of streams (the chip test, the demos), they
remove 60-98 % of the demand fills.  The five demos ran through with prefetch off and on (stills
every 10 s, all distinct where the demo moves).  The monitor's lag maximum is kept since the last
full reset and sits at the cap (18.5 ms) in both runs, as it did in stage 2 with the full cache and
no stalls between boots: it is reached while Kickstart clears memory after the reset (every line a
first touch), not during the demos.

## 5. Audio FIFO

`audio_fifo.vhd`: Paula's level sampled every 128 machine ticks into a 2048-sample FIFO and played
on the ungated source clock when (machine ticks + lag) reaches each sample's slot plus 256 samples
(1.15 ms latency).  The framework takes the audio from the core's ungated clock (M2M-UPSTREAM
audio-src-clock: `G_AUDIO_EXT_CLK`).  On / off at run time (`stallmon.py pf MASK afifo`).
`sim/tb_audio_fifo.vhd`: random stalls of 3-400 ticks with catch-up -- 3000 samples in order, every
one on the real-time grid.

On the board, the 976.6 Hz tone of the determinism disk recorded from the HDMI dongle
(`tone_analyze.py`, flicker-free on, identity mode):

| stalls | audio | short-term phase jitter (RMS / max) | residual |
|---|---|---|---|
| none | direct / FIFO | 4.9 / 34.6 us, 4.3 / 31.0 us | 0.9 / 0.9 dB (flicker-free's pitch switches dominate) |
| 14.3 us x 21 per frame (1.5 %) | direct / FIFO | 4.1 / 33.9 us, 3.8 / 30.1 us | -- |
| 0.64 us x 1730 per frame (5.5 %) | direct / FIFO | 3.4 / 29.1 us, 3.2 / 18.8 us | -- |
| **229 us x 2.6 per frame (3 %)** | **direct** | **74 / 378 us**, tone amplitude down to 30 % | +13.6 dB |
| **229 us x 2.6 per frame (3 %)** | **FIFO** | **4.2 / 35.3 us** (as without stalls) | -1.5 dB |

Stalls up to ~15 us are below the dongle's measurement floor with or without the FIFO (stage 1's
"inaudible"); long stall clusters break the tone without the FIFO and are invisible with it.  Cost:
1.15 ms of audio latency, 2 tiles; harmonics with the FIFO -57 dB instead of -62 dB (the 221 kHz
sample-and-hold; a faster rate would need 4-8 tiles, not free).

## 6. The second board (Luckfox rig, build L3 = build P with Luckfox pins, no picture)

- Kickstart 1.3 from DDR3 boots (2,238 line fills, as on the Radxa).
- Determinism (stalltest3.adf, read through the mailbox), 9 boots: identity x 3, cache 1.5 MB x 2,
  24 KB with prefetch off x 1 and all x 2, 2 MB chip with 2 KB cache and all prefetchers x 1:
  27dbf6f3 / 0c253188, 0 mismatching frames, E-clocks 710,511-710,512 every time.
- Chip test at 24 KB: 0.42 us per fill; demand fills 164.1 / 20 ms without prefetch, 3.5 with all
  prefetchers (the Radxa: 163.8 / 3.4).
- Line latency: the same distribution as before and as on the Radxa (read median 280-320 ns).
Not checkable there: HDMI, the audio FIFO's sound, the demos.

# 68020 (TG68K) back in the core (2026-11-11, branch `cpu-tg68k`)

Increment 5 of the phase-2 table: MiSTer's TG68K is instantiated again in `cpu_wrapper.v` and
selected at run time in the "Amiga Hardware" submenu (CPU radio: **68000** = fx68k, default,
unchanged / **68020** = TG68K).  The change is generic (nothing machine-specific beyond the
68020), so other lines can take it as it is.

## What changed

- `cpu_wrapper.v` (patch `patches/Minimig_MiSTerMEGA65/0002-cpu_wrapper-tg68k-68020.patch` on
  top of 0001): MiSTer's `TG68KdotC_Kernel` instance (same generics) and MiSTer's cpu-port
  outputs (`ramaddr`, `ramlds`/`ramuds`, `ramdin`) are back; the instance moved below the chip
  bus FSM (Vivado rejects Quartus's forward references), `ipl_autovector` is `1'b1` (a 32-bit
  constant on a VHDL `std_logic` port fails elaboration).  `ramsel` stays "autoconfigured Zorro
  RAM only" (no turbo chip/kick: `cachecfg` = 000; `$DD`/`$02` accesses keep going to the chip
  bus, which always acknowledges).  With `cpucfg` = 00 the muxes select the fx68k signals
  exactly as before.
- `main.vhd`: `cpucfg` is taken over from the menu only while minimig holds the CPU in reset;
  the fast RAM port now takes the selected CPU's bus from cpu_wrapper's cpu-port outputs
  (`cpustate` = 11 is a write; for the fx68k these are the same /AS, R/W, /UDS, /LDS and data
  as before).  `amiga_config.vhd` sends the CPU type in userio command 0xF4 (minimig uses it
  for the IDE timing only).
- `amiga_fastram.vhd`: the address is now the DDR3 word address (27 bits, the parent maps the
  windows: Zorro II 8 MB at 16 MB as before -- a different but one-to-one placement inside it
  --, Zorro III 128 MB in the upper half of the DDR3); tags 14 bits.  `pulse_i` selects the
  TG68K handshake: an access starts on `sel_i` alone, `ready_o` is high for exactly one clock,
  and a read hit may be answered while a posted write to another word is still on its way to
  DDR3.  For the fx68k (`pulse_i` = 0) the behaviour is unchanged (the testbench's 68000 run
  gives the same hit/miss counts as before).
- Menu: "128 MB Z3 (68020)" in the fast RAM radio (MiSTer's 128 MB Zorro III board; with the
  68000 it becomes the 8 MB Zorro II board, as on MiSTer), CPU radio 68000 / 68020; any change
  cold-boots the Amiga (`amiga_cold_boot` topology vector, 7 bits).  OPTM_SIZE 93, so the
  settings file is `/amiga/aexp020.cfg` (93 bytes; phase 2's `aexpk325.cfg` stays untouched);
  the menu heap still fits (1465 of 1536 words).
- `build.tcl`: Vivado jobs from `VIVADO_JOBS` (default 4).  `build.sh`: the submodule patches
  now stack (files rebuilt from HEAD + all patches; see README).

## The CPU boundary of cpu_wrapper (what any CPU behind it must do)

Everything runs in the 28.375 MHz core clock `clk`.  A CPU other than the fx68k is connected
like the TG68K:

- **Bus request**: the CPU drives `addr` (32 bit), `busstate` (00 fetch, 10 read, 11 write,
  01 no access), `nWr`, `nUDS`/`nLDS` (byte lanes for a 16-bit data bus; a longword is two
  word accesses), `data_write` -- all stable from the start of the access until it is
  acknowledged.  `cpu_req` = `busstate` /= 01.
- **Acknowledge**: one clock enable, `clkena_in = ~cpu_req | chipready | ramready |
  fastchip_ready`: the CPU stands still while it requests and nobody acknowledges; read data
  (`data_in`) is valid in the clock where the enable is high, and the CPU presents its next
  request in the clock after it.  Each responder must answer with a **one-clock** pulse.
- **Chip bus** (chip RAM, Kickstart in block RAM, custom chips, CIAs): the falling-edge FSM in
  cpu_wrapper turns a request that neither `ramsel` nor `fastchip_selack` claims into a 68000
  bus cycle synchronised to the 7.09 MHz phases (`ph1`/`ph2`): /AS at a ph1 edge, data and
  /DTACK sampled two phases later, `chipready` for one clock afterwards.  The decision uses
  `chipreq`, registered one clock after the request appears, so a claim (`ramsel`,
  `fastchip_selack`) must be combinational from the address in that first clock.
  Interrupts: `ipl` from the chip bus, registered at ph2; `ipl_autovector` = 1.
- **Fast RAM / cpu port** (`ramsel`, `ramaddr`, `ramuds`/`ramlds`, `ramdin`, `ramdout`,
  `ramready`; write = `cpustate` 11): `ramsel` is combinational from the address (Zorro
  windows after autoconfig); the parent answers with `ramready` (one clock, TG68K) and
  `ramdout`.  Here `amiga_fastram` serves it from DDR3 through a 16 KB cache: a hit takes 3
  clocks from the request (IDLE, READ, SERVED), a miss a line fill (8 words, ~20-40 memory
  clocks), writes are posted (1 clock + waiting for the previous write's completion).
- **Fast chip port** (`fastchip_sel` for every request below 16 MB, `fastchip_selack`
  combinational, `fastchip_ready`, `fastchip_dout`): free for I/O devices of a machine
  variant (MiSTer used it for its 32-bit chip RAM).
- Control registers the wrapper reads from the CPU: `vbr` (NMI vector address for HRTmon),
  `cacr` (turbo chip/kick only with data cache bit), `nresetout` (RESET instruction).

## Measured (simulation; board figures below)

`sim/cpu020/run.sh` (Vivado xsim, mixed VHDL/Verilog): cpu_wrapper with both CPUs, the real
`amiga_fastram` and a behavioural chip bus (/DTACK one 7 MHz cycle after /AS) and DDR3 model,
running `prog.s` (autoconfig of the Zorro II or III board, a 1024-longword pattern test, byte
and word writes, a routine copied to fast RAM and run there; with the 68020: MULU.L/DIVU.L/
MULS.L 64-bit, BFEXTU, EXTB.L, scaled index, MOVEC VBR + TRAP through a table in fast RAM):
`TB_CPU020_PASS` for fx68k + Z2, TG68K + Z2 and TG68K + Z3.  2048 DBRA iterations: fx68k
82,216 clocks from ROM and from fast RAM (= 20,480 68000 cycles, exact); TG68K 98,576 clocks
from ROM (the chip bus FSM: one 7 MHz bus cycle per word, slower than the 68000's
prefetch) and **18,648 from fast RAM (4.4x the 68000)**.
`sim/tb_amiga_fastram.vhd`: PASS with the fx68k handshake (unchanged hit/miss statistics) and
with `-gG_PULSE=true` (back-to-back requests, ready exactly one clock).

## Measured on the board (Radxa CM3 carrier, JTAG, 2026-11-11)

Build: timing met (WNS +0.181 ns, WHS +0.052 ns), 48.8 k LUTs (+4.6 k for the TG68K and its
bus), 436 RAMB36 (unchanged), 74 DSP48.

- **68000 unchanged**: SysInfo (`sysinfo.adf`, byte-identical to phase 2's disk) in the default
  A500 configuration (KS 1.3, 512K+512K, OCS) and with ECS + 8 MB Zorro II fast RAM: decoded
  rows identical to the captures of the flashed phase-2 core (`aexp2_si_flash_default`,
  `aexp2_si_flash_ecs_fast8`), and 0 pixels differ by more than 64 grey levels.  DBRA loop 45
  lines, longword reads 65 (chip) / 71 (fast) lines, fast RAM test 0 errors.
- **68020**: Kickstart 3.1 (40.063) boots to its insert-disk screen; SysInfo: exec 40.10,
  AttnFlags `$0003` (68010 + 68020), 8 MB Zorro II board at `$200020-$A00000` found, fast RAM
  pattern test 0 errors.  2048 DBRA: 10 raster lines with the code in fast RAM (68000: 45,
  4.5x), 54 lines with the code in chip RAM (the TG68K's word fetches through the 7 MHz chip bus
  are ~20 % slower than the 68000's prefetch); 2048 longword reads from fast RAM with the loop
  in fast RAM: 17 lines (68000: 71).
- **68020 instructions** (`mk_sysinfo_adf.py --x020`): MULU.L/DIVU.L/MULS.L 64-bit, BFEXTU,
  BFFFO, BFINS, EXTB.L, scaled index, memory indirect, CAS.L, CMP2.L, PACK, LINK.L/UNLK, CHK.L
  pass (14 of 15; the 15th, MOVEC CACR, was run in user mode and took the privilege trap --
  the disk now reports it as not run).  All 15 pass in simulation (`sim/cpu020`).
- **Demo regression** (68020 build, 68000 default configuration, KS 1.3, `tools/aexp_demo_test.py`):
  State of the Art, Enigma, Arte, Eon (disk 2 at its prompt) and Batman Rises (disk 2) run through;
  sampled frames identical to phase-2 runs at some sample points (SOTA 3-4/14, Enigma 6/14, Arte
  14/17, Eon 13/32, Batman 8/44), as between two phase-2 runs (the menu-driven start jitters).
- Not verified on the board: the 128 MB Zorro III board (SysInfo's pattern test over all 128 MB
  had not finished after 75 s; whether it is slow or hangs is open).

# Stage 3 groundwork: AGA + 68EC020 in simulation (branch `a1200-aga`, 2026-11-11)

Prepared on top of the committed head of `a1200-ddr3` (stage 1 + the stage-2 reset fixes) plus the
68020 commit of `cpu-tg68k` (cherry-picked), so that it merges onto stage 2 when that lands.  No board,
no Vivado: Verilator 5.054, GHDL 5 (TG68K -> Verilog), FS-UAE 3.1.66 (distribution package).

## The bench (`sim/aga/`)

`build.sh` builds the A1200 DDR3 study's trace bench from this tree's Minimig (submodule + K325T
patches, three simulation-only race fixes applied to a copy) with the TG68K translated by
`ghdl --synth --out=verilog` (same generics as cpu_wrapper's instance; `tg68k_wrap.v` gives it the
lower-case port names).  cpu_wrapper's CPU comes from the 0xF4 config word as in MiSTer (0 = fx68k,
3 = TG68K 68020).  Memory: 2 MB chip RAM as an ideal 1-tick memory, `chip48` modelled like MiSTer's
SDRAM burst.  Options of `obj_dir/tb`: `--kick` (256/512 KB, read in place), `--chipset 0x10` (AGA),
`--mem 0x03` (2 MB chip), `--cpu`, `--preload FILE ADDR` + `tools/mk_agatest.py`'s boot ROM (no
Kickstart needed), `--shot/--shot-frames` (PPM, rows from Denise's syncs), `--px28`, `--dump`,
`--stop ADDR VALUE`, `--out` (access trace for the cache model), `--cputrace`, `--save/--restore`.
`mister/build_mister.sh` builds MiSTer's own full-system simulation (Minimig-AGA_MiSTer master
`7d5d3c2`, read-only clone copied to the scratch area) with a video tap and the same preload/stop
options, so that every payload also runs on MiSTer's current chipset, cpu_wrapper and 68EC020 model.
Speed: ~2.2 s per frame (ours with the TG68K), ~6 s per frame (MiSTer's full system).

Found on the way: the study's bench registered `chip48` on every tick, so by the time Denise copies
it (clk7n_en, two ticks after the 16-bit word) it held the *next* slot's words.  Every FMODE 1-3
picture was wrong in that bench (the study only counted traffic, so its numbers stand).  The
SDRAM controller holds its `chip48` registers for the whole slot; the bench now latches them at
the clk7_en edge where Denise takes the 16-bit word (see the interface spec below).  Also: MiSTer's
own system simulation has the same copper race as ours (`agnus_copper.v` blocking assignments in
separate clocked blocks): without the fix the copper never starts there either.

## Results: Kickstart 3.1 boot and the AGA checks

**Kickstart 3.1 (40.068, the A1200 ROM) with AGA + TG68K 68020 + 2 MB chip boots to the insert-disk
screen** (first drawn between frame 200 and 250 of the run; frames 250-400 identical apart from the
animation).  The access trace of this boot (frames 1-400, 16.4 M accesses) feeds the cache model.

AGA tests (`tools/mk_agatest.py`, own code; every test is one still picture of 16 x 16 blocks whose
24-bit colours follow from the documented register semantics; the checker samples every block and,
for HAM8, every pixel of the modify sequence):

| test | what | ours (AExp + K325T patches) | MiSTer master (full system) | FS-UAE 3.1.66 (A1200, KS 3.1, from the ADF) |
|---|---|---|---|---|
| pal256 | 8 planes lores FMODE 0, 256 colours via BPLCON3 banks 0-7 + LOCT | 256/256 | 256/256 | 256/256 |
| fmode1 / fmode2 | the same with 32-bit fetches, DDFSTOP $C8 | 256/256 each | 256/256 each | 256/256 each |
| fmode3 | 64-bit fetches, DDFSTOP $B8 | 256/256 | 256/256 | 256/256 |
| ddf3c | fmode3 with DDFSTRT $3C (4 CCK off the 32-CCK fetch grid): the picture moves 8 lores px | moves 8 px | moves **64 px** (one 32-CCK fetch unit) | moves **64 px** |
| hires8f3 | 8 planes hires FMODE 3 (640 px) | 256/256 | 256/256 | 256/256 |
| xor | BPLCON4 BPLAM = $A5 from block row 8 (copper) | 256/256 | 256/256 | 256/256 |
| ham8 | HAM8 (planes 1-2 control), palette + B/R/G modify, low 2 bits kept | 256/256 blocks, 1024/1024 pixels | 256/256, 1024/1024 | 256/256, 1024/1024 |
| spr16 / spr32 / spr64 | 8 sprites, FMODE sprite width 16/32/64, BPLCON4 ESPRM=4 / OSPRM=9 colour banks | 8/8 each (width, height, colours) | 8/8 each | 8/8 each |

One mismatch: **ddf3c** -- with FMODE 3 and a DDFSTRT that is not on the 32-CCK fetch grid, this
tree starts the fetch 4 CCK later (picture 8 px right), MiSTer master and FS-UAE start one whole fetch
unit later (64 px right).  The two references are not independent (MiSTer's #278, "FMODE 1/2/3
fetch that does not start on the 8 or 16 pixel step ... now matching WinUAE", Turrican 2 AGA, was
made to agree with WinUAE), but both differ from ours, and #278 is the fix to take.  The test's own
expectation (8 px) was a guess, not documentation: the public AGA documents do not say what the
hardware does here, and nobody here has a real A1200 to settle it.  Everything else agrees with the
documented semantics in all three.  What the tests do not
cover, and where MiSTer master differed from AExp's base (`eb7a26e`, 2026-06-03; ~90 commits since,
none of them in this tree at the time; stage 3 below ports them): AGA fine positioning (35/70 ns bits of DIWHIGH and SPRxCTL, MiSTer #259,
#260; 64-pixel sprites moved by the copper with them, Flink, #286), HBSTRT/HBSTOP fine bits (#261),
a BPLxPT write right before its fetch (#262), FMODE 1-3 fetches that do not start on the 8/16-pixel
step (Turrican 2 AGA, #278), BPLAM up to the last pixel of the window (`c1f14c3`), the final D write
of a blit before the CPU with AGA (`6e84afe`), VHPOSR one colour clock high (#234), the DMA slot grid
(#232/#239/#241), the 68EC020 timing model (#276, `09226f7`, below).  Unaligned FMODE 1-3 pointers:
MiSTer (and this bench) deliver the words in SDRAM burst order (wrapping inside the 64-bit group);
WinUAE says the real behaviour "is not simple masking" (changelog 3.5.0b7) -- unknown, not tested.

## The wide-fetch interface the stage-2 cache must offer (chip48)

Who wants what (Minimig RTL, `denise_bitplanes.v`, `denise_sprites_shifter.v`, `agnus_bitplanedma.v`,
`agnus_spritedma.v`):

| DMA | FMODE bits | data per slot | pointer step | Denise takes |
|---|---|---|---|---|
| bitplanes | BPL32/BPAGEM = 00 | 16 bit (`ramdata_in`) | 2 bytes | `data16` only |
| bitplanes | 01 or 10 | 32 bit: word A + `chip48[47:32]` = word A+1 | 4 bytes | `{data16, chip48[47:32]}` |
| bitplanes | 11 | 64 bit: word A + `chip48[47:0]` = words A+1..A+3 | 8 bytes | `{data16, chip48}` |
| sprites (data and the POS/CTL fetches) | SPR32/SPAGEM = 00 / 01,10 / 11 | 16 / 32 / 64 bit as above | 2 / 4 / 8 bytes | same layout |
| copper, blitter, audio, disk, refresh | -- | 16 bit | -- | -- |
| CPU (68000, our TG68K) | -- | 16 bit | -- | -- |
| CPU (MiSTer's 68EC020 with AGA, #276) | -- | 32 bit read or write in one CPU slot (word A, A+1; `chipRD2`/`chipWR2`) | -- | -- |

Timing in machine ticks (28.375 MHz, one bus slot = 4 ticks; phase 1 = the tick after `clk7_en`;
measured in the bench with `--debug`): the address (and _OE/_WE, byte enables) is on `ram_address`
from phase 1 to phase 0 of the slot (4 ticks); the 16-bit word must be valid on `ramdata_in` at the
`clk7_en` edge that ends phase 0 for chipset DMA (the CPU bridge latches earlier, at `!c1 & c3`: the
study's "consumer edge n+2" is the binding one for a single memory); `chip48[47:0]` must be valid at
the same `clk7_en` edge and **held until the following `clk7n_en` edge** (2 ticks later, when the next
slot's address is already on the bus): Denise copies `{data16, chip48}` into BPLxDAT / the sprite
registers there.  The extra words come in sequential order from A inside the aligned 64-bit group
(A+1, A+2, A+3 modulo the group), which is MiSTer's SDRAM burst order; with aligned pointers (all
software that works on a real A1200) that is simply the rest of the 64-bit word.

**The 64-bit plan fits.**  One read of the 64-bit data RAM word that contains A serves every slot:
lane A[2:1] to `ramdata_in`, the other three lanes rotated to `chip48` and registered at `clk7_en`
(a 48-bit register next to the data RAM).  A fetch never crosses a 64-byte line (8-byte groups), so
hit/miss and the stall decision stay per slot exactly as for 16-bit accesses; a miss must stall until
the whole 64-bit word is in the data RAM (it arrives with the line anyway).  Rate: at most one 64-bit
read per slot = one per 4 machine ticks (worst case 8 planes hires FMODE 3: 15,899 64-bit fetches per
frame in the traces, ~6.4 MB/s), trivial for a port that can read every tick.  Writes stay 16-bit with
byte enables for the chipset; a 68EC020 32-bit write (if MiSTer's #276 path is adopted) is two
adjacent lanes of the same 64-bit word (aligned: A[1] = 0) in one slot, i.e. 4 byte enables of 8.
`minimig_m65.v` ties `chip48` to 0 today: stage 3 connects it to this register.

## CPU and chip-bus timing with the 68020

Measured with `tools/mk_cputime.py` (11 loops x 4 bus conditions, colour clocks from VPOSR/VHPOSR,
same beam phase for every start; code in chip RAM, instruction cache on where the CPU has one):

| condition / loop (CCK for 2048 instructions) | ours 68000 (fx68k) | ours 68020 (TG68K, AExp+cpu-tg68k) | MiSTer "68020" (unthrottled) | MiSTer stock 68EC020 (#276 tables) | ours stage 3: MiSTer's 68EC020 ported, stock (0xF4 = 3 + AGA) | FS-UAE 68020 CE | WinUAE 6.1b10 68020 CE (A1200 config, run_winuae.py) | 68EC020 manual, cache case, zero-wait memory |
|---|---|---|---|---|---|---|---|---|
| c0 DMA off / L0 dbra (2048x) | 10405 | 12412 | 789 | 3058 | 3057 | 4136 | 2156 | 3072 |
| c0 DMA off / L1 add.l d0,d1 | 9584 | 5727 | 371 | 1397 | 1397 | 1578 | 1394 | 1408 |
| c0 DMA off / L2 move.l (a0),d0 chip | 13693 | 13955 | 4379 | 6520 | 6519 | 4674 | 4230 | 3456 |
| c0 DMA off / L3 move.w (a0),d0 chip | 9593 | 9841 | 4379 | 6525 | 6525 | 4677 | 4237 | 3456 |
| c0 DMA off / L4 move.l d0,(a0) chip | 13693 | 13955 | 4379 | 4403 | 4403 | 4407 | 4229 | 2432 |
| c0 DMA off / L5 move.w d0,(a0) chip | 9592 | 9841 | 4379 | 4403 | 4404 | 4405 | 4230 | 2432 |
| c0 DMA off / L6 mulu.w d2,d0 | 46440 | 5727 | 371 | 14702 | 14702 | 13354 | 11633 | 14208 |
| c0 DMA off / L7 move.l d0,d1 + divu.w d2,d1 | 59404 | 13955 | 4981 | 23917 | 23916 | 29224 | 19893 | 23936 |
| c0 DMA off / L8 move.w $dff006,d0 | 17760 | 18069 | 6217 | 7050 | 7050 | 8796 | 4367 | 3968 |
| c0 DMA off / L9 move.l (a0)+,d0 chip | 13695 | 13955 | 4379 | 6525 | 6525 | 6755 | 4234 | 3456 |
| c0 DMA off / L10 move.l d0,(a0)+ chip | 13693 | 13955 | 4379 | 4403 | 4403 | 4405 | 4229 | 2432 |
| c1 8pl lores FMODE0 / L0 dbra (2048x) | 36070 | 42465 | 891 | 2936 | 3163 | 4292 | 2030 | >= 3072 |
| c1 8pl lores FMODE0 / L1 add.l d0,d1 | 31545 | 19708 | 437 | 1397 | 1397 | 1579 | 1394 | >= 1408 |
| c1 8pl lores FMODE0 / L2 move.l (a0),d0 chip | 46096 | 47865 | 14546 | 18619 | 18619 | 15922 | 14063 | >= 3456 |
| c1 8pl lores FMODE0 / L4 move.l d0,(a0) chip | 46097 | 47864 | 14546 | 14733 | 14733 | 14738 | 14063 | >= 2432 |
| c1 8pl lores FMODE0 / L6 mulu.w d2,d0 | 39923 (*) | 19708 | 437 | 14513 | 14740 | 13606 | 11566 | >= 14208 |
| c2 8pl lores FMODE3 / L0 dbra (2048x) | 12328 | 15088 | 785 | 3054 | 3054 | 4141 | 2149 | >= 3072 |
| c2 8pl lores FMODE3 / L1 add.l d0,d1 | 11335 | 6972 | 376 | 1397 | 1397 | 1578 | 1395 | >= 1408 |
| c2 8pl lores FMODE3 / L2 move.l (a0),d0 chip | 16363 | 16968 | 5189 | 6533 | 6533 | 5678 | 5056 | >= 3456 |
| c2 8pl lores FMODE3 / L4 move.l d0,(a0) chip | 16356 | 16968 | 5189 | 5218 | 5218 | 5224 | 5056 | >= 2432 |
| c2 8pl lores FMODE3 / L6 mulu.w d2,d0 | 49878 | 6972 | 376 | 14709 | 14709 | 13356 | 11639 | >= 14208 |
| c3 blitter nasty / L0 dbra (2048x) | 18821 | 20827 | 9154 | 11437 | 11437 | 12520 | 10530 | >= 3072 |
| c3 blitter nasty / L1 add.l d0,d1 | 18001 | 14142 | 8734 | 9761 | 9761 | 9948 | 9756 | >= 1408 |
| c3 blitter nasty / L2 move.l (a0),d0 chip | 22113 | 22370 | 12741 | 14886 | 14886 | 13048 | 12595 | >= 3456 |
| c3 blitter nasty / L4 move.l d0,(a0) chip | 22111 | 22370 | 12741 | 12783 | 12784 | 12789 | 12603 | >= 2432 |
| c3 blitter nasty / L6 mulu.w d2,d0 | 54857 | 14142 | 8734 | 23068 | 23067 | 21728 | 19996 | >= 14208 |

(*) wrapped: the probe measures modulo one frame (71,051 CCK); the true value is 110,974.  The 68000
column checks the method: L0-L6 match the 68000's documented cycle counts within 1 % (DBRA 10, ADD.L
8, MOVE.L (An),Dn 12, MULU 38+2n clocks; 1 CCK = 2 clocks).  The manual column is a lower bound for
c1-c3.  **c3 is not a test of the instruction cache**: the loop is entered by JSR, whose stack write
waits for the whole blit (64 x 64 words, every cycle a blitter cycle) in every implementation; it
shows that all four stop the CPU completely for a nasty blit when the CPU needs the bus.

What each machine does:
- **Ours (AExp + `cpu-tg68k`)**: TG68K runs at the 28.375 MHz clock enable and stalls for every bus
  word.  Every opcode word and every data word (a long = two words) goes through cpu_wrapper's
  68000-style chip-bus FSM (negedge, synchronised to ph1/ph2): at least 4 cycles of 7 MHz = 2 CCK per
  16-bit access, the next request waits for the next ph1.  No instruction cache, no 32-bit chip
  accesses, no throttle: register code runs at bus speed (one bus cycle per opcode word, ~2.8 CCK per
  `add.l d0,d1` from chip RAM), MULU/DIVU are much faster than a 68020 (TG68K computes them in a few
  clocks), and with the blitter in nasty mode no instruction runs at all (every opcode fetch needs
  the bus; a real 68EC020 executing from its cache would only stop at its next bus access -- not
  measured here, see the note under the table).
- **MiSTer master**: the same TG68K, but cpu_wrapper merges two words into one 32-bit chip-bus cycle
  with AGA (#276), fetches code through a 64-longword instruction cache model (`09226f7`), and with the
  "stock speed" bit (0xF4 bit 5) `cpu_cycles.v` holds the CPU by a per-instruction cost from tables
  (68020 user's manual cycle counts with head/tail overlap, chip access cost 9 CPU clocks).  Without
  that bit (MiSTer's ordinary "68020", config byte 0x07 here) the CPU runs unthrottled: register
  loops 15x faster than ours.  With it (0x23) the register loops land within 0-4 % of the manual's
  cache-case numbers (L0 3058 vs 3072, L1 1397 vs 1408, L6 14702 vs 14208, L7 23917 vs 23936).  Note:
  MiSTer's own Verilator simulation does not load these tables (Quartus `ram_init_file` attribute,
  zeros in Verilator; `mister/mif2hex.py` fixes that in the copy) -- before the fix the "stock" run
  gave register loops 2.5x faster than the manual.
- **FS-UAE 3.1.66** (WinUAE 3.3 core): "68020 cycle-exact" approximate model; WinUAE's own changelog
  says that model is approximate (4.3.0: "Removed all 68020 cycle-exact CPU mode internal idle cycles
  ... real 68020 best case results too slow ... worst case was still too fast"; 6.1 beta 4: "Adjusted
  CPU stealing blitter cycles (blitter nasty) in 68020 CE mode ... due to lack of 68020 CE accuracy").
- **Documentation** (MC68020/MC68EC020 User's Manual, section 8.2, cache case, at 14.18 MHz, 1 CCK =
  4 CPU clocks): DBcc taken 6 clocks -> L0 3072 CCK; ADD Dn,Dn 2 -> L1 1408 CCK; MULU.W 27 ->
  L6 14208 CCK; MOVE.L + DIVU.W 2 + 44 -> L7 23936 CCK; a bus cycle is at least 3 clocks (section 5),
  the A1200's chip-RAM wait states come from Alice/Budgie and are not in public documentation.

The list the user asked for:

| aspect | status |
|---|---|
| chipset slot allocation (bitplane/sprite/copper/audio/disk/refresh/blitter, FMODE fetch patterns, DMA priorities) | **exact** to the extent Minimig is (cycle-based RTL; MiSTer master has ~90 later fixes, see above) |
| which slots the CPU can get (the CPU only gets free slots, blitter nasty takes them) | exact on the chipset side; the CPU side decides how it uses them (below) |
| CPU access width on the AGA chip bus (32 bit per slot on an A1200) | ours: 16 bit (two slots per long) -- **wrong**; MiSTer #276: 32 bit |
| CPU instruction timing (clocks per instruction class, overlap, prefetch) | ours: TG68K's own timing at 28 MHz enable, **not** a 68020 (register ops faster or slower depending on the bus, MUL/DIV far too fast); MiSTer stock mode: **approximate** (manual tables, debt/credit throttle) |
| instruction cache (256 bytes, 64 longwords; code loops do not touch the bus) | ours: **missing** (every fetch is a bus cycle); MiSTer: modelled |
| CPU chip-RAM access length on a real A1200 (wait states, how Alice arbitrates the 020 against DMA, write buffering in Budgie) | **unknown** from public documents; WinUAE ("data latched by chipset buffers", 4.2.0) and MiSTer (9 clocks) use measured/approximated values |
| interrupt latency, exception timing, bus phase of the 020 against the 7 MHz / CCK grid | **approximate** (TG68K + chip-bus FSM), not documented for Alice |
| what a demo can notice | loops timed against the beam (raster splits by the CPU, "busy wait then write" effects, Roots 2.0's globe -- WinUAE had to slow its 68020 NOP for it): ours runs register code ~4x slower (L1 5727 vs 1408 CCK) and MUL/DIV 1.7-2.5x faster than a 68EC020, chip-RAM loops 1.6-5.7x slower (16-bit, no cache); code that needs a frame's CPU budget (texture mappers, chunky-to-planar) drops frames, or runs too fast where it multiplies; MiSTer's stock model is within 0-5 % of the manual for register code, its chip accesses cost 1.9-2.6 CCK, FS-UAE's 1.4-2.3 CCK, the real A1200's are unknown; music and copper effects are chipset-timed and unaffected |

Consequence for stage 3: "cycle-accurate A1200" for the CPU means taking MiSTer's #276 / `09226f7`
work (32-bit chip cycles, instruction cache, the cycle-table throttle) into this tree, then
calibrating against a real A1200 measurement, which nobody here has (the user has no A1200; MiSTer's
PR #233 quotes real-A1200 rows of a "Copperline timing-test.adf" that could serve as a reference).

## Memory traffic with AGA for the cache (study model, AGA + 68020 traces)

`sim/aga/cache_grid.py` runs the study's model (`cachesim.cpp`) over traces from this bench, all
with the TG68K 68020: the Kickstart 3.1 boot, the study's `aga8cpu` and `worst` programs (now with the
68020), and the CPU timing probe.  155 runs; selection (stalled % of real time, max lag):

| workload (TG68K 68020, AGA, 2 MB chip) | cache | prefetch | latency | h | stalls/frame | stalled us/frame mean / max | stalled % | max lag us |
|---|---|---|---|---|---|---|---|---|
| Kickstart 3.1 boot (frames 1-400) | 512 KB | all | B | 1/31 | 9.9 | 6.79 / 99.2 | 0.034 | 39.8 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | none | B | 1/31 | 21.0 | 14.78 / 198.1 | 0.074 | 33.2 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | none | C | 1/31 | 21.0 | 19.12 / 260.4 | 0.096 | 59.9 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | all | B | 1/31 | 0.3 | 0.24 / 91.0 | 0.001 | 33.8 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | all | C | 1/31 | 0.3 | 0.32 / 119.5 | 0.002 | 61.9 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | none | B | 0.1 | 21.0 | 14.78 / 198.2 | 0.074 | 1.1 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | none | C | 0.1 | 21.0 | 19.12 / 260.4 | 0.096 | 1.7 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | all | B | 0.1 | 0.3 | 0.24 / 90.9 | 0.001 | 1.1 |
| Kickstart 3.1 boot (frames 1-400) | 1536 KB | all | C | 0.1 | 0.3 | 0.31 / 119.3 | 0.002 | 1.5 |
| KS 3.1 idle (frames 300-400) | 512 KB | all | B | 1/31 | 7.0 | 4.75 / 13.6 | 0.024 | 2.2 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 512 KB | all | B | 1/31 | 4230.6 | 2975.34 / 3143.1 | 14.877 | 316319.1 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | none | B | 1/31 | 75.8 | 53.26 / 226.4 | 0.266 | 3.5 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | none | C | 1/31 | 75.8 | 69.14 / 291.9 | 0.346 | 5.1 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | all | B | 1/31 | 0.0 | 0.02 / 2.2 | 0.000 | 1.6 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | all | C | 1/31 | 0.0 | 0.02 / 2.7 | 0.000 | 2.1 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | none | B | 0.1 | 75.8 | 53.27 / 226.5 | 0.266 | 2.7 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | none | C | 0.1 | 75.8 | 69.14 / 291.6 | 0.346 | 4.1 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | all | B | 0.1 | 0.0 | 0.02 / 2.2 | 0.000 | 1.3 |
| aga8cpu (8 pl hires FMODE 3 + memcpy 1 MB) | 1536 KB | all | C | 0.1 | 0.0 | 0.02 / 2.8 | 0.000 | 1.7 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 512 KB | all | B | 1/31 | 457.2 | 320.49 / 376.2 | 1.602 | 39.2 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | none | B | 1/31 | 258.9 | 182.04 / 494.1 | 0.910 | 38.2 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | none | C | 1/31 | 258.9 | 236.05 / 634.1 | 1.180 | 149.5 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | all | B | 1/31 | 157.8 | 110.90 / 295.8 | 0.555 | 3.1 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | all | C | 1/31 | 157.8 | 144.02 / 387.0 | 0.720 | 29.0 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | none | B | 0.1 | 258.9 | 182.03 / 493.1 | 0.910 | 3.3 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | none | C | 0.1 | 258.9 | 236.04 / 633.9 | 1.180 | 5.2 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | all | B | 0.1 | 157.8 | 110.91 / 296.1 | 0.555 | 1.1 |
| worst (+ sprites, random blits, random CPU R/W 2 MB) | 1536 KB | all | C | 0.1 | 157.8 | 144.01 / 386.1 | 0.720 | 1.7 |
| CPU timing probe | 512 KB | all | B | 1/31 | 17.9 | 12.24 / 38.4 | 0.061 | 21.3 |
| CPU timing probe | 1536 KB | none | B | 1/31 | 39.6 | 27.89 / 659.3 | 0.139 | 285.7 |
| CPU timing probe | 1536 KB | none | C | 1/31 | 39.6 | 36.08 / 848.2 | 0.180 | 530.9 |
| CPU timing probe | 1536 KB | all | B | 1/31 | 0.1 | 0.04 / 0.7 | 0.000 | 0.7 |
| CPU timing probe | 1536 KB | all | C | 1/31 | 0.1 | 0.07 / 1.5 | 0.000 | 1.5 |
| CPU timing probe | 1536 KB | none | B | 0.1 | 39.6 | 27.89 / 659.3 | 0.139 | 5.8 |
| CPU timing probe | 1536 KB | none | C | 0.1 | 39.6 | 36.12 / 849.5 | 0.181 | 8.7 |
| CPU timing probe | 1536 KB | all | B | 0.1 | 0.1 | 0.04 / 0.7 | 0.000 | 0.7 |
| CPU timing probe | 1536 KB | all | C | 0.1 | 0.1 | 0.07 / 1.5 | 0.000 | 1.5 |
| KS 3.1 idle (frames 300-400) | 1536 KB | any | A/B/C | any | 0 | 0 | 0 | 0 |
| aga8cpu, MiSTer stock 68EC020 | 512 KB | all | B | 1/31 | 11915.4 | 8375.33 / 8395.0 | 41.877 | 1161647.9 |
| aga8cpu, MiSTer stock 68EC020 | 1024 KB | all | B | 1/31 | 7.7 | 5.42 / 23.4 | 0.027 | 17.0 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | none | B | 1/31 | 15.4 | 10.81 / 26.9 | 0.054 | 2.5 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | none | C | 1/31 | 15.4 | 13.94 / 35.6 | 0.070 | 4.1 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | all | B | 1/31 | 0.0 | 0.01 / 0.7 | 0.000 | 0.7 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | all | C | 1/31 | 0.0 | 0.01 / 0.9 | 0.000 | 0.9 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | none | B | 0.1 | 15.4 | 10.82 / 27.0 | 0.054 | 2.2 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | none | C | 0.1 | 15.4 | 13.94 / 35.6 | 0.070 | 4.0 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | all | B | 0.1 | 0.0 | 0.01 / 0.7 | 0.000 | 0.7 |
| aga8cpu, MiSTer stock 68EC020 | 1536 KB | all | C | 0.1 | 0.0 | 0.01 / 0.9 | 0.000 | 0.9 |
| worst, MiSTer stock 68EC020 | 512 KB | all | B | 1/31 | 1002.7 | 702.92 / 778.3 | 3.515 | 11960.7 |
| worst, MiSTer stock 68EC020 | 1024 KB | all | B | 1/31 | 648.4 | 454.92 / 529.0 | 2.275 | 79.7 |
| worst, MiSTer stock 68EC020 | 1536 KB | none | B | 1/31 | 423.0 | 297.41 / 403.4 | 1.487 | 542.6 |
| worst, MiSTer stock 68EC020 | 1536 KB | none | C | 1/31 | 423.0 | 385.20 / 518.5 | 1.926 | 3669.7 |
| worst, MiSTer stock 68EC020 | 1536 KB | all | B | 1/31 | 320.5 | 225.27 / 259.1 | 1.126 | 21.2 |
| worst, MiSTer stock 68EC020 | 1536 KB | all | C | 1/31 | 320.8 | 291.32 / 331.2 | 1.457 | 40.6 |
| worst, MiSTer stock 68EC020 | 1536 KB | none | B | 0.1 | 423.0 | 297.42 / 403.5 | 1.487 | 5.1 |
| worst, MiSTer stock 68EC020 | 1536 KB | none | C | 0.1 | 423.0 | 385.22 / 519.3 | 1.926 | 9.4 |
| worst, MiSTer stock 68EC020 | 1536 KB | all | B | 0.1 | 320.6 | 225.16 / 257.6 | 1.126 | 2.8 |
| worst, MiSTer stock 68EC020 | 1536 KB | all | C | 0.1 | 320.8 | 291.20 / 331.2 | 1.456 | 6.8 |

The two "MiSTer stock 68EC020" workloads are the study's programs run on MiSTer master's full system
(`sim/aga/mister`, access trace added to its bench) with the cycle-table 68EC020, 32-bit chip cycles
and the instruction cache on: the closest model of a real A1200 CPU available here.

Reading: with the study's design (1.5 MB, 3-way, prefetchers) the AGA workloads with our TG68K stall
as little as the study's 68000 ones (worst 0.55 % / 3.1 us at latency B, study 0.51 % / 1.5 us;
aga8cpu ~0); FMODE 3 fetches are 64-bit and prefetchable, they never miss once the walkers run.
With MiSTer's 68EC020 the worst case doubles: 1.13 % stalled, max lag 21 us at latency B (2.8 us
with h = 10 %) -- the 020 runs its loop from the instruction cache, so its random chip reads (4,620
CPU accesses per frame instead of 18,483) come closer together and the blitter takes the freed slots;
without prefetchers 1.5 % and 543 us (5 us with h = 10 %).  aga8cpu stays at ~0 with prefetchers.
Without prefetchers (a likely first stage-2 cache) the boot and the worst case stay below 1 % but
lags reach 33-150 us at h = 1/31; h = 10 % brings every case below 6 us.  A 512 KB cache fails
for programs that touch more than 1 MB (aga8cpu: 15-20 % stalled, unbounded lag).  The TG68K as
used here moves chip RAM like a 68000 (opcode fetches over the bus, one word per 2 CCK), so these
traces do *not* show a real 68EC020's pattern (fewer fetches, 32-bit data, faster bursts); the
study's synthetic 020 cases (10 % random reads: 3.1 % stalled at latency B) remain the bound.
**Stage 2's measured numbers were not available to this work** (its PORTING section on the pushed
head has only the reset fixes); the comparison has to be made when stage 2 reports them.

## The demo acceptance set (part B)

Candidates were checked against public sources: pouet.net comments (prod pages, `which=` id),
MiSTer-devel/Minimig-AGA_MiSTer issues and pull requests (the RTL this core is built from), the WinUAE
changelog (`od-win32/winuaechangelog.txt` in tonioni/WinUAE, version/beta as found there), WinUAE
GitHub issues, and the files' own readme texts.  Downloads (scene archives, freely distributed by the
groups) are in `ext/a1200_demos/<name>/` with `manifest.json` / `manifest.md` (source URL, sha256,
format, requirements); never in a repository.  Reference runs: FS-UAE 3.1.66 (WinUAE 3.3 core),
A1200 quickstart model (68EC020 cycle-exact, AGA, 2 MB chip), the user's Kickstart 3.1 A1200 ROM
read in place, `tools/run_fsuae.py` (SDL offscreen + `fsuae_capture.so`): H.264 video at 25 fps
(every 2nd frame), a still every 10 s and FS-UAE's log in `ext/a1200_demos/ref/`, 150 s per demo.

Sources: P = `https://www.pouet.net/prod.php?which=<id>` (comment author, date); MM = MiSTer-devel/Minimig-AGA_MiSTer
issue / PR (`https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/issues/<n>`); WU = WinUAE changelog version (in
`https://github.com/tonioni/WinUAE/blob/master/od-win32/winuaechangelog.txt`).  "In our base" = the fix is in AExp's
Minimig (`git log` of the submodule).  Stills and sheets: `ext/a1200_demos/ref/<name>_sheet.png`.

| demo (group, year, pouet id) | reported problem, where (source) | verified | downloaded | FS-UAE 3.1.66 baseline (150 s) | requirements |
|---|---|---|---|---|---|
| Nexus 7 (Andromeda, 1994, 402) | MiSTer/MiST/Vampire: wrong colours in "Gouraud Pulse" (TG68K BFINS; MM #11, fixed 2019, in our base); MiSTer: block of white lines in "Shade Cluster" (BPLAM outside the window, MM #182, 2025, in our base); the EXE on a fast 020 showed the main part only after ~30 min (MM #11 comment, 2019-07-16); A1200+030 hangs in the light-sphere scene (P dimouse 2008) | yes (sources quoted) | ADF (zip, the mirror named in MM #11) + EXE | runs: galaxy intro, landscape, title, Gouraud Pulse at ~140 s | stock A1200, floppy (P winden 2005) |
| Fullmoon (Virtual Dreams & Fairlight, 1993, 410) | no emulator report found | no | ADF | loads ~50 s (cruncher), then title and 3D parts | A1200 + fast RAM (P kjb 2013, unverified) |
| Origin (Complex, 1993, 3741) | no emulator report found | no | 2 DMS | runs: title picture, credits, 3D mech, cockpit part | stock A1200 (P krabob 2004) |
| Motion / Origin 2 (Bomb, 1994, 5436) | crashes after the logo in WinUAE (P Optimus 2005-12-26; "cant get it working in UAE", P tFt 2007) | yes (old reports) | 2 DMS | **not reproduced**: runs past the logo into the 3D landscape | A1200, "some fastmem" for the 3D part (P grip 2012); run with 4 MB |
| Mindflow (Stellar, 1994, 3473) | no emulator report found | no | EXE (zip) | without SetPatch it refuses ("AGA Chipset: No ... Something is wrong with your configuration!", as its readme warns); with an own 96-byte `setchiprev` (`tools/mk_setchiprev.py`: graphics.library SetChipRev(best), what SetPatch does) before it: **runs** (Stellar logo, landscape, credits, 3D corridor) | 2 MB 32-bit fast RAM + SetPatch (readme) |
| Roots (Sanity, 1994, 3034) | WinUAE: borderblank blanked sprites (WU 2.8.0 b16, "Roots AGA") | yes | DMS | runs | stock A1200 |
| Roots 2.0 (Sanity, 1995, 3251) | WinUAE: 68020 CE NOP timing for the globe effect ("write must be complete before NOP finishes"), flower-zoomer gaps (BPLCON4 colour change 1 lores pixel later than a colour-register write), missing bottom part (WU 2.2.0 b1); MiSTer: sprite-copper-chunky section (MM #184, 2025, in our base) | yes | DMS | runs, flower zoomer complete | AGA part stock; ECS part 020 + fast (P ryg 2008, Photon 2014) |
| Psychedelic (Virtual Dreams & Fairlight, 1994, 3057) | "Doesn't run in WinUAE now too" (P tomba 2011); WHDLoad slave works in WinUAE (P axis 2016); FS-UAE config trouble (P rloaderro 2022); "code doesn't seem particularly stable" (P dodke 2019) | yes (comments) | LHA (HD install) | with 4 MB fast: **Software Failure 8000 0006** (CHK exception) at the start, reboot loop; without fast RAM (2 MB chip only, as the readme allows): **8000 000B** (line-F) at the start, loop -- the 2011 report is reproduced, cause not determined (no Workbench/SetPatch, HD directory with the volume named psychedelic:) | AGA, 020, ~1.8 MB free, fast recommended (readme) |
| Twisted (Polka Brothers, 1994, 8130) | no emulator report found | no | 4 DMS | runs (disks in df0-df3) | fast RAM (P teo 2002) vs "unaccelerated A1200" (P 2014): unclear |
| ZiF (Parallax, 1995, 1149) | slower than real hardware on MiSTer (MM #72, 2020: closed by the reporter, compared against an accelerated machine); "City part only one or two moving light sources" after a patch (P leGend 2008, platform unclear) | partly | LHA (files) | runs (title, 3D parts, pictures) | A1200 + hard disk, no fast RAM (readme) |
| Domination (Contraz, 1996, 9005) | "WinUAE is not able to emulate sprites very well" (P, the author sp^ctz, 2003; old); MiSTer: phantom read from a write-only register enabling blitter line mode (MM #182, 2025, in our base) | yes | EXE (lha) | **no picture** in 150 s (screen colour (3,3,3); 4 MB fast, own SetChipRev); cause not determined | AGA, 6 MB RAM (readme) |
| Crazy Sexy Cool (Essence, 1995, 3819) | MiSTer: bitplanes hid sprites outside the display window (MM #202, 2025, in our base) | yes | ADF | stops at the boot block's system check ("SYSTEM NOT OK", waits for a mouse button): the headless run has no input | A1200 (not stated) |
| Artificial Paradise (New Generation Crew, 1994, 33775) | loading screen missing in WinUAE: `bset #9,$dff104` reads a write-only register, which on AGA returns "random bits" depending on earlier accesses (WU 2.6.0 b14, again 6.0.0 b20) | yes | 2 ADF | runs, loading screen present, parts 1-2 | A1200 (not stated) |

Named in the brief but not identified: "Real" (no AGA production of that name on pouet; not
verified).  Seen in the sources and not downloaded: Tenebra (Biosynthetic Design 1995, WinUAE
1.1.1b5 "face part partial fix"; a bare executable: needs an OS boot device), Relic (Nerve Axis 1998;
a WinUAE drawing bug, 6.0.2b10, not hardware), Tribute to Boerk (Keso, WinUAE issue #323: a 6.0 beta
regression, fixed), Darkside AGA / Captured Dreams (The Black Lotus: need 030/060 to run smoothly,
misterfpga.org thread "Amiga AGA Demos"), Smoke & Mirrors (WinUAE issue #394, a 6.x black screen,
not reproduced by the author; 040/060 demo), Bacon of Hope and HAMazing (Desire: OCS/ECS, not A1200).
Games with documented AGA behaviour that would make good acceptance cases too (commercial, not
downloaded): Charlie J Cool AGA (MiSTer #288, Amiberry #1960), Flink CD32/AGA (MiSTer #285/#286),
Turrican 2 AGA world 3 (MiSTer #158/#278), Zool 2 AGA (WinUAE 4.9.0b7: 7 planes FMODE 0).

## What stage 3 must include, and the order

From the requirements column (beyond AGA + 68EC020 + 2 MB chip):
- **fast RAM, 4 MB** in the 68EC020's 24-bit window: Mindflow (2 MB 32-bit fast), Domination (6 MB
  in total), Psychedelic / Fullmoon / Motion / Twisted (recommended or reported).  Phase 2's DDR3 fast
  RAM (Zorro II window `$200000-$9FFFFF`, `amiga_fastram.vhd`) already serves the TG68K; on a real
  A1200 it is a trapdoor card (32-bit, about 0-1 wait states at 14 MHz), so its wait-state timing is
  a stage-3 calibration item, not a design change.
- **a boot device for file-based releases**: ZiF and Psychedelic are hard-disk installs, Mindflow,
  Domination and the Nexus 7 executable are single executables.  Two ways: IDE/HDF (Gayle is in the
  RTL, the host side is missing: PORTING phase-2 item 7, large), or a small tool that writes a bootable
  FFS ADF (Kickstart 3.1 has FFS in ROM) with the executable and a one-line startup-sequence (ROM-
  resident commands only); everything except Psychedelic (2.4 MB) and ZiF (1.5 MB) fits one disk.
- **multi-disk swapping**: Origin (2), Motion (2), Twisted (4), Artificial Paradise (2): the OSM
  ADF mount can swap df0; a second drive (df1, `research_df1.md`) would match how some loaders look.
- no candidate needs a 68030 or an FPU (the ones that want 030/060 were dropped).
- **SetPatch's SetChipRev**: Mindflow refuses to run unless graphics.library is switched to AGA
  (Kickstart 3.x boots ECS-compatible); a boot disk made for the FPGA must run `setchiprev`
  (`tools/mk_setchiprev.py`, own code) before such a demo -- shown in FS-UAE: refused without it, runs
  with it.

Proposed order (each step testable on the board against this bench and the FS-UAE baselines):
1. Stage 2 merged (64-bit data RAM, 2 MB chip, stall clock).
2. `chip48` from the 64-bit cache word (interface above), AGA config bit, Kickstart 3.1 A1200:
   the `mk_agatest.py` ADFs must give the bench's pictures pixel for pixel; the A500 demo regression
   unchanged.
3. The AGA fixes of MiSTer master since `eb7a26e` (the list above; at least #278 for the ddf3c
   mismatch, #259/#260/#261/#286 fine positioning, #262, `c1f14c3`, `6e84afe`) as a submodule patch,
   re-run the tests on bench + board.
4. The 68EC020: MiSTer's TG68K + cpu_wrapper with #276 (32-bit chip cycles, cycle tables) and
   `09226f7` (instruction cache) and the follow-ups (`a189426`, `f1af4fe`, `cf24493`, `897af79`);
   `mk_cputime.py` on the board against the bench; fx68k stays the A500 default, unchanged.
5. Fast RAM 4 MB for the 020 (phase 2's), wait states tuned to a trapdoor card.
6. Boot-device tool (FFS ADF from an executable) and df0 swapping; the demo set on the board,
   compared with the FS-UAE baselines frame by frame where the demo is deterministic.
7. IDE/HDF only if the demo set or the user needs it.

## Files of this stage (branch `a1200-aga`)

| file | what |
|---|---|
| `sim/aga/build.sh`, `tb_top.sv`, `main.cpp`, `tg68k_wrap.v`, `stubs.v` | the AGA + 68020 bench |
| `sim/aga/run_agatests.sh` | the AGA tests on the bench (no Kickstart) |
| `sim/aga/cache_grid.py` | the study's cache model over this bench's traces |
| `sim/aga/mister/` | MiSTer's full-system simulation with a video tap (`build_mister.sh`, `run_mister_tests.sh`, `mif2hex.py`: its 68EC020 cycle tables are not initialised in Verilator otherwise) |
| `tools/mk_agatest.py` | AGA test payloads, boot-block ADFs, expected colours, checker, bench boot ROM |
| `tools/mk_cputime.py` | CPU / chip-bus timing probe (payload, ADF, decoders) |
| `tools/run_fsuae.py`, `tools/fsuae_capture.c` | FS-UAE without a display: stills, video, log |
| `tools/mk_setchiprev.py` | 96-byte AmigaDOS tool: graphics.library SetChipRev(best) (SetPatch's AGA switch) for boot media without Workbench |
| `sim/aga/adf_engine_tb.vhd` | the core's `adf_track_engine` with bench generics (df0 in the bench, GHDL -> Verilog) |
| `sim/aga/run_vts.sh`, `sim/aga/vts_compare.py` | vAmigaTS tests on the bench, comparison with the references |
| `tools/mk_a500probe.py` | OCS/ECS probes for the class-b ports |
| `tools/mk_bootadf.py` | bootable FFS ADF from AmigaDOS files (setchiprev first) |
| `tools/run_winuae.py` | WinUAE 6.1 without a display (A1200 accuracy options, capture, scripted clicks) |
| `patches/Minimig_MiSTerMEGA65/0004-0028` | MiSTer upstream ports, one per upstream commit (header names it) |
| `cpu020/` | TG68K_MMU030.vhd and MiSTer's `cpu_cycles.v` with its tables (`.mem`) |

Outside the repository: `ext/a1200_demos/` (downloads, `manifest.*`, `make_manifest.py`, `run_refs.sh`,
`ref/` recordings, stills, contact sheets and FS-UAE logs, `tools/ref_sheet.py`, `tools/fsuae_capture.so`);
`ext/aga_groundwork/` (Kickstart 3.1 boot frames, the AGA test pictures and checker results of all three
machines, the CPU timing JSONs, the cache-model results of the TG68K traces, the demo table).  The
simulation traces (~1 GB) and the MiSTer-trace cache results lived in the session's RAM scratch area
and were lost in a PC crash at 22:02 on 2026-11-11; their numbers are in the tables above.

# Stage 3: AGA through the cache, MiSTer upstream, the 68EC020 (branch `a1200-aga`, 2026-11-11/12)

Rebased onto `a1200-ddr3` (`1b9ff49`: 64-bit cache data path, 2 MB chip, stall clock).  Simulation
only (Verilator bench `sim/aga/`, GHDL for the VHDL parts); no board, no Vivado run of the AGA
machine yet.

## Package 1: AGA through the real stage-2 cache

- `chip_cache.vhd` (separate commits `821c130`, `cb0f9b1`, for the owner of that file to accept):
  the data RAM is 8 byte lanes of 128K x 8, so one read gives the whole 64-bit group: `rdata_o`
  (the addressed word; lane registered on `clk_i`) and `rdata48_o` (the three following words in
  SDRAM burst order, wrapping inside the group = Denise's `chip48`).  Port B moves 64 bits per beat
  (8 beats per 64-byte line).  `long_i` / `wdata2_i` (default '0'): a 68EC020 32-bit write puts
  its second word into the next lane in the same cycle.  `sim/tb_chip_cache.vhd` checks `rdata48`
  against its reference and makes a third of its even-address writes 32-bit: PASS at identity and
  shrink 0/2/3, 40,000 accesses each.  (The cache owner took both onto `a1200-ddr3` as `df85fa6` and
  `90ec55f`, with a correction `12a5f16`: the second word of a 32-bit write only at an even word
  address.  This branch still has the pre-correction version until its next rebase; the 68EC020's
  32-bit writes are long-aligned, so the bench results are not affected.)
- `main.vhd`: `chip48_hold` loaded at the clk7_en edge from the cache's `rdata48` and held to the
  next one (Denise copies {data, chip48} at clk7n_en); `dout2_hold` the same for the second word of
  a 32-bit CPU read.  **AGA is the machine configuration's third chipset radio** ("AGA Chipset",
  line 78 of the RAM submenu, which was an empty line: no OSM size change, the menu heap keeps 59
  words headroom; a change cold-boots the Amiga like the other topology radios) -> `amiga_config`
  0xF3 bit 4.  It takes effect only with 2 MB chip RAM through the cache (stall controller r7 b2,
  `stallmon.py cache on 0 chip2m`, still a debug setting) and gives ECS otherwise.  (A first version
  used stall-controller register 7 bit 0, which is the statistics-clear toggle: replaced; no stall
  register is used for AGA, the controller files are as on `a1200-ddr3` again.)
- Bench: the real `chip_cache` (GHDL -> Verilog) with its three clocks (source 31.31 MHz, MIG ui_clk
  100 MHz, the machine clock = the source clock gated by the cache's combinational miss, as the
  BUFGCE) and a line-port model with random latency; a shadow memory checks every chip read (word and
  chip48) at its clk7_en edge.

**Result:** every AGA test (`mk_agatest.py`, 11 tests, 10-17 frames each) gives frame-for-frame
identical md5 lists with ideal memory and with the cache at shrink 0 (1 MB), 2 and 3 (2 KB: 2-33 % of
the source edges stalled, up to 125,914 line fills per run), with 0 wrong words and 0 wrong chip48
words in 177,000-270,000 checked reads per test.  The same holds with the 68EC020 of package 3
(`--stock`, shrink 3).  The A500 determinism workload gives the board's values on the bench
(27dbf6f3 / 0c253188, entry $407E, mismatch 0; ECS the same with VPOSR $A000).

**How much cache AGA needs** (the study's cache model over this bench's TG68K traces, DDR3 latency B,
hit cost 1/31): `aga8cpu` (8 planes FMODE 3 + CPU) at 1 MB without prefetch 0.78 % of machine time
stalled, longest lag 57 us; 1.5 MB 0.27 % / 3.5 us.  `worst` (all DMA at once): 1 MB 1.95 % / 61 us,
1.5 MB 0.91 % / 38 us.  Correctness does not depend on the size (proved down to 2 KB); the built 1 MB
costs up to ~2 % of machine time in 60-us lumps in the worst case.  1.5 MB, or bitplane/sprite
prefetch on 1 MB, brings both cases under 1 %.  These numbers assume ~1 us per line fill; the owner's
faster fill (0.42 us, `d03ee47`) and the coming 1.5 MB 3-way arrangement need a re-run of the model.

## Package 2: MiSTer upstream since `eb7a26e`, all 90 commits

All 90 commits of MiSTer-devel/Minimig-AGA_MiSTer master from `eb7a26e` (our submodule base) to
`7d5d3c2` (2026-11-10), oldest first.  Class: **a** AGA-only (OCS/ECS bit-identical by construction:
the change is gated by `aga` or sits in AGA-only registers), **b** changes OCS/ECS behaviour
(chipset, CIA, Paula, floppy, blitter, copper, CPU bus), **c** MiSTer platform only (HPS, SDRAM/DDR
controllers, CD32/CDTV/Akiko, A2065, RTG, real floppy drives, menus, releases, README), **d** 68EC020
/ 68030 work.  "Patch" = our file in `patches/Minimig_MiSTerMEGA65/` (one per upstream commit, the
upstream commit in its header); merges are listed with what they add beyond their parents.

| upstream | class | what it does | upstream's motivation / evidence | here |
|---|---|---|---|---|
| d5f541e | c | README: HDF formats (#213) | docs | - |
| 88ab8c6 | c | MiSTerFileSystem DosAllocMem size (#216) | host file system | - |
| 809b955 | c | A2065 Ethernet card (#215) | new MiSTer feature | - |
| 2a600e4 | c | CD32 and CDTV machines | new machine types (gated by cd32/cdtv mode) | - |
| d39b26f | c | sys update | MiSTer framework | - |
| bc4b31c | c | README | docs | - |
| b265a3b | c | release 20260823 | binary | - |
| b013ce3 | b | CIA: CNT pin and Timer A/B INMODE count sources (#230) | Crystal Kingdom Dizzy (crack sets INMODE by accident; the timer must never underflow) | 0016 |
| c26772a | c | Akiko PIO command register (#229) | CD32 | - |
| d16cd84 | b | Agnus: `field1` only with LACE ("false interlace") | LOF toggled by software without LACE was reported as interlace (video output only, no Amiga-visible change) | 0017 |
| 7ce2980 | b | Agnus: DMA slot grid one CCK earlier (#232) | Hybris; reverted by 0bf2182 / 002eef2 (broke Rampage) | net zero, not ported |
| 148931d | d | stock-speed throttle at half A1200 speed (#233) | 68020 speed | in 0013 (MiSTer's cpu_wrapper) |
| 67af318 | d | cpucfg/cachecfg bits re-arranged | 68020 options | in 0013, main.vhd maps the bits |
| 27acb14 | d | Gayle fast IDE for the throttled 68020 | IDE (not built here) | - |
| 06f30af | b | Agnus: VHPOSR reads one CCK lower (#234) | vAmigaTS VPOS suite measured on an A500 ECS: every horizontal probe read +1 | 0018 |
| 74d6ce0 | b | Gary: custom registers only at $DFxxxx (#235) | WhichAmiga 1.4 probing $DD0000 hit a real register; measured on hardware | 0019 |
| 5578afd | b | blitter freezes when BLTCON1 turns fill off during a D-only fill blit (#236) | Absolute Inebriation (Virtual Dreams) | 0020 |
| d760626 | c | release 20260907 | binary | - |
| 0bf2182 | b | restore the pre-#232 DMA grid | Rampage | net zero with 7ce2980 |
| 2764b51 | b | Agnus: vertical beam readback one CCK later | Hybris (MiSTer #237); WinUAE 683311be as reference | 0021 |
| 002eef2 | b | merge: #232 reverted + 2764b51 | - | = 0021 |
| da7632e | c | OS3 Mountlist (#244) | host file system | - |
| c1134ac | c | real floppy drives on the user port (#245) | MiSTer hardware | - |
| e6d9262 | c | zero-floppy-drives mode | MiSTer menu option; changes the HPS floppy status word (our adf_track_engine would need it too) | - |
| 5fea457 | c | chipdma_arb timing | MiSTer's DDR arbiter (file not in AExp) | - |
| a527fbb | c | DSKBYTR legacy value without flux media | undoes c1134ac's change for emulated drives; our base already has the legacy value | - |
| 16934d3 | c | merge #249 (zero drives) | - | - |
| 8325735 | c | README A2065 (#250) | docs | - |
| 7f93ed1 | b | Denise: OCS/ECS BPLCON1 writes act on the live scroll state | Absolute Inebriation | 0022 |
| cfcc0dc | b | Agnus: export bitplane fetch provenance to Denise | Absolute Inebriation (with 3c8a0ed) | 0023 |
| 3c8a0ed | b | Denise: OCS LORES off-grid fetch ownership | Absolute Inebriation | 0024 |
| c5ffbf9 | b | merge "Fix Absolute Inebriation" | adds nothing beyond its parents | - |
| 3c5d2ea | b | Denise: simplify the OCS LORES fetch state (#252) | refactor of 3c8a0ed, same behaviour | 0025 |
| 2bddf21 | b | CIA timers start two E-clock stages after START (#253) | Risky Woods sound effects (OCS/ECS, 68000), as WinUAE | 0026 |
| 56ba962 | b | Gary: custom register mirror at $C00000-$D7FFFF again (#254) | Kickstart 1.2 found 1.75 MB phantom slow RAM after #235 | 0027 |
| 691c2b7 | c | ddram_ctrl: DMA must not overtake a posted CPU write (#255) | MiSTer DDR controller | - |
| d241338 | c | A2065 CSR0 (#256) | - | - |
| 83ea662 | c | ddram_ctrl read beat (#258) | - | - |
| 61d3f02 | a | Denise: DIWHIGH 70/35 ns bits (#259) | AGA fine window | 0004 |
| 16227ac | a | Denise: SPRxCTL 70/35 ns bits (#260) | AGA sprites | 0005 |
| 430209e | a | Agnus: HBSTRT/HBSTOP fine bits (#261) | AGA | 0006 |
| 6b82678 | c | cdtv_bridge / toccata declare before use (#264) | - | - |
| e187420 | b | Agnus: a BPLxPT write right before its fetch goes nowhere (#262) | TLC PowerTrax (hint by Toni Wilen); not chipset-gated | 0007 (ported with the AGA set; OCS determinism unchanged) |
| cbf17d2 | c | Akiko unknown command length (#263) | CD32 | - |
| c9502ba | c | A2065 CSR0 (#274) | - | - |
| c55ecd9 | d | cycle-exact 68EC020 (#276) | A1200 speed | 0013-0015 |
| 6c66eb1 | c | floppy drive sounds (#275) | MiSTer feature (paula_floppy select decode rewritten, same function) | - |
| f3ab2c1 | a | Denise: FMODE fetch start (#278) | Turrican 2 AGA scrolling | 0008 |
| ec1353d | d | 68030 with MMU (#277) | - | only TG68K_MMU030.vhd (the kernel needs it to compile) |
| 6ec821d | c | README 68EC020 (#280) | - | - |
| 5b93485 | c | RTG with MMU (#281), reverted by 4767064 | - | - |
| 9194cef | d | 68EC030 | - | - |
| 9efd296 | d | CPU cache, NetBSD on 030 | fast-RAM cache (not used here) | - |
| 1631376 | c | README | - | - |
| 5cd5056 | c | README | - | - |
| b961d73 | d | merge 68EC030 + cache (#283) | - | - |
| 4767064 | c | revert #281 | - | - |
| 4ab0d5f | a | Denise: sprite fine shift | Flink AGA black stripes | 0009 |
| de795a7 | c | sdram_ctrl | - | - |
| b988bd0 | a/c | merge Flink + 68EC020 freeze (sdram_ctrl) | - | = 0009 |
| 8813609 | b | CPU write to a blitter register waits while a BLTPRI blit runs (#287) | Deep Core (CD32): the cached 68EC020 wrote into a running blit | 0028 adapted: 68020 only (a 68000 keeps the idle cycles of a BLTPRI blit); its ddram_ctrl part is c |
| 5306e18 | c | sdram_ctrl | - | - |
| cf24493 | d | cpu_wrapper memory word mux | timing | in 0013 |
| a189426 | d | TG68K long chains | timing | in 0012 |
| ba5adba | c/d | merge timings (#289) | - | in 0012/0013 |
| 1abd1fa | c | Akiko | - | - |
| 3192739 | c | Akiko | - | - |
| ce1f386 | c | Akiko CD speed | - | - |
| f1af4fe | d | cpu_wrapper: no chip read where TG68K skips the fetch | 68EC020 | in 0013 |
| c1f14c3 | a | Denise: BPLAM (bplxor) up to the last pixel | Alien 3 (AGA) | 0010 |
| 06db70b | a/c/d | merge: CD speed (c), Pierre le Chef CPU fix (d), Alien 3 (a) | - | in 0013 / 0010 |
| bf5d061 | c | Action Replay cartridge option (#291) | cartridge (gated by ar_on) | - |
| a2826ce | c | Akiko | - | - |
| b8a5bbd | c | Akiko DMA delays | - | - |
| 6e84afe | a | Agnus: the final D write of a blit before the CPU, AGA only | - | 0011 |
| 09226f7 | d | 68EC020 instruction cache and chip bus fetch | A1200 speed | 0012/0013 |
| 69fb350 | b | userio: no opposite joystick directions | Deep Core crashed on them; limited to HPS joysticks by c88a6f9 | net c, not ported |
| 6599190 | c | sdram_ctrl | - | - |
| 897af79 | d | cpu_wrapper memory ready | timing | in 0013 |
| e47c345 | a/c/d | merge Akiko / Agnus (= 6e84afe) / CPU / joystick / SDRAM | - | see parents |
| 0d6bd62 | c | SNAC joystick on the user port | MiSTer hardware | - |
| 48a35dd | c | Akiko | - | - |
| 74483cd | c | cpu_cache_new timing | fast-RAM cache | - |
| 9709669 | c | Akiko | - | - |
| 7c9517c | c | merge Akiko (#294) | - | - |
| 3ea7f0e | c | RTG frame buffer as Z3 board (#295) | - | - |
| c88a6f9 | c | opposite-direction filter only for HPS joysticks (#297) | the filter broke Amiga mice on the MEGA65 DB9 ports (#296) | - |
| b0349e7 | c | mouse overflow protection (#298) | HPS mouse packets; our mouse is the DB9 quadrature / keyboard path | - |
| 7821c15 | c | sys update | - | - |
| 7d5d3c2 | c | warnings | - | - |

Totals (90 commits): **a** 7, all ported (0004-0006, 0008-0011); **b** 19: 14 ported as one patch each
(0007 = e187420, 0016-0028), 4 are net zero (7ce2980 / 0bf2182 / the merge 002eef2 revert each other
except for 2764b51 = 0021; the merge c5ffbf9 adds nothing), 69fb350 was narrowed to MiSTer's HPS
joysticks by c88a6f9 (net c); **c** 47 (+ 4 merges mixing a/c/d); **d** 13, in 0012-0015 where they
touch cpu_wrapper / TG68K (MiSTer master's files), the 68030 / MMU / fast-RAM cache not ported.

### Class a: OCS/ECS bit-identical

0004-0011 (0007 = e187420 is class b by the definition, ported with this set).  OCS and ECS
determinism mailbox and frame 159 md5 identical before and after.  ddf3c now moves 64 px (origin
335), as MiSTer master and FS-UAE.

### Class b: one patch per upstream commit

Own probe `tools/mk_a500probe.py` (A500 configuration, no Kickstart) and the determinism workload,
each patch alone on top of 0001-0015 (dependent pairs together: 0018+0021, 0016+0026, 0019+0027,
0020+0028, 0022-0025), and all together (`build_p6`):

| patch (upstream) | behaviour change | own probe, before -> after | determinism workload (A500, fx68k) |
|---|---|---|---|
| 0016 (b013ce3) CIA INMODE | a timer with INMODE counts CNT (or underflows gated by CNT), not the E clock | timer A INMODE=1 from $0040 after 2 frames: $0010 (E counted) -> $0040 (CNT idle) | identical |
| 0017 (d16cd84) false interlace | `field1` (video output, AExp's deinterlacer) only with LACE | - (not readable by the Amiga) | identical |
| 0018 (06f30af) VHPOSR -1 | VHPOSR returns hpos-1 (htotal at the wrap) | VHPOSR after line $40->$41: $410C/$4127 -> $410B/$4126 | **changes**: checksums 27dbf6f3/0c253188 -> 6b9c877b/2649b948, entry $407E -> $407D, start sync row $00040002 -> $00020001; still single-valued (mismatch 0) |
| 0019 (74d6ce0) Gary $DFxxxx | $D80000-$DEFFFF no longer reaches the registers | [$D80006]/[$DE1006]: $4139/$4143 -> 0/0; alone it also loses the $C0 mirror ([$C80006] 0) | identical |
| 0020 (5578afd) blitter freeze | D-only fill blit, fill switched off in BLTCON1 mid-blit: blitter frozen until the next BLTSIZE | DMACONR two frames later: $2240 -> $6240 (BBUSY) | identical |
| 0021 (2764b51) V readback delay | VPOSR/VHPOSR line through two clk7_en registers | first read with line $41: $410B -> $410F | identical to 0018 alone |
| 0022-0025 (7f93ed1, cfcc0dc, 3c8a0ed, 3c5d2ea) OCS LORES | live BPLCON1 scroll; off-grid LORES fetch ownership | none (needs a picture check: vAmigaTS BPLCON1 below) | identical (5 lores planes) |
| 0026 (2bddf21) CIA start delay | an E-clock timer starts two E stages after START | TALO 1/2/3 bus cycles after loading $1000: $FF/$FA/$F5 -> $00/$FB/$F6 | **changes**: E clocks over 50 frames $FFF52890 -> $FFF52892 (two fewer: the delay), so the picture of the result rows changes; checksums unchanged |
| 0027 (56ba962) Gary mirror | $C00000-$D7FFFF mirror back where no slow RAM is | [$C80006] (no slow RAM): 0 with 0019 alone -> $4153 | identical |
| 0028 (8813609) BLTPRI write hold, **adapted** | CPU write to a blitter register held while a BLTPRI blit runs -- **68020 only here** | 68000, D-only BLTPRI blit: 16 CCK around a BLTAFWM write; upstream's ungated rule 8206 CCK (to the end of the blit); with the gate the 68000 keeps 16, the 68020 gets $2010 CCK | identical |

Why the two checksum changes are right: 0018 changes only the value VHPOSR returns (the read mux; no
timing anywhere), and the workload checksums the beam values it reads and syncs its start to the E
clock through VHPOSR -- so its numbers must change; that VHPOSR read one CCK high was measured on
an A500 ECS against the vAmigaTS VPOS suite (upstream #234).  0026 makes the CIA count two E clocks
fewer from START, which is what the 8520 does (WinUAE models it; upstream found it with Risky Woods'
sound effects); the workload's E-clock count shows exactly those two clocks.  Leaving 0018/0021 and
0026 out restores the phase-2 values bit for bit.

Why 0028 is gated: upstream applies the hold to every CPU.  A BLTPRI blit only takes the cycles it
can use; a D-only blit uses every second one, and a 68000 gets the others (HRM's cycle diagrams), so
on an A500 a write lands mid-blit.  The CD32 case upstream fixed (Deep Core) is a 68EC020.

### vAmigaTS: inventory and a first before/after sample

**Source and licence:** `github.com/dirkwhoffmann/vAmigaTS` (Dirk W. Hoffmann, GPL-3.0), fetched
read-only (sparse, without the `.raw`/`.tiff`/`.mov` bulk) at commit `24608226` (2026-11-11) into
`ext/a500_tests/vAmigaTS/` (2.0 GB, write-protected); the `.tiff` references of the sampled tests
in `ext/a500_tests/refs/`.  Nothing of it is built or run on the PC; only its ADFs run inside the
bench.  **Content:** 2,158 test disks (boot-block programs, many derived from alpine9000's examples):
Agnus 655 (blitter 250, copper 125, registers 159, DDF 84, DIW 31), CPU 686 (timing 248, IPL 231,
68010/68020/MMU 103, exceptions 36), Denise 302 (sprites 130, registers 87, modes 66), FPU 206,
Paula 137 (interrupts 86, audio 30, drive 19), CIA 93, mainboard 58 (ports, UART), memory 17,
misc 4.  2,907 regression scripts: A500_ECS_1MB 2,129, A500_OCS_1MB 558, A500+ 109, A1200 111
(all with Kickstart 1.3, 9 s after power-on, then one screenshot).  **References:** per test a
`.tiff`, vAmiga's own 716 x 285 screenshot that its regression compares pixel for pixel (1,727 test
directories), and photos of real machines (A500 OCS/ECS, A500+, A1000, A1200; 1,993 directories have
an A500-family photo).  The tiffs are emulator output that the author matched against the photos;
where the two disagree the photo is the evidence (example below).  Older tiffs use another palette
scaling than newer ones, so the comparison maps colours (`vts_compare.py`, "mapped" count).

**On the bench:** `sim/aga/run_vts.sh`: the A500 machine (fx68k, 512 KB chip + 512 KB slow, OCS or
ECS as the script says), the user's Kickstart 1.3 read in place, the test ADF in df0 served by the
core's own `adf_track_engine` (new in the bench: GHDL translation, image words in the board's
HyperRAM byte order), MiSTer's floppy turbo, started from a state saved at frame 170 (before
Kickstart's first disk access), picture of frame 320 compared at the bench's crop (144,22).  About
8-10 minutes per test and thread; the whole A500 part (~2,700 scripts) would take ~400 thread-hours,
too long for this PC.  **On the board:** the same ADFs through the OSM mount and the HDMI capture
(`aexp_demo_test.py` style, ~25 s per test including the reset: about a day for the A500 part), after
a one-time crop/scale calibration of the capture against the bench picture.

Sample (17 tests, different areas; "before" = patches 0001-0015, "after" = all patches 0001-0028;
mismatching pixels of 204,060 after colour mapping, at the bench crop / best crop near it):

| test (setup) | before | after | note |
|---|---|---|---|
| Agnus/Registers/VPOS/vhpos2 (OCS) | 10,104 | **0** | VHPOSR in the VBL handler: exact with 0018/0021 |
| Agnus/Registers/VPOS/cycle01vh (OCS) | 24,136 | **34** | VHPOSR across line $FF -> $100 |
| Agnus/Copper/coptim/coptim1 (OCS) | 3,128 | **38** | |
| Paula/Interrupts/vblank/vblank1 (OCS) | 2,804 | **80** | |
| CPU/Timing/MOVE1/MOVE1W (ECS, 68000) | 3,132 | **564** | |
| Agnus/Blitter/cputim/cputim1 (ECS) | 4,900 | 3,792 | |
| Agnus/Blitter/bbusy/bbusy1 (ECS) | 4,300 | 4,206 | |
| Agnus/Blitter/fill/fill1 (ECS) | 0 | 0 | exact both |
| Agnus/DDF/DDF/ddf1 (OCS) | 0 | 0 | exact both |
| CIA/CIA/ciareg/aprab0 (ECS) | 0 | 0 | exact both (at crop 144,28) |
| Memory/Rom/mirror/customC2, customD1 (ECS) | 0 | 0 | exact both |
| Memory/Rom/mirror/customD2 (ECS) | 11,456 | 34,368 | **the tiff is wrong**: the real A500+ photo in the same folder shows no mirror at $D80000-$DDFFFF and a mirror at $DE0000-$DFFFFF; vAmiga (tiff) and our "before" mirror $D80000-$DBFFFF (64 probe lines wrong against the photo), "after" (0019) only misses the $DE0000 block (16 lines) |
| Memory/Rom/mirror/custC, custD (ECS) | 2,806 / 5,398 | 8,914 / 28,998 | older CPU-timed versions of the above; their README: the references "are recordings of a machine", "still fail in vAmiga today" -- not usable |
| Denise/Registers/BPLCON1/timing1 (ECS) | 702 | 1,578 | mid-line BPLCON1 writes: the reference shows the scroll change as a staircase, ours shows none before or after 0022 (open) |
| Denise/Sprites/collision/sprcoll1 (OCS) | 15,752 | 15,752 | unchanged, open |

Of the 17, the (b) set moves seven closer to their references (vhpos2, cycle01vh, coptim1 and
vblank1 to exact or within 80 pixels), customD2 closer to the real machine's photo, leaves six
unchanged (five of them exact), and makes three worse: custC/custD (references declared unusable by
their author) and BPLCON1 timing1 (702 -> 1,578, open, like sprcoll1).  The $DE0000 mirror (0019
unmaps it, a Gary-based A500+ mirrors it) is a follow-up for 0019.

## Package 3: the 68EC020 (MiSTer #276, 09226f7 and follow-ups)

Patches 0012 (TG68K Kernel/ALU/Pack = MiSTer master), 0013 (cpu_wrapper: MiSTer master's 68EC020
path transplanted into AExp's wrapper: 32-bit chip cycles, instruction cache, `cpu_cycles.v`
throttle), 0014 (minimig.v + m68k_bridge, c55ecd9), 0015 (minimig_m65 ports); `K325T/cpu020/`
(TG68K_MMU030.vhd for the kernel, `cpu_cycles.v` with its tables as `.mem` files).  The 68EC020
timing is on when the machine is AGA and the CPU config is 68020 (`cpu_ec020` in main.vhd, latched in
reset); fx68k stays the A500 CPU, unchanged (OCS determinism identical with the 020 patches).

- CPU timing probe (`mk_cputime.py`, new column in the table above): within 1 CCK of MiSTer master's
  stock 68EC020 in every DMA-off, FMODE 3 and blitter-nasty loop; with 8 planes FMODE 0 (c1) DBRA is
  7.7 % and MULU 1.6 % slower than MiSTer (cause not found: both stall on the same bitplane slots).
- Kickstart 3.1 (40.068) with AGA + 2 MB chip + the stock 68EC020 boots to the insert-disk screen
  (first drawn between frames 200 and 300).
- The AGA tests pass with it, also through the 2-KB cache.

Remaining differences from a real A1200 CPU (exact / approximate / unknown):
- exact: the chipset side (which slots the CPU can have), 32-bit chip accesses in one slot.
- approximate: instruction timing (manual cycle tables with head/tail overlap, MiSTer's debt/credit
  throttle; register loops within 0-4 % of the manual's cache case), the 256-byte instruction cache
  (modelled, no data cache -- the 68EC020 has none), interrupt latency and exception timing (TG68K),
  chip access cost (MiSTer's 9 CPU clocks).
- unknown: Alice/Budgie wait states and write buffering for CPU chip accesses (not in public
  documents; WinUAE and MiSTer use measured approximations), the 020's bus phase against the CCK
  grid.  No real A1200 is available to calibrate against.
- not modelled: fast RAM timing of a trapdoor card (phase 2's DDR3 fast RAM serves the TG68K with
  DDR3 latency, not with a card's wait states).

## Package 4: tools for the A1200 demo set

- `tools/mk_bootadf.py` (committed earlier): a bootable FFS ADF from AmigaDOS files with a one-line
  startup-sequence (ROM-resident commands only) and `setchiprev` first; verified by reading the image
  back; Mindflow from such a disk runs in FS-UAE.
- `tools/aexp_demo_test.py`: demo entries are disk lists with swap times (df0 swapped through the
  OSM: eject, browse, mount); `--set a1200` holds the A1200 set (ADF names on the card, DMS converted,
  mk_bootadf disks for the executables) and runs the stall controller's AGA setting on the module
  before every full reset.  Not run on a board (no board in this work); the A1200 swap times are
  guesses to check against the first recording.  DMS -> ADF needs a converter (`xdms` from apt, not
  installed: needs the lead's permission).
- The bench takes `--adf` / `--adf2 FRAME FILE` (one swap) for multi-disk runs in simulation.

## Package 5: baselines, FS-UAE 3.1.66 and WinUAE 6.1.0 beta 10

WinUAE: the user's AppImage, unpacked, run as `squashfs-root/AppRun -f CONFIG` under
`xvfb-run -a -s "-screen 0 1280x1024x24"` at nice 19 with the same frame-capture library as FS-UAE
(`tools/fsuae_capture.c`, SDL3 path); `tools/run_winuae.py` writes the configuration.  Accuracy
options (in every `ext/a1200_demos/ref_winuae/*.uae`): `chipset=aga`, `chipset_compatible=A1200`,
`cpu_model=68020` + `cpu_24bit_addressing=true` (= 68EC020), `cpu_compatible`, `cpu_cycle_exact`,
`cpu_memory_cycle_exact`, `blitter_cycle_exact`, `cpu_speed=real`, no JIT, `chipmem_size=4` (2 MB),
fast RAM as Zorro II `fastmem_size` (`--fast`; WinUAE has no trapdoor-card model), Kickstart 3.1
read in place, `sound_output=none`.  What did not work headless, or needed care:
- the window is fixed at 960 x 742 (a status bar at the bottom, the picture scaled 2.54 columns per
  lores pixel and 2.5 rows per line, filtered); `gfx_*` window options did not change it.  The checks
  take that scale (`mk_agatest.py check --xscale 2.54 --yscale 2.5 --settle 3`).
- the Unix port maps the host's x permission to AmigaDOS's e bit: the executables in the
  hard-disk directories needed `chmod u+x` (Amiga hunk files, never run on the PC); before that,
  every HD start ended in "file is not executable".
- `psychedelic_nofast` (directory hard disk, no fast RAM) does not boot from the directory in WinUAE
  (Kickstart's insert-disk screen); not investigated.
- input: scripted mouse buttons through the capture library (`CAP_CLICK`, `--click [R]N`), both
  emulators.

Demo comparison (170 s each, same set-ups as the FS-UAE baselines; stills, contact sheets, video,
logs in `ext/a1200_demos/ref/` and `ref_winuae/`):

| demo | FS-UAE 3.1.66 | WinUAE 6.1b10 |
|---|---|---|
| Nexus 7 | runs (intro, landscape, spheres, Gouraud Pulse) | runs, same parts |
| Fullmoon (4 MB fast) | runs | runs, loads faster (logo at ~50 s against ~70 s), later parts at other times |
| Origin | runs (title, credits, mech, cockpit) | runs, same |
| Motion (4 MB fast) | runs past the logo into the 3D part | same (the old "crashes after the logo" not reproduced in either) |
| Mindflow (HD, setchiprev, 4 MB fast) | runs; from ~140 s stays in the corridor part | runs further (fractal and end logo by 170 s) |
| Roots | runs | runs |
| Roots 2.0 (4 MB fast) | runs | runs |
| Psychedelic (HD, 4 MB fast) | Software Failure 8000 0006 (CHK), reboot loop | **the same** 8000 0006 loop |
| Psychedelic, no fast RAM | Software Failure 8000 000B, loop | does not boot from the HD directory |
| Twisted (4 drives, 4 MB fast) | runs through its parts | **white screen from ~90 s** (after "the man upstairs is angry" and a noise part) to the end |
| ZiF (HD) | runs | runs |
| Domination (HD, 4 MB fast) | no picture | **no picture either**; also tried 8 MB fast, 68030 + 68882 non-CE with 8 MB, audio interrupts emulated, mouse clicks: black screen with one grey flash (~40 s) in all |
| Crazy Sexy Cool | waits at the boot block | see below; with right click + 4 MB fast: runs (Essence, Einstein, objects, texture parts) in both, WinUAE ~10 s earlier |
| Artificial Paradise | runs, loading screen present | runs, loading screen present |

**Crazy Sexy Cool:** the ADF's boot block is not the demo's: it is an "Action Replay MK III
AntiVirus-Boot" (added by whoever archived the disk), which reports "SYSTEM NOT OK" on Kickstart 3.1
and waits: left button = Clear System (WinUAE then: Software Failure 8000 0003), right button =
Continue.  After Continue the disk's startup-sequence types the group's logo and starts
`CrazySexyCool.exe`, which returns to the CLI at once without fast RAM and runs with 4 MB.  Both
baselines now use a scripted right click at frame 1500 and 4 MB fast.

**Domination:** the executable loads (13 hunks: 1.57 MB chip, 1.89 MB fast, 1.78 MB any -- most of a
2 MB chip machine's free chip RAM) and then shows a black screen in both emulators and every
configuration tried; the readme asks only for "an aga machine with 6 megs of ram".  Cause not
determined (candidates: a memory layout it needs that a 2 + 4/8 MB machine does not give, an input
it waits for, or a broken archive); dropped from the acceptance set unless a working report turns up.

AGA tests and CPU probe, fourth column (WinUAE): pal256, fmode1, fmode3, hires8f3, xor, ham8 (also
the 1,024 HAM pixels), spr16 all correct; **fmode2 garbled** (FMODE=2 alone, 32-bit fetch by page
mode: blocks scrambled, wrong border colour; FS-UAE, MiSTer and ours give the documented picture --
no real A1200 to say who is right); ddf3c moves 64 px like the others; spr32 and spr64: the
rightmost sprites are cut by WinUAE's fixed window, not wrong.  CPU probe: new column in the CPU
table above (WinUAE's 68020 CE: DBRA 2,156 CCK against the manual's 3,072, ADD 1,394 against 1,408,
MULU 11,633 against 14,208, chip reads 4,230).

## Package 6: Vivado

One build of this branch (radxacm3 variant, Vivado 2025.2.1, `VIVADO_JOBS=4`, nice 19, started only
after the other agent's build had ended; commit `95ce6da` + the PORTING edits), bitstream
`bin/aexp_k325t_cm4_radxacm3.bit` (not tested on a board).  Two synthesis-only fixes first:
`cpu_cycles.v` and cpu_wrapper's cache arrays (patch 0029) were in SystemVerilog array form, and
0010's register was declared inside an unnamed block (patch 0030).

- **Timing met**: WNS +0.025 ns, WHS +0.041 ns, 0 failing endpoints.  Worst setup path: the chip
  cache's line-port address `b_addr` to a data-RAM lane tile in the MIG ui_clk domain (10 ns, 9.4 ns
  of it routing: 64 data-RAM tiles fed from one register).  main_clk (the gated 31.31 MHz machine
  clock) +1.20 ns, on a half-cycle path from TG68K's `micro_state` to cpu_wrapper's `chipdout_i`
  (the 68EC020 path; stage 1 had ~+8.9 ns in this domain).  Both are the first places to look if a
  later change breaks timing (register `b_addr` per lane; pipeline the CPU-side write data).
- **Area**: 69,113 LUTs (33.9 %; the 68020 build of phase 2 had 48.8 k: +20.3 k for AGA Denise/Agnus,
  the 68EC020 cache and cycle model, the 64-bit cache lanes), of them 17,585 LUT RAM; 41,558
  registers; 438 / 445 RAMB36 (+2); 74 DSP48.  Block RAM is now the limit: the owner's coming 1.5 MB
  3-way data RAM has to come out of the same 445 tiles.
