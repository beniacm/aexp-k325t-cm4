--------------------------------------------------------------------------------
-- audio_fifo.vhd -- the Amiga's audio, taken in machine time and played in real time (A1200 study,
-- stage 2b; the study's section 1.4).
--
-- The Amiga's clock stops during a stall and runs faster afterwards until the lag is repaid; its
-- audio output (a level that Paula updates) therefore pauses and then hurries.  This FIFO samples
-- the level every DIV machine ticks (main_clk edges: machine time) and plays the samples back on
-- the ungated source clock at the times the machine WOULD have produced them without stalls:
-- sample n leaves when (machine ticks + lag) passes the anchor + (n + OFFSET) x DIV.  mach_i + lag_i (from the
-- stall controller) is exactly that ideal machine-tick count, so the FIFO holds OFFSET samples plus
-- the current lag: a stall shows only as a change of the fill level, not in the sound.  The cost is
-- the latency of OFFSET x DIV machine ticks (256 x 128 / 28.375 MHz = 1.15 ms).
-- A lag beyond the FIFO (overload, the lag cap) empties it: the output holds its last sample and
-- the read schedule re-anchors.  en_i = '0': the FIFO is bypassed (the level goes straight through,
-- as before).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_fifo is
   generic (
      G_LOG2   : natural := 11;      -- 2048 samples
      G_DIV    : natural := 7;       -- one sample every 2^7 = 128 machine ticks (221.7 kHz)
      G_OFFSET : natural := 256      -- samples of latency
   );
   port (
      wclk_i     : in  std_logic;                     -- main_clk (gated: machine time)
      rclk_i     : in  std_logic;                     -- the ungated source clock
      rst_i      : in  std_logic;                     -- (rclk domain) the M2M reset
      en_i       : in  std_logic;                     -- (rclk domain)
      l_i, r_i   : in  signed(15 downto 0);           -- wclk domain
      mach_i     : in  unsigned(31 downto 0);         -- rclk domain: machine ticks so far
      lag_i      : in  unsigned(31 downto 0);         -- rclk domain: current lag (machine ticks)
      l_o, r_o   : out signed(15 downto 0);           -- rclk domain
      level_o    : out unsigned(G_LOG2 downto 0);     -- fill level (rclk domain)
      under_o    : out unsigned(31 downto 0)          -- times the FIFO was empty when a sample was due
   );
end entity audio_fifo;

architecture rtl of audio_fifo is
   type mem_t is array (0 to 2 ** G_LOG2 - 1) of std_logic_vector(31 downto 0);
   signal mem : mem_t;
   attribute ram_style : string;
   attribute ram_style of mem : signal is "block";

   signal wdiv       : unsigned(G_DIV - 1 downto 0) := (others => '0');
   signal wp         : unsigned(G_LOG2 downto 0) := (others => '0');
   signal wp_g       : std_logic_vector(G_LOG2 downto 0) := (others => '0');
   signal wrst_s1, wrst_s2 : std_logic := '1';
   signal wp_s1, wp_s2 : std_logic_vector(G_LOG2 downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of wrst_s1, wrst_s2, wp_s1, wp_s2 : signal is "TRUE";
   signal wp_r       : unsigned(G_LOG2 downto 0);
   signal rp         : unsigned(G_LOG2 downto 0) := (others => '0');
   signal rbase      : unsigned(31 downto 0) := (others => '0');
   signal anchored   : std_logic := '0';
   signal under      : unsigned(31 downto 0) := (others => '0');
   signal q          : std_logic_vector(31 downto 0) := (others => '0');
   signal ol, orr    : signed(15 downto 0) := (others => '0');

   function g2b(g : std_logic_vector) return unsigned is
      variable b : unsigned(g'range);
   begin
      b(g'high) := g(g'high);
      for i in g'high - 1 downto g'low loop
         b(i) := b(i + 1) xor g(i);
      end loop;
      return b;
   end function;
begin
   ---------------------------------------------------------------- write side: machine time
   process (wclk_i)
   begin
      if rising_edge(wclk_i) then
         wrst_s1 <= rst_i; wrst_s2 <= wrst_s1;
         if wrst_s2 = '1' then
            wdiv <= (others => '0');
            wp   <= (others => '0');
            wp_g <= (others => '0');
         else
            wdiv <= wdiv + 1;
            if wdiv = 2 ** G_DIV - 1 then
               mem(to_integer(wp(G_LOG2 - 1 downto 0))) <= std_logic_vector(l_i) & std_logic_vector(r_i);
               wp   <= wp + 1;
               wp_g <= std_logic_vector((wp + 1) xor shift_right(wp + 1, 1));
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- read side: real time
   wp_r    <= g2b(wp_s2);
   level_o <= wp_r - rp;
   under_o <= under;
   process (rclk_i)
      variable ideal : unsigned(31 downto 0);
   begin
      if rising_edge(rclk_i) then
         wp_s1 <= wp_g; wp_s2 <= wp_s1;
         q <= mem(to_integer(rp(G_LOG2 - 1 downto 0)));
         ideal := mach_i + lag_i;                          -- the machine tick count without stalls
         if rst_i = '1' then
            rp <= (others => '0'); anchored <= '0';
         elsif anchored = '0' then
            -- (re-)anchor: the next sample leaves OFFSET sample periods from now
            rbase    <= ideal + shift_left(to_unsigned(G_OFFSET, 32), G_DIV);
            anchored <= '1';
         elsif signed(ideal - rbase) >= 0 then             -- the next sample is due
            if wp_r /= rp then
               ol    <= signed(q(31 downto 16));           -- (q is mem(rp): samples leave >100 clocks apart)
               orr   <= signed(q(15 downto 0));
               rp    <= rp + 1;
               rbase <= rbase + 2 ** G_DIV;
            else
               under    <= under + 1;
               anchored <= '0';                            -- empty: hold the output, re-anchor
            end if;
         end if;
         if en_i = '1' then
            l_o <= ol; r_o <= orr;
         else
            l_o <= l_i; r_o <= r_i;                        -- bypass (same clock tree as wclk_i)
         end if;
      end if;
   end process;
end architecture rtl;
