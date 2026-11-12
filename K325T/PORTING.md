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
- **Soak**: from 2026-11-12 01:37 the 2 MB chip RAM test with the 2 KB cache (chiptest2.adf, KS
  3.1, build L2) runs for 6 hours, read every minute through the mailbox
  (`ext/aexp5_stage2/logs/luckfox/chip2m_2k_soak.log` in the harness tree).

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
