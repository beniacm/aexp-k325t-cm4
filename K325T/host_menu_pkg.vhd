-- host_menu_pkg.vhd -- K325T a1200-lxshell: the menu definition's id and factory-default CFM words,
-- readable by the Linux shell through the host master (0xFFF9/0xFFFA, 0xFFC0..0xFFCF, bridge STATUS
-- 78..81).  PLACEHOLDER (all zero) until the menu generator (menu_gen.py --vhdl) writes this file in
-- the build; an id of 0 tells the shell "no menu file matches", so it falls back to its defaults.
library ieee;
use ieee.std_logic_1164.all;

package host_menu_pkg is
   constant C_HOST_MENU_ID      : std_logic_vector(31 downto 0)  := x"00000000";
   constant C_HOST_CFM_DEFAULTS : std_logic_vector(255 downto 0) := (others => '0');
end package host_menu_pkg;
