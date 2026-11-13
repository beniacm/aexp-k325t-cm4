-- tb_host_link.vhd -- rk_bridge (HOST_FIFOS) + qnice_host end to end (K325T a1200-lxshell).
-- An SPI master (mode 0, 33 MHz as the Rockchip's 40 MHz request really gives, no gaps inside a
-- transfer, G_GAP_NS between transfers) talks to the bridge at 162.5 MHz; the master runs at 50 MHz
-- with two device models: 0x0100 a Kickstart port (falling-edge toggle handshake, acknowledged
-- after K_ACK_CYC cycles, about chip_cache's two-way clock crossing) and 0x0103 a RAM with a
-- wait of A_WAIT cycles per access (an estimate for the ADF window's DDR3 byte write).
-- Checks: STATUS 72..81, a 64 KB Kickstart stream in 4 KB HOST_PUTs paced by STATUS 73/74, the
-- data in the device, BR8 answers through HOST_GET, HOST_RESET; prints the throughput.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_host_link is
   generic (K_ACK_CYC : natural := 4; A_WAIT : natural := 6; G_GAP_NS : natural := 50000;
            NKICK : natural := 65536);
end entity;

architecture sim of tb_host_link is
   signal clk162, clk50, clk100 : std_logic := '0';
   signal done : boolean := false;
   signal sck, cs_n, mosi, miso : std_logic := '0';

   signal s_data, m_data : std_logic_vector(7 downto 0);
   signal s_valid, s_pop, m_push, m_full, clr : std_logic;
   signal busy, err, tmo, marker : std_logic;
   signal hflags : std_logic_vector(7 downto 0);
   signal rst_n : std_logic := '0';

   signal dev   : std_logic_vector(15 downto 0);
   signal addr  : std_logic_vector(27 downto 0);
   signal wd, rd : std_logic_vector(15 downto 0);
   signal ce, we, wt : std_logic;

   type mem_t is array (0 to 2 ** 20 - 1) of std_logic_vector(7 downto 0);
   shared variable kick : mem_t;
   shared variable ram  : mem_t;
   signal kst : integer := 0;
   signal kcnt : integer := 0;
   signal kwrites : natural := 0;
   signal acnt : integer := 0;
begin
   clk162 <= not clk162 after 3.077 ns when not done;
   clk50  <= not clk50 after 10 ns when not done;
   clk100 <= not clk100 after 5 ns when not done;

   br : entity work.rk_bridge
      generic map (CORE_ID => x"03", HOST_FIFOS => true)
      port map (clk => clk162, cpuclk => clk100,
                spi_sck => sck, spi_cs_n => cs_n, spi_mosi => mosi, spi_miso => miso,
                sd_rd_req => '0', sd_wr_req => '0', sd_lba => (others => '0'), sd_seq => (others => '0'),
                sd_inited => '0', sd_cmd_cnt => (others => '0'), sd_last_cmd => (others => '0'),
                sd_rd_ready => open, sd_rd_error => open, sd_wr_ack => open,
                rbuf_addr => (others => '0'), rbuf_data => open,
                wbuf_we => '0', wbuf_addr => (others => '0'), wbuf_data => (others => '0'),
                mon_rx => open, mon_tx => '1', matrix_col_idx => 0, matrix_col => open,
                joya => open, joyb => open, ctrl => open, pots => open,
                flash_active => open, flash_sck => open, flash_cs_n => open, flash_mosi => open,
                iprog_toggle => open, iprog_addr => open, spi_active => open,
                host_clk => clk50, host_s_data => s_data, host_s_valid => s_valid, host_s_pop => s_pop,
                host_m_data => m_data, host_m_push => m_push, host_m_full => m_full, host_clr => clr,
                host_ver => x"01", host_flags => hflags, host_id => x"C0FFEE42");

   hflags <= "000" & marker & tmo & err & busy & '0';

   m : entity work.qnice_host
      generic map (G_MENU_ID => x"C0FFEE42")
      port map (clk50_i => clk50, reset_n_i => rst_n, uart_rxd_i => '1', uart_txd_o => open,
                sd_reset_o => open, sd_clk_o => open, sd_mosi_o => open, sd_miso_i => '0', sd_cd_i => '0',
                sd2_reset_o => open, sd2_clk_o => open, sd2_mosi_o => open, sd2_miso_i => '0', sd2_cd_i => '0',
                csr_reset_o => open, csr_pause_o => open, csr_osm_o => open, csr_keyboard_o => open,
                csr_joy1_o => open, csr_joy2_o => open, osm_xy_o => open, osm_dxdy_o => open,
                ascal_mode_i => "00000", ascal_mode_o => open, keys_n_i => x"FFFF",
                control_d_o => open, control_m_o => open, special_i => x"0000", general_i => x"0000",
                ramrom_dev_o => dev, ramrom_addr_o => addr, ramrom_data_o => wd, ramrom_data_i => rd,
                ramrom_ce_o => ce, ramrom_wait_i => wt, ramrom_we_o => we,
                s_data_i => s_data, s_valid_i => s_valid, s_pop_o => s_pop,
                m_data_o => m_data, m_push_o => m_push, m_full_i => m_full,
                clr_i => clr, busy_o => busy, err_o => err, tmo_o => tmo, marker_o => marker);

   wt <= '1' when ce = '1' and dev = x"0100" and ((kst = 0 and we = '1') or kst = 1) else
         '1' when ce = '1' and dev = x"0103" and acnt /= 1 else '0';
   rd <= x"00" & ram(to_integer(unsigned(addr(19 downto 0)))) when ce = '1' and dev = x"0103" else x"0000";

   process (clk50)
   begin
      if falling_edge(clk50) then
         case kst is
            when 0 =>
               if ce = '1' and we = '1' and dev = x"0100" then
                  kick(to_integer(unsigned(addr(19 downto 0)))) := wd(7 downto 0);
                  kwrites <= kwrites + 1; kcnt <= K_ACK_CYC; kst <= 1;
               end if;
            when 1 => if kcnt <= 1 then kst <= 2; else kcnt <= kcnt - 1; end if;
            when others => if we = '0' then kst <= 0; end if;
         end case;
         if ce = '1' and dev = x"0103" then
            if acnt = 0 then
               acnt <= A_WAIT + 1;
               if we = '1' then ram(to_integer(unsigned(addr(19 downto 0)))) := wd(7 downto 0); end if;
            elsif acnt > 1 then
               acnt <= acnt - 1;
            end if;
         else
            acnt <= 0;
         end if;
      end if;
   end process;

   stim : process
      type buf_t is array (0 to 8191) of std_logic_vector(7 downto 0);
      variable tx, rx : buf_t;
      constant TH : time := 15 ns;               -- 33.3 MHz SCK
      procedure xfer(n : natural) is
      begin
         cs_n <= '0'; wait for 40 ns;
         for i in 0 to n - 1 loop
            for b in 7 downto 0 loop
               mosi <= tx(i)(b); wait for TH;
               sck <= '1'; rx(i)(b) := miso; wait for TH;
               sck <= '0';
            end loop;
         end loop;
         wait for 40 ns; cs_n <= '1'; wait for G_GAP_NS * 1 ns;
      end procedure;
      variable st : buf_t;
      procedure status is
      begin
         tx(0) := x"01"; for i in 1 to 90 loop tx(i) := x"00"; end loop;
         xfer(90);
         st := rx;
      end procedure;
      -- the STATUS bytes follow cmd + dummy: find the alignment from 'M' 0x65
      variable so : natural;
      impure function sb(i : natural) return natural is
      begin
         return to_integer(unsigned(st(so + i)));
      end function;
      variable errors : natural := 0;
      procedure check(c : boolean; msg : string) is
      begin
         if not c then report "FAIL: " & msg severity error; errors := errors + 1; end if;
      end procedure;
      variable n, sent, free, fill : natural;
      variable t0, t1 : time;
      variable got : natural;
   begin
      cs_n <= '1';
      wait for 200 ns; rst_n <= '1'; wait for 1 us;
      status;
      so := 0;
      for i in 0 to 4 loop
         if st(i) = x"4D" and st(i + 1) = x"65" then so := i; end if;
      end loop;
      check(st(so) = x"4D", "STATUS signature");
      check(sb(52) = 3 and sb(72) = 1, "core id / host version");
      check(sb(73) * 256 + sb(74) = 8192, "PUT free at start " & integer'image(sb(73) * 256 + sb(74)));
      check(sb(78) = 16#C0# and sb(81) = 16#42#, "menu id");

      -- Kickstart: BW8 header then data in HOST_PUTs of at most 4 KB, paced by the free count
      t0 := now;
      tx(0) := x"80"; tx(1 to 10) := (x"03", x"01", x"00", x"00", x"00", x"00", x"00",
                                      std_logic_vector(to_unsigned(NKICK / 65536, 8)),
                                      std_logic_vector(to_unsigned((NKICK / 256) mod 256, 8)),
                                      std_logic_vector(to_unsigned(NKICK mod 256, 8)));
      xfer(11);
      sent := 0;
      while sent < NKICK loop
         status;
         free := sb(73) * 256 + sb(74);
         n := NKICK - sent;
         if n > 4094 then n := 4094; end if;
         if n > free then n := free; end if;
         if n > 0 then
            tx(0) := x"80";
            for i in 0 to n - 1 loop tx(i + 1) := std_logic_vector(to_unsigned(((sent + i) * 7 + 1) mod 251, 8)); end loop;
            xfer(n + 1);
            sent := sent + n;
         end if;
      end loop;
      loop
         status;
         exit when sb(73) * 256 + sb(74) = 8192 and (sb(77) / 2) mod 2 = 0;
      end loop;
      t1 := now;
      check(kwrites = NKICK, "Kickstart writes " & integer'image(kwrites));
      for i in 0 to NKICK - 1 loop
         if kick(i) /= std_logic_vector(to_unsigned((i * 7 + 1) mod 251, 8)) then
            check(false, "kick byte " & integer'image(i)); exit;
         end if;
      end loop;
      report "Kickstart " & integer'image(NKICK) & " bytes in " & time'image(t1 - t0) & " = " &
             integer'image(NKICK * 1000 / ((t1 - t0) / 1 us)) & " KB/s (x1000/1024)" severity note;

      -- ADF-like device: BW8 of 8 KB, then BR8 of 5632 bytes (one track) read back through HOST_GET
      t0 := now;
      tx(0) := x"80"; tx(1 to 10) := (x"03", x"01", x"03", x"00", x"02", x"00", x"00", x"00", x"20", x"00");
      xfer(11);
      for c in 0 to 1 loop
         loop status; exit when sb(73) * 256 + sb(74) >= 4096; end loop;
         tx(0) := x"80";
         for i in 0 to 4095 loop tx(i + 1) := std_logic_vector(to_unsigned(((c * 4096 + i) * 3) mod 256, 8)); end loop;
         xfer(4097);
      end loop;
      loop status; exit when sb(73) * 256 + sb(74) = 8192 and (sb(77) / 2) mod 2 = 0; end loop;
      t1 := now;
      report "ADF-like writes 8192 bytes in " & time'image(t1 - t0) & " = " &
             integer'image(8192 * 1000 / ((t1 - t0) / 1 us)) & " KB/s" severity note;
      t0 := now;
      tx(0) := x"80"; tx(1 to 10) := (x"05", x"01", x"03", x"00", x"02", x"00", x"00", x"00", x"0B", x"00");  -- 2816
      xfer(11);
      got := 0;
      while got < 2816 loop
         status;
         fill := sb(75) * 256 + sb(76);
         if fill > 0 then
            tx(0) := x"81"; for i in 1 to fill + 1 loop tx(i) := x"00"; end loop;
            xfer(fill + 2);
            for i in 0 to fill - 1 loop
               if rx(i + 2) /= std_logic_vector(to_unsigned(((got + i) * 3) mod 256, 8)) then
                  check(false, "BR8 byte " & integer'image(got + i) & " = " & integer'image(to_integer(unsigned(rx(i + 2)))));
                  exit;
               end if;
            end loop;
            got := got + fill;
         end if;
      end loop;
      t1 := now;
      report "BR8 2816 bytes in " & time'image(t1 - t0) severity note;
      status;
      check(sb(75) * 256 + sb(76) = 0, "GET empty after reading");

      -- HOST_RESET: answers queued and not read are dropped, flags cleared
      tx(0) := x"80"; tx(1 to 4) := (x"07", x"11", x"07", x"22"); xfer(5);
      status; check(sb(75) * 256 + sb(76) = 2, "two MARK answers queued");
      tx(0) := x"82"; xfer(1);
      status; check(sb(75) * 256 + sb(76) = 0 and sb(73) * 256 + sb(74) = 8192, "HOST_RESET empties");
      tx(0) := x"80"; tx(1 to 2) := (x"07", x"33"); xfer(3);
      status;
      tx(0) := x"81"; tx(1 to 2) := (x"00", x"00"); xfer(3);
      check(rx(2) = x"33", "MARK after HOST_RESET: " & integer'image(to_integer(unsigned(rx(2)))));

      report "tb_host_link: " & integer'image(errors) & " errors" severity note;
      done <= true;
      wait;
   end process;
end architecture;
