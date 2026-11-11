--------------------------------------------------------------------------------
-- amiga_mouse.vhd -- Amiga quadrature mouse from the Rockchip bridge (K325T port of AExp).
--
-- The Rockchip (m65d, core id 3) sends the USB mouse as two 8-bit position counters and
-- the buttons in rk_bridge's INPUT bytes 13..16 (the bytes the C64 core reads as SID POT
-- values):
--   byte 13 (pots 31..24)  X position, counts, wraps (increasing = right)
--   byte 14 (pots 23..16)  Y position, counts, wraps (increasing = down)
--   byte 15 (pots 15..8)   buttons, ACTIVE LOW: b0 left, b1 right, b2 middle ($FF = none)
--   byte 16 (pots  7..0)   $01 = mouse on joystick port 2, anything else = port 1
-- (an older m65d, or no mouse, sends $FF $FF $FF $FF: no movement, no button, port 1)
--
-- This module chases the two counters with quadrature steps on the joystick direction lines
-- of the mouse port, one step (one transition, Gray code) per STEP_CLKS clocks, i.e. what a
-- real Amiga mouse puts on DB9 pins 1..4.  Minimig's userio.v counts the transitions into
-- JOYxDAT exactly as Denise does (the lines reach it raw: AExp's M2M debouncer is a plain
-- 2-FF synchroniser).  Horizontal: H = "down" (pin 2), HQ = "right" (pin 4); vertical:
-- V = "up" (pin 1), VQ = "left" (pin 3).  The phase is offset so that the idle position 0
-- leaves all four lines high (= no joystick direction).
-- Left button = the port's fire line (as on the real port); right / middle button = the
-- pot lines POTX / POTY of that port, which AExp's main.vhd reads like an active mouse
-- adapter: >= $80 = line high = released, < $80 = pressed.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amiga_mouse is
  generic (
    STEP_CLKS : integer := 100            -- 1 us per quadrature transition at 100 MHz
  );
  port (
    clk      : in  std_logic;
    pots     : in  std_logic_vector(31 downto 0);   -- rk_bridge INPUT bytes 13..16
    -- active low, rk_bridge joystick bit order: b0 up b1 down b2 left b3 right b4 fire
    port1_n  : out std_logic_vector(4 downto 0);
    port2_n  : out std_logic_vector(4 downto 0);
    -- pot values for the core: pot1 x, pot1 y, pot2 x, pot2 y
    core_pots: out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of amiga_mouse is
  signal xpos, ypos : unsigned(7 downto 0) := (others => '0');
  signal tick       : integer range 0 to STEP_CLKS - 1 := 0;
  signal lines_n    : std_logic_vector(4 downto 0) := (others => '1');
  signal rmb, mmb   : std_logic := '0';
  signal on_port2   : std_logic := '0';

  -- (H, HQ) resp. (V, VQ) for a position: Gray code, offset by 2 so that position 0 = "11"
  function quad(p : unsigned(7 downto 0)) return std_logic_vector is
    variable q : unsigned(1 downto 0);
  begin
    q := p(1 downto 0) + 2;
    return (q(0) xor q(1)) & q(1);     -- (first, second) = (H or V, HQ or VQ)
  end function;
begin
  process (clk)
    variable dx, dy : signed(7 downto 0);
    variable h, v   : std_logic_vector(1 downto 0);
  begin
    if rising_edge(clk) then
      if tick = STEP_CLKS - 1 then
        tick <= 0;
        dx := signed(unsigned(pots(31 downto 24)) - xpos);
        dy := signed(unsigned(pots(23 downto 16)) - ypos);
        if dx > 0 then xpos <= xpos + 1; elsif dx < 0 then xpos <= xpos - 1; end if;
        if dy > 0 then ypos <= ypos + 1; elsif dy < 0 then ypos <= ypos - 1; end if;
      else
        tick <= tick + 1;
      end if;
      h := quad(xpos);
      v := quad(ypos);
      -- b0 up = V, b1 down = H, b2 left = VQ, b3 right = HQ, b4 fire = left button
      lines_n  <= pots(8) & h(0) & v(0) & h(1) & v(1);
      rmb      <= not pots(9);
      mmb      <= not pots(10);
      on_port2 <= '1' when pots(7 downto 0) = x"01" else '0';
    end if;
  end process;

  port1_n <= lines_n when on_port2 = '0' else (others => '1');
  port2_n <= lines_n when on_port2 = '1' else (others => '1');
  core_pots(31 downto 24) <= x"00" when rmb = '1' and on_port2 = '0' else x"FF";
  core_pots(23 downto 16) <= x"00" when mmb = '1' and on_port2 = '0' else x"FF";
  core_pots(15 downto 8)  <= x"00" when rmb = '1' and on_port2 = '1' else x"FF";
  core_pots(7 downto 0)   <= x"00" when mmb = '1' and on_port2 = '1' else x"FF";
end architecture;
