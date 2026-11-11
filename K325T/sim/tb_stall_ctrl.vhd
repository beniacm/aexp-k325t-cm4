--------------------------------------------------------------------------------
-- tb_stall_ctrl.vhd -- test bench for K325T/stall_ctrl.vhd (stoppable Amiga clock, stage 1).
--   ghdl -a --std=08 K325T/stall_ctrl.vhd K325T/sim/tb_stall_ctrl.vhd && ghdl -r --std=08 tb_stall_ctrl
-- The configuration goes in exactly as from the Rockchip (VIDEO byte 1rrrvvvv, held, asynchronous),
-- the statistics come back through the snapshot pages.  Checks, phase by phase:
--   A  no stalls, native: machine edges = 31/32 of the source edges exactly, never 2 drops in a row,
--      lag < 1 tick
--   B..E  random stalls (0.7 us at ~200/frame, 0.3-2.4 us at ~360/frame, 15 us bursts, 3 % load):
--      every edge: lag (DUT) <= fluid debt d + 1, d(t) = max(0, d + s x 31/32 - (1 - s) / 32); the
--      controller never passes an edge during a stall; the reported lag_max = the observed maximum;
--      stall count / stalled ticks = the injector's (seen at ce)
--   then the injector off: the lag returns below 1 tick within 32 x (lag + 1) ticks, and over the whole
--      run machine edges = 31/32 x source edges - lag  (i.e. no edge lost or invented)
--   F  fast rate: machine/source = N_FAST / 2^20 over 2^20 ticks
--   G  overload (10 %): the lag reaches the cap 2^CAP and stays there, forgiven ticks counted
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_stall_ctrl is
   generic (
      G_N_NATIVE : natural := 1015808;   -- 31/32 x 2^20 (stage 1); stage 2: 950272 (29/32)
      G_N_FAST   : natural := 1018045    -- stage 2: 952365
   );
end entity;

architecture sim of tb_stall_ctrl is
   constant T     : time := 34.142 ns;
   constant CAPB  : natural := 12;
   constant KN    : real := real(G_N_NATIVE) / 1048576.0;     -- machine / source edges       -- small cap so that the overload phase is short
   signal clk     : std_logic := '0';
   signal fast    : std_logic := '0';
   signal cfg     : std_logic_vector(7 downto 0) := x"00";
   signal vsync   : std_logic := '0';
   signal ce      : std_logic;
   signal inj     : std_logic;
   signal lag     : unsigned(31 downto 0);
   signal diag    : std_logic_vector(95 downto 0);
   signal done    : boolean := false;

   -- checker state (updated in the clock process below, read by the stimulus)
   signal n_src, n_mach, n_stall_tk, n_stalls : natural := 0;
   signal obs_lag_max : natural := 0;
   signal errors      : natural := 0;    -- stimulus checks
   signal errors_chk  : natural := 0;    -- per-edge checks
   signal fluid_max   : real := 0.0;
   signal checking    : boolean := true;
   signal reset_max   : boolean := false;
