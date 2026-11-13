-- tb_qnice_host.vhd -- bench of the host master's command stream (K325T a1200-lxshell).
-- A device model behind the RAMROM bus: device 0x0100 behaves like chip_cache's Kickstart port
-- (falling-edge toggle handshake, wait combinational on we, acknowledged after a random delay,
-- write-only), device 0x0103 like a RAM with a registered wait of 0..3 cycles, device 0x0005 never
-- answers (timeout).  Checks: registers, menu id / defaults / marker, BW8 across a window carry,
-- BR8 / BW16 / BR16 / MARK, the gap cycle between accesses, the timeout, an unknown opcode + clear,
-- the M2M reset keeping the marker.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_qnice_host is
end entity;

architecture sim of tb_qnice_host is
   signal clk     : std_logic := '0';
   signal rst_n   : std_logic := '0';
   signal done    : boolean := false;

   type bytes_t is array (natural range <>) of std_logic_vector(7 downto 0);
   signal s_data  : std_logic_vector(7 downto 0) := (others => '0');
   signal s_valid : std_logic := '0';
   signal s_pop   : std_logic;
   signal m_data  : std_logic_vector(7 downto 0);
   signal m_push  : std_logic;
   signal clr     : std_logic := '0';
   signal busy, err, tmo, marker : std_logic;

   signal dev     : std_logic_vector(15 downto 0);
   signal addr    : std_logic_vector(27 downto 0);
   signal wd, rd  : std_logic_vector(15 downto 0);
   signal ce, we, wt : std_logic;
   signal csr_reset : std_logic;
   signal cfm     : std_logic_vector(255 downto 0);

   -- stream FIFO (bench side)
   type q_t is array (0 to 65535) of std_logic_vector(7 downto 0);
   shared variable qin  : q_t;
   signal qin_w, qin_r  : natural := 0;
   shared variable qout : q_t;
   signal qout_w        : natural := 0;

   -- devices
   type mem_t is array (0 to 2 ** 17 - 1) of std_logic_vector(15 downto 0);
   shared variable kick : mem_t;
   shared variable ram  : mem_t;
   signal kst      : integer := 0;         -- 0 idle 1 wait 2 done
   signal kdelay   : integer := 0;
   signal kwrites  : natural := 0;
   signal rwait    : std_logic := '0';
   signal rcnt     : integer := 0;
   signal last_ce  : std_logic := '0';
   signal b2b      : natural := 0;          -- accesses without a ce = 0 cycle before them
   signal lfsr     : unsigned(15 downto 0) := x"ACE1";
   signal flush    : std_logic := '0';
