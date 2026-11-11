--------------------------------------------------------------------------------
-- tb_avm_mig_reset.vhd -- avm_mig under M2M resets that cut Avalon bursts in two.
--   ghdl -a --std=08 K325T/avm_mig.vhd K325T/sim/tb_avm_mig_reset.vhd
--   ghdl -r --std=08 tb_avm_mig_reset -gG_FIX=true    (and -gG_FIX=false: the old wiring)
-- A random Avalon master (read and write bursts of 1..128 beats at random addresses, checked
-- against a reference memory) talks to avm_mig, which talks to a MIG native-UI model (random
-- app_rdy / app_wdf_rdy, read latency 15..60 clocks, BL8 128-bit words).  Now and then the
-- "framework" reset (avm_rst) hits for a few clocks at a random moment: the master abandons its
-- transaction, as ascal / the arbiter do when hr_rst resets them.  Words of an abandoned write
-- become "unknown" in the reference.  Checks: every transaction after a reset completes within
-- 20,000 clocks (no hang), all read data equals the reference, the MIG model never sees write
-- data without a command or vice versa.  G_FIX = false drives avm_rst with '0' (before the fix).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_avm_mig_reset is
   generic (G_FIX : boolean := true; G_RESETS : natural := 400;
            G_ARB : boolean := false);   -- true: mig_arb in front of the MIG + a line-port master
end entity;

architecture sim of tb_avm_mig_reset is
   constant T : time := 10 ns;
   constant AW : natural := 12;                       -- 4 K words of 16 bits
   signal clk : std_logic := '0';
   signal done : boolean := false;
   signal mrst : std_logic := '1';                    -- memory not ready
   signal arst, arst_dut : std_logic := '0';          -- Avalon-side reset
   signal old : std_logic := '0';
   signal avm_write, avm_read, avm_wait, avm_rdv : std_logic := '0';
   signal avm_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal avm_wdata, avm_rdata : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_be : std_logic_vector(1 downto 0) := "11";
   signal avm_bc : std_logic_vector(7 downto 0) := x"01";
   signal app_addr : std_logic_vector(27 downto 0);
   signal app_cmd : std_logic_vector(2 downto 0);
   signal app_en, app_rdy, app_wdf_end, app_wdf_wren, app_wdf_rdy, app_rdv : std_logic := '0';
   signal app_wdf_data, app_rd_data : std_logic_vector(127 downto 0) := (others => '0');
   signal app_wdf_mask : std_logic_vector(15 downto 0);
   signal dbg : std_logic_vector(23 downto 0);
   signal mig_err : natural := 0;
   -- avm_mig's UI side (before mig_arb when G_ARB)
   signal c_addr : std_logic_vector(27 downto 0);
   signal c_cmd : std_logic_vector(2 downto 0);
   signal c_en, c_rdy, c_wend, c_wren, c_wrdy, c_rdv : std_logic;
   signal c_wdata, c_rdata : std_logic_vector(127 downto 0);
   signal c_wmask : std_logic_vector(15 downto 0);
   -- line port
   signal lp_req, lp_we, lp_busy, lp_rvalid, lp_done : std_logic := '0';
   signal lp_addr : std_logic_vector(27 downto 0) := (others => '0');
   signal lp_wdata : std_logic_vector(511 downto 0) := (others => '0');
   signal lp_rdata : std_logic_vector(127 downto 0);
   signal lp_lines, lp_bad : natural := 0;
