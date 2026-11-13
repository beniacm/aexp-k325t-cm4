-- tb_rtc_host.vhd -- rtc_controller with G_HOST_RTC (K325T a1200-lxshell): no toggle after reset;
-- stop, write the time, read + run -> the toggle flips once and rtc_o carries the written time.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_rtc_host is end entity;
architecture sim of tb_rtc_host is
   signal clk : std_logic := '0';
   signal rst : std_logic := '1';
   signal done : boolean := false;
   signal rtc : std_logic_vector(64 downto 0);
   signal ce, we : std_logic := '0';
   signal a : std_logic_vector(7 downto 0) := (others => '0');
   signal wd, rd : std_logic_vector(15 downto 0) := (others => '0');
begin
   clk <= not clk after 10 ns when not done;
   dut : entity work.rtc_controller
      generic map (G_CLK_SPEED_HZ => 50_000_000, G_BOARD => "MEGA65_R6", G_HOST_RTC => true)
      port map (clk_i => clk, rst_i => rst, rtc_o => rtc, cpu_s_wait_o => open, cpu_s_ce_i => ce,
                cpu_s_we_i => we, cpu_s_addr_i => a, cpu_s_wr_data_i => wd, cpu_s_rd_data_o => rd,
                cpu_m_wait_i => '0', cpu_m_ce_o => open, cpu_m_we_o => open, cpu_m_addr_o => open,
                cpu_m_wr_data_o => open, cpu_m_rd_data_i => (others => '0'));
   process
      procedure wr(ad, d : natural) is
      begin
         a <= std_logic_vector(to_unsigned(ad, 8)); wd <= std_logic_vector(to_unsigned(d, 16));
         ce <= '1'; we <= '1'; wait until rising_edge(clk); ce <= '0'; we <= '0'; wait until rising_edge(clk);
      end procedure;
      variable t0 : std_logic;
      type v_t is array (0 to 7) of natural;
      constant V : v_t := (16#00#, 16#30#, 16#45#, 16#13#, 16#13#, 16#11#, 16#26#, 16#05#);
   begin
      for i in 0 to 5 loop wait until rising_edge(clk); end loop;
      rst <= '0';
      for i in 0 to 200 loop wait until rising_edge(clk); end loop;
      t0 := rtc(64);
      assert t0 = '0' report "FAIL: toggle flipped after reset" severity error;
      wr(8, 0);                                         -- stop
      for i in 0 to 7 loop wr(i, V(i)); end loop;
      wr(8, 16#000A#);                                  -- read + running
      for i in 0 to 10 loop wait until rising_edge(clk); end loop;
      assert rtc(64) = '1' report "FAIL: toggle did not flip" severity error;
      -- MiSTer format: 63..56 = 0x40, 55..48 weekday, 47..40 year, 39..32 month, 31..24 day,
      -- 23..16 hour, 15..8 min, 7..0 sec
      assert rtc(55 downto 0) = x"05_26_11_13_13_45_30"
         report "FAIL: rtc_o = " & to_hstring(rtc(55 downto 0)) severity error;
      a <= x"08"; wait until rising_edge(clk);
      assert rd = x"0008" report "FAIL: command register " & to_hstring(rd) severity error;
      report "tb_rtc_host done: rtc_o(55:0) = " & to_hstring(rtc(55 downto 0)) severity note;
      done <= true; wait;
   end process;
end architecture;
