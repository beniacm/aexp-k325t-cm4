--------------------------------------------------------------------------------
-- mig_model.vhd -- behavioural MIG 7-series native UI for test benches (x16 DDR3, 4:1, BL8: one
-- command = one 128-bit word, app_addr in 16-bit units, bits 2..0 zero).  Random app_rdy /
-- app_wdf_rdy, read data in command order after G_LAT_MIN..G_LAT_MAX clocks; write data is paired
-- with write commands in order (data may come before its command).  The memory keeps 2^G_AW words
-- of 128 bits, indexed by app_addr(G_AW+2 downto 3) (higher bits ignored).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity mig_model is
   generic (G_AW : natural := 18; G_LAT_MIN : natural := 15; G_LAT_MAX : natural := 60;
            G_SEED : positive := 7);
   port (
      clk          : in  std_logic;
      app_addr     : in  std_logic_vector(27 downto 0);
      app_cmd      : in  std_logic_vector(2 downto 0);
      app_en       : in  std_logic;
      app_rdy      : out std_logic;
      app_wdf_data : in  std_logic_vector(127 downto 0);
      app_wdf_wren : in  std_logic;
      app_wdf_mask : in  std_logic_vector(15 downto 0);
      app_wdf_rdy  : out std_logic;
      app_rd_data  : out std_logic_vector(127 downto 0);
      app_rd_valid : out std_logic;
      errors       : out natural
   );
end entity;

architecture sim of mig_model is
begin
   process (clk)
      type mem_t is array (0 to 2**G_AW - 1) of std_logic_vector(127 downto 0);
      variable mem : mem_t := (others => (others => '0'));
      type q_t is array (0 to 63) of integer;
      variable rq_addr, rq_due : q_t;
      variable rq_n, rq_h : integer := 0;
      type wq_t is array (0 to 63) of std_logic_vector(143 downto 0);
      variable wq : wq_t; variable wq_n : integer := 0;
      variable wc_addr : q_t; variable wc_n : integer := 0;
      variable now_c : integer := 0;
      variable s1 : positive := G_SEED; variable s2 : positive := 3; variable r : real;
      variable a : integer; variable w : std_logic_vector(127 downto 0);
      variable err : natural := 0;
      variable rdy, wrdy : std_logic := '0';
   begin
      if rising_edge(clk) then
         now_c := now_c + 1;
         if app_wdf_wren = '1' and wrdy = '1' then
            wq(wq_n) := app_wdf_mask & app_wdf_data; wq_n := wq_n + 1;
         end if;
         if app_en = '1' and rdy = '1' then
            a := to_integer(unsigned(app_addr(G_AW + 2 downto 3)));
            if app_cmd = "001" then
               uniform(s1, s2, r);
               rq_addr((rq_h + rq_n) mod 64) := a;
               rq_due((rq_h + rq_n) mod 64) := now_c + G_LAT_MIN + integer(r * real(G_LAT_MAX - G_LAT_MIN));
               if rq_n > 0 and rq_due((rq_h + rq_n) mod 64) <= rq_due((rq_h + rq_n - 1) mod 64) then
                  rq_due((rq_h + rq_n) mod 64) := rq_due((rq_h + rq_n - 1) mod 64) + 1;
               end if;
               rq_n := rq_n + 1;
            else
               wc_addr(wc_n) := a; wc_n := wc_n + 1;
            end if;
         end if;
         while wc_n > 0 and wq_n > 0 loop
            a := wc_addr(0); w := mem(a);
            for i in 0 to 15 loop
               if wq(0)(128 + i) = '0' then w(8 * i + 7 downto 8 * i) := wq(0)(8 * i + 7 downto 8 * i); end if;
            end loop;
            mem(a) := w;
            for i in 0 to 62 loop wc_addr(i) := wc_addr(i + 1); wq(i) := wq(i + 1); end loop;
            wc_n := wc_n - 1; wq_n := wq_n - 1;
         end loop;
         if wq_n > 4 or wc_n > 4 then
            report "MIG model: write data and commands do not pair" severity error;
            err := err + 1; wq_n := 0; wc_n := 0;
         end if;
         app_rd_valid <= '0';
         if rq_n > 0 and rq_due(rq_h) <= now_c then
            app_rd_data <= mem(rq_addr(rq_h)); app_rd_valid <= '1';
            rq_h := (rq_h + 1) mod 64; rq_n := rq_n - 1;
         end if;
         uniform(s1, s2, r); if r < 0.8 then rdy := '1'; else rdy := '0'; end if;
         uniform(s1, s2, r); if r < 0.8 then wrdy := '1'; else wrdy := '0'; end if;
         app_rdy <= rdy; app_wdf_rdy <= wrdy;
         errors <= err;
      end if;
   end process;
end architecture;
