--------------------------------------------------------------------------------
-- fc_cen.vhd -- the fast 68020's census counters for the board (K325T a1200-fc8, debug builds only: FCCEN=1)
--
-- The bench census of K325T/sim/aga/fc_census.h in hardware.  Every clock of fc_cpu (cpu_clk) goes into exactly one
-- category, classified from fc_cpu's census probe (fc_cpu G_CENSUS, cen_o) registered one clock earlier:
--   slot  0 total clocks          1 instructions (decodeOPC with the kernel's clkena_lw)
--   slots 2-27 = fc_census.h's categories in its order: fetch_lb fetch_arr read store internal stop lookup_i lookup_d
--         ifill_fast ifill_rom ifill_chip dfill_fast dfill_rom qfull_fr qfull_mb drain_fr drain_mb mbrd_chip
--         mbrd_custom mbrd_cia mbrd_other sync_custom sync_cia guard mbpre reset
--   slot 28 polling: a data read of one of the last 4 data-read addresses, with no store since that earlier read and at
--           most 4095 clocks after it, counts the clocks since then (not counted twice) -- the bench's spin rule
--           (48 requests back, no store between) approximated with 4 addresses and a clock window
--   slot 29 clocks with the SR interrupt mask above 0      slot 30 b47-40 the options in use, b39-0 snapshot number
--   slot 31 b47-32 $FCCE (magic), b31-24 version 1, b23-0 0
-- 48-bit counters, free-running from the FPGA configuration (never reset by the machine).
-- Readout: the stall controller's page 7 (the bridge's VIDEO byte 1rrrvvvv, decoded here as lat_meter.vhd does it):
-- register 6 = 7 selects the page; the index r4 & r5 = $D8..$DF gives slots 2i, 2i+1 (i = index - $D8) and $E8..$EF
-- slots 16 + 2i, 17 + 2i as the 96-bit status word (W0 = slot 2i bits 47..16, W1 = slot 2i bits 15..0 & slot 2i+1
-- bits 47..32, W2 = slot 2i+1 bits 31..0).  Selecting $D8 coming from any other index latches ALL counters at once
-- into the snapshot (coherent); the other indices read that snapshot.  (Free indices: lat_meter uses $FB-$FF, $E0-$E5,
-- $D0-$D6, the audio recorder $80-$CF.)
-- Options (fc_cpu opt_i) at run time: entering index $E8 from another index while register 3 = 8 + p sets preset p:
--   0 x"00" (fc7)   1 x"03" (I side)   2 x"0F" (I + D)   3 x"1F" (all: + long stores)   4 x"10" (long stores only)
--   5 x"13" (I side + long stores)   6, 7 x"00".  The preset stays until changed this way (power-up: G_OPT0 = fc7).
--   (The readout keeps register 3 at 0, so reading never changes the options.)  The options are safe to change at any
--   time (fc_cpu.vhd), but measure each setting from its own reset.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fc_cen is
   generic (
      G_OPT0 : std_logic_vector(7 downto 0) := x"00"
   );
   port (
      clk     : in  std_logic;                        -- cpu_clk
      pr_i    : in  std_logic_vector(127 downto 0);   -- fc_cpu cen_o (cpu_clk)
      guard_i : in  std_logic;                        -- fc_mbox: the retrigger guard holds (main_clk)
      cfg_i   : in  std_logic_vector(7 downto 0);     -- the bridge's VIDEO byte (asynchronous)
      word_o  : out std_logic_vector(95 downto 0);    -- the selected snapshot word (quasi-static)
      opt_o   : out std_logic_vector(7 downto 0)
   );
end entity fc_cen;

