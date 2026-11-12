---------------------------------------------------------------------------------------------
-- AExp: Amiga-local cold boot controller
--
-- A normal 68000 reset is a warm boot: Kickstart reuses the ExecBase pointer stored at
-- Chip RAM $000004 and therefore keeps the old Exec memory list. That is wrong after the
-- OSM changes the physical memory topology (the Slow RAM / A501 toggle; on the K325T the
-- memory and chipset radios of the "RAM" submenu: topology_i).
--
-- This controller turns such a topology change into a cold boot of the emulated Amiga only.
-- It holds Minimig in reset and asks the Chip RAM wrapper to clear the two 16-bit words at
-- $000004-$000007. Kickstart then rejects the warm-boot state, probes the new memory map and
-- rebuilds Exec. QNICE, the framework, HyperRAM and mounted media remain untouched.
--
-- The request is level-based (requested /= applied), not a pulse. Consequently a change
-- cannot be lost, and changes arriving during a cold boot converge to the latest value.
---------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amiga_cold_boot is
   port (
      clk_i             : in  std_logic;
      topology_i        : in  std_logic_vector(8 downto 0);  -- {cache req, 2 MB req, cpu 68020, fast Z3, fast size(2), ecs, chip1m|2m, slow} (K325T)
      -- K325T: the M2M (full) reset is a cold boot too.  In AExp V1 it was one by side effect:
      -- the Slow RAM menu bit drops while QNICE reloads the settings, so every full reset ran
      -- the scrub; the topology vector here does not change then.  Without it, Kickstart
      -- warm-boots on what the last program left in memory (Eon -> Batman hung).
      cold_req_i        : in  std_logic := '0';

      amiga_reset_o     : out std_logic;
      chip_scrub_o      : out std_logic;
      chip_scrub_addr_o : out std_logic_vector(17 downto 0)
   );
end entity amiga_cold_boot;

architecture synthesis of amiga_cold_boot is

   type t_state is (IDLE, ASSERT_RESET, SCRUB_SYSBASE_HI, SCRUB_SYSBASE_LO, HOLD_RESET);

   -- minimig_syscontrol samples its master reset only on clk7_en (one out of four clk28
   -- ticks). Keep the request high for 64 clocks, matching the established keyboard-reset
   -- scale and leaving generous phase margin before Chip RAM is touched.
   constant C_RESET_HOLD_CYCLES : natural := 64;

   signal state            : t_state := IDLE;
   signal topo_applied     : std_logic_vector(8 downto 0) := "000000001"; -- OSM default: OCS, 68000, no fast, A501 on
   signal reset_hold_count : natural range 0 to C_RESET_HOLD_CYCLES - 1 := 0;

begin

   -- ASSERT_RESET gives main.vhd a complete clock before the first BRAM write. HOLD_RESET
   -- similarly keeps the Amiga stopped for a complete clock after the second write.
   amiga_reset_o <= '0' when state = IDLE else '1';

   chip_scrub_o <= '1' when state = SCRUB_SYSBASE_HI or state = SCRUB_SYSBASE_LO else '0';

   -- main_ram_addr is a word address: byte addresses $000004 and $000006 are words 2 and 3.
   chip_scrub_addr_o <= std_logic_vector(to_unsigned(2, chip_scrub_addr_o'length))
                        when state = SCRUB_SYSBASE_HI else
                        std_logic_vector(to_unsigned(3, chip_scrub_addr_o'length));

   cold_boot_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case state is
            when IDLE =>
               if topology_i /= topo_applied or cold_req_i = '1' then
                  reset_hold_count <= C_RESET_HOLD_CYCLES - 1;
                  state            <= ASSERT_RESET;
               end if;

            when ASSERT_RESET =>
               if reset_hold_count = 0 then
                  state <= SCRUB_SYSBASE_HI;
               else
                  reset_hold_count <= reset_hold_count - 1;
               end if;

            when SCRUB_SYSBASE_HI =>
               state <= SCRUB_SYSBASE_LO;

            when SCRUB_SYSBASE_LO =>
               state <= HOLD_RESET;

            when HOLD_RESET =>
               -- Capture the latest requested value, not the value that originally triggered
               -- the reset. If it changes again after this edge, IDLE detects the mismatch and
               -- immediately performs another complete cold boot; no request can be lost.
               topo_applied     <= topology_i;
               state            <= IDLE;
         end case;
      end if;
   end process cold_boot_proc;

end architecture synthesis;
