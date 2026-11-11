-- tb_amiga_mouse.vhd -- amiga_mouse against userio.v's transition counter (transcribed):
-- move the target counters, check the Amiga's JOY0DAT counters follow (ghdl, see run line)
--   ghdl -a --std=08 ../amiga_mouse.vhd tb_amiga_mouse.vhd && ghdl -r --std=08 tb_amiga_mouse
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_amiga_mouse is end;
architecture sim of tb_amiga_mouse is
  signal clk : std_logic := '0';
  signal pots : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  signal p1, p2 : std_logic_vector(4 downto 0);
  signal cp : std_logic_vector(31 downto 0);
  signal j, jd : std_logic_vector(3 downto 0) := "1111";   -- minimig order: 0 right 1 left 2 down 3 up
  signal hcnt, vcnt : unsigned(7 downto 0) := (others => '0');
  signal done : boolean := false;
  signal clr : std_logic := '0';
begin
  clk <= not clk after 5 ns when not done;
  dut : entity work.amiga_mouse generic map (STEP_CLKS => 10)
    port map (clk => clk, pots => pots, port1_n => p1, port2_n => p2, core_pots => cp);
  -- userio.v: _sjoy1 = {.., up, down, left, right}; counters per clk7 (here per clk)
  process (clk)
    variable s, d : std_logic_vector(3 downto 0);
  begin
    if rising_edge(clk) then
      s := p1(0) & p1(1) & p1(2) & p1(3);    -- up down left right
      j <= s; jd <= j; d := j; s := j; d := jd;
      -- horizontal: bits 0 (right) and 2 (down)
      if clr = '1' then
        hcnt <= (others => '0');
      elsif (d(0)='0' and s(0)='1' and s(2)='1') or (d(0)='1' and s(0)='0' and s(2)='0') or
         (d(2)='0' and s(2)='1' and s(0)='0') or (d(2)='1' and s(2)='0' and s(0)='1') then
        hcnt <= hcnt + 1;
      elsif (d(0)='0' and s(0)='1' and s(2)='0') or (d(0)='1' and s(0)='0' and s(2)='1') or
            (d(2)='0' and s(2)='1' and s(0)='1') or (d(2)='1' and s(2)='0' and s(0)='0') then
        hcnt <= hcnt - 1;
      end if;
      if clr = '1' then
        vcnt <= (others => '0');
      elsif (d(1)='0' and s(1)='1' and s(3)='1') or (d(1)='1' and s(1)='0' and s(3)='0') or
         (d(3)='0' and s(3)='1' and s(1)='0') or (d(3)='1' and s(3)='0' and s(1)='1') then
        vcnt <= vcnt + 1;
      elsif (d(1)='0' and s(1)='1' and s(3)='0') or (d(1)='1' and s(1)='0' and s(3)='1') or
            (d(3)='0' and s(3)='1' and s(1)='1') or (d(3)='1' and s(3)='0' and s(1)='0') then
        vcnt <= vcnt - 1;
      end if;
    end if;
  end process;

  process
    procedure go(x, y : integer) is
    begin
      pots(31 downto 16) <= std_logic_vector(to_unsigned(x mod 256, 8)) & std_logic_vector(to_unsigned(y mod 256, 8));
      wait for 30 us;
      assert hcnt = to_unsigned(x mod 256, 8) and vcnt = to_unsigned(y mod 256, 8)
        report "FAIL target " & integer'image(x) & "," & integer'image(y) & " got " &
               integer'image(to_integer(hcnt)) & "," & integer'image(to_integer(vcnt)) severity failure;
    end procedure;
  begin
    pots <= x"0000FF00";              -- position 0,0, no buttons, port 1
    wait for 2 us;
    assert p1(3 downto 0) = "1111" report "FAIL idle lines not high" severity failure;
    clr <= '1'; wait for 1 us; clr <= '0';
    go(5, 0); go(5, 3); go(250, 3); go(250, 200); go(100, 100); go(0, 0);
    assert p1(3 downto 0) = "1111" report "FAIL lines not high at position 0" severity failure;
    pots(15 downto 8) <= x"FA";       -- left + middle pressed (active low b0, b2)
    wait for 1 us;
    assert p1(4) = '0' and cp(31 downto 24) = x"FF" and cp(23 downto 16) = x"00" report "FAIL buttons" severity failure;
    pots(7 downto 0) <= x"01";        -- mouse on port 2
    wait for 1 us;
    assert p1 = "11111" and p2(4) = '0' and cp(7 downto 0) = x"00" report "FAIL port 2" severity failure;
    report "TB_AMIGA_MOUSE_PASS";
    done <= true; wait;
  end process;
end;