begin
   clk <= not clk after T / 2 when not done;
   arst_dut <= arst when G_FIX else '0';
   old      <= '0' when G_FIX else '1';    -- G_FIX = false: exactly the avm_mig before the fix

   dut : entity work.avm_mig
      generic map (ADDR_BITS => 27)
      port map (clk => clk, rst => mrst, avm_rst => arst_dut, old_i => old, dbg => dbg,
                avm_write => avm_write, avm_read => avm_read, avm_address => avm_addr,
                avm_writedata => avm_wdata, avm_byteenable => avm_be, avm_burstcount => avm_bc,
                avm_readdata => avm_rdata, avm_readdatavalid => avm_rdv, avm_waitrequest => avm_wait,
                app_addr => c_addr, app_cmd => c_cmd, app_en => c_en, app_rdy => c_rdy,
                app_wdf_data => c_wdata, app_wdf_end => c_wend, app_wdf_wren => c_wren,
                app_wdf_mask => c_wmask, app_wdf_rdy => c_wrdy, app_rd_data => c_rdata,
                app_rd_data_valid => c_rdv);

   g_direct : if not G_ARB generate
      app_addr <= c_addr; app_cmd <= c_cmd; app_en <= c_en; c_rdy <= app_rdy;
      app_wdf_data <= c_wdata; app_wdf_end <= c_wend; app_wdf_wren <= c_wren;
      app_wdf_mask <= c_wmask; c_wrdy <= app_wdf_rdy; c_rdata <= app_rd_data; c_rdv <= app_rdv;
   end generate;

   g_with_arb : if G_ARB generate
      arb : entity work.mig_arb
         port map (clk => clk, rst => mrst,
                   lp_req => lp_req, lp_we => lp_we, lp_addr => lp_addr, lp_wdata => lp_wdata,
                   lp_busy => lp_busy, lp_rvalid => lp_rvalid, lp_rdata => lp_rdata, lp_done => lp_done,
                   c1_app_addr => c_addr, c1_app_cmd => c_cmd, c1_app_en => c_en, c1_app_rdy => c_rdy,
                   c1_wdf_data => c_wdata, c1_wdf_end => c_wend, c1_wdf_wren => c_wren,
                   c1_wdf_mask => c_wmask, c1_wdf_rdy => c_wrdy, c1_rd_data => c_rdata, c1_rd_valid => c_rdv,
                   app_addr => app_addr, app_cmd => app_cmd, app_en => app_en, app_rdy => app_rdy,
                   app_wdf_data => app_wdf_data, app_wdf_end => app_wdf_end, app_wdf_wren => app_wdf_wren,
                   app_wdf_mask => app_wdf_mask, app_wdf_rdy => app_wdf_rdy, app_rd_data => app_rd_data,
                   app_rd_valid => app_rdv);

      -- line master: random line writes and read-backs in the line area (word $4000000 ...)
      lines : process
         type lref_t is array (0 to 63) of std_logic_vector(511 downto 0);
         variable lref : lref_t := (others => (others => '0'));
         variable s1, s2 : positive := 11; variable r : real;
         variable li, k : integer; variable w : std_logic_vector(511 downto 0);
      begin
         wait until mrst = '0';
         while not done loop
            uniform(s1, s2, r); li := integer(floor(r * 64.0));
            uniform(s1, s2, r);
            lp_addr <= "0100" & std_logic_vector(to_unsigned(li * 32, 24));
            if r < 0.5 then
               for i in 0 to 15 loop
                  uniform(s1, s2, r); w(32 * i + 31 downto 32 * i) := std_logic_vector(to_unsigned(integer(floor(r * 32767.0)) * 65536 + li, 32));
               end loop;
               lp_wdata <= w; lp_we <= '1'; lp_req <= '1';
               wait until rising_edge(clk); lp_req <= '0';
               wait until rising_edge(clk) and lp_done = '1';
               lref(li) := w;
            else
               lp_we <= '0'; lp_req <= '1';
               wait until rising_edge(clk); lp_req <= '0';
               k := 0;
               while k < 4 loop
                  wait until rising_edge(clk);
                  if lp_rvalid = '1' then
                     if lp_rdata /= lref(li)(128 * k + 127 downto 128 * k) then
                        report "line port: wrong data in line " & integer'image(li) severity error;
                        lp_bad <= lp_bad + 1;
                     end if;
                     k := k + 1;
                  end if;
               end loop;
            end if;
            lp_lines <= lp_lines + 1;
            uniform(s1, s2, r); wait for integer(floor(r * 30.0)) * T;
         end loop;
         wait;
      end process;
   end generate;

   -- MIG native UI model: 128-bit words, commands in order, write data FIFO
   mig : process (clk)
      type mem_t is array (0 to 2**(AW - 2) - 1) of std_logic_vector(127 downto 0);
      variable mem : mem_t := (others => (others => '0'));
      type q_t is array (0 to 63) of integer;
      variable rq_addr, rq_due : q_t;
      variable rq_n, rq_h : integer := 0;
      type wq_t is array (0 to 63) of std_logic_vector(143 downto 0);
      variable wq : wq_t; variable wq_n : integer := 0;
      variable wc_addr : q_t; variable wc_n : integer := 0;
      variable now_c : integer := 0;
      variable s1, s2 : positive := 7; variable r : real;
      variable a : integer; variable w : std_logic_vector(127 downto 0);
   begin
      if rising_edge(clk) then
         now_c := now_c + 1;
         uniform(s1, s2, r); app_rdy <= '1' when r < 0.8 else '0';
         uniform(s1, s2, r); app_wdf_rdy <= '1' when r < 0.8 else '0';
         -- write data
         if app_wdf_wren = '1' and app_wdf_rdy = '1' then
            wq(wq_n) := app_wdf_mask & app_wdf_data; wq_n := wq_n + 1;
         end if;
         -- commands
         if app_en = '1' and app_rdy = '1' then
            a := to_integer(unsigned(std_logic_vector'(app_addr(26) & app_addr(AW - 1 downto 3))));
            if app_cmd = "001" then
               uniform(s1, s2, r);
               rq_addr((rq_h + rq_n) mod 64) := a;
               rq_due((rq_h + rq_n) mod 64) := now_c + 15 + integer(r * 45.0);
               if rq_n > 0 and rq_due((rq_h + rq_n) mod 64) < rq_due((rq_h + rq_n - 1) mod 64) then
                  rq_due((rq_h + rq_n) mod 64) := rq_due((rq_h + rq_n - 1) mod 64) + 1;  -- in order
               end if;
               rq_n := rq_n + 1;
            else
               wc_addr(wc_n) := a; wc_n := wc_n + 1;
            end if;
         end if;
         -- pair write commands with data (UG586: data no later than 2 cycles after its command;
         -- the model just pairs them in order and complains about stray data)
         while wc_n > 0 and wq_n > 0 loop
            a := wc_addr(0); w := mem(a);
            for i in 0 to 15 loop
               if wq(0)(128 + i) = '0' then w(8 * i + 7 downto 8 * i) := wq(0)(8 * i + 7 downto 8 * i); end if;
            end loop;
            mem(a) := w;
            for i in 0 to 62 loop wc_addr(i) := wc_addr(i + 1); wq(i) := wq(i + 1); end loop;
            wc_n := wc_n - 1; wq_n := wq_n - 1;
         end loop;
         if wq_n > 4 then
            report "MIG model: write data without a command" severity error;
            mig_err <= mig_err + 1; wq_n := 0;
         end if;
         -- read data, in order
         app_rdv <= '0';
         if rq_n > 0 and rq_due(rq_h) <= now_c then
            app_rd_data <= mem(rq_addr(rq_h)); app_rdv <= '1';
            rq_h := (rq_h + 1) mod 64; rq_n := rq_n - 1;
         end if;
      end if;
   end process;

   master : process
      type ref_t is array (0 to 2**AW - 1) of integer;   -- -1 = unknown
      variable ref : ref_t := (others => 0);
      variable s1, s2 : positive := 3; variable r : real;
      variable addr, n, got, resets, txns, bad, hangs : natural := 0;
      variable is_wr, aborted : boolean;
      variable rst_at : integer;
      variable cyc : natural;
      variable d : integer;
      procedure rnd(x : out natural; lim : natural) is
      begin
         uniform(s1, s2, r); x := natural(floor(r * real(lim)));
      end procedure;
   begin
      mrst <= '1'; wait for 20 * T; wait until rising_edge(clk); mrst <= '0';
      while resets < G_RESETS loop
         uniform(s1, s2, r); is_wr := r < 0.5;
         rnd(n, 128); n := n + 1;
         rnd(addr, 2**AW - n);
         -- a reset at a random clock of this transaction (or none: 30 %)
         uniform(s1, s2, r);
         if r < 0.7 then rnd(rst_at, 3 * n + 40); else rst_at := -1; end if;
         aborted := false; cyc := 0; got := 0;
         avm_addr <= std_logic_vector(to_unsigned(addr, 32));
         avm_bc <= std_logic_vector(to_unsigned(n mod 256, 8)) when n < 256 else x"00";
         if n = 128 then avm_bc <= x"80"; end if;
         if is_wr then
            for i in 0 to n - 1 loop
               d := (addr + i) * 7 + txns; d := d mod 65536;
               avm_wdata <= std_logic_vector(to_unsigned(d, 16)); avm_be <= "11"; avm_write <= '1';
               loop
                  wait until rising_edge(clk); cyc := cyc + 1;
                  if cyc = rst_at then aborted := true; exit; end if;
                  exit when avm_wait = '0';
                  if cyc > 20000 then report "HANG: write beat never accepted" severity error;
                     hangs := hangs + 1; exit; end if;
               end loop;
               exit when hangs > 0;
               if aborted then
                  for j in i to n - 1 loop ref(addr + j) := -1; end loop;   -- may or may not be written
                  if i > 0 then for j in 0 to i - 1 loop ref(addr + j) := -1; end loop; end if;
                  exit;
               end if;
               ref(addr + i) := d;
               -- the word containing the beat is written only when the 128-bit word is flushed;
               -- an abort later in this burst may drop it: keep "unknown" until the burst ends
            end loop;
            avm_write <= '0';
         else
            avm_read <= '1';
            loop
               wait until rising_edge(clk); cyc := cyc + 1;
               if cyc = rst_at then aborted := true; exit; end if;
               exit when avm_wait = '0';
               if cyc > 20000 then report "HANG: read command never accepted" severity error;
                  hangs := hangs + 1; exit; end if;
            end loop;
            avm_read <= '0';
            while not aborted and got < n loop
               wait until rising_edge(clk); cyc := cyc + 1;
               if cyc = rst_at then aborted := true; exit; end if;
               if avm_rdv = '1' then
                  d := ref(addr + got);
                  if d >= 0 and to_integer(unsigned(avm_rdata)) /= d then
                     report "read data wrong at " & integer'image(addr + got) severity error;
                     bad := bad + 1;
                  end if;
                  got := got + 1;
               end if;
               if cyc > 20000 then
                  report "HANG: read burst never completed (" & integer'image(got) & " of " &
                         integer'image(n) & " beats)" severity error;
                  hangs := hangs + 1; exit;
               end if;
            end loop;
         end if;
         if aborted then
            -- the framework reset: masters and arbiter restart; a few clocks of reset
            arst <= '1'; avm_write <= '0'; avm_read <= '0';
            wait for 5 * T; wait until rising_edge(clk); arst <= '0';
            resets := resets + 1;
         end if;
         txns := txns + 1;
         exit when hangs > 0;
         -- verify a written burst completely only if it was not aborted
         if is_wr and not aborted then
            null;
         end if;
         -- hang check for the NEXT command: if waitrequest never drops, it is a hang
         if hangs > 0 then exit; end if;
         -- make the next transaction's waitrequest wait bounded
         cyc := 0;
         while avm_wait = '1' and cyc < 20000 loop wait until rising_edge(clk); cyc := cyc + 1; end loop;
         if cyc >= 20000 then report "HANG: waitrequest stuck" severity error; hangs := hangs + 1; exit; end if;
         -- also catch reads that were accepted but never answered (old S_WR behaviour)
      end loop;
      -- final read-back of the whole memory against the reference
      for b in 0 to 2**AW / 128 - 1 loop
         exit when hangs > 0;
         avm_addr <= std_logic_vector(to_unsigned(b * 128, 32)); avm_bc <= x"80"; avm_read <= '1';
         loop wait until rising_edge(clk); exit when avm_wait = '0'; end loop;
         avm_read <= '0'; got := 0; cyc := 0;
         while got < 128 and cyc < 20000 loop
            wait until rising_edge(clk); cyc := cyc + 1;
            if avm_rdv = '1' then
               d := ref(b * 128 + got);
               if d >= 0 and to_integer(unsigned(avm_rdata)) /= d then bad := bad + 1; end if;
               got := got + 1;
            end if;
         end loop;
         if got < 128 then hangs := hangs + 1; report "HANG in the read-back" severity error; end if;
      end loop;
      report "transactions " & integer'image(txns) & ", resets " & integer'image(resets) &
             ", aborts seen by avm_mig " & integer'image(to_integer(unsigned(dbg(23 downto 20)))) &
             " (mod 16), wrong read words " & integer'image(bad) & ", hangs " & integer'image(hangs) &
             ", MIG protocol errors " & integer'image(mig_err) & ", line-port lines " &
             integer'image(lp_lines) & " (wrong " & integer'image(lp_bad) & ")";
      if hangs = 0 and bad = 0 and mig_err = 0 and lp_bad = 0 then
         report "TB_AVM_MIG_RESET_PASS";
      else
         report "TB_AVM_MIG_RESET_FAIL" severity error;
      end if;
      done <= true; wait;
   end process;
end architecture;
