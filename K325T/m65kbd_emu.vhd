--------------------------------------------------------------------------------
-- m65kbd_emu.vhd -- the MEGA65 keyboard's side of the serial keyboard link
-- (kio8 clock in, kio10 data out), answering from a key matrix instead of
-- real keys.  Used on boards without a MEGA65 keyboard: the matrix comes
-- from the Rockchip bridge (rk_bridge, active low, column index in, 8 rows out).
--
-- Protocol (as M2M's mega65kbd_to_matrix drives it): the host clocks kio8
-- and samples kio10 when kio8 rises; it advances its bit counter ("phase")
-- when kio8 falls.  A frame starts after a long kio8 high (sync, ~14 half
-- periods); phase 0 is sampled before the first falling edge after it.
--   phase 0..71 : column = phase / 8, row = phase mod 8   (0 = pressed)
--   72 CAPS LOCK (0 = on)  73 cursor up  74 cursor left (1 = not pressed)
--   75 RESTORE (0 = pressed)  76 INST/DEL  77 RETURN (column 0 rows 0/1;
--   the host takes those two from here, not from phases 0/1)  78 fast key
--
-- SYNC_CYCLES: a kio8 high longer than this (in clk cycles) is the frame
-- sync.  Normal high time is one half period (~1.6 us at the C64 core's
-- 31.5 MHz), the sync ~14 times that; the default is 5 us at 100 MHz.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity m65kbd_emu is
  generic (
    SYNC_CYCLES : integer := 500
  );
  port (
    clk            : in  std_logic;
    kio8           : in  std_logic;                       -- clock from the host
    kio10          : out std_logic := '1';                -- data to the host
    matrix_col_idx : out integer range 0 to 15;
    matrix_col     : in  std_logic_vector(7 downto 0);    -- active low
    capslock_n     : in  std_logic := '1';
    restore_n      : in  std_logic := '1';
    -- the MEGA65 keyboard's dedicated cursor up / left keys (0 = pressed); the C64 core turns
    -- them into RIGHT SHIFT + vertical / horizontal cursor itself (keyboard.vhd, keys 73/74)
    up_n           : in  std_logic := '1';
    left_n         : in  std_logic := '1'
  );
end entity;

architecture rtl of m65kbd_emu is
  signal kio8_s  : std_logic_vector(2 downto 0) := (others => '0');
  signal hi_cnt  : integer range 0 to SYNC_CYCLES := 0;
  signal phase   : unsigned(7 downto 0) := (others => '1');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of kio8_s : signal is "TRUE";
begin
  matrix_col_idx <= 0 when phase >= 72 else to_integer(phase(6 downto 3));

  process (clk)
    variable p : integer range 0 to 255;
  begin
    if rising_edge(clk) then
      kio8_s <= kio8_s(1 downto 0) & kio8;
      if kio8_s(1) = '1' then
        if hi_cnt /= SYNC_CYCLES then
          hi_cnt <= hi_cnt + 1;
        else
          phase <= (others => '0');            -- in the sync: next sample is phase 0
        end if;
      else
        hi_cnt <= 0;
      end if;
      if kio8_s(2) = '1' and kio8_s(1) = '0' and phase /= 255 then
        phase <= phase + 1;                    -- host advanced its bit counter
      end if;

      p := to_integer(phase);
      if p < 72 then
        kio10 <= matrix_col(p mod 8);
      elsif p = 72 then
        kio10 <= capslock_n;
      elsif p = 73 then
        kio10 <= up_n;
      elsif p = 74 then
        kio10 <= left_n;
      elsif p = 75 then
        kio10 <= restore_n;
      elsif p = 76 then
        kio10 <= matrix_col(0);                -- INST/DEL (column 0 row 0)
      elsif p = 77 then
        kio10 <= matrix_col(1);                -- RETURN (column 0 row 1)
      else
        kio10 <= '1';
      end if;
    end if;
  end process;
end architecture;
