# The host master: bridge commands for the Amiga core's Linux shell (v1, 2026-11-13)

The interface between the host master in the FPGA (`G_LXSHELL`, build.sh `LXSHELL=1`; see
PORTING.md, "the M2M shell on the Linux module") and the Linux shell that drives it from m65d on
the Rockchip module.  Implemented and bench-tested in this branch, used on the boards since
2026-11-13 (section 7).  Numbers marked "est." are estimates from before the board measurements.

## 0. Principle

In the host build the QNICE SoC (CPU, ROM, RAM, UART, SD controller) is not instantiated.  In its
place sits the **host master**: the same register file QNICE had (CSR, OSM window, ascal mode, CFD,
CFM, the RAMROM device/window selectors and the 0x7000 data window) plus a bus engine, driven by
a byte stream from the Linux module through rk_bridge.  Everything behind QNICE's ports stays as it
is: the framework's device decoders in qnice_wrapper (VRAM, polyphase, SYS_INFO, RTC, HyperRAM
bridge), the core's devices 0x0100 / 0x0103, `qnice_osm_control` / `qnice_gp_reg` into the core,
the overlay.  So **every register and device is reachable at the address QNICE used** (section 3
lists them).

rk_bridge (master copy: mega65-core's `src/vhdl/rk_bridge.vhdl`, used by the MEGA65, C64 and
Amiga builds; this branch uses its own Amiga-only copy, section 7) only gets **new opcodes and new
STATUS bytes**; nothing existing changes.  With a QNICE bitstream or another core the new STATUS bytes read 0 and the new opcodes
are ignored, so m65d behaves exactly as today.

## 1. rk_bridge additions (SPI, mode 0, CS low .. high = one transaction, as today)

| Opcode | Bytes (Rockchip -> FPGA) | Answer | Meaning |
|---|---|---|---|
| 0x80 HOST_PUT | cmd, then N bytes (N <= 4095 with spidev's 4096-byte buffer; send at most the free count of STATUS 73..74) | - | the N bytes go into the **PUT FIFO** (8 KB) towards the host master; bytes that do not fit are dropped and set the sticky overflow flag |
| 0x81 HOST_GET | cmd, dummy, then N clocked bytes | N bytes | the next N bytes of the **GET FIFO** (4 KB, answers of the master); if fewer are there, the rest reads 0x00 and nothing is consumed beyond the fill level -- read the fill level from STATUS first |
| 0x82 HOST_RESET | cmd | - | empties both FIFOs, resets the master's stream parser and clears the sticky flags; **registers are not touched** (CSR, CFM, CFD, OSM, start marker keep their values) |

STATUS (opcode 0x01, unchanged layout up to byte 71) gets:

| Byte | Content |
|---|---|
| 72 | host master version: **0 = no host master** (a QNICE bitstream or another core) -- this is the capability bit the shell tests; 1 = this protocol |
| 73..74 | PUT FIFO free bytes (BE) |
| 75..76 | GET FIFO fill bytes (BE) |
| 77 | flags: b0 PUT overflow (sticky, cleared by HOST_RESET), b1 master busy (executing a command), b2 stream error (unknown opcode: the parser stops until HOST_RESET), b3 bus timeout seen (sticky until HOST_RESET, section 2.3), b4 start marker set (register 0xFFFB != 0); b1..b4 cross from the 50 MHz domain, so a value can be 2 clk162 cycles old |
| 78..81 | the 32-bit **menu id** (BE), the same value as registers 0xFFF9/0xFFFA |

Bytes 73..81 are only meaningful when byte 72 != 0.

## 2. The master's command stream (bytes inside HOST_PUT)

A command is an opcode byte followed by its arguments (big-endian); commands follow each other
without gaps and may span HOST_PUT transactions.  The master executes them in order, in the QNICE
clock domain (50 MHz), with the device's wait honoured on every access.

| Op | Arguments | Answer into the GET FIFO | Action |
|---|---|---|---|
| 0x01 WR | addr(2) data(2) | - | one write to QNICE address `addr` (register or the 0x7000 window) |
| 0x02 RD | addr(2) | data(2) | one read |
| 0x03 BW8 | dev(2) win(2) off(2) n(3) + n bytes | - | burst write: device `dev`, 4 KB window `win`, word offset `off` (0..0xFFF): n accesses, data = the byte zero-extended to 16 bits; offset auto-increments, carrying into `win` at 0x1000 (the Kickstart / ADF byte devices: one file byte per word address) |
| 0x04 BW16 | dev(2) win(2) off(2) n(3) + 2n bytes | - | as BW8 with 16-bit words (VRAM, polyphase tables) |
| 0x05 BR8 | dev(2) win(2) off(2) n(3) | n bytes | burst read, low byte of each word (ADF write-back: one track = 5632 bytes) |
| 0x06 BR16 | dev(2) win(2) off(2) n(3) | 2n bytes | burst read of 16-bit words |
| 0x07 MARK | tag(1) | tag(1) | barrier: answered when everything before it has completed |

n is 1..16 M (3 bytes); a burst longer than what one HOST_PUT carries simply continues in the
next one.  BW8/BW16/BRx set the device and window registers (0xFFF4/0xFFF5) as a side effect; after
the burst they hold the last window used.

### 2.1 Flow control
The PUT FIFO is drained at device speed while the next transfer comes in.  The shell sends at most
`free` bytes (STATUS 73..74) per HOST_PUT; with 8 KB of FIFO and 4 KB transfers this double-buffers.
Answers are fetched with HOST_GET after STATUS shows them (75..76), or after a MARK echo.

### 2.2 Atomicity
A WR to 0xFFF3 (CFM data) is one bus write: the 16 bits of that window change together.  Topology
changes are made with the core held (CSR b0).

### 2.3 Wait and timeouts
Every access waits for the device's wait signal (Kickstart port: until the byte is handed to the
DDR3 line buffer; ADF window: until the HyperRAM/DDR3 bridge acknowledges).  A wait longer than
2^20 QNICE clocks (21 ms) aborts the command: the rest of a burst is skipped (its data bytes are
still consumed from the stream, reads answer 0x00), STATUS 77 b3 is set, the parser continues.