architecture rtl of fc_cen is
   constant NS : integer := 32;
   type cnt_t is array (0 to NS - 1) of unsigned(47 downto 0);
   signal cnt   : cnt_t := (others => (others => '0'));
   signal snap  : cnt_t := (others => (others => '0'));
   signal seq   : unsigned(39 downto 0) := (others => '0');
   signal pr    : std_logic_vector(127 downto 0) := (others => '0');
   signal g_s1, g_s2, guard : std_logic := '0';
   signal cfg_s1, cfg_s2, cfg_s3 : std_logic_vector(7 downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of cfg_s1, cfg_s2, g_s1, g_s2 : signal is "TRUE";
   signal stable : unsigned(3 downto 0) := (others => '0');
   signal r3, r4, r5, r6 : std_logic_vector(3 downto 0) := (others => '0');
   signal idx, idx_d : std_logic_vector(7 downto 0) := (others => '0');
   signal opt   : std_logic_vector(7 downto 0) := G_OPT0;
   signal word  : std_logic_vector(95 downto 0) := (others => '0');
   -- polling: the last 4 data-read addresses, the clock of their read, valid (no store since)
   type pa_t is array (0 to 3) of std_logic_vector(23 downto 0);
   type pt_t is array (0 to 3) of unsigned(47 downto 0);
   signal pl_a  : pa_t := (others => (others => '1'));
   signal pl_t  : pt_t := (others => (others => '0'));
   signal pl_v  : std_logic_vector(0 to 3) := (others => '0');
   signal pl_end : unsigned(47 downto 0) := (others => '0');   -- counted up to this clock

   -- address classes as fc_census.h: 0 chip 1 custom 2 cia 3 rom 4 fast 5 gayle 6 acfg 7 other
   function cls(a : std_logic_vector(23 downto 0)) return integer is
      variable u : unsigned(23 downto 0);
   begin
      u := unsigned(a);
      if u < x"200000" then return 0;
      elsif u < x"A00000" then return 4;
      elsif u < x"C00000" then return 2;
      elsif u >= x"DA0000" and u < x"DF0000" then return 5;
      elsif u < x"E00000" then return 1;
      elsif u < x"E80000" then return 3;
      elsif u < x"F00000" then return 6;
      elsif u >= x"F80000" then return 3;
      else return 7;
      end if;
   end function;
begin
   opt_o  <= opt;
   word_o <= word;

   process (clk)
      variable rq, ack, use_i, use_d, lbh, fill_i, fill_mb, q_full, sync_r, rst, stop, dec, clw, mbopen, imnz : std_logic;
      variable bs, dr : std_logic_vector(1 downto 0);
      variable st : integer range 0 to 7;
      variable ka, ma, fa : std_logic_vector(23 downto 0);
      variable e : integer range 0 to 27;
      variable fe, rd, wr : boolean;
      variable mc, i : integer;
      variable hk : integer range -1 to 3;
      variable from : unsigned(47 downto 0);
   begin
      if rising_edge(clk) then
         pr <= pr_i;
         g_s1 <= guard_i; g_s2 <= g_s1; guard <= g_s2;
         -- the probe of the last clock (fc_cpu.vhd cen_o)
         rq := pr(0); ack := pr(1); bs := pr(3 downto 2); st := to_integer(unsigned(pr(6 downto 4)));
         use_i := pr(7); use_d := pr(8); lbh := pr(9); fill_i := pr(10); fill_mb := pr(11); q_full := pr(12);
         dr := pr(14 downto 13); sync_r := pr(15); rst := pr(16); stop := pr(17); dec := pr(18); clw := pr(19);
         mbopen := pr(20); imnz := pr(21);
         ka := pr(55 downto 32); ma := pr(79 downto 56); fa := pr(103 downto 80);
         fe := bs = "00"; rd := bs = "10"; wr := bs = "11";
         mc := cls(ma);
         -- one category per clock (fc_census.h step())
         if rst = '1' then e := 27;
         elsif rq = '0' then
            if stop = '1' then e := 7; else e := 6; end if;
         elsif ack = '1' and st = 3 then
            if fill_i = '1' then
               if fill_mb = '0' then e := 10; elsif cls(fa) = 3 then e := 11; else e := 12; end if;
            else
               if fill_mb = '0' then e := 13; else e := 14; end if;
            end if;
         elsif ack = '1' and st = 7 then
            if sync_r = '1' then
               if mc = 2 then e := 24; else e := 23; end if;
            else
               if mc = 0 then e := 19; elsif mc = 1 then e := 20; elsif mc = 2 then e := 21; else e := 22; end if;
            end if;
         elsif ack = '1' then
            if fe then
               if lbh = '1' then e := 2; else e := 3; end if;
            elsif rd then e := 4;
            else e := 5;
            end if;
         else
            case st is
               when 0 =>
                  if use_i = '1' then e := 8;
                  elsif use_d = '1' then e := 9;
                  elsif wr and q_full = '1' then
                     if dr = "11" then e := 16; else e := 15; end if;
                  else e := 26;
                  end if;
               when 1 | 4 =>
                  if dr = "11" or (dr = "00" and mbopen = '1') then e := 18; else e := 17; end if;
               when 2 =>
                  if fill_i = '1' then
                     if fill_mb = '0' then e := 10; elsif cls(fa) = 3 then e := 11; else e := 12; end if;
                  else
                     if fill_mb = '0' then e := 13; else e := 14; end if;
                  end if;
               when 5 | 6 =>
                  if sync_r = '1' then
                     if guard = '1' then e := 25; elsif mc = 2 then e := 24; else e := 23; end if;
                  else
                     if mc = 0 then e := 19; elsif mc = 1 then e := 20; elsif mc = 2 then e := 21; else e := 22; end if;
                  end if;
               when others => e := 26;
            end case;
         end if;
         cnt(0) <= cnt(0) + 1;
         if dec = '1' and clw = '1' then cnt(1) <= cnt(1) + 1; end if;
         for k in 2 to 27 loop
            if e = k then cnt(k) <= cnt(k) + 1; end if;
         end loop;
         if imnz = '1' then cnt(29) <= cnt(29) + 1; end if;
         -- polling (slot 28); cnt(0) is the clock number of the probed clock
         if rq = '1' and ack = '1' and rst = '0' then
            if rd then
               hk := -1;
               for k in 0 to 3 loop
                  if pl_v(k) = '1' and pl_a(k) = ka and cnt(0) - pl_t(k) <= 4095 then hk := k; end if;
               end loop;
               if hk >= 0 then
                  if pl_t(hk) > pl_end then from := pl_t(hk); else from := pl_end; end if;
                  cnt(28) <= cnt(28) + (cnt(0) - from);
                  pl_end <= cnt(0);
               end if;
               -- this read goes to the front (its entry moves up if it was there)
               pl_a(0) <= ka; pl_t(0) <= cnt(0); pl_v(0) <= '1';
               for k in 1 to 3 loop
                  if hk < 0 or k <= hk then
                     pl_a(k) <= pl_a(k - 1); pl_t(k) <= pl_t(k - 1); pl_v(k) <= pl_v(k - 1);
                  end if;
               end loop;
            elsif wr then
               pl_v <= (others => '0');
            end if;
         end if;

         -- page 7 registers (lat_meter.vhd's decode of the bridge byte)
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
         -- $D8 entered: the snapshot of all counters
         if r6(2 downto 0) = "111" and idx = x"D8" and idx_d /= x"D8" then
            snap <= cnt;
            snap(30) <= unsigned(opt) & (seq + 1);
            snap(31) <= x"FCCE" & x"01" & x"000000";
            seq <= seq + 1;
         end if;
         -- the options: $E8 entered with register 3 = 8 + preset (the readout never does that: it keeps r3 = 0)
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
         -- the selected word
         i := to_integer(unsigned(idx(2 downto 0)));
         if idx(7 downto 3) = "11011" then
            word <= std_logic_vector(snap(2 * i)) & std_logic_vector(snap(2 * i + 1));
         elsif idx(7 downto 3) = "11101" then
            word <= std_logic_vector(snap(16 + 2 * i)) & std_logic_vector(snap(17 + 2 * i));
         else
            word <= (others => '0');
         end if;
      end if;
   end process;
end architecture rtl;
