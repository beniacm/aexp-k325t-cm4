--------------------------------------------------------------------------------
-- tb_chip_cache.vhd -- chip_cache + stall_ctrl + mig_arb + a MIG model, driven by a minimig-like
-- memory master on the GATED clock (BUFGCE model: a source edge reaches the "Amiga" only when the
-- controller's ce_o is high just before it).
--   ghdl -r --std=08 tb_chip_cache -gG_MODE=1 -gG_SHRINK=2 -gG_N=200000
-- G_MODE 0 = identity (phase 2), 1 = cache; G_SHRINK 0..3 = 8192 / 1024 / 128 / 16 sets.
-- The master makes 4-tick bus cycles like minimig's port (address and _OE/_WE from tick 0, read
-- data taken at tick 2) to random words of chip RAM (2 MB in cache mode, 1 MB in identity mode)
-- and slow RAM, with random byte enables, runs of sequential addresses (DMA-like) and random
-- jumps (CPU-like), and checks every read against a flat reference memory.  The machine-time view
-- is what matters: the master counts machine ticks only, so a stall is invisible to it unless data
-- is wrong.  Also checked: no MIG protocol error, the cache statistics.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_chip_cache is
   generic (G_MODE : natural := 1; G_SHRINK : natural := 0; G_N : natural := 100000;
            G_WR : natural := 35; G_SLOW : natural := 20);   -- percent
end entity;

architecture sim of tb_chip_cache is
   constant TS : time := 31.94 ns;          -- source clock
   constant TU : time := 10 ns;             -- MIG ui_clk
   signal clk, ui_clk : std_logic := '0';
   signal done : boolean := false;
   signal ce, miss, inj, reset : std_logic := '0';
   signal lag : unsigned(31 downto 0);
   signal diag : std_logic_vector(95 downto 0);
   signal chip_sel, slow_sel, we_n, oe_n, bhe_n, ble_n : std_logic := '1';
   signal addr : std_logic_vector(20 downto 1) := (others => '0');
   signal wdata, rdata : std_logic_vector(15 downto 0) := (others => '0');
   signal rdata48 : std_logic_vector(47 downto 0);
   signal long, long_v : std_logic := '0';   -- stage 3: 32-bit writes (68EC020)
   signal wdata2 : std_logic_vector(15 downto 0) := (others => '0');
   signal fills, wbacks : unsigned(31 downto 0);
   signal mode : std_logic;
   signal lp_req, lp_we, lp_busy, lp_rvalid, lp_done : std_logic;
   signal lp_addr : std_logic_vector(27 downto 0);
   signal lp_wdata : std_logic_vector(511 downto 0);
   signal lp_rdata : std_logic_vector(127 downto 0);
   signal app_addr : std_logic_vector(27 downto 0);
   signal app_cmd : std_logic_vector(2 downto 0);
   signal app_en, app_rdy, app_wend, app_wren, app_wrdy, app_rdv : std_logic;
   signal app_wdata, app_rdata : std_logic_vector(127 downto 0);
   signal app_wmask : std_logic_vector(15 downto 0);
   signal mig_err : natural;
   signal shrink : std_logic_vector(1 downto 0);
   signal cache_on : std_logic;