## 3. Register map (QNICE addresses, identical to today unless noted)

| Address | Register | Notes |
|---|---|---|
| 0xFFE0 | CSR | b0 core reset (held), b1 pause, b2 OSM overlay on, b3 keyboard to the core, b4 joy 1, b5 joy 2, b11 ascal auto; b6..b10 (SD) read 0; reset value 0x0839 as QNICE's CSR_DEFAULT: **core held** at power-up.  b3/b4/b5 gate exactly as today in the host build (the gates sit in the framework, downstream of the register: b3 -> m2m_keyb `enable_core_i`, b4/b5 -> the joystick debouncer's `joy_1_on`/`joy_2_on`, which carry the mouse's quadrature lines and left button too).  Not gated in either build, unchanged: the right/middle mouse buttons (pot lines straight from amiga_mouse) |
| 0xFFE1 / 0xFFE2 | OSM_XY / OSM_DXDY | |
| 0xFFE3 | ASCAL_MODE | |
| 0xFFF0 / 0xFFF1 | CFD_ADDR / CFD_DATA | 16 gp words (screen adjustment) |
| 0xFFF2 / 0xFFF3 | CFM_ADDR / CFM_DATA | the 256 menu bits, 16 windows; readable (read-back of the current configuration) |
| 0xFFF4 / 0xFFF5 | RAMROM_DEV / RAMROM_4KWIN | device and window of the 0x7000 window |
| 0x7000..0x7FFF | RAMROM_DATA | single accesses into the selected device/window |
| 0xFFE8 | KEYBOARD | **gone** (the menu key is handled in Linux; reads 0xFFFF) |
| new 0xFFF8 | master version / capabilities (RO) | 0x0001 |
| new 0xFFF9 / 0xFFFA | menu id hi / lo (RO) | 32-bit id of the menu definition (CRC-32 of the generated menu data file), generated at build time from config.vhd together with the file |
| new 0xFFFB | start marker (RW) | cleared only by FPGA configuration (its power-on value), never by a core, M2M or bridge reset: the shell writes it after its first start; a restarted m65d that finds it set adopts the running machine |
| new 0xFFC0..0xFFCF | factory default CFM words 0..15 (RO) | OPTM_G_STDSEL as 16 words, bit n of word w = menu line 16w+n, generated in the same step as the menu id |

