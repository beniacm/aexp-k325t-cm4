--------------------------------------------------------------------------------
-- lat_meter.vhd -- latency of 64-byte line reads / writes on the MIG line port (mig_arb.vhd),
-- measured on the board with the rest of the system running (A1200 study stage 2, condition C2).
-- In the MIG ui_clk (100 MHz: 10 ns per tick).
--
-- Requests: line reads and / or writes at pseudo-random 64-byte-aligned addresses in a 1 MB test
-- area at byte 128 MB (word $4000000; nothing else uses DDR3 there), one at a time, with a random gap of
-- 0..1023 ticks between them.  Latency = ticks from the request (lp_req, the line port idle) to
-- lp_done (the last read word delivered / the last write command accepted).
-- Statistics per direction: count, min, max, sum, histogram of 64 bins x 4 ticks (40 ns; the last
-- bin collects everything >= 2.52 us).
--
-- Control and readout share the stall controller's register stream (the bridge's VIDEO byte,
-- 1rrrvvvv) and its STATUS window: when register 6 selects page 7 the top shows this meter's
-- aux_o instead of the stall monitor.  With page 7 selected:
--   register 3: b0 = run reads, b1 = run writes, b2 = clear (level: held clear), b3 = freeze
--   registers 4 / 5 (high / low nibble): index i: b6 = 0 reads, 1 writes; b5..0 = histogram bin
--   aux_o: W0 = histogram[i(6..0)], W1 = min(16) & max(16) and W2 = count, both of the direction
--          i(6); with i(7) = 1: W0 = sum(31..0), W1 = min & max, W2 = sum(47..32) (ticks);
--          i = $FF / $FE: the top's Avalon debug words dbg_i(95..0) / dbg_i(191..96);
--          i = $FD / $FC: the core's fast RAM debug words dbg2_i(191..96) / dbg2_i(95..0) (stage 3);
--          i = $FB: the core's memory mode and stall register read-back dbg2_i(287..192) (stage 3);
--          i = $E0-$E5: the core's result mailbox (Amiga $C0-$FF), longwords 3(i-$E0) .. +2;
--          i = $D0-$D6: the cache's prefetch counters of class i-$D0 (issued, useful, wasted)
-- (the stall injector's registers 3..5 are reused: keep the injector off while measuring)
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity lat_meter is
   generic (
      -- false (a1200-lxshell, the flash-size build): only the read-back words the validation tools
      -- use -- $FB (memory mode / topology, stallmon cache) and $E0-$E5 (the result mailbox, stallmon
      -- mbox: gates, cputime2) -- no latency measurement, no $FF..$FC / $D0-$D6 words (they read 0)
      G_FULL : boolean := true
   );
   port (
      clk        : in  std_logic;               -- MIG ui_clk
      rst        : in  std_logic;
      cfg_i      : in  std_logic_vector(7 downto 0);   -- bridge VIDEO byte (asynchronous)
      page7_o    : out std_logic;               -- register 6 selects page 7
      aux_o      : out std_logic_vector(95 downto 0);
      dbg_i      : in  std_logic_vector(191 downto 0) := (others => '0');   -- index $FF / $FE
      dbg2_i     : in  std_logic_vector(287 downto 0) := (others => '0');   -- index $FD..$FB (async)
      mbox_i     : in  std_logic_vector(511 downto 0) := (others => '0');   -- index $E0-$E5 (async)
      pf_i       : in  std_logic_vector(671 downto 0) := (others => '0');   -- index $D0-$D6 (async)
      lp_req     : out std_logic;
      lp_we      : out std_logic;
      lp_addr    : out std_logic_vector(27 downto 0);
      lp_wdata   : out std_logic_vector(511 downto 0);
      lp_busy    : in  std_logic;
      lp_done    : in  std_logic
   );
end entity lat_meter;

architecture rtl of lat_meter is
   signal cfg_s1, cfg_s2, cfg_s3 : std_logic_vector(7 downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of cfg_s1, cfg_s2 : signal is "TRUE";
   signal stable : unsigned(3 downto 0) := (others => '0');
   signal r3, r4, r5 : std_logic_vector(3 downto 0) := (others => '0');
   signal r6 : std_logic_vector(3 downto 0) := (others => '0');

   signal rnd   : unsigned(31 downto 0) := x"1234ABCD";
   signal gap   : unsigned(9 downto 0) := (others => '0');
   signal busy  : std_logic := '0';
   signal dir   : std_logic := '0';
   signal t     : unsigned(15 downto 0) := (others => '0');
   signal req   : std_logic := '0';

   type hist_t is array (0 to 127) of unsigned(31 downto 0);
   signal hist  : hist_t := (others => (others => '0'));
   type st2 is array (0 to 1) of unsigned(15 downto 0);
   signal mn    : st2 := (others => (others => '1'));
   signal mx    : st2 := (others => (others => '0'));
   type c2 is array (0 to 1) of unsigned(31 downto 0);
   signal cnt   : c2 := (others => (others => '0'));
   type s2 is array (0 to 1) of unsigned(47 downto 0);
   signal sum   : s2 := (others => (others => '0'));
   signal aux   : std_logic_vector(95 downto 0) := (others => '0');
   signal hidx  : unsigned(7 downto 0);
begin
   page7_o <= '1' when r6(2 downto 0) = "111" else '0';
   aux_o   <= aux;
   lp_req  <= req;
   lp_we   <= dir;
   g_wd : for i in 0 to 15 generate
      lp_wdata(32 * i + 31 downto 32 * i) <= std_logic_vector(rnd);
   end generate;
   hidx <= unsigned(r4 & r5);

   process (clk)
      variable x : unsigned(31 downto 0);
      variable d : integer range 0 to 1;
      variable b : integer range 0 to 63;
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

         x := rnd; x := x xor shift_left(x, 13); x := x xor shift_right(x, 17); x := x xor shift_left(x, 5);
         rnd <= x;

         req <= '0';
         if busy = '0' then
            if gap /= 0 then
               gap <= gap - 1;
            elsif G_FULL and lp_busy = '0' and r3(3) = '0' and (r3(0) = '1' or r3(1) = '1') then
               -- next request: direction alternates when both are enabled
               if r3(0) = '1' and r3(1) = '1' then dir <= rnd(20);
               elsif r3(1) = '1' then dir <= '1'; else dir <= '0'; end if;
               -- 16-bit-word address $4000000 (byte 128 MB) + a random line of a 1 MB area
               lp_addr <= "01000000" & std_logic_vector(rnd(13 downto 0)) & "000000";
               req  <= '1';
               busy <= '1';
               t    <= (others => '0');
            end if;
         else
            if t /= x"FFFF" then t <= t + 1; end if;
            if lp_done = '1' then
               busy <= '0';
               gap  <= rnd(25 downto 16);
               d := 0; if dir = '1' then d := 1; end if;
               if t + 1 < 252 then b := to_integer((t + 1) / 4); else b := 63; end if;
               hist(d * 64 + b) <= hist(d * 64 + b) + 1;
               cnt(d) <= cnt(d) + 1;
               sum(d) <= sum(d) + resize(t + 1, 48);
               if t + 1 < mn(d) then mn(d) <= t + 1; end if;
               if t + 1 > mx(d) then mx(d) <= t + 1; end if;
            end if;
         end if;
         if r3(2) = '1' or rst = '1' then
            hist <= (others => (others => '0'));
            mn <= (others => (others => '1')); mx <= (others => (others => '0'));
            cnt <= (others => (others => '0')); sum <= (others => (others => '0'));
         end if;

         d := 0; if hidx(6) = '1' then d := 1; end if;
         if not G_FULL and hidx /= x"FB" and hidx(7 downto 3) /= "11100" then
            aux <= (others => '0');
         elsif hidx(7 downto 3) = "11010" and hidx(2 downto 0) < 7 then
            -- the cache's prefetch counters of class i - $D0: issued, useful, wasted
            aux <= pf_i(96 * to_integer(hidx(2 downto 0)) + 95 downto 96 * to_integer(hidx(2 downto 0)));
         elsif hidx(7 downto 3) = "11100" and hidx(2 downto 0) < 6 then
            -- the core's mailbox: longword k = words 2k (high) and 2k+1; three per index
            for k in 0 to 2 loop
               if 3 * to_integer(hidx(2 downto 0)) + k < 16 then
                  aux(95 - 32 * k downto 64 - 32 * k) <=
                     mbox_i(32 * (3 * to_integer(hidx(2 downto 0)) + k) + 15 downto 32 * (3 * to_integer(hidx(2 downto 0)) + k)) &
                     mbox_i(32 * (3 * to_integer(hidx(2 downto 0)) + k) + 31 downto 32 * (3 * to_integer(hidx(2 downto 0)) + k) + 16);
               else
                  aux(95 - 32 * k downto 64 - 32 * k) <= (others => '0');
               end if;
            end loop;
         elsif hidx = x"FF" then
            aux <= dbg_i(95 downto 0);
         elsif hidx = x"FE" then
            aux <= dbg_i(191 downto 96);
         elsif hidx = x"FD" then
            aux <= dbg2_i(191 downto 96);
         elsif hidx = x"FC" then
            aux <= dbg2_i(95 downto 0);
         elsif hidx = x"FB" then
            aux <= dbg2_i(287 downto 192);
            if not G_FULL then
               aux(30) <= '1';          -- W2 b30: the lean meter (stallmon: lat / avm / fdbg not built)
            end if;
         elsif hidx(7) = '1' then
            aux <= std_logic_vector(sum(d)(31 downto 0)) & std_logic_vector(mn(d)) &
                   std_logic_vector(mx(d)) & x"0000" & std_logic_vector(sum(d)(47 downto 32));
         else
            aux <= std_logic_vector(hist(to_integer(hidx(6 downto 0)))) &
                   std_logic_vector(mn(d)) & std_logic_vector(mx(d)) & std_logic_vector(cnt(d));
         end if;
      end if;
   end process;
end architecture rtl;