begin
   clk <= not clk after TS / 2 when not done;
   ui_clk <= not ui_clk after TU / 2 when not done;
   shrink <= std_logic_vector(to_unsigned(G_SHRINK, 2));
   cache_on <= '1' when G_MODE = 1 else '0';

   ctrl : entity work.stall_ctrl
      generic map (G_N_NATIVE => 950272, G_N_FAST => 952365)
      port map (clk_i => clk, fast_i => '0', cfg_i => x"00", stall_i => '0', miss_i => miss,
                vsync_i => '0', ce_o => ce, inj_o => inj, lag_o => lag, diag_o => diag, mode_o => open);

   dut : entity work.chip_cache
      port map (clk_i => clk, reset_i => reset, cache_on_i => cache_on, shrink_i => shrink,
                chip1m_i => '1', chip_sel_i => chip_sel, slow_sel_i => slow_sel, addr_i => addr,
                wdata_i => wdata, we_n_i => we_n, oe_n_i => oe_n, bhe_n_i => bhe_n, ble_n_i => ble_n,
                long_i => long, wdata2_i => wdata2,
                rdata_o => rdata, rdata48_o => rdata48, miss_o => miss, fills_o => fills, wbacks_o => wbacks, mode_o => mode,
                ui_clk_i => ui_clk, lp_req_o => lp_req, lp_we_o => lp_we, lp_addr_o => lp_addr,
                lp_wdata_o => lp_wdata, lp_busy_i => lp_busy, lp_rvalid_i => lp_rvalid,
                lp_rdata_i => lp_rdata, lp_done_i => lp_done);

   arb : entity work.mig_arb
      port map (clk => ui_clk, rst => '0',
                lp_req => lp_req, lp_we => lp_we, lp_addr => lp_addr, lp_wdata => lp_wdata,
                lp_busy => lp_busy, lp_rvalid => lp_rvalid, lp_rdata => lp_rdata, lp_done => lp_done,
                c1_app_addr => (others => '0'), c1_app_cmd => "001", c1_app_en => '0', c1_app_rdy => open,
                c1_wdf_data => (others => '0'), c1_wdf_end => '0', c1_wdf_wren => '0',
                c1_wdf_mask => (others => '0'), c1_wdf_rdy => open, c1_rd_data => open, c1_rd_valid => open,
                app_addr => app_addr, app_cmd => app_cmd, app_en => app_en, app_rdy => app_rdy,
                app_wdf_data => app_wdata, app_wdf_end => app_wend, app_wdf_wren => app_wren,
                app_wdf_mask => app_wmask, app_wdf_rdy => app_wrdy, app_rd_data => app_rdata,
                app_rd_valid => app_rdv);

   mig : entity work.mig_model
      generic map (G_AW => 19)
      port map (clk => ui_clk, app_addr => app_addr, app_cmd => app_cmd, app_en => app_en,
                app_rdy => app_rdy, app_wdf_data => app_wdata, app_wdf_wren => app_wren,
                app_wdf_mask => app_wmask, app_wdf_rdy => app_wrdy, app_rd_data => app_rdata,
                app_rd_valid => app_rdv, errors => mig_err);

   -- the Amiga: one process on the gated clock
   amiga : process

      type ref_t is array (natural range <>) of std_logic_vector(15 downto 0);
      variable ref : ref_t(0 to 2**21 - 1) := (others => (others => '0'));   -- chip 2M words? (1M) + slow
      variable s1, s2 : positive := 5; variable r : real;
      variable a, ra, run, bad, nacc, ticks, bad48, g : natural := 0;
      variable w48 : std_logic_vector(47 downto 0);
      variable d2 : std_logic_vector(15 downto 0);
      variable is_long : boolean;
      variable is_slow, is_wr : boolean;
      variable be : std_logic_vector(1 downto 0);
      variable d : std_logic_vector(15 downto 0);
      variable chipw : natural;
      procedure tick is   -- wait for the next machine edge
      begin
         loop
            wait until rising_edge(clk);
            exit when ce = '1';
         end loop;
         ticks := ticks + 1;
      end procedure;
   begin
      if G_MODE = 1 then chipw := 2**20; else chipw := 2**19; end if;   -- chip words: 2 MB / 1 MB
      -- a full reset: the cache latches its mode and flushes
      reset <= '1'; for i in 1 to 20 loop tick; end loop; reset <= '0';
      for i in 1 to 9000 loop tick; end loop;
      while nacc < G_N loop
         uniform(s1, s2, r);
         if run = 0 then
            uniform(s1, s2, r); run := 1 + integer(r * 40.0);   -- a DMA-like run or a single access
            uniform(s1, s2, r); is_slow := r < real(G_SLOW) / 100.0 and G_MODE = 1;   -- identity: 1M chip, no slow RAM
            uniform(s1, s2, r);
            if is_slow then a := integer(r * real(2**18 - 64)); else a := integer(r * real(chipw - 64)); end if;
         else
            a := a + 1;
         end if;
         run := run - 1;
         uniform(s1, s2, r); is_wr := r < real(G_WR) / 100.0;
         uniform(s1, s2, r);
         if r < 0.7 then be := "00"; elsif r < 0.85 then be := "01"; else be := "10"; end if;  -- active low
         if is_slow then ra := 2**20 + a; slow_sel <= '1'; chip_sel <= '0';
            addr <= "00" & std_logic_vector(to_unsigned(a, 18));
         else ra := a; slow_sel <= '0'; chip_sel <= '1';
            addr <= std_logic_vector(to_unsigned(a, 20));
         end if;
         bhe_n <= be(1); ble_n <= be(0);
         uniform(s1, s2, r); d := std_logic_vector(to_unsigned(integer(r * 65535.0), 16));
         wdata <= d;
         -- stage 3: a third of the word writes at even addresses are 32-bit (both words, all bytes)
         uniform(s1, s2, r); is_long := is_wr and (a mod 2) = 0 and r < 0.33;
         uniform(s1, s2, r); d2 := std_logic_vector(to_unsigned(integer(r * 65535.0), 16));
         if is_long then be := "00"; bhe_n <= '0'; ble_n <= '0'; long <= '1'; else long <= '0'; end if;
         wdata2 <= d2;
         if is_wr then we_n <= '0'; oe_n <= '1'; else we_n <= '1'; oe_n <= '0'; end if;
         tick; tick;                     -- ticks 0, 1
         tick;                           -- tick 2: the consumer edge
         if not is_wr then
            -- stage 3: the AGA chip48 words (A+1, A+2, A+3 inside the aligned group of 4)
            g := ra - (ra mod 4);
            w48 := ref(g + (ra + 1) mod 4) & ref(g + (ra + 2) mod 4) & ref(g + (ra + 3) mod 4);
            if rdata48 /= w48 then
               bad48 := bad48 + 1;
               if bad48 < 10 then report "chip48 at " & integer'image(ra) & " wrong" severity error; end if;
            end if;
            if rdata /= ref(ra) then
               bad := bad + 1;
               if bad < 10 then
                  report "read " & integer'image(ra) & ": got " & integer'image(to_integer(unsigned(rdata))) &
                         " want " & integer'image(to_integer(unsigned(ref(ra)))) & " (fills " &
                         integer'image(to_integer(fills)) & ", run left " & integer'image(run) & "), ref(577279) " &
                         integer'image(to_integer(unsigned(ref(577279)))) & " ref(577278) " &
                         integer'image(to_integer(unsigned(ref(577278)))) severity error;
               end if;
            end if;
         else
            if be(1) = '0' then ref(ra)(15 downto 8) := d(15 downto 8); end if;
            if be(0) = '0' then ref(ra)(7 downto 0) := d(7 downto 0); end if;
            if is_long then ref(ra + 1) := d2; end if;
         end if;
         we_n <= '1'; oe_n <= '1'; long <= '0';
         tick;                           -- tick 3
         nacc := nacc + 1;
      end loop;
      wait until rising_edge(clk);
      report "mode " & integer'image(G_MODE) & " shrink " & integer'image(G_SHRINK) & ": " &
             integer'image(nacc) & " accesses in " & integer'image(ticks) & " machine ticks, wrong reads " &
             integer'image(bad) & ", wrong chip48 " & integer'image(bad48) & ", fills " & integer'image(to_integer(fills)) & ", write-backs " &
             integer'image(to_integer(wbacks)) & ", MIG errors " & integer'image(mig_err);
      if bad = 0 and bad48 = 0 and mig_err = 0 and (G_MODE = 0 or fills > 0) then
         report "TB_CHIP_CACHE_PASS";
      else
         report "TB_CHIP_CACHE_FAIL" severity error;
      end if;
      done <= true; wait;
   end process;
end architecture;