Devices (via RAMROM_DEV/4KWIN or the bursts), all as today: 0x0000 VRAM data, 0x0001 VRAM
attributes, 0x0003 ascal polyphase, 0x0004 HyperRAM (DDR3 through the framework's port), 0x0006 RTC
(rtc_controller; see 3.1), 0x00FF SYS_INFO (window 0x30 core video measurement), 0x0100 Kickstart
(byte address, write-only, wait honoured), 0x0103 ADF (byte windows 0x0000.., CSR window 0xFFFF,
write-back window 0xFFFE), the core's devices unchanged.  **0x0002 M2M$CONFIG (menu strings) is gone**
in the host build: reads return 0; the strings come from the data file.

### 3.1 RTC (the host build completes the read itself)

Today on the K325T (`G_NO_I2C`) rtc_master's I2C read never completes: rtc_busy stays 1, the
"new value" toggle (bit 64 of the 65-bit MiSTer word) never flips, so minimig's $DC0000 registers
keep their power-up value (all zero) and the Amiga never gets a time.

**Host build only** (`G_QNICE_LOCAL = false`; the local-QNICE build keeps rtc_master and stays as it
is): rtc_master is replaced by a host variant with no I2C.  After reset it is idle (busy = 0, and the
reset-time read is NOT completed, so the Amiga sees nothing until the shell sets a time).  A read
command completes in one clock and returns rtc_controller's own registers, i.e. the values the shell
has just written; rtc_controller then copies them back and flips the toggle as it does after a real
I2C read.  A write command (b2) completes at once and does nothing.

Device 0x0006, word offsets in the 0x7000 window (one register per word, low byte used, BCD):

| Offset | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| | 1/100 s | seconds | minutes | hours | day | month | year (00..99) | weekday (0..6, 0 = Sunday) | command: b0 busy (RO), b1 read, b2 write, b3 running |

Sequence (the shell, at start and once per minute or whenever it likes):

1. `WR 0xFFF4 = 0x0006`, `WR 0xFFF5 = 0x0000` (or BW16 to device 6 window 0).
2. `WR 0x7008 = 0x0000` -- stop the controller's clock (only accepted while running and not busy;
   registers 0..7 are writable only when stopped).
3. `WR 0x7000..0x7007` = 1/100 s, s, min, h, day, month, year, weekday (BCD, e.g. 0x59 for 59).
4. `WR 0x7008 = 0x000A` -- read (b1) + running (b3): the host rtc_master completes the read at once;
   rtc_controller copies the registers, flips the toggle, minimig loads them into $DC0000.
5. Optional check: `RD 0x7008` == 0x0008 (running, not busy).

minimig's own copy advances seconds only (it stops at :59), so the shell repeats the sequence once
per minute (today's RTC_STEP cadence); rtc_controller keeps running between updates.

**Visibility to the Amiga:** there is no menu selection.  gary.v decodes $DC0000-$DCFFFF as the
clock unconditionally (`sel_rtc`), in every topology; today it reads all zero digits.  Once the shell
sets a time, Kickstart's battclock and `setclock` see a set clock.  The effect on the reference
values (A500 gate 6b9c877b / 2649b948, E fff52892, cputime2) is information only: the reference
runs are made with the clock unset (below).

**Decision (2026-11-13):** no clock bit in the FPGA.  Setting the clock is an opt-in setting of
the Linux shell, default off: with it off the shell never writes device 6, so the machine is exactly
today's (clock unset) and the reference runs are untouched by construction.
## 4. Service requests (no hard polling)

The core's requests all were polled by QNICE (ADF write-back STAT, PARSEST, the screen-mode
measurement, the RTC minute).  The bridge STATUS is already read by m65io/m65d at a high rate; v1
of the master adds no core-side attention signal (the core VHDL stays unchanged).  The shell polls
WBC STAT (one RD) at 10 Hz and SYS_INFO window 0x30 at 20 Hz -- each a few microseconds of bridge
time.  If a hard attention line is ever needed: the hard disk's GPIO approach (BCM7 is taken by the
disk; another free line would have to be found per board).

## 5. Reset, hold and power-up

- Without a host after configuration: CSR = 0x0839 -> the core is held in reset, the overlay is
  off, the picture shows what a held core shows (black), no output floats.  Nothing starts until the
  shell releases CSR b0.