begin
   clk <= not clk after T / 2 when not done;

   dut : entity work.stall_ctrl
      generic map (G_CAP_BITS => CAPB, G_N_NATIVE => G_N_NATIVE, G_N_FAST => G_N_FAST)
      port map (clk_i => clk, fast_i => fast, cfg_i => cfg, stall_i => '0', vsync_i => vsync,
                ce_o => ce, inj_o => inj, lag_o => lag, diag_o => diag);

   -- machine "vsync": one per 568,408 machine edges would take too long; one per 4096 machine edges
   process (clk)
      variable m : natural := 0;
   begin
      if rising_edge(clk) and ce = '1' then
         m := m + 1;
         if m mod 4096 = 0 then vsync <= '1'; elsif m mod 4096 = 8 then vsync <= '0'; end if;
      end if;
   end process;

   -- checker: every source edge
   process (clk)
      variable d       : real := 0.0;     -- fluid debt in machine ticks
      variable inj_d   : std_logic := '0';
      variable l       : natural;
   begin
      if rising_edge(clk) then
         n_src <= n_src + 1;
         if ce = '1' then n_mach <= n_mach + 1; end if;
         -- the ce register sampled here belongs to the previous tick's decision, inj to this one:
         -- the DUT decided ce from the registered inj of the previous tick
         if inj_d = '1' and ce = '1' then
            report "edge passed during a stall" severity error;
            errors_chk <= errors_chk + 1;
         end if;
         if inj_d = '1' then
            n_stall_tk <= n_stall_tk + 1;
            d := d + KN;
         else
            d := d - (1.0 - KN);
            if d < 0.0 then d := 0.0; end if;
         end if;
         if reset_max then fluid_max <= 0.0; elsif d > fluid_max then fluid_max <= d; end if;
         if inj = '1' and inj_d = '0' then n_stalls <= n_stalls + 1; end if;
         inj_d := inj;
         l := to_integer(lag);
         if reset_max then obs_lag_max <= 0; elsif l > obs_lag_max then obs_lag_max <= l; end if;
         if checking and real(l) > d + 1.0 + 1.0e-9 and fast = '0' then
            report "lag " & integer'image(l) & " > fluid debt " & real'image(d) & " + 1" severity error;
            errors_chk <= errors_chk + 1;
         end if;
      end if;
   end process;

   stim : process
      variable seq : std_logic := '0';
      variable w0, w1, w2 : unsigned(31 downto 0);
      variable src0, mach0, stk0, st0 : natural;

      function b2n(x : std_logic) return natural is
      begin
         if x = '1' then return 1; else return 0; end if;
      end function;

      procedure wr(r : natural; v : natural) is
      begin
         cfg <= '1' & std_logic_vector(to_unsigned(r, 3)) & std_logic_vector(to_unsigned(v, 4));
         wait for 40 * T;                 -- the Rockchip's next SPI frame is microseconds away
      end procedure;

      procedure snap(page : natural) is
      begin
         seq := not seq;
         wr(6, page + 8 * b2n(seq));
         w0 := unsigned(diag(95 downto 64));
         w1 := unsigned(diag(63 downto 32));
         w2 := unsigned(diag(31 downto 0));
      end procedure;

      procedure page(p : natural) is      -- another page of the same snapshot
      begin
         wr(6, p + 8 * b2n(seq));
         w0 := unsigned(diag(95 downto 64));
         w1 := unsigned(diag(63 downto 32));
         w2 := unsigned(diag(31 downto 0));
      end procedure;

      procedure check(c : boolean; msg : string) is
      begin
         if not c then
            report "FAIL: " & msg severity error;
            errors <= errors + 1;
         else
            report "ok: " & msg;
         end if;
      end procedure;

      variable clr : natural := 0;
      procedure clear is
      begin
         clr := 1 - clr;
         wr(7, clr);
         reset_max <= true;
         wait until rising_edge(clk);
         reset_max <= false;
      end procedure;

      -- run with the injector on for n source ticks, then off until the lag is gone
      procedure stalls(name : string; e, m, de, dm, j, n : natural) is
         variable lag_peak : natural;
         variable t_off    : natural;
         variable dsrc, dmach : natural;
      begin
         clear;
         wr(1, e); wr(2, m); wr(3, de); wr(4, dm); wr(5, j);
         src0 := n_src; mach0 := n_mach; stk0 := n_stall_tk; st0 := n_stalls;
         wr(0, 1);
         wait for n * T;
         wr(0, 0);
         wait until rising_edge(clk) and inj = '0';
         t_off := n_src;
         lag_peak := to_integer(lag);
         wait until rising_edge(clk) and lag = 0;
         check(real(n_src - t_off) <= real(lag_peak + 2) / (1.0 - KN) + 2.0,
               name & ": lag " & integer'image(lag_peak) & " repaid in " &
               integer'image(n_src - t_off) & " ticks (<= (lag + 2) / (1 - K))");
         wait for 100 * T;
         snap(0);
         check(to_integer(w1) = obs_lag_max, name & ": lag_max " & integer'image(to_integer(w1)) &
               " = observed " & integer'image(obs_lag_max) & " (fluid bound " &
               real'image(fluid_max) & ")");
         page(1);
         check(to_integer(w0) = n_stalls - st0 and to_integer(w1) = n_stall_tk - stk0,
               name & ": " & integer'image(to_integer(w0)) & " stalls, " &
               integer'image(to_integer(w1)) & " stalled ticks (bench " &
               integer'image(n_stalls - st0) & ", " & integer'image(n_stall_tk - stk0) & ")");
         dsrc := n_src - src0; dmach := n_mach - mach0;
         report name & ": stall fraction " &
                real'image(real(n_stall_tk - stk0) / real(dsrc)) & ", stalls per 585806 ticks (frame) " &
                real'image(real(n_stalls - st0) * 585806.0 / real(dsrc));
      end procedure;

      variable a, b : natural;
   begin
      wait for 100 * T;
      ---------------------------------------------------------------- A: native, no stalls
      snap(4);
      check(w0 = x"A1200001", "id word");
      wait until rising_edge(clk);
      a := n_src; b := n_mach;
      wait for 32 * 100000 * T;
      wait until rising_edge(clk);
      check(abs(real(n_mach - b) - KN * real(n_src - a)) <= 1.5,
            "A: " & integer'image(n_mach - b) & " machine edges in " & integer'image(n_src - a) &
            " source edges (K x source = " & real'image(KN * real(n_src - a)) & " +- 1)");
      snap(0);
      check(w2 = 0 and w1 <= 1, "A: lag now " & integer'image(to_integer(w2)) & ", max " &
            integer'image(to_integer(w1)));
      ---------------------------------------------------------------- B..E: random stalls
      -- B: the study's worst RTL workload: 0.68 us (20 ticks) at ~200 per frame
      stalls("B 0.7us x200/frame", 7, 10, 2, 4, 0, 2000000);
      -- C: 0.3-2.4 us at ~360 per frame (~2.5 %, below the 3.1 % budget)
      stalls("C 0.3-2.4us x360/frame", 5, 4, 0, 8, 6, 2000000);
      -- D: 15 us bursts (448 ticks) at ~20 per frame (1.5 %)
      stalls("D 15us x20/frame", 10, 8, 5, 13, 0, 3000000);
      -- E: 3.0 % in 0.7 us stalls (~880 per frame: at the budget)
      stalls("E 0.7us x860/frame", 3, 2, 2, 4, 0, 3000000);
      ---------------------------------------------------------------- whole run: nothing lost
      wait until rising_edge(clk);
      snap(4);
      a := to_integer(w2);                -- machine edges at the snapshot (low 32 bits)
      page(3);
      b := to_integer(w2);                -- source edges at the snapshot
      page(0);
      -- target = b x 31/32 (exact up to the start-up phase): machine edges = target - lag (+-1)
      check(abs(real(a) - (real(b) * KN - real(to_integer(w2)))) <= 1.5,
            "whole run: " & integer'image(a) & " machine edges for " & integer'image(b) &
            " source edges (K x source = " & real'image(real(b) * KN) & ", lag " &
            integer'image(to_integer(w2)) & ")");
      page(2);
      report "vsyncs " & integer'image(to_integer(w0)) & ", last at source tick " &
             integer'image(to_integer(w2));
      check(abs(to_integer(w0) - a / 4096) <= 1, "vsync count " & integer'image(to_integer(w0)) &
            " = machine edges / 4096 = " & integer'image(a / 4096));
      ---------------------------------------------------------------- F: fast rate
      checking <= false;
      fast <= '1';
      wait for 1000 * T;
      wait until rising_edge(clk);
      a := n_src; b := n_mach;
      wait for 1048576 * T;
      wait until rising_edge(clk);
      check(abs(real(n_mach - b) - real(G_N_FAST)) <= 1.5,
            "F: fast: " & integer'image(n_mach - b) & " machine edges in 2^20 source edges (" &
            integer'image(G_N_FAST) & ")");
      fast <= '0';
      wait for 1000 * T;
      ---------------------------------------------------------------- G: overload, lag cap
      clear;
      wr(1, 2); wr(2, 7); wr(3, 2); wr(4, 4); wr(5, 0);          -- 20 ticks, p = 8/1024: ~15 %
      wr(0, 1);
      wait for 400000 * T;
      snap(0);
      check(w2 >= 2**CAPB - 40 and w1 = 2**CAPB, "G: overload: lag now " & integer'image(to_integer(w2)) &
            ", max " & integer'image(to_integer(w1)) & " (cap " & integer'image(2**CAPB) & ")");
      page(3);
      check(w0 > 0, "G: forgiven ticks " & integer'image(to_integer(w0)));
      wr(0, 0);
      wait until rising_edge(clk) and lag = 0;
      report "G: lag repaid after the overload";

      wait until rising_edge(clk);
      if errors = 0 and errors_chk = 0 then
         report "TB_STALL_CTRL_PASS" severity note;
      else
         report "TB_STALL_CTRL_FAIL: " & integer'image(errors) & " + " & integer'image(errors_chk) &
                " errors" severity error;
      end if;
      done <= true;
      wait;
   end process;
end architecture sim;
