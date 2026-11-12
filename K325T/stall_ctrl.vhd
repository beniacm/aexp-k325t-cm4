--------------------------------------------------------------------------------
-- stall_ctrl.vhd -- catch-up clock controller for a stoppable Amiga clock (K325T, A1200 study
-- stage 1).  Runs on the UNGATED source clock clk_i (28.375 MHz x 32/31 = 29.290 MHz in stage 1,
-- x 32/29 = 31.310 MHz since stage 2; the native MMCM's VCO / 38.75 resp. / 36.25; the generics
-- give the ratio) and decides for every source edge whether the next edge reaches
-- the Amiga (ce_o -> BUFGCE of main_clk).
--
-- DDS: credit (in 2^-20 machine ticks) grows by N per source edge, N = 31/32 x 2^20 (native,
-- average 28.375000 MHz exactly) or N_FAST (the HDMI flicker-free "fast" target, +0.22 %);
-- an edge is passed while credit >= 1 tick and no stall is requested, and costs 1 tick.
-- Without stalls one edge in 32 is dropped (native).  During a stall no edge passes, the
-- credit (= the machine's lag behind real time, in machine ticks) grows; afterwards every edge
-- passes until it is back below one tick: S ns of stall are repaid in 31 x S ns.  The lag is
-- capped at 2^G_CAP_BITS machine ticks (default 2^19 = 18.5 ms): under sustained overload the
-- excess is forgiven (counted), so the machine does not race at +3.2 % for minutes afterwards.
--
-- Stall injector (stage 1 test, no memory involved): pseudo-random stalls, start probability
-- per source tick (m+1) / 2^(e+8), duration ((dm+1) << de) + (random AND (2^j - 1)) source
-- ticks (34.14 ns each).
--
-- Configuration: the Rockchip bridge's VIDEO byte (command 0x70, unused by this core) =
-- 1 rrr vvvv: register rrr := vvvv (bytes with bit 7 = 0 are ignored, m65d writes only 0..3):
--   0 mode: b0 injector on, b1 native rate (flicker-free ignored), b2 avm_mig without the
--           burst abort on M2M resets (the old behaviour, to reproduce the frozen picture)
--                                 1 e (rate exponent)      2 m (rate mantissa)
--   3 de (duration exponent)      4 dm (duration mantissa)  5 j (duration jitter bits)
--   6 b3 toggles = take a snapshot of all statistics, b2..0 = page shown in diag_o
--   7 b0 toggles = clear lag_max and the event counters
-- Readout (diag_o = bridge STATUS 60..71, three big-endian 32-bit words W0 W1 W2):
--   page 0: W0 = e m de dm j mode (4 bits each) & snapshot sequence (8), W1 = lag max, W2 = lag
--           now (machine ticks)
--   page 1: W0 = stall count, W1 = stalled source ticks, W2 = dropped pulses without a stall
--   page 2: W0 = machine vsync count, W1:W2 = source tick count at the last vsync (64 bits)
--   page 3: W0 = forgiven ticks (lag cap), W1:W2 = source tick count at the snapshot
--   page 4: W0 = x"A1200001" (id) , W1:W2 = machine (passed) ticks at the snapshot
--   page 5: W0 = probe(31:0) at the snapshot, W1 = probe(22) falling edges, W2 = ticks with any of
--           probe(26:24) set;  page 6: W0 = probe(63:32), W1 = chip cache line fills, W2 = write-backs
--   stage 2b: while page 5 is selected, writes to registers 3 / 4 also set the chip cache's prefetch
--           enables (r3 b0 bitplane, b1 sprite, b2 audio, b3 disk; r4 b0 copper, b1 blitter, b2 CPU)
--           and r4 b3 = the audio FIFO (audio_fifo.vhd) on; r5 b1 = memory mode override (stage 3 P4:
--           without it the cache mode follows the machine profile: AGA = cache + 2 MB chip, else identity);
--           keep the stall injector off (mode b0) meanwhile, it reads registers 3 / 4 too
--   register 7 bits 3..1 + register 0 bit 3: the chip cache (chip_cache.vhd), taken at a full reset:
--           r7 b1 = chip RAM through the cache, b2 = 2 MB chip RAM, b3 & r0 b3 = shrink (sets / 1, 8,
--           64, 512)
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity stall_ctrl is
   generic (
      G_N_NATIVE : natural := 1015808;     -- 31/32 x 2^20
      G_N_FAST   : natural := 1018045;     -- 31/32 x 455/454 x 2^20 (28.4375 MHz average)
      G_CAP_BITS : natural := 19
   );
   port (
      clk_i      : in  std_logic;          -- ungated source clock
      fast_i     : in  std_logic;          -- flicker-free target select (asynchronous)
      cfg_i      : in  std_logic_vector(7 downto 0);   -- bridge VIDEO byte (asynchronous)
      stall_i    : in  std_logic := '0';   -- external stall request (synchronous to clk_i)
      miss_i     : in  std_logic := '0';   -- combinational stall (cache miss): blocks THIS edge;
                                           -- must be stable before the clk_i edge it gates
      vsync_i    : in  std_logic;          -- machine vsync (a main_clk register)
      probe_i    : in  std_logic_vector(63 downto 0) := (others => '0');  -- main_clk signals (debug)
      ce_o       : out std_logic;          -- BUFGCE enable: '1' = the next edge passes
      inj_o      : out std_logic;          -- injected stall active (for a probe / test bench)
      lag_o      : out unsigned(31 downto 0);           -- current lag, machine ticks
      diag_o     : out std_logic_vector(95 downto 0);
      mode_o     : out std_logic_vector(3 downto 0);   -- register 0 (b2: test switch for the top)
      cache_o    : out std_logic_vector(3 downto 0);   -- register 7 bits 3..1 (cache) & register 0 bit 3
      pf_en_o    : out std_logic_vector(6 downto 0);   -- stage 2b: the chip cache's prefetch enables
      afifo_o    : out std_logic;                      -- stage 2b: the audio FIFO on (r4 b3, page 5)
      memovr_o   : out std_logic;                      -- stage 3 (P4): cache_o overrides the menu (r5 b1, page 5)
      regs_o     : out std_logic_vector(40 downto 0);  -- stage 3: read-back r7..r0 & pf_en & afifo & memovr
      mach_o     : out unsigned(31 downto 0);          -- stage 2b: machine ticks so far (for the FIFO)
      fills_i    : in  unsigned(31 downto 0) := (others => '0');   -- chip cache statistics (clk_i)
      wbacks_i   : in  unsigned(31 downto 0) := (others => '0')
   );
end entity stall_ctrl;

architecture rtl of stall_ctrl is
   constant C_ONE   : unsigned(40 downto 0) := to_unsigned(2**20, 41);
   constant C_CAP   : unsigned(40 downto 0) := shift_left(to_unsigned(1, 41), G_CAP_BITS + 20);

   signal fast_s1, fast_s2 : std_logic := '0';
   signal cfg_s1, cfg_s2, cfg_s3 : std_logic_vector(7 downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of fast_s1, fast_s2, cfg_s1, cfg_s2 : signal is "TRUE";
   signal cfg_stable : unsigned(3 downto 0) := (others => '0');

   type reg_t is array (0 to 7) of unsigned(3 downto 0);
   signal regs     : reg_t := (others => (others => '0'));
   signal pf_en    : std_logic_vector(6 downto 0) := (others => '0');
   signal afifo    : std_logic := '0';
   signal memovr   : std_logic := '0';
   signal snap_tog : std_logic := '0';
   signal clr_tog  : std_logic := '0';

   signal credit   : unsigned(39 downto 0) := (others => '0');
   signal ce       : std_logic := '0';

   -- injector
   signal rnd      : unsigned(31 downto 0) := x"2545F491";
   signal inj_left : unsigned(20 downto 0) := (others => '0');
   signal inj      : std_logic := '0';
   signal stall_d  : std_logic := '0';

   -- statistics
   signal src_cnt, mach_cnt, vs_ts : unsigned(63 downto 0) := (others => '0');
   signal vs_cnt, stalls, stall_tk, drops, forgiven : unsigned(31 downto 0) := (others => '0');
   signal lag_now, lag_max : unsigned(31 downto 0) := (others => '0');
   signal vs_d     : std_logic := '0';
   signal pr_d     : std_logic_vector(63 downto 0) := (others => '0');
   signal we_fall, oe_fall, rst_cyc : unsigned(31 downto 0) := (others => '0');
   signal s_probe  : std_logic_vector(63 downto 0) := (others => '0');
   signal s_we_fall, s_oe_fall, s_rst_cyc : unsigned(31 downto 0) := (others => '0');
   signal s_fills, s_wbacks : unsigned(31 downto 0) := (others => '0');

   -- snapshot
   signal s_src, s_mach, s_vs_ts : unsigned(63 downto 0) := (others => '0');
   signal s_vs_cnt, s_stalls, s_stall_tk, s_drops, s_forgiven, s_lag_now, s_lag_max :
          unsigned(31 downto 0) := (others => '0');
   signal s_seq    : unsigned(7 downto 0) := (others => '0');
   signal diag     : std_logic_vector(95 downto 0) := (others => '0');
begin
   ce_o   <= ce and not miss_i;          -- the BUFGCE enable (combinational miss path)
   inj_o  <= inj;
   lag_o  <= lag_now;
   diag_o <= diag;
   mode_o <= std_logic_vector(regs(0));
   cache_o <= std_logic_vector(regs(7)(3 downto 1)) & regs(0)(3);
   pf_en_o <= pf_en;
   afifo_o <= afifo;
   memovr_o <= memovr;
   regs_o  <= std_logic_vector(regs(7)) & std_logic_vector(regs(6)) & std_logic_vector(regs(5)) &
              std_logic_vector(regs(4)) & std_logic_vector(regs(3)) & std_logic_vector(regs(2)) &
              std_logic_vector(regs(1)) & std_logic_vector(regs(0)) & pf_en & afifo & memovr;
   mach_o  <= mach_cnt(31 downto 0);

   process (clk_i)
      variable cr      : unsigned(40 downto 0);
      variable pass    : std_logic;
      variable stall   : std_logic;
      variable kmask   : unsigned(22 downto 0);
      variable jmask   : unsigned(15 downto 0);
      variable dur     : unsigned(20 downto 0);
      variable x       : unsigned(31 downto 0);
      variable idx     : integer range 0 to 7;
      variable lagv    : unsigned(31 downto 0);
   begin
      if rising_edge(clk_i) then
         ---------------------------------------------------------------- configuration
         fast_s1 <= fast_i;
         fast_s2 <= fast_s1;
         cfg_s1  <= cfg_i;
         cfg_s2  <= cfg_s1;
         cfg_s3  <= cfg_s2;
         if cfg_s2 /= cfg_s3 then
            cfg_stable <= (others => '0');
         elsif cfg_stable /= 15 then
            cfg_stable <= cfg_stable + 1;
         end if;
         if cfg_stable = 15 and cfg_s3(7) = '1' then
            idx := to_integer(unsigned(cfg_s3(6 downto 4)));
            regs(idx) <= unsigned(cfg_s3(3 downto 0));
            -- stage 2b: with page 5 selected, registers 3 / 4 also set the cache's prefetch enables
            if regs(6)(2 downto 0) = "101" and idx = 3 then pf_en(3 downto 0) <= cfg_s3(3 downto 0); end if;
            if regs(6)(2 downto 0) = "101" and idx = 4 then pf_en(6 downto 4) <= cfg_s3(2 downto 0);
                                                               afifo <= cfg_s3(3); end if;
            -- stage 3 (P4): with page 5 selected, register 5 b1 = the memory mode override: the
            -- cache settings below (r7 b3..1, r0 b3) are used instead of the menu's machine profile
            if regs(6)(2 downto 0) = "101" and idx = 5 then memovr <= cfg_s3(1); end if;
         end if;

         ---------------------------------------------------------------- injector
         x := rnd;
         x := x xor shift_left(x, 13);
         x := x xor shift_right(x, 17);
         x := x xor shift_left(x, 5);
         rnd <= x;
         kmask := resize(shift_left(to_unsigned(1, 24), to_integer(regs(1)) + 8) - 1, 23);  -- 2^(e+8)-1
         jmask := shift_left(to_unsigned(1, 16), to_integer(regs(5))) - 1;
         dur   := shift_left(resize(regs(4), 21) + 1, to_integer(regs(3))) +
                  resize(rnd(31 downto 16) and jmask, 21);
         if inj_left /= 0 then
            inj_left <= inj_left - 1;
         elsif regs(0)(0) = '1' and (rnd(22 downto 0) and kmask) <= resize(regs(2), 23) then
            inj_left <= dur;
         end if;
         if inj_left /= 0 then             -- loaded with dur: inj is '1' for exactly dur ticks
            inj <= '1';
         else
            inj <= '0';
         end if;

         ---------------------------------------------------------------- DDS / catch-up
         stall := inj or stall_i;
         -- the edge happening now was granted by ce (decided at the previous edge); a miss blocked
         -- it: refund the machine tick (the credit was spent when it was granted)
         if fast_s2 = '1' and regs(0)(1) = '0' then
            cr := resize(credit, 41) + G_N_FAST;
         else
            cr := resize(credit, 41) + G_N_NATIVE;
         end if;
         if ce = '1' and miss_i = '1' then
            cr := cr + C_ONE;
         end if;
         pass := '0';
         if cr >= C_ONE and stall = '0' then
            pass := '1';
            cr   := cr - C_ONE;
         end if;
         if cr > C_CAP then
            cr := C_CAP;
            forgiven <= forgiven + 1;
         end if;
         credit <= cr(39 downto 0);
         ce     <= pass;

         ---------------------------------------------------------------- statistics
         src_cnt <= src_cnt + 1;
         if pass = '1' and not (ce = '1' and miss_i = '1') then
            mach_cnt <= mach_cnt + 1;
         elsif pass = '0' and ce = '1' and miss_i = '1' then
            mach_cnt <= mach_cnt - 1;
         elsif pass = '0' and stall = '0' and miss_i = '0' then
            drops <= drops + 1;
         end if;
         stall_d <= stall or miss_i;
         if stall = '1' or miss_i = '1' then
            stall_tk <= stall_tk + 1;
            if stall_d = '0' then
               stalls <= stalls + 1;
            end if;
         end if;
         lagv    := resize(cr(40 downto 20), 32);
         lag_now <= lagv;
         if lagv > lag_max then
            lag_max <= lagv;
         end if;
         vs_d <= vsync_i;
         if vsync_i = '1' and vs_d = '0' then
            vs_cnt <= vs_cnt + 1;
            vs_ts  <= src_cnt;
         end if;
         pr_d <= probe_i;
         if pr_d(22) = '1' and probe_i(22) = '0' then we_fall <= we_fall + 1; end if;
         if pr_d(23) = '1' and probe_i(23) = '0' then oe_fall <= oe_fall + 1; end if;
         if probe_i(24) = '1' or probe_i(25) = '1' or probe_i(26) = '1' then rst_cyc <= rst_cyc + 1; end if;
         if regs(7)(0) /= clr_tog then
            clr_tog  <= regs(7)(0);
            lag_max  <= (others => '0');
            stalls   <= (others => '0');
            stall_tk <= (others => '0');
            drops    <= (others => '0');
            forgiven <= (others => '0');
         end if;

         ---------------------------------------------------------------- snapshot + readout
         if regs(6)(3) /= snap_tog then
            snap_tog   <= regs(6)(3);
            s_src      <= src_cnt;
            s_mach     <= mach_cnt;
            s_vs_ts    <= vs_ts;
            s_vs_cnt   <= vs_cnt;
            s_stalls   <= stalls;
            s_stall_tk <= stall_tk;
            s_drops    <= drops;
            s_forgiven <= forgiven;
            s_lag_now  <= lag_now;
            s_lag_max  <= lag_max;
            s_seq      <= s_seq + 1;
            s_probe    <= pr_d;
            s_we_fall  <= we_fall;
            s_oe_fall  <= oe_fall;
            s_rst_cyc  <= rst_cyc;
            s_fills    <= fills_i;
            s_wbacks   <= wbacks_i;
         end if;
         case to_integer(regs(6)(2 downto 0)) is
            when 0 => diag <= std_logic_vector(regs(1)) & std_logic_vector(regs(2)) &
                              std_logic_vector(regs(3)) & std_logic_vector(regs(4)) &
                              std_logic_vector(regs(5)) & std_logic_vector(regs(0)) &
                              std_logic_vector(s_seq) & std_logic_vector(s_lag_max) &
                              std_logic_vector(s_lag_now);
            when 1 => diag <= std_logic_vector(s_stalls) & std_logic_vector(s_stall_tk) &
                              std_logic_vector(s_drops);
            when 2 => diag <= std_logic_vector(s_vs_cnt) & std_logic_vector(s_vs_ts);
            when 3 => diag <= std_logic_vector(s_forgiven) & std_logic_vector(s_src);
            when 4 => diag <= x"A1200001" & std_logic_vector(s_mach);
            when 5 => diag <= s_probe(31 downto 0) & std_logic_vector(s_we_fall) & std_logic_vector(s_rst_cyc);
            when 6 => diag <= s_probe(63 downto 32) & std_logic_vector(s_fills) & std_logic_vector(s_wbacks);
            when others => diag <= (others => '0');
         end case;
      end if;
   end process;
end architecture rtl;