- The M2M reset (bridge ctrl b0, m65d `hold_reset`) resets the core and the framework as today; it
  also resets the master's registers to their power-up values **except the start marker** (and the
  menu id / defaults, which are constants).  So after a long press the core is held again and the
  shell must reload settings + Kickstart (as today's QNICE restart did).
- Short press (core reset only): as today, the master is untouched.
- Topology lines (CFM) are held by the core during resets and a change while running cold-boots the
  Amiga (unchanged core rule); the shell changes them only with the core held.

## 6. Throughput (present bridge rate: 40 MHz requested = 33 MHz real; the rate stays as it is)

Measured in the GHDL bench `K325T/sim/tb_host_link.vhd` (SPI master at 33.3 MHz, no gaps inside a
transfer, 50 us between transfers as a stand-in for the RK3568's per-transfer cost, a STATUS read
before every HOST_PUT to pace by the free count; the real rk_bridge and qnice_host RTL):

| Stream | Bench result | Limit |
|---|---|---|
| 64 KB into a Kickstart-port model (toggle handshake, 4-cycle acknowledge) in 4 KB HOST_PUTs | **3.66 MB/s** | the wire (4 KB = 0.98 ms + the gap + one STATUS) |
| 8 KB into a RAM device with 6 wait cycles per byte | 3.5 MB/s | the wire |
| BR8 of 2816 bytes, answers fetched through HOST_GET as STATUS shows them | 1.1 ms (2.6 MB/s incl. the polls) | the poll pattern |

The master itself needs 4 clocks + the device's wait per byte (S_DATA, S_ACC, S_WAIT, the idle
cycle QNICE also had): 12.5 M bytes/s with no wait, so a device limits only above ~10 wait cycles
(50 MHz / (4 + w) < 3.7 MB/s when w > 9).

- **Kickstart (0x0100):** chip_cache's load port acknowledges each byte through two clock crossings
  (qnice_clk -> ui_clk and back, ~4-6 qnice clocks) and writes a 64-byte line into DDR3 every 64
  bytes (a byte waits while the previous line is still being written).  Expected 5-8 MB/s at the
  device, so the wire limits: **512 KB in ~0.15 s, 1 MB in ~0.3 s.**
