-- host_bench.vhd -- the host master for the Verilator bench (a1200-lxshell, GHDL -> Verilog):
-- qnice_host with the generated menu id / defaults, and the core's device decode for the devices
-- the bench has, as mega65.vhd does it: 0x0100 the Kickstart port of chip_cache (write-only, the
-- byte on lane U/L by address bit 0, wait from the cache; byte 1 = $14 -> 512 KB).
-- Simulation tooling only.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.host_menu_pkg.all;

entity host_bench is
port (
   q_clk       : in  std_logic;
   q_rst       : in  std_logic;                       -- the M2M reset (QNICE's reset)
   s_data      : in  std_logic_vector(7 downto 0);
   s_valid     : in  std_logic;
   s_pop       : out std_logic;
   m_data      : out std_logic_vector(7 downto 0);
   m_push      : out std_logic;
   m_full      : in  std_logic;
   clr         : in  std_logic;
   flags       : out std_logic_vector(7 downto 0);
   csr         : out std_logic_vector(5 downto 0);    -- b0 core reset .. b5 joy 2
   cfm         : out std_logic_vector(255 downto 0);
   -- chip_cache's Kickstart load port
   kq_we       : out std_logic;
   kq_addr     : out std_logic_vector(18 downto 0);
   kq_data     : out std_logic_vector(7 downto 0);
   kq_wait     : in  std_logic;
   kick512     : out std_logic
);
end entity;

architecture rtl of host_bench is
   function cfm_flat(a : t_cfm_defaults) return std_logic_vector is
      variable r : std_logic_vector(255 downto 0);
   begin
      for w in 0 to 15 loop r(16 * w + 15 downto 16 * w) := a(w); end loop;
      return r;
   end function;
   signal dev, wd, rd : std_logic_vector(15 downto 0);
   signal addr        : std_logic_vector(27 downto 0);
   signal ce, we, wt  : std_logic;
   signal k512        : std_logic := '0';
begin
   i_host : entity work.qnice_host
      generic map (G_MENU_ID => C_HOST_MENU_ID, G_CFM_DEFAULTS => cfm_flat(C_HOST_CFM_DEFAULTS))
      port map (clk50_i => q_clk, reset_n_i => not q_rst, uart_rxd_i => '1', uart_txd_o => open,
                sd_reset_o => open, sd_clk_o => open, sd_mosi_o => open, sd_miso_i => '0', sd_cd_i => '0',
                sd2_reset_o => open, sd2_clk_o => open, sd2_mosi_o => open, sd2_miso_i => '0', sd2_cd_i => '0',
                csr_reset_o => csr(0), csr_pause_o => csr(1), csr_osm_o => csr(2), csr_keyboard_o => csr(3),
                csr_joy1_o => csr(4), csr_joy2_o => csr(5), osm_xy_o => open, osm_dxdy_o => open,
                ascal_mode_i => "00000", ascal_mode_o => open, keys_n_i => x"FFFF",
                control_d_o => open, control_m_o => cfm, special_i => x"0000", general_i => x"0000",
                ramrom_dev_o => dev, ramrom_addr_o => addr, ramrom_data_o => wd, ramrom_data_i => rd,
                ramrom_ce_o => ce, ramrom_wait_i => wt, ramrom_we_o => we,
                s_data_i => s_data, s_valid_i => s_valid, s_pop_o => s_pop,
                m_data_o => m_data, m_push_o => m_push, m_full_i => m_full,
                clr_i => clr, busy_o => flags(1), err_o => flags(2), tmo_o => flags(3), marker_o => flags(4));
   flags(0) <= '0';
   flags(7 downto 5) <= "000";

   kq_we   <= ce and we when dev = x"0100" else '0';
   kq_addr <= addr(18 downto 0);
   kq_data <= wd(7 downto 0);
   wt      <= kq_wait when dev = x"0100" else '0';
   rd      <= x"0000";

   process (q_clk)
   begin
      if falling_edge(q_clk) then
         if ce = '1' and we = '1' and dev = x"0100" and unsigned(addr(18 downto 0)) = 1 then
            if wd(7 downto 0) = x"14" then k512 <= '1'; else k512 <= '0'; end if;
         end if;
      end if;
   end process;
   kick512 <= k512;
end architecture;
