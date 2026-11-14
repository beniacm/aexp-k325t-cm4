--------------------------------------------------------------------------------
-- fc_opt.vhd -- the fast 68020's speed options as a run-time register (K325T a1200-fc8, builds without the census:
-- FCCEN /= 1)
--
-- fc8a carried the options as a constant (main.vhd C_FC_OPT x"1F" straight into fc_cpu opt_i): that bitstream ended
-- on Kickstart's red screen in the fast setting on the board, while the census bitstream (fc_cen.vhd: the same RTL with
-- the options in a register set at run time) boots under every preset.  This register is fc_cen's option logic without
-- the counters: the power-up value is G_OPT0, and the bridge's VIDEO byte (the stall controller's page 7, decoded as
-- lat_meter.vhd and fc_cen.vhd do it) can change it -- so synthesis cannot treat the options as constants and the
-- logic is the census build's.
--   entering index $E8 from another index while register 3 = 8 + p sets preset p (as fc_cen):
--   0 x"00" (fc7)   1 x"03" (I side)   2 x"0F" (I + D)   3 x"1F" (all)   4 x"10" (long stores)   5 x"13"   6, 7 x"00"
-- The census readout and every other tool keep register 3 at 0 here, so nothing else changes the options.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fc_opt is
   generic (
      G_OPT0 : std_logic_vector(7 downto 0) := x"1F"
   );
   port (
      clk   : in  std_logic;                        -- cpu_clk
      cfg_i : in  std_logic_vector(7 downto 0);     -- the bridge's VIDEO byte (asynchronous)
      opt_o : out std_logic_vector(7 downto 0)
   );
end entity fc_opt;

architecture rtl of fc_opt is
   signal cfg_s1, cfg_s2, cfg_s3 : std_logic_vector(7 downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of cfg_s1, cfg_s2 : signal is "TRUE";
   signal stable : unsigned(3 downto 0) := (others => '0');
   signal r3, r4, r5, r6 : std_logic_vector(3 downto 0) := (others => '0');
   signal idx, idx_d : std_logic_vector(7 downto 0) := (others => '0');
   signal opt   : std_logic_vector(7 downto 0) := G_OPT0;
   attribute DONT_TOUCH : string;
   attribute DONT_TOUCH of opt : signal is "TRUE";
begin
   opt_o <= opt;

   process (clk)
   begin
      if rising_edge(clk) then
         cfg_s1 <= cfg_i; cfg_s2 <= cfg_s1; cfg_s3 <= cfg_s2;
         if cfg_s2 /= cfg_s3 then stable <= (others => '0');
         elsif stable /= 15 then stable <= stable + 1; end if;
         if stable = 15 and cfg_s3(7) = '1' then
            case cfg_s3(6 downto 4) is
               when "110" => r6 <= cfg_s3(3 downto 0);
               when "011" => if r6(2 downto 0) = "111" then r3 <= cfg_s3(3 downto 0); end if;
               when "100" => if r6(2 downto 0) = "111" then r4 <= cfg_s3(3 downto 0); end if;
               when "101" => if r6(2 downto 0) = "111" then r5 <= cfg_s3(3 downto 0); end if;
               when others => null;
            end case;
         end if;
         idx <= r4 & r5; idx_d <= idx;
         if r6(2 downto 0) = "111" and idx = x"E8" and idx_d /= x"E8" and r3(3) = '1' then
            case r3(2 downto 0) is
               when "001" => opt <= x"03";
               when "010" => opt <= x"0F";
               when "011" => opt <= x"1F";
               when "100" => opt <= x"10";
               when "101" => opt <= x"13";
               when others => opt <= x"00";
            end case;
         end if;
      end if;
   end process;
end architecture rtl;