- **ADF (0x0103):** writes are posted -- qnice2hyperram's wait is only the avm_fifo's waitrequest,
  so bytes stream at the wire rate while the FIFO drains into the MIG (one 16-bit DDR3 write with a
  byte enable per file byte): expected near the wire rate, **880 KB in ~0.25-0.4 s** (to be measured
  on the board; the MIG's random-write rate is far above 3.7 M/s).  One floppy track (5632 bytes)
  = ~1.6 ms of wire time.
- **ADF write-back read (BR8 of a track, 5632 bytes):** every byte is a DDR3 read round trip
  (two clock crossings + the MIG), est. 300-500 ns -> **~2-3 ms per track**; the shell splits a
  track into reads of at most 4 KB of answers (the GET FIFO), menu_gen/shell side.
- **Key latency:** a key event waits behind at most one 4 KB transfer: ~1.1 ms.

Both targets (>= 1 MB/s sustained into 0x0100 and 0x0103, chunks <= 4 KB) are met in the bench.
On the boards (m65d's own timing, file read included): Kickstart 256 KB in 0.36-0.41 s (Radxa CM3),
512 KB in 0.78 s (Luckfox Core3566); the core is released ~1.2 s after the JTAG load returns.

## 6a. Bench link (Verilator bench `K325T/sim/aga`, option `--host-link REQ RSP`)

For running the shell against the simulated core.  The bench opens two named pipes (the client
creates them with mkfifo; REQ is read by the bench, RSP written by it) and handles one request
line at a time, answering each with one line.  The simulation runs only inside `W`.

| Request | Answer | Meaning |
|---|---|---|
| `S` | 164 hex digits | the 82 STATUS bytes, the bridge's layout: 0..2 = 4D 65 04, 52 = 03, 72 = 01, 73/74 PUT free, 75/76 GET fill, 77 flags (b0 overflow, b1..b4 from the master), 78..81 the menu id given with `--menu-id HEX` (the bench's package id is printed in its build log, `menu_gen.log`) |
| `P <hex>` | `OK` | HOST_PUT: the bytes join the 8 KB PUT queue (overflow sets STATUS 77 b0) |
| `G <n>` | 2n hex digits | HOST_GET: n bytes from the GET queue, 00 past its fill level |
| `R` | `OK` | HOST_RESET: both queues emptied, b0 cleared, the master's clear pulse |
| `W <ticks>` | `OK <frame> <tick>` | run n machine ticks (28.375 MHz; the master's 50 MHz clock runs alongside) |
| `Q` | - | quit (EOF on REQ too) |

What is real in the bench: qnice_host (the register file, the stream parser, the device bus) and,
behind it, chip_cache's Kickstart load port into the DDR3 model -- the Kickstart reaches the machine
only through the master (`--kick FILE` is then only the cache check's shadow copy).  CSR b0 holds
the machine (rst_ext) as on the board.  What is modelled: the bridge's SPI and FIFOs (queues in
the bench; `sim/tb_host_link.vhd` tests the real ones), time on the wire (none), the menu bits
(CFM drives nothing yet: the machine configuration comes from the bench's `--chipset/--mem/--cpu`
options).  Device 0x0103 is the real adf_mount_wrapper (its CDC FIFO is a pass-through in the
bench); with the link on, df0 (the core's adf_track_engine) follows the wrapper's mounted / track
count and reads the image the wrapper wrote -- the bench's own `--adf` is not used.  Not wired yet:
the track engine's write-back events into the wrapper (WBC dirty bits stay 0).  (The example
client used for the bench runs is lab tooling outside this repository.)

## 7. FPGA side: state (2026-11-13, branch a1200-lxshell)

1. RTL done and bench-tested: `K325T/qnice_host.vhd` (register file + bus engine + stream parser,
   `sim/tb_qnice_host.vhd`), `K325T/bridge/rk_bridge.vhdl` (HOST_FIFOS: PUT 8 KB = 2 RAMB36, GET 4 KB
   = 1 RAMB36, Gray-coded pointers clk162 <-> qnice_clk; `sim/tb_host_link.vhd` end to end over SPI),
   the host RTC (`rtc_controller` G_HOST_RTC, `sim/tb_rtc_host.vhd`).  Wired: G_LXSHELL builds it,
   sd_emu is not built.  Built (build_lx1, both boards) and board-tested with the Linux shell;
   results and sizes in PORTING.md.
2. The bridge change lives ONLY in the Amiga branch copy `K325T/bridge/rk_bridge.vhdl` (user decision
   2026-11-13: the Linux menu is for the Amiga only, mega65-core is not touched).  That copy has
   diverged from the master copy `mega65-core/src/vhdl/rk_bridge.vhdl` (base 0705ce35, identical in
   the Vixen trees): + generic HOST_FIFOS (default false), + ports host_* (with defaults), + opcodes
   0x80/0x81/0x82, + STATUS 72..81 (0 without HOST_FIFOS), + the PUT/GET FIFOs and their Gray-code
   crossing.  A later sync in either direction is a conscious step, not routine.
3. Menu id / defaults: `K325T/host_menu_pkg.vhd` is written by `menu_gen.py --vhdl` in every build
   (not tracked; package `host_menu_pkg`, constants `C_HOST_MENU_ID`,
   `C_HOST_CFM_DEFAULTS` with bit n of word w = CFM bit 16w+n, i.e. word w at bits 16w+15..16w).
   An id of 0 means "no menu file matches".
4. How the shell uses this protocol (agreed with the Linux side):
   - the RTC sequence of section 3.1; the weekday byte is passed through unchanged, the shell picks
     the convention;
   - a long press (SW3 or m65d `hold_reset`) is detected by the shell itself: start marker set and
     CSR b0 = 1 although the shell did not hold the core = the master's registers were reset ->
     reload settings + Kickstart, release (CSR is polled at 10 Hz together with WBC STAT);
   - an ADF track (5632 bytes) is read in BR8 bursts of at most 4096 bytes (the GET FIFO);
   - before every single WR/RD into 0x7000..0x7FFF the shell writes 0xFFF4/0xFFF5 again and never
     relies on what a burst left there;
   - at most 4093 bytes per HOST_PUT including the command headers (a burst header is 10 bytes);
   - a (re)started m65d sends HOST_RESET first to drop a half-sent stream (registers untouched);
   - the menu data file `<bitstream>.menu` is made by `K325T/menu_gen.py` in the build (sorted JSON,
     no timestamps); its CRC-32 is the menu id at 0xFFF9/0xFFFA, the shell checks it before drawing;
   - CSR b3/b4/b5 gate keyboard, mouse (port 1) and joystick (port 2) exactly as in the QNICE build
     (section 3); the shell clears b3 while the menu is open.
