--------------------------------------------------------------------------------
-- rk_bridge.vhdl -- Rockchip (CM4 socket) <-> MEGA65 service bridge.
--
-- AExp (Amiga) COPY, diverged on purpose from the master copy mega65-core/src/vhdl/rk_bridge.vhdl
-- (base 0705ce35): + HOST_FIFOS and the host master's opcodes 0x80..0x82 / STATUS 72..81 for the
-- Linux shell (a1200-lxshell, user decision 2026-11-13: the Linux menu is for the Amiga only, the
-- MEGA65 core and mega65-core stay untouched).  Syncing the two copies is a conscious step.
--
-- The Rockchip is SPI master on spi3-m1 (/dev/spidev3.0, mode 0, MSB first).
-- The SPI slave, command decoder, FIFOs and UART engine run in a FAST clock
-- (clk, 162 MHz on the K325T = 4 x cpuclock from the same MMCM).  SCK is
-- oversampled there, so the link runs at up to ~25 MHz (v1 sampled at
-- 40.5 MHz and topped out near 4-6 MHz).  Everything the MEGA65 side uses is
-- resynchronised into cpuclk; the sector buffers are dual-clock block RAMs.
--
-- One transaction = CS low, command byte, payload, CS high.
--   0x01 STATUS   : cmd, dummy, then status bytes (see below)
--   0x10 SD_PUT   : cmd, 512 bytes  -> read buffer; marks read data ready
--   0x11 SD_GET   : cmd, dummy, 512 bytes of the captured write block
--   0x12 SD_WACK  : cmd             -> write block consumed, release busy
--   0x13 SD_RERR  : cmd             -> pending read is out of range (error token)
--   0x14 SD_PREF  : cmd, slot, count, lba(4, BE), count x 512 bytes  (v4)
--                   read-ahead: sectors lba.. into prefetch slots slot.. (mod 16), count 1..7
--                   (the Rockchip's spidev moves at most 4096 bytes per transaction).  A slot is
--                   invalidated before it is written and validated with its LBA tag once
--                   complete; the slot the emulator is reading from is never overwritten, and a
--                   sector whose LBA is being written by the MEGA65 is not validated.
--   0x15 SD_INVAL : cmd             -> invalidate all prefetch slots (v4)
--   0x20 UART_PUT : cmd, N bytes    -> MEGA65 serial monitor input (RsRx)
--   0x21 UART_GET : cmd, dummy, N bytes of monitor output (0x00 when empty)
--   0x40 ETH_TXGET: cmd, dummy, frame bytes (MAC -> Rockchip; length from STATUS
--                   16-17). The frame is released at CS rise once it was fully read.
--   0x41 ETH_RXPUT: cmd, len_hi, len_lo, frame bytes incl. FCS (Rockchip -> MAC);
--                   committed at CS rise if exactly len bytes arrived and a slot is free.
--   0x70 VIDEO    : cmd, sel        -> HDMI picture source: b0 = 1 the Rockchip's own picture
--                   (BT1120 -> linux_fb video buffer), 0 = the core's picture (K325T)
--                   b1 = sample the BT1120 data on the rising clock edge (else falling)
--                   STATUS 59 = sel; 60..63 = linux_fb diagnostics (BT1120 clock domain):
--                   frames seen (8) | lines of the last frame (12) | b3 rising edge, b2 data
--                   enable seen, b1 YC swapped, b0 locked | pixels of the last line / 16
--                   64..71 = raw bus per 2^20-clock window: data lines seen high (16), seen
--                   low (16), FF words on the low / high byte (8+8), BT1120 clock count / 65536
--   0x80 HOST_PUT : cmd, N bytes    -> the host master's command FIFO (8 KB; HOST_FIFOS only)
--   0x81 HOST_GET : cmd, dummy, N bytes of the master's answers (0x00 when empty)
--   0x82 HOST_RESET: cmd            -> empty both FIFOs, clear the sticky flags, reset the
--                   master's stream parser (host_clr); see ext/aexp9_lxshell/PROTOCOL.md
--   0x30 INPUT    : cmd, ctrl, joyA, joyB, col0..col8   (all active high)
--                   ctrl: b0 hold CPU reset, b1 RESTORE, b2 CAPS LOCK,
--                         b3 use physical J12 SD instead of the emulator
--                   joy : b0 up b1 down b2 left b3 right b4 fire
--                   colN: MEGA65 keyboard matrix column N, bit = row
--
-- STATUS bytes (after cmd + dummy):
--   0 'M'(0x4D) 1 0x65 2 version 3 flags 4 sd seq 5..8 sd lba (BE)
--   9..10 uart rx count (BE) 11..12 uart tx free (BE) 13 sd cmd count
--   14 last sd cmd (b7 = ACMD) 15 ctrl readback
--   16..17 next Ethernet frame MAC->Rockchip, length (BE, 0 = none)
--   18 free Ethernet RX slots   19 Ethernet frames dropped (no free TX slot)
--   flags: b0 rd_req b1 rd_ready b2 wr_req b3 sd inited b4 uart rx overflow
--          b5 rd_error
--   52 core id  53 flash overrun  54..55 prefetch valid bitmap (BE)  56..57 prefetch hits
--   (BE, wraps)  58 slot the emulator reads (16 = the SD_PUT slot)  59 VIDEO sel readback
-- Read cache (v4): 16 prefetch slots + 1 demand slot (SD_PUT) in one 16 KB block RAM.  While
-- a read is pending and unanswered, its LBA is compared with the 16 tags; on a hit the
-- emulator is switched to that slot and rd_ready rises after a short settle time (the slot
-- number crosses into cpuclk first) -- no Rockchip round trip.  Writes stay synchronous; a write
-- captured for an LBA invalidates a slot holding it.
--
-- Handshake with sd_emu (levels, safe across the clock domains):
--   rd_ready / rd_error rise when the server answers and fall once the
--   emulator drops rd_req; wr_ack rises on SD_WACK and falls once the
--   emulator drops wr_req.
--
-- The monitor UART is bridged at BIT_CLKS fast clocks per bit
-- (80 @ 162 MHz = 2.025 Mbaud, the monitor's 40.5 MHz / 20).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rk_bridge is
  generic (
    BIT_CLKS : integer := 80;
    CORE_ID  : std_logic_vector(7 downto 0) := x"01";  -- STATUS byte 52: 1 = MEGA65, 2 = C64
    -- the host master's FIFOs (Amiga core without local QNICE): false = none, STATUS 72..81 read 0
    HOST_FIFOS : boolean := false
  );
  port (
    clk        : in  std_logic;              -- fast bridge clock (162 MHz)
    cpuclk     : in  std_logic;              -- MEGA65 cpuclock (40.5 MHz)
    -- SPI from the Rockchip (asynchronous)
    spi_sck    : in  std_logic;
    spi_cs_n   : in  std_logic;
    spi_mosi   : in  std_logic;
    spi_miso   : out std_logic;
    -- SD emulator (cpuclk domain)
    sd_rd_req  : in  std_logic;
    sd_wr_req  : in  std_logic;
    sd_lba     : in  unsigned(31 downto 0);
    sd_seq     : in  unsigned(7 downto 0);
    sd_inited  : in  std_logic;
    sd_cmd_cnt : in  unsigned(7 downto 0);
    sd_last_cmd: in  unsigned(7 downto 0);
    sd_rd_ready: out std_logic;
    sd_rd_error: out std_logic;
    sd_wr_ack  : out std_logic;
    rbuf_addr  : in  unsigned(8 downto 0);
    rbuf_data  : out std_logic_vector(7 downto 0);
    wbuf_we    : in  std_logic;
    wbuf_addr  : in  unsigned(8 downto 0);
    wbuf_data  : in  std_logic_vector(7 downto 0);
    -- serial monitor (cpuclk domain)
    mon_rx     : out std_logic;              -- to machine RsRx
    mon_tx     : in  std_logic;              -- from machine UART_TXD
    -- keyboard matrix (widget interface) and joysticks (cpuclk domain)
    matrix_col_idx : in  integer range 0 to 15;
    matrix_col     : out std_logic_vector(7 downto 0);   -- active low
    joya           : out std_logic_vector(4 downto 0);   -- active high
    joyb           : out std_logic_vector(4 downto 0);
    ctrl           : out std_logic_vector(7 downto 0);
    -- paddles / 1351 mouse: pot1 x, pot1 y, pot2 x, pot2 y (INPUT bytes 13..16), $FF = open
    pots           : out std_logic_vector(31 downto 0);
    -- configuration flash pass-through (command 0x50), all in clk: SPI mode 0, ~clk/6
    flash_active   : out std_logic;              -- a 0x50 frame owns the flash pins
    flash_sck      : out std_logic;              -- to STARTUPE2.USRCCLKO
    flash_cs_n     : out std_logic;
    flash_mosi     : out std_logic;              -- DQ0
    flash_miso     : in  std_logic := '1';       -- DQ1
    -- reboot into another bitstream (command 0x60): toggles once per request, in clk
    iprog_toggle   : out std_logic;
    video_sel      : out std_logic_vector(7 downto 0) := x"00";   -- 0x70 VIDEO (clk domain)
    video_diag     : in  std_logic_vector(31 downto 0) := (others => '0');  -- STATUS 60..63 (async, diagnostic)
    video_diag2    : in  std_logic_vector(63 downto 0) := (others => '0');  -- STATUS 64..71 (async, diagnostic)
    iprog_addr     : out std_logic_vector(31 downto 0);
    -- Ethernet virtual PHY (eth_vphy, clk side)
    eth_tx_avail   : in  std_logic := '0';
    eth_tx_len     : in  unsigned(10 downto 0) := (others => '0');
    eth_tx_raddr   : out unsigned(10 downto 0);
    eth_tx_rdata   : in  std_logic_vector(7 downto 0) := (others => '0');
    eth_tx_pop     : out std_logic;
    eth_tx_drops   : in  unsigned(7 downto 0) := (others => '0');
    eth_rx_free    : in  unsigned(3 downto 0) := (others => '0');
    eth_rx_we      : out std_logic;
    eth_rx_waddr   : out unsigned(10 downto 0);
    eth_rx_wdata   : out std_logic_vector(7 downto 0);
    eth_rx_push    : out std_logic;
    eth_rx_len     : out unsigned(10 downto 0);
    -- host master (HOST_FIFOS): command bytes out (FWFT) and answer bytes in, in host_clk
    host_clk       : in  std_logic := '0';
    host_s_data    : out std_logic_vector(7 downto 0);
    host_s_valid   : out std_logic;
    host_s_pop     : in  std_logic := '0';
    host_m_data    : in  std_logic_vector(7 downto 0) := (others => '0');
    host_m_push    : in  std_logic := '0';
    host_m_full    : out std_logic;
    host_clr       : out std_logic;                   -- one host_clk pulse per HOST_RESET
    host_ver       : in  std_logic_vector(7 downto 0)  := (others => '0');  -- STATUS 72
    host_flags     : in  std_logic_vector(7 downto 0)  := (others => '0');  -- STATUS 77 b7..b1 (async)
    host_id        : in  std_logic_vector(31 downto 0) := (others => '0');  -- STATUS 78..81 (constant)
    -- activity
    spi_active     : out std_logic
  );
end entity;

architecture rtl of rk_bridge is

  constant VERSION : std_logic_vector(7 downto 0) := x"04";
  constant DEMAND  : unsigned(4 downto 0) := to_unsigned(16, 5);   -- SD_PUT slot

  type ram512_t  is array (0 to 511)  of std_logic_vector(7 downto 0);
  type ram1k_t   is array (0 to 1023) of std_logic_vector(7 downto 0);
  type ram16k_t  is array (0 to 16383) of std_logic_vector(7 downto 0);
  type mat_t     is array (0 to 8) of std_logic_vector(7 downto 0);

  signal rbuf : ram16k_t;   -- 17 x 512: prefetch slots 0..15 + SD_PUT slot 16; written in clk, read in cpuclk
  signal wbuf : ram512_t;   -- written in cpuclk, read in clk
  signal txf  : ram1k_t;    -- Rockchip -> monitor (clk only)
  signal rxf  : ram16k_t;   -- monitor  -> Rockchip (clk only)

  -- ---------------- fast (clk) domain ----------------
  -- SPI slave
  signal sck_s  : std_logic_vector(2 downto 0) := (others => '0');
  signal cs_s   : std_logic_vector(1 downto 0) := (others => '1');
  signal mosi_s : std_logic_vector(1 downto 0) := (others => '0');
  signal rx_sr  : std_logic_vector(6 downto 0) := (others => '0');
  signal bitcnt : integer range 0 to 7 := 0;
  signal bidx   : unsigned(11 downto 0) := (others => '0');  -- byte index, saturating (Ethernet frames up to 1518 + 3 bytes)
  signal cmd    : std_logic_vector(7 downto 0) := (others => '0');
  signal miso_r : std_logic := '0';
  -- ethernet status bytes 16..19, registered one cycle before the STATUS mux (they are polled:
  -- one cycle of staleness is harmless; the live eth_tx_avail -> mux -> miso_r path was the
  -- design's critical path)
  signal eth_avail_r : std_logic := '0';
  signal eth_len_r   : unsigned(10 downto 0) := (others => '0');
  signal eth_free_r  : unsigned(3 downto 0) := (others => '0');
  signal eth_drops_r : unsigned(7 downto 0) := (others => '0');
  signal tx_sr  : std_logic_vector(6 downto 0) := (others => '0');

  -- inputs from the cpuclk domain, synchronised
  signal rd_req_s, wr_req_s, inited_s : std_logic_vector(1 downto 0) := (others => '0');
  signal lba_f   : unsigned(31 downto 0) := (others => '0');
  signal seq_f, ccnt_f, lcmd_f : unsigned(7 downto 0) := (others => '0');

  -- buffers / handshake
  signal wbuf_raddr : unsigned(8 downto 0) := (others => '0');
  signal wbuf_dout  : std_logic_vector(7 downto 0) := (others => '0');
  -- wbuf_dout registered once more (the BRAM's output register): the SD_GET byte reaches the
  -- MISO mux from a flip-flop, not from the BRAM's clock-to-out.  The read address changes at a
  -- byte boundary and the next boundary is >= 32 clk cycles later, so the extra cycle of
  -- latency is invisible (the prefetch at the command byte covers the first data byte).
  signal wbuf_q     : std_logic_vector(7 downto 0) := (others => '0');
  signal stat_q     : std_logic_vector(7 downto 0) := (others => '0');   -- STATUS byte, registered
  -- early MISO: the bit miso_r takes at the next rising SCK edge, prepared between edges (nxt_pre
  -- = the byte the boundary arm below will send, mbit_r = its MSB or the next bit of tx_sr), so
  -- miso_r can take it one clock earlier, from the first input stage (see the SPI slave)
  signal nxt_pre    : std_logic_vector(7 downto 0) := (others => '0');
  signal mbit_r     : std_logic := '0';
  signal nxt_av     : std_logic := '0';   -- UART_GET: a byte was there when nxt_pre was taken
  signal rd_ready_r : std_logic := '0';
  signal rd_error_r : std_logic := '0';
  signal wr_ack_r   : std_logic := '0';
  signal rbuf_we    : std_logic := '0';
  signal rbuf_wa    : unsigned(13 downto 0) := (others => '0');

  -- host master FIFOs (HOST_FIFOS).  PUT: written here (clk), read in host_clk; GET: written in
  -- host_clk, read here with a peek pointer like the UART RX FIFO.  Pointers cross in Gray code.
  type ram8k_t is array (0 to 8191) of std_logic_vector(7 downto 0);
  type ram4k_t is array (0 to 4095) of std_logic_vector(7 downto 0);
  signal pf_we      : std_logic := '0';
  signal pf_wa      : unsigned(12 downto 0) := (others => '0');
  signal pf_wd      : std_logic_vector(7 downto 0) := (others => '0');
  signal pf_wp      : unsigned(13 downto 0) := (others => '0');   -- clk
  signal pf_wp_g    : std_logic_vector(13 downto 0) := (others => '0');
  signal pf_rp      : unsigned(13 downto 0) := (others => '0');   -- host_clk
  signal pf_rp_g    : std_logic_vector(13 downto 0) := (others => '0');
  signal pf_rp_s1, pf_rp_s2 : std_logic_vector(13 downto 0) := (others => '0');   -- in clk
  signal pf_wp_h1, pf_wp_h2 : std_logic_vector(13 downto 0) := (others => '0');   -- in host_clk
  signal pf_free    : unsigned(14 downto 0) := (others => '0');
  signal pf_ovf     : std_logic := '0';
  signal gf_wp      : unsigned(12 downto 0) := (others => '0');   -- host_clk
  signal gf_wp_g    : std_logic_vector(12 downto 0) := (others => '0');
  signal gf_wp_s1, gf_wp_s2 : std_logic_vector(12 downto 0) := (others => '0');   -- in clk
  signal gf_wp_c    : unsigned(12 downto 0) := (others => '0');   -- gf_wp in clk
  signal gf_rp      : unsigned(12 downto 0) := (others => '0');   -- clk: committed
  signal gf_pp      : unsigned(12 downto 0) := (others => '0');   -- clk: peek
  signal gf_rp_g    : std_logic_vector(12 downto 0) := (others => '0');
  signal gf_rp_h1, gf_rp_h2 : std_logic_vector(12 downto 0) := (others => '0');   -- in host_clk
  signal gf_dout    : std_logic_vector(7 downto 0) := (others => '0');
  signal gf_fill    : unsigned(12 downto 0) := (others => '0');
  signal gcur_from_fifo : std_logic := '0';
  signal gnxt_av    : std_logic := '0';
  signal hr_tgl     : std_logic := '0';                              -- HOST_RESET, clk
  signal hr_h1, hr_h2, hr_h3 : std_logic := '0';                     -- in host_clk
  signal hr_drop    : unsigned(6 downto 0) := (others => '0');       -- clk: drop GET bytes a while
  signal hflags_s1, hflags_s2 : std_logic_vector(7 downto 0) := (others => '0');

  function gray(b : unsigned) return std_logic_vector is
  begin
    return std_logic_vector(b xor ('0' & b(b'high downto b'low + 1)));
  end function;
  function ungray(g : std_logic_vector) return unsigned is
    variable b : unsigned(g'range);
  begin
    b(g'high) := g(g'high);
    for i in g'high - 1 downto g'low loop
      b(i) := b(i + 1) xor g(i);
    end loop;
    return b;
  end function;
  -- read cache
  type tag_t is array (0 to 15) of unsigned(31 downto 0);
  signal tags       : tag_t := (others => (others => '0'));
  signal vld        : std_logic_vector(15 downto 0) := (others => '0');
  signal match      : std_logic_vector(15 downto 0) := (others => '0');
  signal act_slot   : unsigned(4 downto 0) := to_unsigned(16, 5);
  signal act_c1, act_c2 : unsigned(4 downto 0) := to_unsigned(16, 5);   -- cpuclk copies
  signal hit_wait   : integer range 0 to 15 := 0;
  signal hit_cnt    : unsigned(15 downto 0) := (others => '0');
  signal demand_busy: std_logic := '0';
  signal pf_cur     : unsigned(3 downto 0) := (others => '0');
  signal pf_count   : integer range 0 to 7 := 0;
  signal pf_k       : integer range 0 to 8 := 0;
  signal pf_off     : integer range 0 to 511 := 0;
  signal pf_lba     : unsigned(31 downto 0) := (others => '0');
  signal pf_skip    : std_logic := '0';
  signal fresh1     : std_logic_vector(15 downto 0) := (others => '0');  -- tagged last cycle
  signal rbuf_wd    : std_logic_vector(7 downto 0) := (others => '0');

  -- UART FIFOs (pointers carry one extra wrap bit)
  signal txf_wp, txf_rp : unsigned(10 downto 0) := (others => '0');
  signal txf_wp_d, txf_wp_d2 : unsigned(10 downto 0) := (others => '0');
  signal txf_dout       : std_logic_vector(7 downto 0) := (others => '1');
  signal txf_we         : std_logic := '0';
  signal txf_wa         : unsigned(9 downto 0) := (others => '0');
  signal txf_wd         : std_logic_vector(7 downto 0) := (others => '0');
  signal rxf_wp, rxf_rp : unsigned(14 downto 0) := (others => '0');
  -- UART_GET pre-loads the next byte before the master clocks it; it is only
  -- committed (rxf_rp advanced) once actually shifted out, so the byte loaded
  -- for a position the master never clocks (end of transaction) stays queued.
  signal rxf_pp         : unsigned(14 downto 0) := (others => '0');  -- peek pointer
  signal cur_from_fifo  : std_logic := '0';
  signal rxf_wp_d, rxf_wp_d2 : unsigned(14 downto 0) := (others => '0');
  signal rxf_dout       : std_logic_vector(7 downto 0) := (others => '0');
  signal rxf_we         : std_logic := '0';
  signal rxf_wa         : unsigned(13 downto 0) := (others => '0');
  signal rxf_wd         : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_overflow    : std_logic := '0';
  signal rx_count       : unsigned(14 downto 0);
  signal tx_free        : unsigned(10 downto 0);

  -- serializer to the monitor / deserializer from the monitor
  signal ser_busy  : std_logic := '0';
  signal ser_sr    : std_logic_vector(9 downto 0) := (others => '1');
  signal ser_bits  : integer range 0 to 10 := 0;
  signal ser_tmr   : integer range 0 to BIT_CLKS-1 := 0;
  signal ser_wait  : integer range 0 to 3 := 0;
  signal mon_rx_f  : std_logic := '1';
  signal des_in    : std_logic_vector(2 downto 0) := (others => '1');
  signal des_busy  : std_logic := '0';
  signal des_tmr   : integer range 0 to BIT_CLKS-1 := 0;
  signal des_bits  : integer range 0 to 9 := 0;
  signal des_sr    : std_logic_vector(7 downto 0) := (others => '0');

  -- Ethernet
  signal eth_raddr  : unsigned(10 downto 0) := (others => '0');
  signal eth_rxlen  : unsigned(10 downto 0) := (others => '0');
  signal cs_prev    : std_logic := '1';

  -- input registers
  signal ctrl_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal joya_r  : std_logic_vector(4 downto 0) := (others => '0');
  signal joyb_r  : std_logic_vector(4 downto 0) := (others => '0');
  signal mat     : mat_t := (others => (others => '0'));
  signal pots_r  : std_logic_vector(31 downto 0) := (others => '1');

  -- configuration flash pass-through (0x50): frame = 0x50, len_hi, len_lo, len data bytes,
  -- then 2 pad bytes; the flash's answer to data byte k comes back in frame byte k + 5.
  -- 8 clocks with CS high go out first (STARTUPE2 swallows the first USRCCLKO cycles).
  signal fl_len    : unsigned(15 downto 0) := (others => '0');
  signal fl_sent   : unsigned(15 downto 0) := (others => '0');
  signal fl_act    : std_logic := '0';                 -- frame in progress
  signal fl_busy   : std_logic := '0';                 -- engine shifting a byte
  signal fl_pre    : std_logic := '0';                 -- shifting the dummy clocks
  signal fl_tx     : std_logic_vector(7 downto 0) := (others => '1');
  signal fl_rx     : std_logic_vector(7 downto 0) := (others => '1');
  signal fl_resp   : std_logic_vector(7 downto 0) := (others => '1');
  signal fl_phase  : integer range 0 to 5 := 0;
  signal fl_bit    : integer range 0 to 7 := 0;
  signal fl_sck_r  : std_logic := '0';
  signal fl_cs_r   : std_logic := '1';
  signal fl_ovf    : std_logic := '0';                 -- a byte arrived while busy (sticky)
  signal fl_last   : std_logic := '0';                 -- release CS after this byte
  signal ip_addr   : std_logic_vector(31 downto 0) := (others => '0');
  signal ip_tog    : std_logic := '0';
  signal vid_r     : std_logic_vector(7 downto 0) := x"00";   -- 0x70 VIDEO

  -- ---------------- cpuclk domain copies ----------------
  signal rd_ready_c, rd_error_c, wr_ack_c : std_logic_vector(1 downto 0) := (others => '0');
  signal mon_rx_c : std_logic_vector(1 downto 0) := (others => '1');
  signal mat_c1, mat_c2 : mat_t := (others => (others => '0'));
  signal ctrl_c1, ctrl_c2 : std_logic_vector(7 downto 0) := (others => '0');
  signal joya_c1, joya_c2, joyb_c1, joyb_c2 : std_logic_vector(4 downto 0) := (others => '0');
  signal pots_c1, pots_c2, pots_c : std_logic_vector(31 downto 0) := (others => '1');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rd_req_s, wr_req_s, inited_s, rd_ready_c, rd_error_c,
    wr_ack_c, mon_rx_c, mat_c1, mat_c2, ctrl_c1, ctrl_c2, joya_c1, joya_c2,
    joyb_c1, joyb_c2, pots_c1, pots_c2, sck_s, cs_s, mosi_s, act_c1, act_c2 : signal is "TRUE";

begin

  -------------------------------------------------------------------------
  -- cpuclk side: buffer ports and synchronised outputs
  -------------------------------------------------------------------------
  process (cpuclk)
  begin
    if rising_edge(cpuclk) then
      -- the slot number is set >= 2 cpuclks before rd_ready rises and held while it is up
      act_c1 <= act_slot; act_c2 <= act_c1;
      rbuf_data <= rbuf(to_integer(act_c2 & rbuf_addr));
      if wbuf_we = '1' then
        wbuf(to_integer(wbuf_addr)) <= wbuf_data;
      end if;
      rd_ready_c <= rd_ready_c(0) & rd_ready_r;
      rd_error_c <= rd_error_c(0) & rd_error_r;
      wr_ack_c   <= wr_ack_c(0) & wr_ack_r;
      mon_rx_c   <= mon_rx_c(0) & mon_rx_f;
      mat_c1  <= mat;    mat_c2  <= mat_c1;
      ctrl_c1 <= ctrl_r; ctrl_c2 <= ctrl_c1;
      joya_c1 <= joya_r; joya_c2 <= joya_c1;
      joyb_c1 <= joyb_r; joyb_c2 <= joyb_c1;
      -- multi-bit value: take it only once two successive samples agree (no torn bytes)
      pots_c1 <= pots_r; pots_c2 <= pots_c1;
      if pots_c2 = pots_c1 then
        pots_c <= pots_c2;
      end if;
    end if;
  end process;

  sd_rd_ready <= rd_ready_c(1);
  sd_rd_error <= rd_error_c(1);
  sd_wr_ack   <= wr_ack_c(1);
  mon_rx      <= mon_rx_c(1);
  ctrl        <= ctrl_c2;
  joya        <= joya_c2;
  joyb        <= joyb_c2;
  pots        <= pots_c;
  -- The keymapper samples the column combinationally while it scans
  -- (a registered lookup shifts every key one column up).
  matrix_col  <= not mat_c2(matrix_col_idx) when matrix_col_idx <= 8 else (others => '1');

  -------------------------------------------------------------------------
  -- fast side
  -------------------------------------------------------------------------
  spi_miso   <= miso_r;
  eth_tx_raddr <= eth_raddr;
  eth_rx_len   <= eth_rxlen;
  spi_active <= not cs_s(1);
  flash_active <= fl_act;
  flash_sck    <= fl_sck_r;
  flash_cs_n   <= fl_cs_r;
  flash_mosi   <= fl_tx(7);
  iprog_toggle <= ip_tog;
  video_sel    <= vid_r;
  iprog_addr   <= ip_addr;
  rx_count   <= rxf_wp_d2 - rxf_rp;
  tx_free    <= to_unsigned(1024, 11) - (txf_wp - txf_rp);

  -- STATUS bytes: the byte for index bidx - 1 (the one sent at the end of byte bidx), computed
  -- every cycle into a register, so the wide status mux is off the boundary -> miso_r path.  The
  -- sources are polled; bidx changes at a byte boundary and the next one is >= 32 cycles later.
  process (clk)
    variable st : integer;
    variable v : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      st := to_integer(bidx) - 1;
      v := x"00";
      case st is
        when 0  => v := x"4D";
        when 1  => v := x"65";
        when 2  => v := VERSION;
        when 3  => v := "00" & rd_error_r & rx_overflow & inited_s(1) & wr_req_s(1)
                          & rd_ready_r & rd_req_s(1);
        when 4  => v := std_logic_vector(seq_f);
        when 5  => v := std_logic_vector(lba_f(31 downto 24));
        when 6  => v := std_logic_vector(lba_f(23 downto 16));
        when 7  => v := std_logic_vector(lba_f(15 downto 8));
        when 8  => v := std_logic_vector(lba_f(7 downto 0));
        when 9  => v := "0" & std_logic_vector(rx_count(14 downto 8));
        when 10 => v := std_logic_vector(rx_count(7 downto 0));
        when 11 => v := "00000" & std_logic_vector(tx_free(10 downto 8));
        when 12 => v := std_logic_vector(tx_free(7 downto 0));
        when 13 => v := std_logic_vector(ccnt_f);
        when 14 => v := std_logic_vector(lcmd_f);
        when 15 => v := ctrl_r;
        when 16 => if eth_avail_r = '1' then v := "00000" & std_logic_vector(eth_len_r(10 downto 8)); end if;
        when 17 => if eth_avail_r = '1' then v := std_logic_vector(eth_len_r(7 downto 0)); end if;
        when 18 => v := "0000" & std_logic_vector(eth_free_r);
        when 19 => v := std_logic_vector(eth_drops_r);
        when 52 => v := CORE_ID;
        when 72 => if HOST_FIFOS then v := host_ver; end if;
        when 73 => if HOST_FIFOS then v := '0' & std_logic_vector(pf_free(14 downto 8)); end if;
        when 74 => if HOST_FIFOS then v := std_logic_vector(pf_free(7 downto 0)); end if;
        when 75 => if HOST_FIFOS then v := "000" & std_logic_vector(gf_fill(12 downto 8)); end if;
        when 76 => if HOST_FIFOS then v := std_logic_vector(gf_fill(7 downto 0)); end if;
        when 77 => if HOST_FIFOS then v := hflags_s2(7 downto 1) & pf_ovf; end if;
        when 78 => if HOST_FIFOS then v := host_id(31 downto 24); end if;
        when 79 => if HOST_FIFOS then v := host_id(23 downto 16); end if;
        when 80 => if HOST_FIFOS then v := host_id(15 downto 8); end if;
        when 81 => if HOST_FIFOS then v := host_id(7 downto 0); end if;
        when 53 => v := "0000000" & fl_ovf;
        when 54 => v := vld(15 downto 8);
        when 55 => v := vld(7 downto 0);
        when 56 => v := std_logic_vector(hit_cnt(15 downto 8));
        when 57 => v := std_logic_vector(hit_cnt(7 downto 0));
        when 58 => v := "000" & std_logic_vector(act_slot);
        when 59 => v := vid_r;
        when 60 => v := video_diag(31 downto 24);
        when 61 => v := video_diag(23 downto 16);
        when 62 => v := video_diag(15 downto 8);
        when 63 => v := video_diag(7 downto 0);
        when 64 => v := video_diag2(63 downto 56);
        when 65 => v := video_diag2(55 downto 48);
        when 66 => v := video_diag2(47 downto 40);
        when 67 => v := video_diag2(39 downto 32);
        when 68 => v := video_diag2(31 downto 24);
        when 69 => v := video_diag2(23 downto 16);
        when 70 => v := video_diag2(15 downto 8);
        when 71 => v := video_diag2(7 downto 0);
        when others => v := x"00";
      end case;
      stat_q <= v;
    end if;
  end process;

  -- RAM ports in the fast domain (one write process per RAM -> BRAM)
  process (clk)
  begin
    if rising_edge(clk) then
      if rbuf_we = '1' then
        rbuf(to_integer(rbuf_wa)) <= rbuf_wd;
      end if;
      wbuf_dout <= wbuf(to_integer(wbuf_raddr));
      wbuf_q <= wbuf_dout;
      if txf_we = '1' then
        txf(to_integer(txf_wa)) <= txf_wd;
      end if;
      txf_dout <= txf(to_integer(txf_rp(9 downto 0)));
      if rxf_we = '1' then
        rxf(to_integer(rxf_wa)) <= rxf_wd;
      end if;
      rxf_dout <= rxf(to_integer(rxf_pp(13 downto 0)));
    end if;
  end process;

  process (clk)
    variable rxb   : std_logic_vector(7 downto 0);
    variable nxt   : std_logic_vector(7 downto 0);
    variable st    : integer range 0 to 4095;
    variable put_i : integer range 0 to 4095;
    variable vld_v : std_logic_vector(15 downto 0);
    variable fresh_v : std_logic_vector(15 downto 0);   -- tagged this cycle
    variable hit_i : integer range 0 to 16;

    -- the slot the emulator is being served from (or is about to be): never overwrite it
    impure function busy_slot(sl : unsigned(3 downto 0)) return boolean is
    begin
      return act_slot = ('0' & sl) and rd_req_s(1) = '1' and (rd_ready_r = '1' or hit_wait /= 0);
    end function;
  begin
    if rising_edge(clk) then
      eth_avail_r <= eth_tx_avail; eth_len_r <= eth_tx_len;
      eth_free_r <= eth_rx_free; eth_drops_r <= eth_tx_drops;
      vld_v := vld;
      fresh_v := (others => '0');
      rbuf_we   <= '0';
      eth_tx_pop  <= '0';
      eth_rx_we   <= '0';
      eth_rx_push <= '0';
      cs_prev   <= cs_s(1);
      txf_we    <= '0';
      rxf_we    <= '0';
      rxf_wp_d  <= rxf_wp;
      rxf_wp_d2 <= rxf_wp_d;
      -- host FIFOs, clk side
      pf_we     <= '0';
      pf_rp_s1  <= pf_rp_g;  pf_rp_s2 <= pf_rp_s1;
      pf_free   <= to_unsigned(8192, 15) - ('0' & (pf_wp - ungray(pf_rp_s2)));
      gf_wp_s1  <= gf_wp_g;  gf_wp_s2 <= gf_wp_s1;
      gf_wp_c   <= ungray(gf_wp_s2);
      gf_fill   <= gf_wp_c - gf_rp;
      hflags_s1 <= host_flags; hflags_s2 <= hflags_s1;
      if hr_drop /= 0 then          -- HOST_RESET: answers already given (or still coming) go
        hr_drop <= hr_drop - 1;
        gf_rp   <= gf_wp_c;
        gf_pp   <= gf_wp_c;
      end if;
      txf_wp_d  <= txf_wp;
      txf_wp_d2 <= txf_wp_d;

      -- emulator state, synchronised (lba/seq are stable whenever a request
      -- flag is seen: the emulator sets them long before raising the flag)
      rd_req_s <= rd_req_s(0) & sd_rd_req;
      wr_req_s <= wr_req_s(0) & sd_wr_req;
      inited_s <= inited_s(0) & sd_inited;
      lba_f  <= sd_lba;
      seq_f  <= sd_seq;
      ccnt_f <= sd_cmd_cnt;
      lcmd_f <= sd_last_cmd;

      -- level handshakes fall once the emulator has withdrawn the request
      if rd_req_s(1) = '0' then
        rd_ready_r  <= '0';
        rd_error_r  <= '0';
        hit_wait    <= 0;
        demand_busy <= '0';
      end if;
      -- tag compare, registered (lba_f is stable long before a request flag is seen)
      for i in 0 to 15 loop
        if tags(i) = lba_f then match(i) <= '1'; else match(i) <= '0'; end if;
      end loop;
      -- a write captured for an LBA invalidates its cached copy (writes stay synchronous)
      if wr_req_s(1) = '1' then
        for i in 0 to 15 loop
          if tags(i) = lba_f then vld_v(i) := '0'; end if;
        end loop;
      end if;
      if wr_req_s(1) = '0' then
        wr_ack_r <= '0';
      end if;

      ------------------------------------------------------------------
      -- SPI slave
      ------------------------------------------------------------------
      sck_s  <= sck_s(1 downto 0) & spi_sck;
      cs_s   <= cs_s(0) & spi_cs_n;
      mosi_s <= mosi_s(0) & spi_mosi;

      ------------------------------------------------------------------
      -- configuration flash engine: one byte = 8 bits x 6 clocks
      ------------------------------------------------------------------
      if fl_busy = '1' then
        if fl_phase = 5 then
          fl_phase <= 0;
          fl_sck_r <= '0';
          if fl_pre = '0' then
            fl_rx <= fl_rx(6 downto 0) & flash_miso;     -- sampled at the end of SCK high
          end if;
          if fl_bit = 7 then
            fl_busy <= '0';
            fl_bit  <= 0;
            if fl_pre = '0' then
              fl_resp <= fl_rx(6 downto 0) & flash_miso;
            end if;
            fl_pre <= '0';
            if fl_last = '1' then
              fl_cs_r <= '1';
              fl_last <= '0';
            end if;
          else
            fl_bit <= fl_bit + 1;
            fl_tx  <= fl_tx(6 downto 0) & '1';
          end if;
        else
          if fl_phase = 2 then
            fl_sck_r <= '1';                         -- flash samples MOSI on this edge
          end if;
          fl_phase <= fl_phase + 1;
        end if;
      end if;

      -- early MISO (one clock162 cycle = 6.2 ns more margin for the master's sample): when the
      -- rising SCK edge is in the first input stage (sck_s(0) = 1, sck_s(1) = 0), miso_r takes
      -- the prepared bit now; the edge detection below (sck_s(1)/sck_s(2), unchanged) assigns the
      -- same bit one cycle later.  sck_s(0) feeds only this LUT and sck_s(1): if it resolves late,
      -- miso_r changes one cycle later (as before), and the FSM never sees the unresolved stage.
      if bidx = 0 then
        nxt_pre <= x"00";
      else
        case cmd is
          when x"01" => nxt_pre <= stat_q;
          when x"11" => nxt_pre <= wbuf_q;
          when x"21" =>
            if rxf_wp_d2 /= rxf_pp then nxt_pre <= rxf_dout; else nxt_pre <= x"00"; end if;
          when x"81" =>
            if HOST_FIFOS and gf_wp_c /= gf_pp then nxt_pre <= gf_dout; else nxt_pre <= x"00"; end if;
          when x"40" => nxt_pre <= eth_tx_rdata;
          when x"50" =>
            if bidx > 2 then nxt_pre <= fl_resp; else nxt_pre <= x"00"; end if;
          when others => nxt_pre <= x"00";
        end case;
      end if;
      if rxf_wp_d2 /= rxf_pp then nxt_av <= '1'; else nxt_av <= '0'; end if;
      if HOST_FIFOS and gf_wp_c /= gf_pp then gnxt_av <= '1'; else gnxt_av <= '0'; end if;
      if bitcnt /= 7 then mbit_r <= tx_sr(6); else mbit_r <= nxt_pre(7); end if;
      if cs_s(1) = '0' and sck_s(1) = '0' and sck_s(0) = '1' then
        miso_r <= mbit_r;
      end if;

      if cs_s(1) = '1' then
        -- end of a transaction (bidx still holds its byte count here)
        if fl_busy = '0' and fl_last = '0' then
          fl_cs_r <= '1';
          fl_act  <= '0';
        end if;
        if cs_prev = '0' then
          if cmd = x"40" and bidx >= 2 and eth_tx_avail = '1'
             and (bidx - 2) >= ("0" & eth_tx_len) then
            eth_tx_pop <= '1';
          end if;
          if cmd = x"41" and bidx >= 3 and eth_rxlen /= 0 and eth_rx_free /= 0
             and (bidx - 3) = ("0" & eth_rxlen) then
            eth_rx_push <= '1';
          end if;
        end if;
        bitcnt <= 0;
        bidx   <= (others => '0');
        miso_r <= '0';
        tx_sr  <= (others => '0');
        rxf_pp <= rxf_rp;          -- un-sent pre-loaded byte stays in the FIFO
        gf_pp  <= gf_rp;
        gcur_from_fifo <= '0';
        cur_from_fifo <= '0';
      elsif sck_s(2) = '0' and sck_s(1) = '1' then
        -- rising SCLK: sample MOSI, then present the next MISO bit (the master
        -- samples it a full SCK period later)
        if bitcnt /= 7 then
          rx_sr  <= rx_sr(5 downto 0) & mosi_s(1);
          bitcnt <= bitcnt + 1;
          miso_r <= tx_sr(6);
          tx_sr  <= tx_sr(5 downto 0) & '0';
        else
          bitcnt <= 0;
          rxb := rx_sr & mosi_s(1);
          nxt := x"00";
          -- the byte that just finished shifting out came from the FIFO: commit it
          if gcur_from_fifo = '1' then
            gf_rp <= gf_rp + 1;
          end if;
          gcur_from_fifo <= '0';
          if cur_from_fifo = '1' then
            rxf_rp <= rxf_rp + 1;
          end if;
          cur_from_fifo <= '0';
          if bidx /= 4095 then
            bidx <= bidx + 1;
          end if;

          if bidx = 0 then
            cmd <= rxb;
            case rxb is
              when x"11" => wbuf_raddr <= (others => '0');   -- prefetch
              when x"40" => eth_raddr  <= (others => '0');   -- prefetch
              when x"12" => wr_ack_r   <= wr_req_s(1);
              when x"13" => rd_error_r <= rd_req_s(1);
              when x"10" =>                                  -- demand sector: present slot 16
                if rd_req_s(1) = '1' and rd_ready_r = '0' and hit_wait = 0 then
                  act_slot    <= DEMAND;
                  demand_busy <= '1';
                end if;
              when x"15" => vld_v := (others => '0');       -- SD_INVAL
              when x"82" =>                                  -- HOST_RESET
                if HOST_FIFOS then
                  hr_tgl  <= not hr_tgl;
                  hr_drop <= (others => '1');
                  pf_ovf  <= '0';
                end if;
              when others => null;
            end case;
          else
            case cmd is
              when x"01" =>                 -- STATUS (byte 1 = dummy)
                nxt := nxt_pre;             -- (stat_q: status byte bidx - 1, registered twice)

              when x"10" =>                 -- SD_PUT: payload bytes 1..512
                put_i := to_integer(bidx) - 1;
                if put_i < 512 then
                  rbuf_we <= '1';
                  rbuf_wa <= DEMAND & to_unsigned(put_i, 9);
                  rbuf_wd <= rxb;
                  if put_i = 511 and rd_req_s(1) = '1' and demand_busy = '1' then
                    rd_ready_r <= '1';               -- (a cache hit may have answered already)
                  end if;
                end if;

              when x"14" =>                 -- SD_PREF: slot, count, lba(4), count x 512 bytes
                case to_integer(bidx) is
                  when 1 => pf_cur <= unsigned(rxb(3 downto 0));
                  when 2 =>
                    if unsigned(rxb) > 7 then pf_count <= 7; else pf_count <= to_integer(unsigned(rxb)); end if;
                  when 3 | 4 | 5 => pf_lba <= pf_lba(23 downto 0) & unsigned(rxb);
                  when 6 =>
                    pf_lba <= pf_lba(23 downto 0) & unsigned(rxb);
                    pf_k   <= 0;
                    pf_off <= 0;
                    if busy_slot(pf_cur) then
                      pf_skip <= '1';
                    else
                      pf_skip <= '0';
                      vld_v(to_integer(pf_cur)) := '0';    -- invalid while it is rewritten
                    end if;
                  when others =>
                    if pf_k < pf_count then
                      if pf_skip = '0' then
                        rbuf_we <= '1';
                        rbuf_wa <= ('0' & pf_cur) & to_unsigned(pf_off, 9);
                        rbuf_wd <= rxb;
                      end if;
                      if pf_off = 511 then
                        -- sector complete: tag it (unless the MEGA65 is writing that LBA)
                        if pf_skip = '0' and not (wr_req_s(1) = '1' and lba_f = pf_lba) then
                          tags(to_integer(pf_cur)) <= pf_lba;
                          vld_v(to_integer(pf_cur)) := '1';
                          fresh_v(to_integer(pf_cur)) := '1';
                        end if;
                        pf_k   <= pf_k + 1;
                        pf_off <= 0;
                        pf_lba <= pf_lba + 1;
                        pf_cur <= pf_cur + 1;
                        if pf_k + 1 < pf_count then
                          if busy_slot(pf_cur + 1) then
                            pf_skip <= '1';
                          else
                            pf_skip <= '0';
                            vld_v(to_integer(pf_cur + 1)) := '0';
                          end if;
                        end if;
                      else
                        pf_off <= pf_off + 1;
                      end if;
                    end if;
                end case;

              when x"11" =>                 -- SD_GET: byte 1 dummy, then data
                nxt := nxt_pre;             -- (wbuf_q, registered once more)
                wbuf_raddr <= wbuf_raddr + 1;

              when x"20" =>                 -- UART_PUT
                if (txf_wp - txf_rp) /= 1024 then
                  txf_we <= '1';
                  txf_wa <= txf_wp(9 downto 0);
                  txf_wd <= rxb;
                  txf_wp <= txf_wp + 1;
                end if;

              when x"80" =>                 -- HOST_PUT: command bytes for the host master
                if HOST_FIFOS then
                  if pf_free /= 0 then
                    pf_we <= '1';
                    pf_wa <= pf_wp(12 downto 0);
                    pf_wd <= rxb;
                    pf_wp <= pf_wp + 1;
                  else
                    pf_ovf <= '1';
                  end if;
                end if;

              when x"81" =>                 -- HOST_GET: byte 1 dummy, then answers
                if HOST_FIFOS and gnxt_av = '1' then
                  nxt := nxt_pre;
                  gf_pp <= gf_pp + 1;
                  gcur_from_fifo <= '1';
                end if;

              when x"21" =>                 -- UART_GET: byte 1 dummy, then data
                -- (the byte and the "there is one" flag as registered together in nxt_pre / nxt_av:
                -- a byte arriving in the last cycles goes with the next one)
                if nxt_av = '1' then
                  nxt := nxt_pre;
                  rxf_pp <= rxf_pp + 1;
                  cur_from_fifo <= '1';
                end if;

              when x"40" =>                 -- ETH_TXGET: byte 1 dummy, then data
                nxt := nxt_pre;             -- (eth_tx_rdata, registered)
                eth_raddr <= eth_raddr + 1;

              when x"41" =>                 -- ETH_RXPUT: len_hi, len_lo, data
                if bidx = 1 then
                  eth_rxlen(10 downto 8) <= unsigned(rxb(2 downto 0));
                elsif bidx = 2 then
                  eth_rxlen(7 downto 0) <= unsigned(rxb);
                elsif eth_rx_free /= 0 and bidx - 3 < 2048 then
                  eth_rx_we    <= '1';
                  eth_rx_waddr <= resize(bidx - 3, 11);
                  eth_rx_wdata <= rxb;
                end if;

              when x"50" =>                 -- FLASH: len_hi, len_lo, data..., 2 pads
                if bidx = 1 then
                  fl_len(15 downto 8) <= unsigned(rxb);
                  fl_act  <= '1';
                  fl_sent <= (others => '0');
                  fl_ovf  <= '0';
                  -- dummy clocks with CS high
                  fl_cs_r <= '1'; fl_pre <= '1'; fl_busy <= '1'; fl_tx <= x"FF";
                  fl_phase <= 0; fl_bit <= 0;
                elsif bidx = 2 then
                  fl_len(7 downto 0) <= unsigned(rxb);
                else
                  if fl_sent < fl_len then
                    if fl_busy = '1' then
                      fl_ovf <= '1';
                    end if;
                    fl_tx    <= rxb;
                    fl_cs_r  <= '0';
                    fl_busy  <= '1';
                    fl_phase <= 0;
                    fl_bit   <= 0;
                    fl_pre   <= '0';
                    fl_sent  <= fl_sent + 1;
                    if fl_sent + 1 = fl_len then
                      fl_last <= '1';
                    end if;
                  end if;
                  nxt := nxt_pre;           -- (fl_resp, registered: 1 cycle older)
                end if;

              when x"60" =>                 -- IPROG: addr(31..24) .. addr(7..0), $A5
                case to_integer(bidx) is
                  when 1 => ip_addr(31 downto 24) <= rxb;
                  when 2 => ip_addr(23 downto 16) <= rxb;
                  when 3 => ip_addr(15 downto 8)  <= rxb;
                  when 4 => ip_addr(7 downto 0)   <= rxb;
                  when 5 => if rxb = x"A5" then ip_tog <= not ip_tog; end if;
                  when others => null;
                end case;

              when x"70" =>                 -- VIDEO: picture source
                if to_integer(bidx) = 1 then
                  vid_r <= rxb;
                end if;

              when x"30" =>                 -- INPUT
                case to_integer(bidx) is
                  when 1 => ctrl_r <= rxb;
                  when 2 => joya_r <= rxb(4 downto 0);
                  when 3 => joyb_r <= rxb(4 downto 0);
                  when 4 to 12 => mat(to_integer(bidx) - 4) <= rxb;
                  when 13 => pots_r(31 downto 24) <= rxb;   -- pot1 x
                  when 14 => pots_r(23 downto 16) <= rxb;   -- pot1 y
                  when 15 => pots_r(15 downto 8)  <= rxb;   -- pot2 x
                  when 16 => pots_r(7 downto 0)   <= rxb;   -- pot2 y
                  when others => null;
                end case;

              when others => null;
            end case;
          end if;

          if bidx = 0 then
            nxt := x"00";
          end if;
          -- the byte sent is nxt_pre: the same as nxt above (the arms say where it comes from),
          -- but from a register, so nothing but a flip-flop drives miso_r / tx_sr here
          miso_r <= nxt_pre(7);
          tx_sr  <= nxt_pre(6 downto 0);
        end if;
      end if;

      ------------------------------------------------------------------
      -- Serializer: TX FIFO -> monitor RsRx (8N1, BIT_CLKS clocks/bit)
      ------------------------------------------------------------------
      if ser_busy = '0' then
        mon_rx_f <= '1';
        if ser_wait /= 0 then
          ser_wait <= ser_wait - 1;
        elsif txf_wp_d2 /= txf_rp then
          ser_sr   <= '1' & txf_dout & '0';   -- stop, data, start (LSB first)
          txf_rp   <= txf_rp + 1;
          ser_bits <= 10;
          ser_tmr  <= 0;
          ser_busy <= '1';
        end if;
      else
        mon_rx_f <= ser_sr(0);
        if ser_tmr /= BIT_CLKS-1 then
          ser_tmr <= ser_tmr + 1;
        else
          ser_tmr <= 0;
          ser_sr  <= '1' & ser_sr(9 downto 1);
          if ser_bits = 1 then
            ser_busy <= '0';
            ser_wait <= 3;      -- lets txf_dout settle on the new read pointer
          end if;
          ser_bits <= ser_bits - 1;
        end if;
      end if;

      ------------------------------------------------------------------
      -- Deserializer: monitor UART_TXD -> RX FIFO
      ------------------------------------------------------------------
      des_in <= des_in(1 downto 0) & mon_tx;
      if des_busy = '0' then
        if des_in(2) = '1' and des_in(1) = '0' then   -- start bit edge
          des_busy <= '1';
          des_tmr  <= 0;
          des_bits <= 0;
        end if;
      else
        if (des_bits = 0 and des_tmr = BIT_CLKS/2 - 1) or
           (des_bits /= 0 and des_tmr = BIT_CLKS-1) then
          des_tmr <= 0;
          if des_bits = 0 then
            if des_in(1) = '1' then       -- false start
              des_busy <= '0';
            end if;
            des_bits <= 1;
          elsif des_bits <= 8 then
            des_sr   <= des_in(1) & des_sr(7 downto 1);
            des_bits <= des_bits + 1;
          else                            -- stop bit
            des_busy <= '0';
            if (rxf_wp - rxf_rp) /= 16384 then
              rxf_we <= '1';
              rxf_wa <= rxf_wp(13 downto 0);
              rxf_wd <= des_sr;
              rxf_wp <= rxf_wp + 1;
            else
              rx_overflow <= '1';
            end if;
          end if;
        else
          des_tmr <= des_tmr + 1;
        end if;
      end if;

      ------------------------------------------------------------------
      -- read cache: answer a pending read from a prefetch slot.  Last in the process so
      -- that vld_v already holds this cycle's prefetch invalidations: a slot that is being
      -- rewritten can never be picked.  'match' is registered from 'tags', so it lags a new
      -- tag by up to two cycles: slots tagged this or the last cycle are not used yet.
      ------------------------------------------------------------------
      if rd_req_s(1) = '1' and rd_ready_r = '0' and rd_error_r = '0' and demand_busy = '0' then
        if hit_wait = 0 then
          hit_i := 16;
          for i in 15 downto 0 loop
            if match(i) = '1' and vld_v(i) = '1' and fresh_v(i) = '0' and fresh1(i) = '0' then
              hit_i := i;
            end if;
          end loop;
          if hit_i /= 16 then
            act_slot <= to_unsigned(hit_i, 5);
            hit_wait <= 12;                    -- 12 x 6.2 ns: > 2 cpuclks for act_slot to cross
            hit_cnt  <= hit_cnt + 1;
          end if;
        elsif hit_wait = 1 then
          rd_ready_r <= '1';
          hit_wait   <= 0;
        else
          hit_wait <= hit_wait - 1;
        end if;
      end if;
      vld    <= vld_v;
      fresh1 <= fresh_v;

    end if;
  end process;

  -------------------------------------------------------------------------
  -- host master FIFOs (HOST_FIFOS only; the other cores build none of this)
  -------------------------------------------------------------------------
  g_host : if HOST_FIFOS generate
    signal pf      : ram8k_t;
    signal gf      : ram4k_t;
    signal pf_q    : std_logic_vector(7 downto 0) := (others => '0');
    signal pf_v    : std_logic := '0';
    signal clr_r   : std_logic := '0';
    signal full_r  : std_logic := '0';
  begin
    -- Gray copies of the pointers, registered in their own domain
    process (clk)
    begin
      if rising_edge(clk) then
        pf_wp_g <= gray(pf_wp);
        gf_rp_g <= gray(gf_rp);
        if pf_we = '1' then
          pf(to_integer(pf_wa)) <= pf_wd;
        end if;
        gf_dout <= gf(to_integer(gf_pp(11 downto 0)));
      end if;
    end process;

    process (host_clk)
      variable ra  : unsigned(13 downto 0);
      variable wpc : unsigned(13 downto 0);
    begin
      if rising_edge(host_clk) then
        pf_wp_h1 <= pf_wp_g; pf_wp_h2 <= pf_wp_h1;
        gf_rp_h1 <= gf_rp_g; gf_rp_h2 <= gf_rp_h1;
        hr_h1 <= hr_tgl; hr_h2 <= hr_h1; hr_h3 <= hr_h2;
        clr_r <= hr_h2 xor hr_h3;
        wpc := ungray(pf_wp_h2);
        -- PUT FIFO read side, first word fall through: pf_q / pf_v describe address ra
        if (hr_h2 xor hr_h3) = '1' then
          ra := wpc;                                   -- HOST_RESET: drop what is queued
        elsif host_s_pop = '1' and pf_v = '1' then
          ra := pf_rp + 1;
        else
          ra := pf_rp;
        end if;
        pf_rp   <= ra;
        pf_rp_g <= gray(ra);
        pf_q    <= pf(to_integer(ra(12 downto 0)));
        if ra /= wpc then pf_v <= '1'; else pf_v <= '0'; end if;
        -- GET FIFO write side
        if host_m_push = '1' then
          gf(to_integer(gf_wp(11 downto 0))) <= host_m_data;
          gf_wp <= gf_wp + 1;
        end if;
        gf_wp_g <= gray(gf_wp);
        if (gf_wp - ungray(gf_rp_h2)) >= 4092 then full_r <= '1'; else full_r <= '0'; end if;
      end if;
    end process;

    host_s_data  <= pf_q;
    host_s_valid <= pf_v;
    host_m_full  <= full_r;
    host_clr     <= clr_r;
  end generate g_host;

  g_nohost : if not HOST_FIFOS generate
    host_s_data  <= (others => '0');
    host_s_valid <= '0';
    host_m_full  <= '1';
    host_clr     <= '0';
  end generate g_nohost;

end architecture;
