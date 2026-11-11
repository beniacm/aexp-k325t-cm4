--------------------------------------------------------------------------------
-- tb_amiga_fastram.vhd -- amiga_fastram against a reference memory: random 68000-like
-- bus cycles (word/byte writes, reads) on the core clock (28.375 MHz), an Avalon memory
-- model on the memory clock (100 MHz) with a random number of wait states and read
-- latency.  Every read is checked against the reference; reports hits / misses / the
-- number of core clocks from select to ready.
-- G_PULSE = true: the TG68K handshake instead (K325T 68020): requests back to back, the
-- next one in the clock after the one-clock ready pulse, which must be exactly one clock.
--   ghdl -a --std=08 ../amiga_fastram.vhd tb_amiga_fastram.vhd
--   ghdl -e --std=08 tb_amiga_fastram && ghdl -r --std=08 tb_amiga_fastram [-gG_PULSE=true]
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_amiga_fastram is
   generic (G_PULSE : boolean := false);
end entity tb_amiga_fastram;

architecture sim of tb_amiga_fastram is
   signal clk, hr_clk : std_logic := '0';
   signal sel, we, uds_n, lds_n, ready : std_logic := '0';
   signal addr  : std_logic_vector(26 downto 0) := (others => '0');
   signal pulse : std_logic := '0';
   signal wdata, rdata : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_write, avm_read, avm_rdv, avm_wait : std_logic := '0';
   signal avm_addr : std_logic_vector(31 downto 0);
   signal avm_wd, avm_rd : std_logic_vector(15 downto 0);
   signal avm_be : std_logic_vector(1 downto 0);
   signal avm_bc : std_logic_vector(7 downto 0);
   signal done : boolean := false;
   signal hr_rst : std_logic := '0';

   -- two 64 KB test windows: DDR3 words $900000.. (Zorro II area) and $7FF8000.. (the top
   -- of the 256 MB DDR3: Zorro III)
   type t_mem is array (0 to 65535) of std_logic_vector(15 downto 0);
   shared variable ddr : t_mem := (others => x"0000");   -- the Avalon model's memory
   function idx(a : std_logic_vector(31 downto 0)) return integer is
   begin
      return to_integer(unsigned(a(14 downto 0))) + 32768 * to_integer(unsigned(a(26 downto 26)));
   end function;
