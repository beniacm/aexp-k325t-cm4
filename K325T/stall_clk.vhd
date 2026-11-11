-------------------------------------------------------------------------------------------------------------
-- stall_clk.vhd -- K325T replacement of CORE/vhdl/clk.vhd (same entity name "clk", same ports plus the
-- stall machinery): a STOPPABLE Amiga clock with catch-up (A1200/DDR3 study, stage 1).
--
--   MMCM (VCO 1135 MHz = 100 MHz x 56.75 / 5, as upstream's native leg) -- CLKOUT0 / 36.25 -->
--   31.310345 MHz = 28.375 MHz x 32/29 --+-- BUFG   --> src_clk_o  (never stops: stall_ctrl)
--   (stage 1 used / 38.75 = 28.375 x 32/31: 3.1 % catch-up headroom; stage 2 10.3 %)
--                                         +-- BUFGCE --> main_clk_o (the Amiga's machine clock)
--
-- stall_ctrl passes 29 of 32 edges on average (exactly 28.375000 MHz long-term, as upstream's native
-- clock), or the flicker-free "fast" rate (28.4375 MHz) when core_speed_i(0) = '1'; it withholds
-- edges while a stall is requested (here: the built-in injector) and repays the lag afterwards by
-- passing every edge.  Everything on main_clk (minimig, fx68k, main.vhd, the M2M core-side logic,
-- ascal's input side) sees fewer edges and nothing else: machine-time behaviour is unchanged by
-- construction.  The upstream file's two MMCMs + BUFGMUX_CTRL (flicker-free twin) are gone: the
-- flicker-free FSM in mega65.vhd now selects the DDS rate.
-------------------------------------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz
      core_speed_i    : in  unsigned(1 downto 0);   -- b0: '1' = flicker-free "fast" rate (asynchronous)
      main_clk_o      : out std_logic;   -- the gated Amiga clock (average 28.375000 MHz)
      main_rst_o      : out std_logic;   -- main's reset, synchronized
      -- K325T stall machinery (CORE/vhdl/clk.vhd has the same ports as dummies)
      src_clk_o       : out std_logic;   -- the ungated source clock (29.290 MHz)
      stall_cfg_i     : in  std_logic_vector(7 downto 0);   -- bridge VIDEO byte (asynchronous)
      stall_i         : in  std_logic := '0';                -- external stall request (src_clk_o)
      miss_i          : in  std_logic := '0';                -- combinational stall of this edge
      vsync_i         : in  std_logic;   -- machine vsync (main_clk register)
      probe_i         : in  std_logic_vector(63 downto 0) := (others => '0');  -- debug (main_clk)
      stall_diag_o    : out std_logic_vector(95 downto 0);   -- bridge STATUS 60..71 (src_clk_o)
      stall_mode_o    : out std_logic_vector(3 downto 0);    -- controller register 0 (src_clk_o)
      stall_cache_o   : out std_logic_vector(3 downto 0);    -- chip cache settings (src_clk_o)
      cache_fills_i   : in  unsigned(31 downto 0) := (others => '0');
      cache_wbacks_i  : in  unsigned(31 downto 0) := (others => '0')
   );
end entity clk;

architecture rtl of clk is
   signal main_fb, main_fb_mmcm : std_logic;
   signal src_clk_mmcm          : std_logic;
   signal src_clk               : std_logic;
   signal main_clk              : std_logic;
   signal main_locked           : std_logic;
   signal ce                    : std_logic;
begin

   i_clk_main : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 5,
         CLKFBOUT_MULT_F      => 56.750,     -- VCO = 1135.000 MHz (Kintex-7 -1: 600..1200 MHz)
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 36.250,     -- 31.310345 MHz = 28.375 MHz x 32/29 (stage 2: h = 10.3 %)
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE
      )
      port map (
         CLKFBOUT => main_fb_mmcm, CLKOUT0 => src_clk_mmcm,
         CLKFBIN => main_fb, CLKIN1 => sys_clk_i, CLKIN2 => '0', CLKINSEL => '1',
         DADDR => (others => '0'), DCLK => '0', DEN => '0', DI => (others => '0'), DO => open,
         DRDY => open, DWE => '0', PSCLK => '0', PSEN => '0', PSINCDEC => '0', PSDONE => open,
         LOCKED => main_locked, CLKINSTOPPED => open, CLKFBSTOPPED => open, PWRDWN => '0', RST => '0'
      );

   main_fb_bufg : BUFG port map (I => main_fb_mmcm, O => main_fb);

   -- the ungated source clock: the controller
   src_bufg : BUFG port map (I => src_clk_mmcm, O => src_clk);

   -- the gated machine clock: CE is a register in src_clk (stall_ctrl.ce), timed by Vivado as a
   -- setup/hold check against I; a low CE suppresses the next pulse, the output stays low
   main_bufgce : BUFGCE
      generic map (SIM_DEVICE => "7SERIES")
      port map (I => src_clk_mmcm, CE => ce, O => main_clk);

   i_stall_ctrl : entity work.stall_ctrl
      generic map (
         G_N_NATIVE => 950272,     -- 29/32 x 2^20: 31.310345 MHz x 29/32 = 28.375000 MHz
         G_N_FAST   => 952365      -- 29/32 x 455/454 x 2^20 (the flicker-free 28.4375 MHz)
      )
      port map (
         clk_i   => src_clk,
         fast_i  => core_speed_i(0),
         cfg_i   => stall_cfg_i,
         stall_i => stall_i,
         miss_i  => miss_i,
         vsync_i => vsync_i,
         probe_i => probe_i,
         ce_o    => ce,
         inj_o   => open,
         lag_o   => open,
         diag_o  => stall_diag_o,
         mode_o  => stall_mode_o,
         cache_o => stall_cache_o,
         fills_i => cache_fills_i,
         wbacks_i => cache_wbacks_i
      );

   main_clk_o <= main_clk;
   src_clk_o  <= src_clk;

   i_xpm_cdc_async_rst_main : xpm_cdc_async_rst
      generic map (RST_ACTIVE_HIGH => 1, DEST_SYNC_FF => 6)
      port map (src_arst => not main_locked, dest_clk => main_clk, dest_arst => main_rst_o);

end architecture rtl;