begin
   clk <= not clk after 10 ns when not done;

   dut : entity work.qnice_host
      generic map (G_MENU_ID => x"DEADBEEF",
                   G_CFM_DEFAULTS => x"000F_000E_000D_000C_000B_000A_0009_0008_0007_0006_0005_0004_0003_0002_0001_1234",
                   G_TMO_BITS => 8)
      port map (clk50_i => clk, reset_n_i => rst_n, uart_rxd_i => '1', uart_txd_o => open,
                sd_reset_o => open, sd_clk_o => open, sd_mosi_o => open, sd_miso_i => '0', sd_cd_i => '0',
                sd2_reset_o => open, sd2_clk_o => open, sd2_mosi_o => open, sd2_miso_i => '0', sd2_cd_i => '0',
                csr_reset_o => csr_reset, csr_pause_o => open, csr_osm_o => open, csr_keyboard_o => open,
                csr_joy1_o => open, csr_joy2_o => open, osm_xy_o => open, osm_dxdy_o => open,
                ascal_mode_i => "00000", ascal_mode_o => open, keys_n_i => x"FFFF",
                control_d_o => open, control_m_o => cfm, special_i => x"0000", general_i => x"0000",
                ramrom_dev_o => dev, ramrom_addr_o => addr, ramrom_data_o => wd, ramrom_data_i => rd,
                ramrom_ce_o => ce, ramrom_wait_i => wt, ramrom_we_o => we,
                s_data_i => s_data, s_valid_i => s_valid, s_pop_o => s_pop,
                m_data_o => m_data, m_push_o => m_push, m_full_i => '0',
                clr_i => clr, busy_o => busy, err_o => err, tmo_o => tmo, marker_o => marker);

   -- FWFT stream source
   s_valid <= '1' when qin_r < qin_w else '0';
   s_data  <= qin(qin_r) when qin_r < qin_w else x"00";
   process (clk)
   begin
      if rising_edge(clk) then
         if flush = '1' then
            qin_r <= qin_w;
         elsif s_pop = '1' then
            assert qin_r < qin_w report "pop of an empty FIFO" severity failure;
            qin_r <= qin_r + 1;
         end if;
         if m_push = '1' then
            qout(qout_w) := m_data;
            qout_w <= qout_w + 1;
         end if;
         lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
         last_ce <= ce;
         if ce = '1' and last_ce = '0' then null; end if;
      end if;
   end process;

   -- every access must start after a cycle with ce = 0 (rising-edge view)
   process (clk)
      variable prev_ce : std_logic := '0';
      variable prev_wt : std_logic := '0';
   begin
      if rising_edge(clk) then
         if prev_ce = '1' and prev_wt = '0' and ce = '1' then
            b2b <= b2b + 1;
         end if;
         prev_ce := ce; prev_wt := wt;
      end if;
   end process;

   -- read mux / wait
   wt <= '1' when ce = '1' and dev = x"0100" and ((kst = 0 and we = '1') or kst = 1) else
         '1' when ce = '1' and dev = x"0103" and rwait = '1' else
         '1' when ce = '1' and dev = x"0005" else '0';
   rd <= ram(to_integer(unsigned(addr(16 downto 0)))) when ce = '1' and dev = x"0103" else x"0000";

   -- Kickstart-port model (falling edge, as chip_cache)
   process (clk)
   begin
      if falling_edge(clk) then
         case kst is
            when 0 =>
               if ce = '1' and we = '1' and dev = x"0100" then
                  kick(to_integer(unsigned(addr(16 downto 0)))) := wd;
                  kwrites <= kwrites + 1;
                  kdelay  <= to_integer(lfsr(2 downto 0));
                  kst     <= 1;
               end if;
            when 1 =>
               if kdelay = 0 then kst <= 2; else kdelay <= kdelay - 1; end if;
            when others =>
               if we = '0' then kst <= 0; end if;
         end case;
      end if;
   end process;

   -- RAM device with a 0..3 cycle wait (falling edge)
   process (clk)
   begin
      if falling_edge(clk) then
         if ce = '1' and dev = x"0103" then
            if rwait = '0' and rcnt = 0 then
               rcnt  <= to_integer(lfsr(5 downto 4));
               if lfsr(5 downto 4) /= "00" then rwait <= '1'; end if;
               if we = '1' then ram(to_integer(unsigned(addr(16 downto 0)))) := wd; end if;
            elsif rcnt > 1 then
               rcnt <= rcnt - 1;
            else
               rwait <= '0';
            end if;
         else
            rwait <= '0'; rcnt <= 0;
         end if;
      end if;
   end process;

   stim : process
      procedure put(b : bytes_t) is
      begin
         for i in b'range loop
            qin(qin_w + i - b'low) := b(i);
         end loop;
         qin_w <= qin_w + b'length;
         wait until rising_edge(clk);
      end procedure;
      procedure w16(v : natural) is
      begin
         put((std_logic_vector(to_unsigned(v / 256, 8)), std_logic_vector(to_unsigned(v mod 256, 8))));
      end procedure;
      procedure idle is
      begin
         wait until rising_edge(clk);
         while busy = '1' or s_valid = '1' loop wait until rising_edge(clk); end loop;
         wait until rising_edge(clk);
      end procedure;
      procedure wr(a, d : natural) is
      begin
         put((0 => x"01")); w16(a); w16(d);
      end procedure;
      procedure rdr(a : natural) is
      begin
         put((0 => x"02")); w16(a);
      end procedure;
      procedure hdr(op, dv, win, off, n : natural) is
      begin
         put((0 => std_logic_vector(to_unsigned(op, 8)))); w16(dv); w16(win); w16(off);
         put((std_logic_vector(to_unsigned(n / 65536, 8)), std_logic_vector(to_unsigned((n / 256) mod 256, 8)),
              std_logic_vector(to_unsigned(n mod 256, 8))));
      end procedure;
      variable o : natural;
      impure function ans16(i : natural) return natural is
      begin
         return to_integer(unsigned(qout(i))) * 256 + to_integer(unsigned(qout(i + 1)));
      end function;
      variable errors : natural := 0;
      procedure check(c : boolean; msg : string) is
      begin
         if not c then
            report "FAIL: " & msg severity error;
            errors := errors + 1;
         end if;
      end procedure;
      constant NK : natural := 5000;
   begin
      for i in 0 to 9 loop wait until rising_edge(clk); end loop;
      rst_n <= '1';
      wait until rising_edge(clk);

      -- power-up: core held, CSR 0x0839, id, defaults
      check(csr_reset = '1', "core held at power-up");
      o := qout_w;
      rdr(16#FFE0#); rdr(16#FFF9#); rdr(16#FFFA#); rdr(16#FFC0#); rdr(16#FFCF#); rdr(16#FFF8#); idle;
      check(ans16(o) = 16#0839#, "CSR default");
      check(ans16(o + 2) = 16#DEAD# and ans16(o + 4) = 16#BEEF#, "menu id");
      check(ans16(o + 6) = 16#1234# and ans16(o + 8) = 16#000F#, "defaults");
      check(ans16(o + 10) = 1, "version");

      -- CFM window 5, CSR, marker
      wr(16#FFF2#, 5); wr(16#FFF3#, 16#A55A#); wr(16#FFE0#, 16#0838#); wr(16#FFFB#, 16#0001#); idle;
      check(cfm(95 downto 80) = x"A55A", "CFM window 5");
      check(csr_reset = '0', "core released");
      check(marker = '1', "marker set");
      o := qout_w;
      rdr(16#FFF3#); idle;
      check(ans16(o) = 16#A55A#, "CFM read-back");

      -- Kickstart: BW8 of NK bytes into device 0x0100 from window 0 offset 0xF00 (carry at 0x1000)
      hdr(3, 16#0100#, 0, 16#0F00#, NK);
      for i in 0 to NK - 1 loop
         qin(qin_w + i) := std_logic_vector(to_unsigned((i * 7 + 3) mod 256, 8));
      end loop;
      qin_w <= qin_w + NK;
      idle;
      check(kwrites = NK, "Kickstart writes " & integer'image(kwrites));
      for i in 0 to NK - 1 loop
         if kick(16#F00# + i) /= x"00" & std_logic_vector(to_unsigned((i * 7 + 3) mod 256, 8)) then
            check(false, "kick byte " & integer'image(i));
            exit;
         end if;
      end loop;
      o := qout_w;
      rdr(16#FFF5#); idle;
      check(ans16(o) = 2, "window carried to 2 (0xF00 + 5000 = 0x2288)");

      report "phase:ADF-like RAM" severity note;
      -- ADF-like RAM: BW8 then BR8, BW16 then BR16, then MARK
      hdr(3, 16#0103#, 2, 16#0FFE#, 600);
      for i in 0 to 599 loop qin(qin_w + i) := std_logic_vector(to_unsigned((i * 13) mod 256, 8)); end loop;
      qin_w <= qin_w + 600;
      idle;
      o := qout_w;
      hdr(5, 16#0103#, 2, 16#0FFE#, 600); idle;
      check(qout_w = o + 600, "BR8 count");
      for i in 0 to 599 loop
         if qout(o + i) /= std_logic_vector(to_unsigned((i * 13) mod 256, 8)) then
            check(false, "BR8 byte " & integer'image(i)); exit;
         end if;
      end loop;
      hdr(4, 16#0103#, 7, 0, 300);
      for i in 0 to 599 loop qin(qin_w + i) := std_logic_vector(to_unsigned((i * 5 + 1) mod 256, 8)); end loop;
      qin_w <= qin_w + 600;
      idle;
      o := qout_w;
      hdr(6, 16#0103#, 7, 0, 300); put((x"07", x"5C")); idle;
      check(qout_w = o + 601, "BR16 count + mark");
      for i in 0 to 599 loop
         if qout(o + i) /= std_logic_vector(to_unsigned((i * 5 + 1) mod 256, 8)) then
            check(false, "BR16 byte " & integer'image(i)); exit;
         end if;
      end loop;
      check(qout(o + 600) = x"5C", "MARK");

      report "phase:timeout: device 5" severity note;
      -- timeout: device 5 never answers; the rest of a 4-byte burst is consumed, reads answer 0
      hdr(3, 16#0005#, 0, 0, 4); put((x"11", x"22", x"33", x"44")); idle;
      check(tmo = '1', "timeout flag");
      o := qout_w;
      hdr(5, 16#0005#, 0, 0, 3); put((x"07", x"77")); idle;
      check(qout_w = o + 4 and qout(o + 3) = x"77", "reads after a timeout answer");
      check(qin_r = qin_w, "stream consumed after the timeout");

      report "phase:unknown opcode" severity note;
      -- unknown opcode: parser stops until clr
      put((0 => x"EE")); for i in 0 to 5 loop wait until rising_edge(clk); end loop;
      check(err = '1', "stream error");
      put((x"07", x"99")); for i in 0 to 20 loop wait until rising_edge(clk); end loop;
      check(qin_r /= qin_w, "parser stopped");
      o := qout_w;
      clr <= '1'; wait until rising_edge(clk); clr <= '0';
      put((x"07", x"42")); idle;
      check(err = '0' and tmo = '0' and qout(o) = x"99" and qout(o + 1) = x"42", "clear, then the waiting MARK");

      report "phase:M2M reset" severity note;
      -- M2M reset: registers back, marker kept
      rst_n <= '0'; wait until rising_edge(clk); rst_n <= '1'; wait until rising_edge(clk);
      check(csr_reset = '1' and cfm = (cfm'range => '0'), "reset values");
      check(marker = '1', "marker survives the M2M reset");

      check(b2b = 0, "accesses without the idle cycle: " & integer'image(b2b));
      report "tb_qnice_host: " & integer'image(errors) & " errors, " & integer'image(kwrites) &
             " Kickstart writes" severity note;
      done <= true;
      wait;
   end process;
end architecture;