begin
   clk    <= not clk after 17.62 ns when not done;     -- 28.375 MHz
   hr_clk <= not hr_clk after 5 ns when not done;      -- 100 MHz

   dut : entity work.amiga_fastram
      port map (clk_i => clk, sel_i => sel, pulse_i => pulse, addr_i => addr, we_i => we, uds_n_i => uds_n,
                lds_n_i => lds_n, wdata_i => wdata, rdata_o => rdata, ready_o => ready,
                hr_clk_i => hr_clk, hr_rst_i => hr_rst,
                avm_write_o => avm_write, avm_read_o => avm_read, avm_address_o => avm_addr,
                avm_writedata_o => avm_wd, avm_byteenable_o => avm_be, avm_burstcount_o => avm_bc,
                avm_readdata_i => avm_rd, avm_readdatavalid_i => avm_rdv, avm_waitrequest_i => avm_wait);

   -- memory-side resets (the framework's M2M reset resets the arbiters): every ~37 us for
   -- 0.5 us; the memory model drops its transaction
   rstgen : process
   begin
      while not done loop
         wait for 37 us;
         wait until rising_edge(hr_clk);
         hr_rst <= '1';
         wait for 500 ns;
         wait until rising_edge(hr_clk);
         hr_rst <= '0';
      end loop;
      wait;
   end process;

   -- Avalon memory: random wait states before accepting, read data after 8..40 cycles
   mem : process
      variable s1, s2 : positive := 7;
      variable r : real;
      variable a : std_logic_vector(31 downto 0);
      variable n : integer;
      variable drop : boolean;
   begin
      avm_wait <= '1'; avm_rdv <= '0';
      wait until rising_edge(hr_clk);
      if avm_write = '1' or avm_read = '1' then
         uniform(s1, s2, r);
         for i in 1 to integer(r * 6.0) loop wait until rising_edge(hr_clk); end loop;
         if (avm_write = '1' or avm_read = '1') and hr_rst = '0' then   -- not withdrawn by a reset
         avm_wait <= '0';
         a := avm_addr; n := to_integer(unsigned(avm_bc));
         if avm_write = '1' then
            assert n = 1 report "write burst" severity failure;
            if avm_be(1) = '1' then ddr(idx(a))(15 downto 8) := avm_wd(15 downto 8); end if;
            if avm_be(0) = '1' then ddr(idx(a))(7 downto 0)  := avm_wd(7 downto 0);  end if;
            wait until rising_edge(hr_clk);
            avm_wait <= '1';
         else
            assert n = 8 and a(2 downto 0) = "000" report "fill burst" severity failure;
            wait until rising_edge(hr_clk);
            avm_wait <= '1';
            uniform(s1, s2, r);
            for i in 1 to 8 + integer(r * 32.0) loop wait until rising_edge(hr_clk); end loop;
            uniform(s1, s2, r);
            drop := r < 0.5;     -- after a reset: the arbiter drops the beats, or they still come
            for i in 0 to 7 loop
               exit when hr_rst = '1' and drop;
               avm_rd <= ddr(idx(std_logic_vector(unsigned(a) + i))); avm_rdv <= '1';
               wait until rising_edge(hr_clk);
               avm_rdv <= '0';
               if i mod 2 = 1 then wait until rising_edge(hr_clk); end if;   -- bubbles
            end loop;
         end if;
         end if;
      end if;
   end process;

   cpu : process
      variable s1, s2 : positive := 3;
      variable r : real;
      variable ref : t_mem := (others => x"0000");
      variable a, w : integer;
      variable cyc, hits, misses, writes, maxc : integer := 0;
      variable d : std_logic_vector(15 downto 0);
      variable ua, la : std_logic;
      variable iswr : boolean;
      variable base : std_logic_vector(26 downto 0);
   begin
      if G_PULSE then pulse <= '1'; end if;
      wait for 200 ns;
      for n in 1 to 20000 loop
         uniform(s1, s2, r);
         -- addresses: mostly a small working set (hits), sometimes anywhere in the window
         if r < 0.7 then
            uniform(s1, s2, r); a := integer(r * 255.0);
         else
            uniform(s1, s2, r); a := integer(r * 32767.0);
         end if;
         uniform(s1, s2, r);
         if r < 0.5 then base := std_logic_vector(to_unsigned(16#0900000#, 27));
         else            base := std_logic_vector(to_unsigned(16#7FF8000#, 27)); end if;
         w := a + 32768 * to_integer(unsigned(base(26 downto 26)));
         addr <= std_logic_vector(unsigned(base) + a);
         uniform(s1, s2, r);
         we <= '0'; uds_n <= '0'; lds_n <= '0';
         iswr := r < 0.4;
         if iswr then
            we <= '1';
            uniform(s1, s2, r);
            d := std_logic_vector(to_unsigned(integer(r * 65535.0), 16));
            wdata <= d;
            uniform(s1, s2, r);
            ua := '1'; la := '1';
            if r < 0.2 then la := '0'; elsif r < 0.4 then ua := '0'; end if;
            uds_n <= not ua; lds_n <= not la;
            if ua = '1' then ref(w)(15 downto 8) := d(15 downto 8); end if;
            if la = '1' then ref(w)(7 downto 0) := d(7 downto 0); end if;
            writes := writes + 1;
         end if;
         -- 68000 timing: a write drives the data bus and the byte strobes after the
         -- address strobe (S3/S4); a read asserts the strobes with /AS
         -- (TG68K: everything is valid with the request)
         if iswr and not G_PULSE then
            uds_n <= '1'; lds_n <= '1';
         end if;
         if not G_PULSE then
            wait until rising_edge(clk);
         end if;
         sel <= '1';
         if iswr and not G_PULSE then
            wdata <= x"DEAD";
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            wdata <= d;
            uds_n <= not ua; lds_n <= not la;
         end if;
         cyc := 0;
         loop
            wait until rising_edge(clk);
            cyc := cyc + 1;
            -- TG68K mode: every access needs two clocks at least, so ready at the first edge
            -- would be the previous access's (ready longer than one clock)
            assert not (G_PULSE and cyc = 1 and ready = '1')
               report "ready longer than one clock" severity failure;
            exit when ready = '1';
            assert cyc < 2000 report "timeout" severity failure;
         end loop;
         if not iswr then
            assert rdata = ref(w) report "read mismatch at word " & integer'image(w) &
               " got " & to_hstring(rdata) & " want " & to_hstring(ref(w)) severity failure;
            if cyc <= 3 then hits := hits + 1; else misses := misses + 1; end if;
            if cyc > maxc then maxc := cyc; end if;
         end if;
         if G_PULSE then
            -- the TG68K takes the data with the enable and presents its next request at
            -- once (here: 70 % back to back, else an internal cycle or two first)
            -- the CPU took the data with the edge that showed ready (sampled before the edge)
            uniform(s1, s2, r);
            if r > 0.7 then
               sel <= '0'; uds_n <= '1'; lds_n <= '1';
               wait until rising_edge(clk);
               if r > 0.85 then wait until rising_edge(clk); end if;
            end if;
         else
            sel <= '0'; uds_n <= '1'; lds_n <= '1';
            uniform(s1, s2, r);
            for i in 0 to 2 + integer(r * 12.0) loop wait until rising_edge(clk); end loop;
         end if;
      end loop;
      report "PASS: 20000 cycles, writes " & integer'image(writes) & ", read hits " &
         integer'image(hits) & ", read misses " & integer'image(misses) &
         ", slowest read " & integer'image(maxc) & " core clocks";
      done <= true;
      wait;
   end process;
end architecture sim;
