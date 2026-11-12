--------------------------------------------------------------------------------
-- chip_cache.vhd -- the Amiga's chip and slow RAM through a block-RAM cache in front of DDR3, with a
-- stoppable Amiga clock (A1200 study stage 2).  Replaces the chip / slow RAM lanes of mega65.vhd.
--
-- Data RAM: the 256 RAMB36 that held chip 512 KB + slow 512 KB: 512 K words of 16 bits (two 8-bit
-- lanes), port A in the UNGATED source clock (clk_i; address and data from minimig's memory port,
-- which only changes on main_clk edges), port B in the MIG ui_clk (line fills and write-backs).
--
-- Two modes, chosen at a full M2M reset (cache_on_i is sampled while reset_i is high):
--  * identity (cache off, the phase-2 machine): data word address = bank & addr(18:1) with bank 0
--    = chip 0..512K, 1 = slow RAM (or chip 512K..1M in the "1M chip" configuration) -- exactly
--    phase 2's layout; no tags, never a stall.  Reads at the extra source-clock edges between
--    main_clk edges are harmless, writes repeat the same data at the same address (idempotent).
--  * cache: 2-way set associative, 64-byte lines (32 words), 8192 sets (1 MB), write-back,
--    write-allocate; the backing store is DDR3 (word address base G_DDR_BASE): chip RAM up to
--    2 MB at backing words 0..1M-1, slow RAM at 1M..1M+256K-1.  Tags in LUT RAM (asynchronous
--    read): hit / miss is known in the same tick as the address; a miss (an access with _OE or
--    _WE low that is not a hit) is the COMBINATIONAL stall miss_o -> stall_ctrl.miss_i -> the
--    BUFGCE enable: the Amiga stops before it can consume the data.  The line is filled (after a
--    write-back of a dirty victim) through the MIG line port (mig_arb.vhd), the tag is installed,
--    miss_o drops, port A (re-reading every source tick) has the data before the next edge.
--    shrink_i ("00" all 8192 sets, "01" 1024, "10" 128, "11" 16) makes the cache small so that
--    misses and write-backs happen all the time (test of machine-time exactness).
--    Replacement: an invalid way first, else pseudo-random.
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
-- Not in this version (study section 3): prefetchers, write miss without stall.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity chip_cache is
   generic (
      G_DDR_BASE : unsigned(27 downto 0) := x"2000000"   -- backing store, MIG app_addr units (64 MB)
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
   type tag_t is array (0 to SETS - 1) of std_logic_vector(17 downto 0);
   signal tag0, tag1 : tag_t := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of tag0, tag1 : signal is "distributed";

   signal mode        : std_logic := '0';
   signal smask       : unsigned(12 downto 0) := (others => '1');

   -- the access
   signal acc         : std_logic;
   signal bword       : unsigned(20 downto 0);      -- backing word address
   signal bline       : unsigned(15 downto 0);      -- backing line
   signal setn        : unsigned(12 downto 0);
   signal t0, t1      : std_logic_vector(17 downto 0);
   signal hit0, hit1  : std_logic;
   signal miss        : std_logic;
   signal hway        : std_logic;

   -- port A (word address a_addr: index a_addr(18 downto 2), lane a_addr(1 downto 0))
   signal a_addr      : std_logic_vector(18 downto 0);
   signal a_wdata     : std_logic_vector(15 downto 0);
   signal a_we_u, a_we_l : std_logic;
   signal a_we_2      : std_logic;                  -- the second word of a 32-bit write
   type q_t is array (0 to 3) of std_logic_vector(15 downto 0);
   signal q           : q_t;                        -- the four words of the group
   signal a_lane_q    : unsigned(1 downto 0) := (others => '0');   -- lane of the word in q

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
   signal fill_way    : std_logic := '0';
   signal fill_crit   : unsigned(1 downto 0) := (others => '0');
   signal beats_ok    : unsigned(2 downto 0);       -- 16-byte words of that fill installed (0..4)
   signal notready    : std_logic;
   signal hitany      : std_logic;
   signal r_way       : std_logic := '0';
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
   type fst_t is (F_IDLE, F_RUN, F_WBREQ, F_WBWAIT);
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
   signal e_way       : std_logic := '0';
   signal e_set       : unsigned(12 downto 0) := (others => '0');
   signal e_crit      : unsigned(1 downto 0) := (others => '0');
   signal e_dirty     : std_logic := '0';
   signal b_addr      : std_logic_vector(16 downto 0) := (others => '0');   -- 64-bit group index
   signal b_wdata     : std_logic_vector(63 downto 0) := (others => '0');
   signal b_we        : std_logic := '0';
   signal b_q         : std_logic_vector(63 downto 0);
   signal f_cnt       : unsigned(5 downto 0) := (others => '0');
   signal f_line      : std_logic_vector(511 downto 0) := (others => '0');
   signal lp_req      : std_logic := '0';
   signal lp_we       : std_logic := '0';
   signal lp_addr     : std_logic_vector(27 downto 0) := (others => '0');
begin
   ---------------------------------------------------------------- the access, combinational
   acc   <= (chip_sel_i or slow_sel_i) and (not we_n_i or not oe_n_i);
   bword <= unsigned(std_logic_vector'("100" & addr_i(18 downto 1))) when slow_sel_i = '1' else
            unsigned(std_logic_vector'('0' & addr_i));
   bline <= bword(20 downto 5);
   setn  <= bline(12 downto 0) and smask;
   t0    <= tag0(to_integer(setn));
   t1    <= tag1(to_integer(setn));
   hit0  <= '1' when t0(17) = '1' and unsigned(t0(15 downto 0)) = bline else '0';
   hit1  <= '1' when t1(17) = '1' and unsigned(t1(15 downto 0)) = bline else '0';
   hway  <= hit1;
   hitany <= hit0 or hit1;
   -- the line being filled: its tag is valid already, but a 16-byte word not yet installed waits
   bc_bin   <= unsigned(bc_s2) xor ('0' & unsigned(bc_s2(2 downto 1))) xor ("00" & bc_s2(2));
   beats_ok <= bc_bin - fill_base;
   notready <= '1' when fill_act = '1' and setn = fill_set and hway = fill_way and
                        resize(bword(4 downto 3) - fill_crit, 3) >= beats_ok else '0';
   eng_idle <= '1' when done_s2 = done_seen else '0';
   miss  <= '1' when mode = '1' and acc = '1' and (hitany = '0' or notready = '1') else
            '1' when mode = '1' and mst = M_FLUSH else '0';
   miss_o <= miss;
   mode_o <= mode;
   fills_o  <= fills;
   wbacks_o <= wbacks;

   ---------------------------------------------------------------- port A
   a_addr <= std_logic_vector(hway & setn & bword(4 downto 0)) when mode = '1' else
             (slow_sel_i or (chip1m_i and addr_i(19))) & addr_i(18 downto 1);
   a_wdata <= wdata_i;
   -- writes: identity mode as phase 2; cache mode only on a hit (a miss is filled first)
   a_we_u <= '1' when acc = '1' and we_n_i = '0' and bhe_n_i = '0' and (mode = '0' or miss = '0') else '0';
   a_we_l <= '1' when acc = '1' and we_n_i = '0' and ble_n_i = '0' and (mode = '0' or miss = '0') else '0';
   -- (only for an even word address: word A+1 must be in the same 64-bit group; the 68EC020's 32-bit
   --  chip cycles are long-aligned, a misaligned one would otherwise write lane 0 of the same group)
   a_we_2 <= '1' when acc = '1' and we_n_i = '0' and long_i = '1' and a_addr(0) = '0' and
                      (mode = '0' or miss = '0') else '0';

   -- tdp_ram directly (dualport_2clk_ram passes its clocks through an expression: one delta of
   -- delay that races the registers feeding it in simulation).  8 byte lanes: lane k (word k of
   -- the group) upper = 2k+1, lower = 2k; port B word k = b_wdata(16k+15 downto 16k).
   g_lane : for k in 0 to 3 generate
      signal we_u, we_l, sec : std_logic;
      signal d : std_logic_vector(15 downto 0);
   begin
      -- sec: this lane is word A+1 of a 32-bit write
      sec  <= '1' when long_i = '1' and a_addr(0) = '0' and unsigned(a_addr(1 downto 0)) + 1 = k else '0';
      we_u <= a_we_u when unsigned(a_addr(1 downto 0)) = k else a_we_2 when sec = '1' else '0';
      we_l <= a_we_l when unsigned(a_addr(1 downto 0)) = k else a_we_2 when sec = '1' else '0';
      d    <= wdata2_i when sec = '1' else a_wdata;
      ram_u : entity work.tdp_ram
         generic map (ADDR_WIDTH => 17, DATA_WIDTH => 8)
         port map (clock_a => clk_i, address_a => a_addr(18 downto 2), data_a => d(15 downto 8),
                   wren_a => we_u, q_a => q(k)(15 downto 8), clock_b => ui_clk_i, address_b => b_addr,
                   data_b => b_wdata(16 * k + 15 downto 16 * k + 8), wren_b => b_we,
                   q_b => b_q(16 * k + 15 downto 16 * k + 8));
      ram_l : entity work.tdp_ram
         generic map (ADDR_WIDTH => 17, DATA_WIDTH => 8)
         port map (clock_a => clk_i, address_a => a_addr(18 downto 2), data_a => d(7 downto 0),
                   wren_a => we_l, q_a => q(k)(7 downto 0), clock_b => ui_clk_i, address_b => b_addr,
                   data_b => b_wdata(16 * k + 7 downto 16 * k), wren_b => b_we,
                   q_b => b_q(16 * k + 7 downto 16 * k));
   end generate;
   -- the RAMs register the address every clk_i edge: the lane select follows one edge later
   process (clk_i)
   begin
      if rising_edge(clk_i) then a_lane_q <= unsigned(a_addr(1 downto 0)); end if;
   end process;
   rdata_o   <= q(to_integer(a_lane_q));
   rdata48_o <= q(to_integer(a_lane_q + 1)) & q(to_integer(a_lane_q + 2)) & q(to_integer(a_lane_q + 3));


   ---------------------------------------------------------------- tags and misses (clk_i)
   -- one write port per tag RAM (LUT RAM): flush, install or "dirty"
   process (clk_i)
      variable way      : std_logic;
      variable w0, w1   : boolean;
      variable wa       : unsigned(12 downto 0);
      variable wd0, wd1 : std_logic_vector(17 downto 0);
   begin
      if rising_edge(clk_i) then
         rnd <= rnd(14 downto 0) & (rnd(15) xor rnd(13) xor rnd(12) xor rnd(10));
         done_s1 <= done_tgl; done_s2 <= done_s1;
         bc_s1 <= bcnt_g; bc_s2 <= bc_s1;
         reset_d <= reset_i;
         w0 := false; w1 := false; wa := setn; wd0 := t0; wd1 := t1;
         if fill_act = '1' and beats_ok = 4 then fill_act <= '0'; end if;
         case mst is
            when M_FLUSH =>
               wa := flush_idx; wd0 := (others => '0'); wd1 := (others => '0'); w0 := true; w1 := true;
               flush_idx <= flush_idx + 1;
               if flush_idx = SETS - 1 then mst <= M_IDLE; end if;
            when M_IDLE =>
               if mode = '1' and acc = '1' then
                  if hitany = '1' then
                     -- a hit (also on a filling line whose word is in): a write marks the line dirty
                     if notready = '0' and we_n_i = '0' then
                        if hit0 = '1' and t0(16) = '0' then wd0 := t0(17) & '1' & t0(15 downto 0); w0 := true; end if;
                        if hit1 = '1' and t1(16) = '0' then wd1 := t1(17) & '1' & t1(15 downto 0); w1 := true; end if;
                     end if;
                  elsif eng_idle = '1' and fill_act = '0' then
                     -- a miss: choose the victim, install the new tag now (its words follow), ask the
                     -- fill engine; the access waits in notready until its 16-byte word is in
                     if t0(17) = '0' then way := '0';
                     elsif t1(17) = '0' then way := '1';
                     else way := rnd(0); end if;
                     r_way  <= way;
                     r_set  <= setn;
                     r_line <= bline;
                     r_crit <= bword(4 downto 3);
                     if way = '0' then
                        r_vline <= unsigned(t0(15 downto 0)); r_vdirty <= t0(17) and t0(16);
                        wd0 := "10" & std_logic_vector(bline); w0 := true;
                        if t0(17) = '1' and t0(16) = '1' then wbacks <= wbacks + 1; end if;
                     else
                        r_vline <= unsigned(t1(15 downto 0)); r_vdirty <= t1(17) and t1(16);
                        wd1 := "10" & std_logic_vector(bline); w1 := true;
                        if t1(17) = '1' and t1(16) = '1' then wbacks <= wbacks + 1; end if;
                     end if;
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
         end case;
         -- a full reset (its first tick): latch mode and size, invalidate all tags (a cold boot:
         -- dirty lines are dropped; the Amiga clears its memory after a cold boot anyway)
         -- (once per reset, and only with the fill engine idle: a fill must not write into the data
         --  RAM after a switch to identity mode)
         if reset_i = '0' then rlatch <= '0'; end if;
         if reset_i = '1' and rlatch = '0' and eng_idle = '1' and fill_act = '0' then
            rlatch <= '1';
            mode <= cache_on_i;
            case shrink_i is
               when "01" => smask <= to_unsigned(1023, 13);
               when "10" => smask <= to_unsigned(127, 13);
               when "11" => smask <= to_unsigned(15, 13);
               when others => smask <= (others => '1');
            end case;
            mst <= M_FLUSH;
            flush_idx <= (others => '0');
            w0 := false; w1 := false;
         end if;
         if w0 then tag0(to_integer(wa)) <= wd0; end if;
         if w1 then tag1(to_integer(wa)) <= wd1; end if;
      end if;
   end process;

   ---------------------------------------------------------------- fill engine (ui_clk)
   lp_req_o   <= lp_req;
   lp_we_o    <= lp_we;
   lp_addr_o  <= lp_addr;
   lp_wdata_o <= wb_line;

   process (ui_clk_i)
      variable la   : unsigned(27 downto 0);
      variable slot : integer range 0 to 3;
   begin
      if rising_edge(ui_clk_i) then
         req_s1 <= req_tgl; req_s2 <= req_s1; req_d <= req_s2;
         lp_req <= '0';
         b_we   <= '0';
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
               if req_s2 /= req_d then
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
                  la := G_DDR_BASE + shift_left(resize(r_vline, 28), 5);
                  lp_addr <= std_logic_vector(la);
                  lp_we   <= '1';
                  lp_req  <= '1';
                  fst     <= F_WBWAIT;
               end if;
            when F_WBWAIT =>
               if lp_done_i = '1' then done_tgl <= not done_tgl; fst <= F_IDLE; end if;
         end case;
      end if;
   end process;
end architecture rtl;
