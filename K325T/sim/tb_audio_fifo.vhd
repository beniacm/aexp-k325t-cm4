--------------------------------------------------------------------------------
-- tb_audio_fifo.vhd -- audio_fifo.vhd with a stoppable machine clock: the machine's "audio" is its
-- own tick count (a ramp); stalls of random length stop it, a catch-up runs it at full source rate
-- until the lag is repaid (as stall_ctrl does).  Checked: every sample comes out exactly once and in
-- order, and the output changes on a regular real-time grid (2^G_DIV ideal ticks = 35.6 source
-- ticks apart, +-1), however the stalls fall.
--   ghdl -r --std=08 tb_audio_fifo
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_audio_fifo is
   generic (G_SAMPLES : natural := 3000);
end entity;

architecture sim of tb_audio_fifo is
   constant T : time := 31.94 ns;
   signal clk, mclk, gate : std_logic := '0';
   signal rst : std_logic := '1';
   signal mach, lag : unsigned(31 downto 0) := (others => '0');
   signal l_i, r_i, l_o, r_o : signed(15 downto 0) := (others => '0');
   signal under : unsigned(31 downto 0);
   signal done : boolean := false;
begin
   clk  <= not clk after T / 2 when not done;
   mclk <= clk and gate;              -- BUFGCE model (gate changes while clk is low)

   dut : entity work.audio_fifo
      generic map (G_LOG2 => 11, G_DIV => 5, G_OFFSET => 64)
      port map (wclk_i => mclk, rclk_i => clk, rst_i => rst, en_i => '1', l_i => l_i, r_i => r_i,
                mach_i => mach, lag_i => lag, l_o => l_o, r_o => r_o, level_o => open, under_o => under);

   -- the machine: its audio level is (machine ticks / 32) mod 2^16
   process (mclk)
      variable n : unsigned(31 downto 0) := (others => '0');
   begin
      if rising_edge(mclk) then
         n := n + 1;
         l_i <= signed(n(20 downto 5));
         r_i <= signed(not n(20 downto 5));
      end if;
   end process;

   -- the stall controller (simplified): the ideal machine clock passes 9 of 10 source ticks; the
   -- machine follows it (lag constant), stops during a stall (the lag grows) and passes every tick
   -- while it has a lag to repay (h = 1/9): ideal = mach + lag advances 9 per 10 ticks always
   process
      variable s1, s2 : positive := 7; variable r : real;
      variable stall, ph : natural := 0;
      variable pass, ideal : boolean;
   begin
      wait until falling_edge(clk);
      rst <= '1'; gate <= '1';
      for i in 1 to 20 loop wait until falling_edge(clk); end loop;
      rst <= '0';
      loop
         wait until falling_edge(clk);
         ph := (ph + 1) mod 10;
         ideal := ph /= 9;
         if stall > 0 then
            stall := stall - 1; pass := false;
         else
            pass := ideal or lag > 0;
            uniform(s1, s2, r);
            if r < 0.0005 then uniform(s1, s2, r); stall := 3 + integer(r * 400.0); end if;
         end if;
         if pass then gate <= '1'; mach <= mach + 1; else gate <= '0'; end if;
         if ideal and not pass then lag <= lag + 1; end if;
         if pass and not ideal then lag <= lag - 1; end if;
         exit when done;
      end loop;
      wait;
   end process;

   -- the listener
   process
      variable last : signed(15 downto 0);
      variable t_last, t_now : time := 0 ns;
      variable n, bad_seq, bad_t : natural := 0;
      variable dt : time;
   begin
      wait until rst = '0';
      wait until l_o /= 0;
      last := l_o; t_last := now;
      while n < G_SAMPLES loop
         wait until l_o'event;
         t_now := now;
         if l_o /= last + 1 then
            bad_seq := bad_seq + 1;
            if bad_seq < 5 then report "sample " & integer'image(to_integer(l_o)) & " after " & integer'image(to_integer(last)) severity error; end if;
         end if;
         dt := t_now - t_last;
         if dt < 34 * T or dt > 37 * T then   -- 32 ideal ticks = 35.6 source ticks
            bad_t := bad_t + 1;
            if bad_t < 5 then report "gap " & time'image(dt) severity error; end if;
         end if;
         last := l_o; t_last := t_now; n := n + 1;
      end loop;
      report integer'image(n) & " samples, out of sequence " & integer'image(bad_seq) & ", off the grid " &
             integer'image(bad_t) & ", underflows " & integer'image(to_integer(under));
      if bad_seq = 0 and bad_t = 0 then report "TB_AUDIO_FIFO_PASS"; else report "TB_AUDIO_FIFO_FAIL" severity error; end if;
      done <= true; wait;
   end process;
end architecture;
