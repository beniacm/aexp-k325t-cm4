--------------------------------------------------------------------------------
-- chip_cache.vhd -- the Amiga's chip and slow RAM through a block-RAM cache in front of DDR3, with a
-- stoppable Amiga clock (A1200 study stage 2).  Replaces the chip / slow RAM lanes of mega65.vhd.
--
-- Data RAM (stage 2b): the 384 RAMB36 that held chip 512 KB + slow 512 KB + Kickstart 512 KB, as
-- three banks of 512 KB (bank = way), each 64 bits wide (8 byte lanes of 64 K x 8); port A in the
-- UNGATED source clock (clk_i; address and data from minimig's memory port, which only changes on
-- main_clk edges), port B in the MIG ui_clk (line fills and write-backs).  The Kickstart lives in
-- DDR3 (loaded by QNICE through the load port below) and reaches the Amiga through bank 2.
--
-- Two modes, chosen at a full M2M reset (cache_on_i is sampled while reset_i is high):
--  * identity (cache off, the phase-2 machine): bank 0 = chip 0..512K, bank 1 = slow RAM (or chip
--    512K..1M in the "1M chip" configuration) -- phase 2's layout, no tags, never a stall; bank 2 =
--    the Kickstart, direct-mapped by its address (tags of way 2): each 64-byte line is fetched from
--    DDR3 at its first use (a stall, invisible to the machine), then it stays.  Reads at the extra
--    source-clock edges between main_clk edges are harmless, writes repeat the same data at the
--    same address (idempotent).
--  * cache: 3-way set associative, 64-byte lines (32 words), 8192 sets (1.5 MB), write-back,
--    write-allocate; the backing store is DDR3 (word address base G_DDR_BASE): chip RAM up to
--    2 MB at backing words 0..1M-1, slow RAM at 1M..1M+256K-1, Kickstart at 1.25M..1.5M-1
--    (read-only).  Tags in LUT RAM (asynchronous
--    read): hit / miss is known in the same tick as the address; a miss (an access with _OE or
--    _WE low that is not a hit) is the COMBINATIONAL stall miss_o -> stall_ctrl.miss_i -> the
--    BUFGCE enable: the Amiga stops before it can consume the data.  The line is filled (after a
--    write-back of a dirty victim) through the MIG line port (mig_arb.vhd), the tag is installed,
--    miss_o drops, port A (re-reading every source tick) has the data before the next edge.
--    shrink_i ("00" all 8192 sets, "01" 1024, "10" 128, "11" 16) makes the cache small so that
--    misses and write-backs happen all the time (test of machine-time exactness).
--    Replacement: an invalid way first, then a Kickstart line (clean, cheap to fetch again; the
--    study's rule), else pseudo-random.
-- amiga_cold_boot's scrub of $4 (ExecBase) arrives as an ordinary chip write (mega65.vhd muxes it
-- onto the port), so it goes through the cache like any other write.
-- AGA wide fetch (stage 3): the data RAM is organised 64 bits wide (8 byte lanes of 128 K x 8, the
-- same 256 tiles): one port-A read gives the whole aligned 64-bit group of the accessed word; rdata_o
-- is the accessed word, rdata48_o the other three words in sequential order from it (A+1, A+2, A+3
-- modulo the group: MiSTer's SDRAM burst order, minimig's chip48), with the same timing as rdata_o.
-- Port B moves a line as 8 x 64 bits (was 32 x 16).  Addressing, tags, identity layout, stalls and
-- write behaviour are unchanged.
-- Fill path (stage 2b): the line is read critical word first (the 16-byte word with the missing
-- access comes first) and installed while the words arrive; the tag is written when the request
-- goes out, and an access to the line being filled waits only until its own 16-byte word is in
-- (a beat count, Gray-coded from the ui_clk side).  A dirty victim is read out of the data RAM into
-- a write-back buffer while the MIG fetches the new line, and written back after the fill: its
-- write is no longer part of the stall.  A new miss waits until the engine is idle (fill and
-- write-back done).
-- Prefetchers (stage 2b): every DMA access carries Agnus' target register (minimig patch 0002:
-- dbr_i, dreg_i), so the streams are known by channel: bitplanes (one per plane), sprites (per
-- sprite), audio (per channel), disk, copper, blitter (A/B/C/D) and the CPU.  When a stream enters a
-- new 64-byte line, the next line of the stream (the previous one if it walks downwards) is queued;
-- queued lines are fetched while the engine is idle and no demand miss waits, exactly like a miss
-- but with no access stalled behind it.  Enable bits per class (pf_en_i); counters per class:
-- issued, useful (the first demand access to a prefetched line) and wasted (evicted unused).
-- Not in this version: copper restart / COP1LC and the blitter's precomputed sequence (the stream
-- rule covers them only from their second line on), write misses without stall.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity chip_cache is
   generic (
      G_DDR_BASE : unsigned(27 downto 0) := x"2000000";  -- backing store, MIG app_addr units (64 MB)
      -- bitstream size (K325T, 2026-11-13): false = built without the prefetchers' tag bits (21..18:
      -- class, prefetched), the tag RAM 18 bits wide; only valid with pf_en_i tied to 0
      G_PREFETCH : boolean := true;
      -- the tag RAM's sets (2**G_SET_BITS, at most 8192): fewer = a smaller cache (the full line
      -- address is in every tag, so this is the same as the run-time shrink of the set index; the
      -- data RAM keeps its layout, the identity mode is unchanged)
      G_SET_BITS : natural range 4 to 13 := 13
   );
   port (
      clk_i       : in  std_logic;     -- ungated source clock (stall_clk.vhd src_clk_o)
      reset_i     : in  std_logic;     -- the M2M full reset (main_clk register): mode latch, flush
      cache_on_i  : in  std_logic;     -- sampled during reset_i
      shrink_i    : in  std_logic_vector(1 downto 0);
      chip1m_i    : in  std_logic;     -- "1M chip": banked "0001" = chip 512K..1M (identity mode)
      -- minimig's memory port (main_clk registers), already decoded
      chip_sel_i  : in  std_logic;     -- banked address "00xx" (chip RAM)
      slow_sel_i  : in  std_logic;     -- banked address "1000" (slow RAM), and not 1M chip
      kick_sel_i  : in  std_logic;     -- banked address "1111" (Kickstart ROM, read-only)
      kick512_i   : in  std_logic;     -- 512 KB Kickstart (else 256 KB: address bit 18 ignored)
      addr_i      : in  std_logic_vector(20 downto 1);   -- word address within the bank group
      wdata_i     : in  std_logic_vector(15 downto 0);
      we_n_i      : in  std_logic;
      oe_n_i      : in  std_logic;
      bhe_n_i     : in  std_logic;
      ble_n_i     : in  std_logic;
      -- 68EC020 32-bit chip cycle (stage 3, MiSTer #276): with long_i a write also stores wdata2_i
      -- (both bytes) into the next word (A+1, A even: the same 64-bit group); reads need nothing new
      -- (rdata48_o(47 downto 32) is word A+1)
      long_i      : in  std_logic := '0';
      wdata2_i    : in  std_logic_vector(15 downto 0) := (others => '0');
      rdata_o     : out std_logic_vector(15 downto 0);
      rdata48_o   : out std_logic_vector(47 downto 0);   -- AGA chip48: words A+1..A+3 of the group
      miss_o      : out std_logic;     -- combinational: stop the Amiga before the next edge
      -- statistics (clk_i)
      fills_o     : out unsigned(31 downto 0);
      wbacks_o    : out unsigned(31 downto 0);
      mode_o      : out std_logic;     -- the latched mode ('1' = cache)
      -- Kickstart load port (QNICE device 0x0100, qnice clock, bytes in address order; even byte =
      -- bits 15..8 of the word): written into DDR3 a 64-byte line at a time.  q_wait_o holds the
      -- QNICE until the byte is taken.
      q_clk_i     : in  std_logic := '0';
      q_we_i      : in  std_logic := '0';
      q_addr_i    : in  std_logic_vector(18 downto 0) := (others => '0');
      q_data_i    : in  std_logic_vector(7 downto 0) := (others => '0');
      q_wait_o    : out std_logic;
      -- prefetch: Agnus' bus grant and target register of the access (minimig patch 0002), the
      -- enables (b0 bitplane, b1 sprite, b2 audio, b3 disk, b4 copper, b5 blitter, b6 CPU) and the
      -- counters (class c: bits 96c+95..96c+64 issued, +63..+32 useful, +31..+0 wasted)
      dbr_i       : in  std_logic := '0';
      dreg_i      : in  std_logic_vector(7 downto 0) := (others => '0');
      pf_en_i     : in  std_logic_vector(6 downto 0) := (others => '0');
      pf_stats_o  : out std_logic_vector(671 downto 0);
      -- line port (MIG ui_clk)
      ui_clk_i    : in  std_logic;
      lp_req_o    : out std_logic;
      lp_we_o     : out std_logic;
      lp_addr_o   : out std_logic_vector(27 downto 0);
      lp_wdata_o  : out std_logic_vector(511 downto 0);
      lp_busy_i   : in  std_logic;
      lp_rvalid_i : in  std_logic;
      lp_rdata_i  : in  std_logic_vector(127 downto 0);
      lp_done_i   : in  std_logic
   );
end entity chip_cache;

architecture rtl of chip_cache is
   constant SETS : natural := 8192;

   -- tag store: per way and set: valid, dirty, line address (backing word address 20..5)
   -- tag: 21..19 prefetch class, 18 prefetched and not used yet, 17 valid, 16 dirty, 15..0 line
   function tagw return natural is
   begin
      if G_PREFETCH then return 22; end if;
      return 18;
   end function;
   constant TW    : natural := tagw;                 -- stored tag bits (the upper ones read as 0)
   constant TSETS : natural := 2 ** G_SET_BITS;
   type tag_t is array (0 to TSETS - 1) of std_logic_vector(TW - 1 downto 0);
   signal tag0, tag1, tag2 : tag_t := (others => (others => '0'));
   function tix(n : unsigned(12 downto 0)) return natural is
   begin
      return to_integer(n(G_SET_BITS - 1 downto 0));
   end function;
   function pad(v : std_logic_vector) return std_logic_vector is
      variable r : std_logic_vector(21 downto 0) := (others => '0');
   begin
      r(v'length - 1 downto 0) := v;
      return r;
   end function;
   attribute ram_style : string;
   attribute ram_style of tag0, tag1, tag2 : signal is "distributed";
   constant KICK_LINE : std_logic_vector(2 downto 0) := "101";   -- bline(15:13) of the Kickstart

   signal mode        : std_logic := '0';
   signal smask       : unsigned(12 downto 0) := to_unsigned(2 ** G_SET_BITS - 1, 13);

   -- the access
   signal acc         : std_logic;
   signal bword       : unsigned(20 downto 0);      -- backing word address
   signal bline       : unsigned(15 downto 0);      -- backing line
   signal setn        : unsigned(12 downto 0);
   signal t0, t1, t2  : std_logic_vector(21 downto 0);
   -- prefetch
   signal pcls        : unsigned(2 downto 0);      -- class of the access (7 = none)
   signal psid        : unsigned(7 downto 0);      -- stream of the access
   type stl_t is array (0 to 255) of std_logic_vector(16 downto 0);   -- valid & last line
   signal stl         : stl_t := (others => (others => '0'));
   attribute ram_style of stl : signal is "distributed";
   signal st_cur      : std_logic_vector(16 downto 0);
   type pfq_t is array (0 to 7) of std_logic_vector(18 downto 0);     -- class & line
   signal pfq         : pfq_t := (others => (others => '0'));
   signal pf_wp, pf_rp : unsigned(3 downto 0) := (others => '0');
   signal pf_last     : std_logic_vector(18 downto 0) := (others => '1');
   signal pf_head     : std_logic_vector(18 downto 0);
   signal pf_set      : unsigned(12 downto 0);
   signal p0, p1, p2  : std_logic_vector(21 downto 0);
   signal pf_hit      : std_logic;
   type cnt7_t is array (0 to 6) of unsigned(31 downto 0);
   signal pf_iss, pf_use, pf_wst : cnt7_t := (others => (others => '0'));
   signal hit0, hit1, hit2 : std_logic;
   signal miss        : std_logic;
   signal hway        : std_logic_vector(1 downto 0);
   signal tagged      : std_logic;                 -- this access goes through the tags
   signal rom0, rom1, rom2 : std_logic;            -- the way holds a (valid) Kickstart line

   -- port A (a_addr: bank 19..18, 64-bit group 17..2, lane 1..0)
   signal a_addr      : std_logic_vector(19 downto 0);
   signal a_wdata     : std_logic_vector(15 downto 0);
   signal a_we_u, a_we_l : std_logic;
   signal a_we_2      : std_logic;                  -- the second word of a 32-bit write
   type q_t is array (0 to 11) of std_logic_vector(15 downto 0);
   signal q           : q_t;                        -- the four words of the group, per bank (4b + k)
   signal a_lane_q    : unsigned(1 downto 0) := (others => '0');   -- lane of the word in q
   signal a_bank_q    : unsigned(1 downto 0) := (others => '0');   -- bank of the word in q

   -- miss handling (clk_i)
   type mst_t is (M_IDLE, M_FLUSH);
   signal mst         : mst_t := M_IDLE;
   signal req_tgl     : std_logic := '0';
   signal done_s1, done_s2 : std_logic := '0';       -- the engine's job-done toggle, synchronised
   signal done_seen   : std_logic := '0';
   signal eng_idle    : std_logic;
   signal bc_s1, bc_s2 : std_logic_vector(2 downto 0) := (others => '0');   -- beat count (Gray)
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of done_s1, done_s2, bc_s1, bc_s2 : signal is "TRUE";
   signal bc_bin      : unsigned(2 downto 0);
   signal cbase       : unsigned(2 downto 0) := (others => '0');   -- beat count at the next fill
   signal fill_base   : unsigned(2 downto 0) := (others => '0');
   signal fill_act    : std_logic := '0';           -- a fill whose tag is installed is running
   signal fill_set    : unsigned(12 downto 0) := (others => '0');
   signal fill_way    : std_logic_vector(1 downto 0) := "00";
   signal fill_crit   : unsigned(1 downto 0) := (others => '0');
   signal beats_ok    : unsigned(2 downto 0);       -- 16-byte words of that fill installed (0..4)
   signal notready    : std_logic;
   signal hitany      : std_logic;
   signal r_way       : std_logic_vector(1 downto 0) := "00";
   signal r_set       : unsigned(12 downto 0) := (others => '0');
   signal r_line      : unsigned(15 downto 0) := (others => '0');
   signal r_vline     : unsigned(15 downto 0) := (others => '0');
   signal r_vdirty    : std_logic := '0';
   signal r_crit      : unsigned(1 downto 0) := (others => '0');
   signal rnd         : unsigned(15 downto 0) := x"ACE1";
   signal fills, wbacks : unsigned(31 downto 0) := (others => '0');
   signal flush_idx   : unsigned(12 downto 0) := (others => '0');
   signal reset_d     : std_logic := '0';
   signal rlatch      : std_logic := '0';

   -- fill engine (ui_clk)
   type fst_t is (F_IDLE, F_RUN, F_WBREQ, F_WBWAIT, F_KLREQ, F_KLWAIT);
   signal fst         : fst_t := F_IDLE;
   signal req_s1, req_s2, req_d : std_logic := '0';
   attribute ASYNC_REG of req_s1, req_s2 : signal is "TRUE";
   signal done_tgl    : std_logic := '0';
   signal bcnt        : unsigned(2 downto 0) := (others => '0');   -- beats installed, all fills
   signal bcnt_g      : std_logic_vector(2 downto 0) := (others => '0');
   signal rd_sent     : std_logic := '0';           -- the line read has been requested
   signal rd_done     : std_logic := '0';           -- ... and all its words have arrived
   signal got         : std_logic_vector(3 downto 0) := (others => '0');   -- line words arrived
   signal f_rx        : unsigned(1 downto 0) := (others => '0');   -- words received so far
   signal vic_done    : std_logic := '0';           -- the victim is in the write-back buffer
   signal ins_n       : unsigned(2 downto 0) := (others => '0');   -- words installed (0..4)
   signal ins_h       : std_logic := '0';           -- half (64 bits) of the word being installed
   signal wb_line     : std_logic_vector(511 downto 0) := (others => '0');
   signal e_way       : std_logic_vector(1 downto 0) := "00";
   signal e_set       : unsigned(12 downto 0) := (others => '0');
   signal e_crit      : unsigned(1 downto 0) := (others => '0');
   signal e_dirty     : std_logic := '0';
   signal b_addr      : std_logic_vector(17 downto 0) := (others => '0');   -- bank & 64-bit group
   signal b_wdata     : std_logic_vector(63 downto 0) := (others => '0');
   signal b_we        : std_logic := '0';
   type bq_t is array (0 to 2) of std_logic_vector(63 downto 0);
   signal b_qb        : bq_t;
   signal b_q         : std_logic_vector(63 downto 0);
   signal b_bank_q    : std_logic_vector(1 downto 0) := "00";
   -- Kickstart loader: QNICE side
   type qst_t is (Q_IDLE, Q_WAIT, Q_DONE);
   signal qst         : qst_t := Q_IDLE;
   signal q_tgl       : std_logic := '0';
   signal q_a         : std_logic_vector(18 downto 0) := (others => '0');
   signal q_d         : std_logic_vector(7 downto 0) := (others => '0');
   signal qack_s1, qack_s2 : std_logic := '0';
   attribute ASYNC_REG of qack_s1, qack_s2 : signal is "TRUE";
   -- Kickstart loader: ui side
   signal qreq_s1, qreq_s2, qreq_d : std_logic := '0';
   attribute ASYNC_REG of qreq_s1, qreq_s2 : signal is "TRUE";
   signal q_ack       : std_logic := '0';
   signal kl_line     : std_logic_vector(511 downto 0) := (others => '0');
   signal kl_out      : std_logic_vector(511 downto 0) := (others => '0');
   signal kl_oaddr    : std_logic_vector(12 downto 0) := (others => '0');   -- line of the Kickstart
   signal kl_pend     : std_logic := '0';          -- kl_out waits to be written
   signal kl_held     : std_logic := '0';          -- a byte waits: the line is full, kl_out busy
   signal lp_src      : std_logic := '0';          -- '1': the write comes from the loader
   signal f_cnt       : unsigned(5 downto 0) := (others => '0');
   signal f_line      : std_logic_vector(511 downto 0) := (others => '0');
   signal lp_req      : std_logic := '0';
   signal lp_we       : std_logic := '0';
   signal lp_addr     : std_logic_vector(27 downto 0) := (others => '0');
begin
   ---------------------------------------------------------------- the access, combinational
   -- (the Kickstart only for reads: a write to the ROM is ignored, never a miss)
   acc   <= ((chip_sel_i or slow_sel_i) and (not we_n_i or not oe_n_i)) or (kick_sel_i and not oe_n_i);
   bword <= unsigned(std_logic_vector'("100" & addr_i(18 downto 1))) when slow_sel_i = '1' else
            unsigned(std_logic_vector'(KICK_LINE & (addr_i(18) and kick512_i) & addr_i(17 downto 1)))
               when kick_sel_i = '1' else
            unsigned(std_logic_vector'('0' & addr_i));
   -- cache mode: every access; identity mode: only the Kickstart (bank 2, way 2 forced)
   tagged <= '1' when mode = '1' or kick_sel_i = '1' else '0';
   bline <= bword(20 downto 5);
   setn  <= bline(12 downto 0) and smask and to_unsigned(TSETS - 1, 13);   -- the cap: G_SET_BITS
   t0    <= pad(tag0(tix(setn)));
   t1    <= pad(tag1(tix(setn)));
   t2    <= pad(tag2(tix(setn)));
   hit0  <= '1' when mode = '1' and t0(17) = '1' and unsigned(t0(15 downto 0)) = bline else '0';
   hit1  <= '1' when mode = '1' and t1(17) = '1' and unsigned(t1(15 downto 0)) = bline else '0';
   hit2  <= '1' when t2(17) = '1' and unsigned(t2(15 downto 0)) = bline else '0';
   hway  <= "01" when hit1 = '1' else "10" when hit2 = '1' else "00";
   hitany <= hit0 or hit1 or hit2;
   -- the access's prefetch class and stream (Agnus' target register, minimig patch 0002)
   pcls <= "110" when dbr_i = '0' else                                         -- CPU
           "000" when dreg_i(7 downto 3) = "10001" else                         -- BPLxDAT $110-$11E
           "001" when dreg_i(7 downto 5) = "101" else                           -- SPRxPOS..DATB $140-$17E
           "010" when dreg_i = x"55" or dreg_i = x"5D" or dreg_i = x"65" or dreg_i = x"6D" else -- AUDxDAT
           "011" when dreg_i = x"04" or dreg_i = x"13" else                     -- DSKDATR / DSKDAT
           "100" when dreg_i = x"46" else                                       -- COPINS
           "101" when dreg_i = x"00" or dreg_i = x"38" or dreg_i = x"39" or dreg_i = x"3A" else -- BLTxDAT
           "111";
   psid    <= x"FF" when dbr_i = '0' else unsigned(dreg_i);
   st_cur  <= stl(to_integer(psid));
   pf_head <= pfq(to_integer(pf_rp(2 downto 0)));
   pf_set  <= unsigned(pf_head(12 downto 0)) and smask and to_unsigned(TSETS - 1, 13);
   p0      <= pad(tag0(tix(pf_set)));
   p1      <= pad(tag1(tix(pf_set)));
   p2      <= pad(tag2(tix(pf_set)));
   pf_hit  <= '1' when (p0(17) = '1' and p0(15 downto 0) = pf_head(15 downto 0)) or
                       (p1(17) = '1' and p1(15 downto 0) = pf_head(15 downto 0)) or
                       (p2(17) = '1' and p2(15 downto 0) = pf_head(15 downto 0)) else '0';
   g_pfst : for c in 0 to 6 generate
      pf_stats_o(96 * c + 95 downto 96 * c) <= std_logic_vector(pf_iss(c)) & std_logic_vector(pf_use(c)) &
                                                std_logic_vector(pf_wst(c));
   end generate;

   rom0  <= '1' when t0(17) = '1' and t0(15 downto 13) = KICK_LINE else '0';
   rom1  <= '1' when t1(17) = '1' and t1(15 downto 13) = KICK_LINE else '0';
   rom2  <= '1' when t2(17) = '1' and t2(15 downto 13) = KICK_LINE else '0';
   -- the line being filled: its tag is valid already, but a 16-byte word not yet installed waits
   bc_bin   <= unsigned(bc_s2) xor ('0' & unsigned(bc_s2(2 downto 1))) xor ("00" & bc_s2(2));
   beats_ok <= bc_bin - fill_base;
   notready <= '1' when fill_act = '1' and setn = fill_set and hway = fill_way and
                        resize(bword(4 downto 3) - fill_crit, 3) >= beats_ok else '0';
   eng_idle <= '1' when done_s2 = done_seen else '0';
   miss  <= '1' when tagged = '1' and acc = '1' and (hitany = '0' or notready = '1') else
            '1' when mode = '1' and mst = M_FLUSH else
            '1' when kick_sel_i = '1' and acc = '1' and mst = M_FLUSH else '0';
   miss_o <= miss;
   mode_o <= mode;
   fills_o  <= fills;
   wbacks_o <= wbacks;

   ---------------------------------------------------------------- port A
   a_addr <= hway & std_logic_vector(setn) & std_logic_vector(bword(4 downto 0)) when tagged = '1' else
             '0' & (slow_sel_i or (chip1m_i and addr_i(19))) & addr_i(18 downto 1);
   a_wdata <= wdata_i;
   -- writes: identity mode as phase 2; cache mode only on a hit (a miss is filled first); never the ROM
   a_we_u <= '1' when acc = '1' and kick_sel_i = '0' and we_n_i = '0' and bhe_n_i = '0' and miss = '0' else '0';
   a_we_l <= '1' when acc = '1' and kick_sel_i = '0' and we_n_i = '0' and ble_n_i = '0' and miss = '0' else '0';
   -- (only for an even word address: word A+1 must be in the same 64-bit group; the 68EC020's 32-bit
   --  chip cycles are long-aligned, a misaligned one would otherwise write lane 0 of the same group)
   a_we_2 <= '1' when acc = '1' and kick_sel_i = '0' and we_n_i = '0' and long_i = '1' and a_addr(0) = '0' and
                      miss = '0' else '0';

   -- tdp_ram directly (dualport_2clk_ram passes its clocks through an expression: one delta of
   -- delay that races the registers feeding it in simulation).  Bank n (= way n), 8 byte lanes:
   -- lane k (word k of the group) upper = 2k+1, lower = 2k; port B word k = b_wdata(16k+15 .. 16k).
   g_bank : for n in 0 to 2 generate
      signal bsel_a, bwe : std_logic;
   begin
      bsel_a <= '1' when unsigned(a_addr(19 downto 18)) = n else '0';
      bwe    <= b_we when unsigned(b_addr(17 downto 16)) = n else '0';
      g_lane : for k in 0 to 3 generate
         signal we_u, we_l, sec : std_logic;
         signal d : std_logic_vector(15 downto 0);
      begin
         -- sec: this lane is word A+1 of a 32-bit write
         sec  <= '1' when long_i = '1' and a_addr(0) = '0' and unsigned(a_addr(1 downto 0)) + 1 = k else '0';
         we_u <= (a_we_u and bsel_a) when unsigned(a_addr(1 downto 0)) = k else
                 (a_we_2 and bsel_a) when sec = '1' else '0';
         we_l <= (a_we_l and bsel_a) when unsigned(a_addr(1 downto 0)) = k else
                 (a_we_2 and bsel_a) when sec = '1' else '0';
         d    <= wdata2_i when sec = '1' else a_wdata;
         ram_u : entity work.tdp_ram
            generic map (ADDR_WIDTH => 16, DATA_WIDTH => 8)
            port map (clock_a => clk_i, address_a => a_addr(17 downto 2), data_a => d(15 downto 8),
                      wren_a => we_u, q_a => q(4 * n + k)(15 downto 8), clock_b => ui_clk_i,
                      address_b => b_addr(15 downto 0), data_b => b_wdata(16 * k + 15 downto 16 * k + 8),
                      wren_b => bwe, q_b => b_qb(n)(16 * k + 15 downto 16 * k + 8));
         ram_l : entity work.tdp_ram
            generic map (ADDR_WIDTH => 16, DATA_WIDTH => 8)
            port map (clock_a => clk_i, address_a => a_addr(17 downto 2), data_a => d(7 downto 0),
                      wren_a => we_l, q_a => q(4 * n + k)(7 downto 0), clock_b => ui_clk_i,
                      address_b => b_addr(15 downto 0), data_b => b_wdata(16 * k + 7 downto 16 * k),
                      wren_b => bwe, q_b => b_qb(n)(16 * k + 7 downto 16 * k));
      end generate;
   end generate;
   -- the RAMs register the address every clk_i edge: the bank / lane select follows one edge later
   process (clk_i)
   begin
      if rising_edge(clk_i) then
         a_lane_q <= unsigned(a_addr(1 downto 0));
         a_bank_q <= unsigned(a_addr(19 downto 18));
      end if;
   end process;
   rdata_o   <= q(4 * to_integer(a_bank_q) + to_integer(a_lane_q));
   rdata48_o <= q(4 * to_integer(a_bank_q) + to_integer(a_lane_q + 1)) &
                q(4 * to_integer(a_bank_q) + to_integer(a_lane_q + 2)) &
                q(4 * to_integer(a_bank_q) + to_integer(a_lane_q + 3));
   process (ui_clk_i)
   begin
      if rising_edge(ui_clk_i) then b_bank_q <= b_addr(17 downto 16); end if;
   end process;
   b_q <= b_qb(to_integer(unsigned(b_bank_q)));


   ---------------------------------------------------------------- tags and misses (clk_i)
   -- one write port per tag RAM (LUT RAM): flush, install or "dirty"
   process (clk_i)
      variable way      : std_logic_vector(1 downto 0);
      variable w0, w1, w2 : boolean;
      variable wa       : unsigned(12 downto 0);
      variable wd0, wd1, wd2 : std_logic_vector(21 downto 0);
      variable vt       : std_logic_vector(21 downto 0);
      variable nt       : std_logic_vector(21 downto 0);
      variable useful   : boolean;
      variable busy_req : boolean;
      variable cand     : unsigned(15 downto 0);
      variable pline    : unsigned(15 downto 0);
      variable pc       : integer range 0 to 7;
   begin
      if rising_edge(clk_i) then
         rnd <= rnd(14 downto 0) & (rnd(15) xor rnd(13) xor rnd(12) xor rnd(10));
         done_s1 <= done_tgl; done_s2 <= done_s1;
         bc_s1 <= bcnt_g; bc_s2 <= bc_s1;
         reset_d <= reset_i;
         w0 := false; w1 := false; w2 := false; wa := setn; wd0 := t0; wd1 := t1; wd2 := t2;
         if fill_act = '1' and beats_ok = 4 then fill_act <= '0'; end if;
         case mst is
            when M_FLUSH =>
               wa := flush_idx; wd0 := (others => '0'); wd1 := (others => '0'); wd2 := (others => '0');
               w0 := true; w1 := true; w2 := true;
               flush_idx <= flush_idx + 1;
               if flush_idx = SETS - 1 then mst <= M_IDLE; end if;
            when M_IDLE =>
               if tagged = '1' and acc = '1' then
                  if hitany = '1' then
                     -- a hit (also on a filling line whose word is in): a write marks the line dirty,
                     -- the first use of a prefetched line counts it as useful
                     if notready = '0' then
                        case hway is
                           when "00"   => vt := t0;
                           when "01"   => vt := t1;
                           when others => vt := t2;
                        end case;
                        useful := vt(18) = '1';
                        nt := vt(21 downto 19) & '0' & vt(17) & vt(16) & vt(15 downto 0);
                        if we_n_i = '0' and kick_sel_i = '0' then nt(16) := '1'; end if;
                        if useful then pf_use(to_integer(unsigned(vt(21 downto 19)))) <=
                                          pf_use(to_integer(unsigned(vt(21 downto 19)))) + 1; end if;
                        if nt /= vt then
                           case hway is
                              when "00"   => wd0 := nt; w0 := true;
                              when "01"   => wd1 := nt; w1 := true;
                              when others => wd2 := nt; w2 := true;
                           end case;
                        end if;
                     end if;
                  elsif eng_idle = '1' and fill_act = '0' then
                     -- a miss: choose the victim, install the new tag now (its words follow), ask the
                     -- fill engine; the access waits in notready until its 16-byte word is in.
                     -- Identity mode: only the Kickstart misses, always into way 2.
                     if mode = '0' then way := "10";
                     elsif t0(17) = '0' then way := "00";
                     elsif t1(17) = '0' then way := "01";
                     elsif t2(17) = '0' then way := "10";
                     elsif rom0 = '1' then way := "00";
                     elsif rom1 = '1' then way := "01";
                     elsif rom2 = '1' then way := "10";
                     elsif rnd(1 downto 0) = "11" then way := '0' & rnd(2);
                     else way := std_logic_vector(rnd(1 downto 0)); end if;
                     case way is
                        when "00"   => vt := t0;
                        when "01"   => vt := t1;
                        when others => vt := t2;
                     end case;
                     r_way  <= way;
                     r_set  <= setn;
                     r_line <= bline;
                     r_crit <= bword(4 downto 3);
                     r_vline <= unsigned(vt(15 downto 0));
                     r_vdirty <= vt(17) and vt(16);
                     if vt(17) = '1' and vt(16) = '1' then wbacks <= wbacks + 1; end if;
                     if vt(17) = '1' and vt(18) = '1' then
                        pf_wst(to_integer(unsigned(vt(21 downto 19)))) <= pf_wst(to_integer(unsigned(vt(21 downto 19)))) + 1;
                     end if;
                     nt := "000" & "0" & "10" & std_logic_vector(bline);
                     case way is
                        when "00"   => wd0 := nt; w0 := true;
                        when "01"   => wd1 := nt; w1 := true;
                        when others => wd2 := nt; w2 := true;
                     end case;
                     fills     <= fills + 1;
                     fill_act  <= '1';
                     fill_set  <= setn;
                     fill_way  <= way;
                     fill_crit <= bword(4 downto 3);
                     fill_base <= cbase;
                     cbase     <= cbase + 4;
                     done_seen <= not done_seen;     -- the engine is busy until it toggles back
                     req_tgl   <= not req_tgl;
                  end if;
               end if;
               ------------------------------------------------ prefetch (cache mode)
               -- a stream that enters a new line queues its next line (the previous one downwards)
               if mode = '1' and acc = '1' and pcls /= "111" and pf_en_i(to_integer(pcls)) = '1' and
                  (st_cur(16) = '0' or unsigned(st_cur(15 downto 0)) /= bline) then
                  stl(to_integer(psid)) <= '1' & std_logic_vector(bline);
                  if st_cur(16) = '1' and unsigned(st_cur(15 downto 0)) = bline + 1 then cand := bline - 1;
                  else cand := bline + 1; end if;
                  if std_logic_vector(pcls) & std_logic_vector(cand) /= pf_last and pf_wp - pf_rp /= 8 then
                     pfq(to_integer(pf_wp(2 downto 0))) <= std_logic_vector(pcls) & std_logic_vector(cand);
                     pf_wp   <= pf_wp + 1;
                     pf_last <= std_logic_vector(pcls) & std_logic_vector(cand);
                  end if;
               end if;
               -- a queued line is fetched when nothing else uses the tag port or the engine: a line
               -- already in the cache is dropped
               busy_req := (tagged = '1' and acc = '1' and hitany = '0') or w0 or w1 or w2;
               if mode = '1' and pf_wp /= pf_rp and not busy_req then
                  if pf_hit = '1' then
                     pf_rp <= pf_rp + 1;
                  elsif eng_idle = '1' and fill_act = '0' then
                     pf_rp <= pf_rp + 1;
                     pline := unsigned(pf_head(15 downto 0));
                     pc    := to_integer(unsigned(pf_head(18 downto 16)));
                     if p0(17) = '0' then way := "00";
                     elsif p1(17) = '0' then way := "01";
                     elsif p2(17) = '0' then way := "10";
                     elsif p0(15 downto 13) = KICK_LINE then way := "00";
                     elsif p1(15 downto 13) = KICK_LINE then way := "01";
                     elsif p2(15 downto 13) = KICK_LINE then way := "10";
                     elsif rnd(1 downto 0) = "11" then way := '0' & rnd(2);
                     else way := std_logic_vector(rnd(1 downto 0)); end if;
                     case way is
                        when "00"   => vt := p0;
                        when "01"   => vt := p1;
                        when others => vt := p2;
                     end case;
                     r_way    <= way;
                     r_set    <= pf_set;
                     r_line   <= pline;
                     r_crit   <= "00";
                     r_vline  <= unsigned(vt(15 downto 0));
                     r_vdirty <= vt(17) and vt(16);
                     if vt(17) = '1' and vt(16) = '1' then wbacks <= wbacks + 1; end if;
                     if vt(17) = '1' and vt(18) = '1' then
                        pf_wst(to_integer(unsigned(vt(21 downto 19)))) <= pf_wst(to_integer(unsigned(vt(21 downto 19)))) + 1;
                     end if;
                     nt := pf_head(18 downto 16) & "1" & "10" & pf_head(15 downto 0);
                     wa := pf_set;
                     case way is
                        when "00"   => wd0 := nt; w0 := true;
                        when "01"   => wd1 := nt; w1 := true;
                        when others => wd2 := nt; w2 := true;
                     end case;
                     pf_iss(pc) <= pf_iss(pc) + 1;
                     fill_act  <= '1';
                     fill_set  <= pf_set;
                     fill_way  <= way;
                     fill_crit <= "00";
                     fill_base <= cbase;
                     cbase     <= cbase + 4;
                     done_seen <= not done_seen;
                     req_tgl   <= not req_tgl;
                  end if;
               end if;
         end case;
         -- a full reset (its first tick): latch mode and size, invalidate all tags (a cold boot:
         -- dirty lines are dropped; the Amiga clears its memory after a cold boot anyway)
         -- (once per reset, and only with the fill engine idle: a fill must not write into the data
         --  RAM after a switch to identity mode)
         -- stage 3 (P4): also when the requested mode changes while reset_i stays high -- the
         -- profile applies at the release of the M2M reset, often while amiga_cold_boot's own reset
         -- (which then follows the topology change) keeps reset_i high without a gap
         if reset_i = '0' then rlatch <= '0'; end if;
         if reset_i = '1' and (rlatch = '0' or cache_on_i /= mode) and eng_idle = '1' and fill_act = '0' then
            rlatch <= '1';
            mode <= cache_on_i;
            case shrink_i is
               when "01" => smask <= to_unsigned(1023, 13);
               when "10" => smask <= to_unsigned(127, 13);
               when "11" => smask <= to_unsigned(15, 13);
               when others => smask <= to_unsigned(2 ** G_SET_BITS - 1, 13);
            end case;
            mst <= M_FLUSH;
            flush_idx <= (others => '0');
            pf_rp <= pf_wp;
            w0 := false; w1 := false; w2 := false;
         end if;
         if w0 then tag0(tix(wa)) <= wd0(TW - 1 downto 0); end if;
         if w1 then tag1(tix(wa)) <= wd1(TW - 1 downto 0); end if;
         if w2 then tag2(tix(wa)) <= wd2(TW - 1 downto 0); end if;
      end if;
   end process;

   ---------------------------------------------------------------- Kickstart loader, QNICE side
   -- one byte at a time: taken on the falling QNICE edge (the M2M device convention), handed to the
   -- ui_clk side with a toggle; q_wait_o holds the QNICE until the toggle comes back
   q_wait_o <= '1' when (qst = Q_IDLE and q_we_i = '1') or qst = Q_WAIT else '0';
   process (q_clk_i)
   begin
      if falling_edge(q_clk_i) then
         qack_s1 <= q_ack; qack_s2 <= qack_s1;
         case qst is
            when Q_IDLE =>
               if q_we_i = '1' then
                  q_a <= q_addr_i; q_d <= q_data_i;
                  q_tgl <= not q_tgl;
                  qst <= Q_WAIT;
               end if;
            when Q_WAIT =>
               if qack_s2 = q_tgl then qst <= Q_DONE; end if;
            when Q_DONE =>
               if q_we_i = '0' then qst <= Q_IDLE; end if;   -- the write cycle has ended
         end case;
      end if;
   end process;

   ---------------------------------------------------------------- fill engine (ui_clk)
   lp_req_o   <= lp_req;
   lp_we_o    <= lp_we;
   lp_addr_o  <= lp_addr;
   lp_wdata_o <= kl_out when lp_src = '1' else wb_line;

   process (ui_clk_i)
      variable la   : unsigned(27 downto 0);
      variable slot : integer range 0 to 3;
   begin
      if rising_edge(ui_clk_i) then
         req_s1 <= req_tgl; req_s2 <= req_s1; req_d <= req_s2;
         qreq_s1 <= q_tgl; qreq_s2 <= qreq_s1;
         lp_req <= '0';
         b_we   <= '0';
         -- Kickstart bytes: into the line being assembled; the 64th byte hands the line to kl_out
         -- (a byte waits, unacknowledged, while kl_out still holds the previous line)
         if qreq_s2 /= qreq_d or kl_held = '1' then
            if q_a(5 downto 0) = "111111" and kl_pend = '1' then
               kl_held <= '1';
            else
               kl_held <= '0';
               qreq_d  <= qreq_s2;
               q_ack   <= qreq_s2;
               if q_a(0) = '0' then
                  kl_line(16 * to_integer(unsigned(q_a(5 downto 1))) + 15 downto 16 * to_integer(unsigned(q_a(5 downto 1))) + 8) <= q_d;
               else
                  kl_line(16 * to_integer(unsigned(q_a(5 downto 1))) + 7 downto 16 * to_integer(unsigned(q_a(5 downto 1)))) <= q_d;
               end if;
               if q_a(5 downto 0) = "111111" then
                  kl_out(511 downto 8) <= kl_line(511 downto 8);
                  kl_out(7 downto 0)   <= kl_line(7 downto 0);
                  kl_out(16 * 31 + 7 downto 16 * 31) <= q_d;     -- the last byte (odd: low half)
                  kl_oaddr <= q_a(18 downto 6);
                  kl_pend  <= '1';
               end if;
            end if;
         end if;
         bcnt_g <= std_logic_vector(bcnt xor ('0' & bcnt(2 downto 1)));
         -- the line's words as they arrive (critical word first: arrival i is word e_crit + i)
         if lp_rvalid_i = '1' and fst = F_RUN then
            slot := to_integer(e_crit + f_rx);
            f_line(128 * slot + 127 downto 128 * slot) <= lp_rdata_i;
            got(slot) <= '1';
            f_rx <= f_rx + 1;
         end if;
         if lp_done_i = '1' and fst = F_RUN then rd_done <= '1'; end if;
         case fst is
            when F_IDLE =>
               if kl_pend = '1' then
                  fst <= F_KLREQ;
               elsif req_s2 /= req_d then
                  e_way <= r_way; e_set <= r_set; e_crit <= r_crit; e_dirty <= r_vdirty;
                  got <= (others => '0'); f_rx <= (others => '0');
                  rd_sent <= '0'; rd_done <= '0';
                  vic_done <= not r_vdirty;
                  ins_n <= (others => '0'); ins_h <= '0';
                  f_cnt <= (others => '0');
                  b_addr <= r_way & std_logic_vector(r_set) & "000";
                  fst <= F_RUN;
               end if;
            when F_RUN =>
               -- 1. the line read goes out first (critical word first)
               if rd_sent = '0' and lp_busy_i = '0' and lp_req = '0' then
                  lp_src  <= '0';
                  la := G_DDR_BASE + shift_left(resize(r_line, 28), 5) + shift_left(resize(e_crit, 28), 3);
                  lp_addr <= std_logic_vector(la);
                  lp_we   <= '0';
                  lp_req  <= '1';
                  rd_sent <= '1';
               end if;
               -- 2. meanwhile a dirty victim is read out of the data RAM into the write-back buffer
               if vic_done = '0' then
                  if f_cnt /= 0 then
                     wb_line(64 * to_integer(f_cnt - 1) + 63 downto 64 * to_integer(f_cnt - 1)) <= b_q;
                  end if;
                  if f_cnt = 8 then
                     vic_done <= '1';
                  else
                     b_addr(2 downto 0) <= std_logic_vector(f_cnt(2 downto 0) + 1);
                     f_cnt <= f_cnt + 1;
                  end if;
               -- 3. then the words are installed in arrival order, 2 x 64 bits each
               elsif ins_n /= 4 then
                  slot := to_integer(e_crit + ins_n(1 downto 0));
                  if got(slot) = '1' then
                     b_addr  <= e_way & std_logic_vector(e_set) & std_logic_vector(to_unsigned(slot, 2)) & ins_h;
                     if ins_h = '0' then
                        b_wdata <= f_line(128 * slot + 63 downto 128 * slot);
                     else
                        b_wdata <= f_line(128 * slot + 127 downto 128 * slot + 64);
                     end if;
                     b_we  <= '1';
                     ins_h <= not ins_h;
                     if ins_h = '1' then
                        ins_n <= ins_n + 1;
                        bcnt  <= bcnt + 1;           -- seen by clk_i one cycle after the write
                     end if;
                  end if;
               elsif rd_done = '1' then
                  if e_dirty = '1' then fst <= F_WBREQ; else done_tgl <= not done_tgl; fst <= F_IDLE; end if;
               end if;
            when F_WBREQ =>
               -- 4. the victim goes back to DDR3 after the fill: not part of the stall
               if lp_busy_i = '0' and lp_req = '0' then
                  lp_src  <= '0';
                  la := G_DDR_BASE + shift_left(resize(r_vline, 28), 5);
                  lp_addr <= std_logic_vector(la);
                  lp_we   <= '1';
                  lp_req  <= '1';
                  fst     <= F_WBWAIT;
               end if;
            when F_WBWAIT =>
               if lp_done_i = '1' then done_tgl <= not done_tgl; fst <= F_IDLE; end if;
            when F_KLREQ =>
               -- a Kickstart line into DDR3 (the Amiga is held in reset while QNICE loads)
               if lp_busy_i = '0' and lp_req = '0' then
                  la := G_DDR_BASE + shift_left(resize(unsigned(std_logic_vector'(KICK_LINE & kl_oaddr)), 28), 5);
                  lp_addr <= std_logic_vector(la);
                  lp_we   <= '1';
                  lp_src  <= '1';
                  lp_req  <= '1';
                  fst     <= F_KLWAIT;
               end if;
            when F_KLWAIT =>
               if lp_done_i = '1' then kl_pend <= '0'; lp_src <= '0'; fst <= F_IDLE; end if;
         end case;
      end if;
   end process;
end architecture rtl;
