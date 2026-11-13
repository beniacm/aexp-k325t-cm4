----------------------------------------------------------------------------------------------------------
-- qnice_host.vhd -- the host master (K325T a1200-lxshell): stands in for the QNICE SoC inside
-- qnice_wrapper when the menu processor runs on the Linux module (G_QNICE_LOCAL = false).
--
-- Same ports and generics as M2M/vhdl/QNICE/qnice.vhd (entity QNICE) plus a byte stream in and out.
-- It holds QNICE's register file (CSR, OSM window, ascal mode, CFD, CFM, the RAMROM device / window
-- selectors) with QNICE's reset values and drives the RAMROM device bus with QNICE's timing: the bus
-- signals change on the rising clk50 edge, devices act on the falling edge, the access ends on the
-- first rising edge that sees wait = 0 (read data taken there), and one idle cycle (ce = 0) follows
-- every access, as QNICE's instruction fetch always gave (the Kickstart port needs it).
--
-- The command stream (bytes from the Linux module through rk_bridge's HOST_PUT; see
-- ext/aexp9_lxshell/PROTOCOL.md section 2):
--   0x01 WR   addr(2) data(2)                  one write to a QNICE address (register or 0x7000 window)
--   0x02 RD   addr(2)              -> data(2)  one read
--   0x03 BW8  dev(2) win(2) off(2) n(3) + n bytes      burst write, byte zero-extended
--   0x04 BW16 dev(2) win(2) off(2) n(3) + 2n bytes     burst write, 16-bit words
--   0x05 BR8  dev(2) win(2) off(2) n(3)  -> n bytes    burst read, low bytes
--   0x06 BR16 dev(2) win(2) off(2) n(3)  -> 2n bytes   burst read, 16-bit words
--   0x07 MARK tag(1)               -> tag(1)   barrier
-- all big-endian; the word offset auto-increments and carries into the window at 0x1000.
-- An unknown opcode stops the parser (err_o) until clr_i.  A device wait longer than 2^20 clocks
-- aborts the rest of the command (tmo_o, sticky until clr_i): its remaining write data is consumed,
-- its remaining reads answer 0.
--
-- Extra registers (read-only unless noted): 0xFFF8 version, 0xFFF9/0xFFFA menu id hi/lo,
-- 0xFFFB start marker (RW, cleared only by FPGA configuration), 0xFFC0..0xFFCF factory default
-- CFM words.  0xFFE8 (QNICE's key scan) reads 0xFFFF, 0xFFE4/0xFFE5 read special_i / general_i.
----------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qnice_host is
generic (
   G_FIRMWARE        : string  := "";             -- unused (QNICE's generics, kept for the same instance)
   G_VGA_DX          : natural := 800;
   G_VGA_DY          : natural := 600;
   G_FONT_DX         : natural := 16;
   G_FONT_DY         : natural := 16;
   G_MENU_ID         : std_logic_vector(31 downto 0)  := (others => '0');
   G_CFM_DEFAULTS    : std_logic_vector(255 downto 0) := (others => '0');
   G_TMO_BITS        : natural := 20
);
port (
   -- QNICE's ports
   clk50_i           : in  std_logic;
   reset_n_i         : in  std_logic;
   uart_rxd_i        : in  std_logic;
   uart_txd_o        : out std_logic;
   sd_reset_o        : out std_logic;
   sd_clk_o          : out std_logic;
   sd_mosi_o         : out std_logic;
   sd_miso_i         : in  std_logic;
   sd_cd_i           : in  std_logic;
   sd2_reset_o       : out std_logic;
   sd2_clk_o         : out std_logic;
   sd2_mosi_o        : out std_logic;
   sd2_miso_i        : in  std_logic;
   sd2_cd_i          : in  std_logic;
   csr_reset_o       : out std_logic;
   csr_pause_o       : out std_logic;
   csr_osm_o         : out std_logic;
   csr_keyboard_o    : out std_logic;
   csr_joy1_o        : out std_logic;
   csr_joy2_o        : out std_logic;
   osm_xy_o          : out std_logic_vector(15 downto 0);
   osm_dxdy_o        : out std_logic_vector(15 downto 0);
   ascal_mode_i      : in  std_logic_vector(4 downto 0);
   ascal_mode_o      : out std_logic_vector(4 downto 0);
   keys_n_i          : in  std_logic_vector(15 downto 0);
   control_d_o       : out std_logic_vector(255 downto 0);
   control_m_o       : out std_logic_vector(255 downto 0);
   special_i         : in  std_logic_vector(15 downto 0);
   general_i         : in  std_logic_vector(15 downto 0);
   ramrom_dev_o      : out std_logic_vector(15 downto 0);
   ramrom_addr_o     : out std_logic_vector(27 downto 0);
   ramrom_data_o     : out std_logic_vector(15 downto 0);
   ramrom_data_i     : in  std_logic_vector(15 downto 0);
   ramrom_ce_o       : out std_logic;
   ramrom_wait_i     : in  std_logic;
   ramrom_we_o       : out std_logic;
   -- the command stream (first-word-fall-through FIFO read side, clk50_i)
   s_data_i          : in  std_logic_vector(7 downto 0) := (others => '0');
   s_valid_i         : in  std_logic := '0';
   s_pop_o           : out std_logic;
   -- the answer stream (FIFO write side, clk50_i)
   m_data_o          : out std_logic_vector(7 downto 0);
   m_push_o          : out std_logic;
   m_full_i          : in  std_logic := '0';
   -- control / status (clk50_i)
   clr_i             : in  std_logic := '0';     -- HOST_RESET: parser and sticky flags (not the registers)
   busy_o            : out std_logic;
   err_o             : out std_logic;
   tmo_o             : out std_logic;
   marker_o          : out std_logic
);
end entity qnice_host;

architecture rtl of qnice_host is

   constant CSR_DEFAULT : std_logic_vector(15 downto 0) := x"0839";
   constant CHARS_DX    : natural := G_VGA_DX / G_FONT_DX;
   constant CHARS_DY    : natural := G_VGA_DY / G_FONT_DY;
   constant VERSION     : std_logic_vector(15 downto 0) := x"0001";

   -- registers (QNICE's)
   signal reg_csr       : std_logic_vector(15 downto 0) := CSR_DEFAULT;
   signal reg_ascal     : std_logic_vector(4 downto 0)  := (others => '0');
   signal reg_osm_xy    : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_osm_dxdy  : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(CHARS_DX * 256 + CHARS_DY, 16));
   signal reg_cfd_addr  : unsigned(3 downto 0) := (others => '0');
   signal reg_cfm_addr  : unsigned(3 downto 0) := (others => '0');
   signal reg_cfd       : std_logic_vector(255 downto 0) := (others => '0');
   signal reg_cfm       : std_logic_vector(255 downto 0) := (others => '0');
   signal reg_dev       : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_win       : unsigned(15 downto 0) := (others => '0');
   -- the start marker: power-on value only, never reset
   signal reg_marker    : std_logic_vector(15 downto 0) := (others => '0');

   signal ascal_mode    : std_logic_vector(4 downto 0);

   -- stream parser
   type st_t is (S_OP, S_ARG, S_EXEC, S_DATA, S_ACC, S_WAIT, S_GAP, S_ANS, S_ERR);
   signal st            : st_t := S_OP;
   signal op            : unsigned(7 downto 0) := (others => '0');
   signal args          : std_logic_vector(71 downto 0) := (others => '0');   -- up to 9 bytes
   signal nargs         : natural range 0 to 9 := 0;
   signal cnt           : unsigned(23 downto 0) := (others => '0');            -- burst words left
   signal off           : unsigned(11 downto 0) := (others => '0');
   signal byte_hi       : std_logic := '0';     -- BW16: the high byte is in wdata(15:8)
   signal wdata         : std_logic_vector(15 downto 0) := (others => '0');
   signal rdata         : std_logic_vector(15 downto 0) := (others => '0');
   signal ans           : std_logic_vector(15 downto 0) := (others => '0');
   signal ans_n         : natural range 0 to 2 := 0;
   signal acc_we        : std_logic := '0';
   signal acc_addr      : std_logic_vector(15 downto 0) := (others => '0');
   signal abort         : std_logic := '0';
   signal tmo_cnt       : unsigned(G_TMO_BITS - 1 downto 0) := (others => '0');
   signal tmo_r         : std_logic := '0';
   signal err_r         : std_logic := '0';

   signal bus_ce        : std_logic := '0';
   signal bus_we        : std_logic := '0';
   signal bus_addr      : std_logic_vector(27 downto 0) := (others => '0');
   signal bus_wd        : std_logic_vector(15 downto 0) := (others => '0');

   function nargs_of(o : unsigned(7 downto 0)) return natural is
   begin
      case to_integer(o) is
         when 1      => return 4;
         when 2      => return 2;
         when 3 to 6 => return 9;
         when 7      => return 1;
         when others => return 0;
      end case;
   end function;

   -- internal register read (QNICE addresses other than the 0x7000 window)
   function reg_rd(a : std_logic_vector(15 downto 0); csr, osm_xy, osm_dxdy : std_logic_vector(15 downto 0);
                   asc : std_logic_vector(4 downto 0); spec, gen : std_logic_vector(15 downto 0);
                   cfd_a, cfm_a : unsigned(3 downto 0); cfd, cfm : std_logic_vector(255 downto 0);
                   dev : std_logic_vector(15 downto 0); win : unsigned(15 downto 0);
                   marker : std_logic_vector(15 downto 0)) return std_logic_vector is
      variable i : natural;
   begin
      case a is
         when x"FFE0" => return "0000" & csr(11) & "000" & csr(7 downto 6) & csr(5 downto 0);
         when x"FFE1" => return osm_xy;
         when x"FFE2" => return osm_dxdy;
         when x"FFE3" => return x"00" & "000" & asc;
         when x"FFE4" => return spec;
         when x"FFE5" => return gen;
         when x"FFE8" => return x"FFFF";
         when x"FFF0" => return x"000" & std_logic_vector(cfd_a);
         when x"FFF1" => i := to_integer(cfd_a); return cfd(16 * i + 15 downto 16 * i);
         when x"FFF2" => return x"000" & std_logic_vector(cfm_a);
         when x"FFF3" => i := to_integer(cfm_a); return cfm(16 * i + 15 downto 16 * i);
         when x"FFF4" => return dev;
         when x"FFF5" => return std_logic_vector(win);
         when x"FFF8" => return VERSION;
         when x"FFF9" => return G_MENU_ID(31 downto 16);
         when x"FFFA" => return G_MENU_ID(15 downto 0);
         when x"FFFB" => return marker;
         when others =>
            if a(15 downto 4) = x"FFC" then
               i := to_integer(unsigned(a(3 downto 0)));
               return G_CFM_DEFAULTS(16 * i + 15 downto 16 * i);
            end if;
            return x"0000";
      end case;
   end function;

begin

   -- QNICE's outputs
   uart_txd_o     <= '1';
   sd_reset_o     <= '1';  sd_clk_o  <= '0';  sd_mosi_o  <= '0';
   sd2_reset_o    <= '1';  sd2_clk_o <= '0';  sd2_mosi_o <= '0';
   csr_reset_o    <= reg_csr(0);
   csr_pause_o    <= reg_csr(1);
   csr_osm_o      <= reg_csr(2);
   csr_keyboard_o <= reg_csr(3);
   csr_joy1_o     <= reg_csr(4);
   csr_joy2_o     <= reg_csr(5);
   osm_xy_o       <= reg_osm_xy;
   osm_dxdy_o     <= reg_osm_dxdy;
   ascal_mode     <= ascal_mode_i when reg_csr(11) = '1' else reg_ascal;
   ascal_mode_o   <= reg_ascal;
   control_d_o    <= reg_cfd;
   control_m_o    <= reg_cfm;
   ramrom_dev_o   <= reg_dev;
   ramrom_addr_o  <= bus_addr;
   ramrom_data_o  <= bus_wd;
   ramrom_ce_o    <= bus_ce;
   ramrom_we_o    <= bus_we;

   busy_o   <= '0' when st = S_OP else '1';
   err_o    <= err_r;
   tmo_o    <= tmo_r;
   marker_o <= '1' when reg_marker /= x"0000" else '0';

   process (clk50_i)
      variable a    : std_logic_vector(15 downto 0);
      variable d    : std_logic_vector(15 downto 0);
      variable i    : natural;
      variable isrd : boolean;
   begin
      if rising_edge(clk50_i) then
         s_pop_o  <= '0';
         m_push_o <= '0';

         -- ascal mode follows the scaler while ascal_usage (CSR b11) is set, as QNICE's
         if reg_csr(11) = '1' then
            reg_ascal <= ascal_mode_i;
         end if;

         case st is
            when S_OP =>
               abort <= '0';
               if s_valid_i = '1' then
                  s_pop_o <= '1';
                  op      <= unsigned(s_data_i);
                  nargs   <= nargs_of(unsigned(s_data_i));
                  if nargs_of(unsigned(s_data_i)) = 0 then
                     err_r <= '1';
                     st    <= S_ERR;
                  else
                     st <= S_ARG;
                  end if;
               end if;

            when S_ARG =>                           -- (the pop of the previous byte shows next cycle)
               if s_valid_i = '1' and s_pop_o = '0' then
                  s_pop_o <= '1';
                  args    <= args(63 downto 0) & s_data_i;
                  nargs   <= nargs - 1;
                  if nargs = 1 then
                     st <= S_EXEC;
                  end if;
               end if;

            when S_EXEC =>
               case to_integer(op) is
                  when 1 | 2 =>                     -- WR / RD
                     if op = 1 then
                        acc_addr <= args(31 downto 16);
                        wdata    <= args(15 downto 0);
                        acc_we   <= '1';
                     else
                        acc_addr <= args(15 downto 0);
                        acc_we   <= '0';
                     end if;
                     cnt <= to_unsigned(1, 24);
                     st  <= S_ACC;
                  when 3 to 6 =>                    -- bursts: dev, win, off, n
                     reg_dev  <= args(71 downto 56);
                     reg_win  <= unsigned(args(55 downto 40));
                     off      <= unsigned(args(35 downto 24));
                     cnt      <= unsigned(args(23 downto 0));
                     acc_addr <= x"7" & args(35 downto 24);
                     byte_hi  <= '0';
                     if unsigned(args(23 downto 0)) = 0 then
                        st <= S_OP;
                     elsif op = 3 or op = 4 then
                        acc_we <= '1';
                        st     <= S_DATA;
                     else
                        acc_we <= '0';
                        st     <= S_ACC;
                     end if;
                  when others =>                    -- MARK
                     ans   <= args(7 downto 0) & x"00";
                     ans_n <= 1;
                     st    <= S_ANS;
               end case;

            when S_DATA =>                          -- burst write data
               if s_valid_i = '1' and s_pop_o = '0' then
                  s_pop_o <= '1';
                  if op = 3 then
                     wdata <= x"00" & s_data_i;
                     st    <= S_ACC;
                  elsif byte_hi = '0' then
                     wdata(15 downto 8) <= s_data_i;
                     byte_hi <= '1';
                  else
                     wdata(7 downto 0) <= s_data_i;
                     byte_hi <= '0';
                     st      <= S_ACC;
                  end if;
               end if;

            when S_ACC =>                           -- one access (QNICE address acc_addr)
               a := acc_addr;
               tmo_cnt <= (others => '0');
               if a(15 downto 12) = x"7" then
                  if abort = '1' then
                     rdata <= (others => '0');
                     st    <= S_GAP;
                  else
                     bus_addr <= std_logic_vector(reg_win) & a(11 downto 0);
                     bus_wd   <= wdata;
                     bus_ce   <= '1';
                     bus_we   <= acc_we;
                     st       <= S_WAIT;
                  end if;
               else
                  rdata <= reg_rd(a, reg_csr, reg_osm_xy, reg_osm_dxdy, ascal_mode, special_i, general_i,
                                  reg_cfd_addr, reg_cfm_addr, reg_cfd, reg_cfm, reg_dev, reg_win, reg_marker);
                  if acc_we = '1' then
                     d := wdata;
                     case a is
                        when x"FFE0" => reg_csr <= d;
                        when x"FFE1" => reg_osm_xy <= d;
                        when x"FFE2" => reg_osm_dxdy <= d;
                        when x"FFE3" => if reg_csr(11) = '0' then reg_ascal <= d(4 downto 0); end if;
                        when x"FFF0" => reg_cfd_addr <= unsigned(d(3 downto 0));
                        when x"FFF1" => i := to_integer(reg_cfd_addr); reg_cfd(16 * i + 15 downto 16 * i) <= d;
                        when x"FFF2" => reg_cfm_addr <= unsigned(d(3 downto 0));
                        when x"FFF3" => i := to_integer(reg_cfm_addr); reg_cfm(16 * i + 15 downto 16 * i) <= d;
                        when x"FFF4" => reg_dev <= d;
                        when x"FFF5" => reg_win <= unsigned(d);
                        when x"FFFB" => reg_marker <= d;
                        when others  => null;
                     end case;
                  end if;
                  st <= S_GAP;
               end if;

            when S_WAIT =>                          -- the device acted on the falling edge
               if ramrom_wait_i = '0' then
                  rdata  <= ramrom_data_i;
                  bus_ce <= '0';
                  bus_we <= '0';
                  st     <= S_GAP;
               elsif tmo_cnt = (tmo_cnt'range => '1') then
                  rdata  <= (others => '0');
                  bus_ce <= '0';
                  bus_we <= '0';
                  abort  <= '1';
                  tmo_r  <= '1';
                  st     <= S_GAP;
               else
                  tmo_cnt <= tmo_cnt + 1;
               end if;

            when S_GAP =>                           -- ce = 0 for one cycle; answer / next word
               isrd := op = 2 or op = 5 or op = 6;
               cnt  <= cnt - 1;
               if op >= 3 then                      -- next burst address, carry into the window
                  off <= off + 1;
                  acc_addr <= x"7" & std_logic_vector(off + 1);
                  if off = x"FFF" then
                     reg_win <= reg_win + 1;
                  end if;
               end if;
               if isrd then
                  ans <= rdata;
                  if op = 5 then
                     ans <= rdata(7 downto 0) & x"00";
                     ans_n <= 1;
                  else
                     ans_n <= 2;
                  end if;
                  st <= S_ANS;
               elsif cnt = 1 then
                  st <= S_OP;
               else
                  st <= S_DATA;
               end if;

            when S_ANS =>                           -- answer bytes, high byte first
               if m_full_i = '0' and m_push_o = '0' then
                  m_data_o <= ans(15 downto 8);
                  m_push_o <= '1';
                  ans      <= ans(7 downto 0) & x"00";
                  if ans_n = 1 then
                     ans_n <= 0;
                     if op = 7 or cnt = 0 then
                        st <= S_OP;
                     else
                        st <= S_ACC;
                     end if;
                  else
                     ans_n <= ans_n - 1;
                  end if;
               end if;

            when S_ERR =>
               null;                                -- until clr_i
         end case;

         if clr_i = '1' then
            st    <= S_OP;
            err_r <= '0';
            tmo_r <= '0';
            abort <= '0';
            bus_ce <= '0';
            bus_we <= '0';
         end if;

         -- QNICE's reset: the registers (not the start marker, not the parser: the host may already
         -- be talking when the M2M reset ends)
         if reset_n_i = '0' then
            reg_csr      <= CSR_DEFAULT;
            reg_ascal    <= (others => '0');
            reg_osm_xy   <= (others => '0');
            reg_osm_dxdy <= std_logic_vector(to_unsigned(CHARS_DX * 256 + CHARS_DY, 16));
            reg_cfd_addr <= (others => '0');
            reg_cfm_addr <= (others => '0');
            reg_cfd      <= (others => '0');
            reg_cfm      <= (others => '0');
            reg_dev      <= (others => '0');
            reg_win      <= (others => '0');
         end if;
      end if;
   end process;

end architecture rtl;
