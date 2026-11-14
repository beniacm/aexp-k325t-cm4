--------------------------------------------------------------------------------
-- aud_hold.vhd -- K325T a1200-audrec 2 (debug): is the audio that ENTERS the HDMI encoder intact?
--
-- Watches, in the framework's audio clock (12.288 MHz), the sample pair the HDMI encoder takes
-- (av_pipeline audio_left_o / audio_right_o = digital_pipeline audio_left_i / _right_i = vga_to_hdmi
-- pcm_l / pcm_r, sampled at the encoder's own 48-kHz enable pcm_clken, exported by the framework's
-- M2M-UPSTREAM audio-probe ports) and the encoder's per-sample handshake (vga_to_hdmi pcm_hs_tog: one
-- toggle in the pixel clock per sample the packetiser takes).  Drives nothing: its only output is the
-- readout word (lat_meter rec2_i, indices $CC / $CD of the flight recorder's page; K325T/aud_rec.v).
--
-- (a) hold detector: a run = consecutive 48-kHz samples with L AND R both equal to the previous sample.
--     A run counts as an episode once it contains G_HOLD_SMP (100 ms) samples during which the
--     machine's mix was changing ("live": a toggle of aud_rec.v live_tog -- at most one per ms while L or
--     R of Paula's mixer changes -- seen within the last G_LIVE_CLK audio clocks = 10 ms).  A musical
--     pause (the mix constant too) is not live after 10 ms and never counts; a hold of the encoder input
--     while the mix plays does.  Kept: a sticky flag, the episode count, the longest episode (ms), the
--     longest run of any kind (ms) and the current run (ms).
-- (b) handshakes: the samples the packetiser took in the last full second (G_CLK_HZ audio clocks; must
--     read 48,000), the encoder's enables in the same second (48,000 by construction), and per enable
--     interval (20.8 us; the handshake completes ~0.5 us after the enable) the number of samples taken:
--     0 = swallowed (vga_to_hdmi drops an enable that meets its acknowledge), > 1 = repeated.  Not judged
--     while the framework's audio reset (vga_to_hdmi pcm_rst) is active nor in the first interval after it.
-- Everything is cleared by the recorder's arm command (index $CF with r3 = $A, decoded here from the
-- bridge byte as aud_rec.v does), nothing by a machine reset; power-up = armed.
--
-- Readout (quasi-static: the tools read a word twice until both reads agree):
--   $CC W0 = $A0D (12) | flag | live now | episode now | handshake check active | episodes (16)
--       W1 = longest episode, ms (16) | longest constant run of any kind, ms (16)
--       W2 = samples taken by the packetiser in the last full second (32)
--   $CD W0 = swallowed enables (16) | repeated samples (16)          (saturating)
--       W1 = encoder enables (pcm_clken) in the last full second (32)
--       W2 = seconds since arm (16) | current constant run, ms (16)
-- word_o(95 downto 0) = $CC, word_o(191 downto 96) = $CD.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aud_hold is
   generic (
      G_CLK_HZ   : natural := 12_288_000;   -- audio clock: one "second" of the handshake counts
      G_HOLD_SMP : natural := 4_800;        -- 100 ms of live samples at 48 kHz
      G_LIVE_CLK : natural := 122_880       -- 10 ms of audio clocks after the last heartbeat toggle
   );
   port (
      clk_i      : in  std_logic;                       -- the framework's audio clock
      rst_i      : in  std_logic;                       -- the framework's audio reset (handshake checks off)
      clken_i    : in  std_logic;                       -- the encoder's 48-kHz enable (same clock)
      pcm_l_i    : in  std_logic_vector(15 downto 0);   -- the encoder's input (same clock)
      pcm_r_i    : in  std_logic_vector(15 downto 0);
      hs_tog_i   : in  std_logic;                       -- asynchronous (pixel clock): a toggle per sample taken
      live_tog_i : in  std_logic;                       -- asynchronous (machine clock): the mix heartbeat
      cfg_i      : in  std_logic_vector(7 downto 0);    -- asynchronous: the bridge configuration byte
      word_o     : out std_logic_vector(191 downto 0)   -- readout ($CD & $CC), audio clock, quasi-static
   );
end entity aud_hold;

architecture rtl of aud_hold is
   signal cfg_s1, cfg_s2, cfg_s3 : std_logic_vector(7 downto 0) := (others => '0');
   signal lv_s1, lv_s2, lv_s3    : std_logic := '0';
   signal hs_s1, hs_s2, hs_s3    : std_logic := '0';
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of cfg_s1, cfg_s2, lv_s1, lv_s2, hs_s1, hs_s2 : signal is "TRUE";
   signal stable : unsigned(3 downto 0) := (others => '0');
   signal r3, r4, r5, r6 : std_logic_vector(3 downto 0) := (others => '0');
   signal arm_d  : std_logic := '0';

   signal live_age : natural range 0 to G_LIVE_CLK := G_LIVE_CLK;
   signal l_d, r_d : std_logic_vector(15 downto 0) := (others => '0');
   signal sub      : natural range 0 to 47 := 0;
   signal run_ms, longest, maxrun : unsigned(15 downto 0) := (others => '0');
   signal live_smp : natural range 0 to G_HOLD_SMP := 0;
   signal counted, flag : std_logic := '0';
   signal episodes : unsigned(15 downto 0) := (others => '0');

   signal primed   : std_logic := '0';
   signal nd       : unsigned(1 downto 0) := (others => '0');
   signal swallowed, repeated, secs : unsigned(15 downto 0) := (others => '0');
   signal sec_cnt  : natural range 0 to G_CLK_HZ - 1 := 0;
   signal hs_acc, ce_acc, hs_sec, ce_sec : unsigned(31 downto 0) := (others => '0');
begin
   process (clk_i)
      variable live, hs_ev, arm : boolean;
      variable n : unsigned(1 downto 0);
      variable lv : std_logic;
      variable hs_acc_n, ce_acc_n : unsigned(31 downto 0);
   begin
      if rising_edge(clk_i) then
         -- the bridge byte, as aud_rec.v / lat_meter.vhd decode it (page 7 registers r3..r5)
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
         arm := r4 = x"C" and r5 = x"F" and r3 = x"A";
         if arm then arm_d <= '1'; else arm_d <= '0'; end if;
         arm := arm and arm_d = '0';

         -- the two asynchronous toggles
         lv_s1 <= live_tog_i; lv_s2 <= lv_s1; lv_s3 <= lv_s2;
         hs_s1 <= hs_tog_i;   hs_s2 <= hs_s1; hs_s3 <= hs_s2;
         hs_ev := hs_s2 /= hs_s3;
         if lv_s2 /= lv_s3 then live_age <= 0;
         elsif live_age /= G_LIVE_CLK then live_age <= live_age + 1; end if;
         live := live_age < G_LIVE_CLK;
         if live then lv := '1'; else lv := '0'; end if;

         -- (a) the hold detector, at the encoder's sample enable
         if clken_i = '1' then
            l_d <= pcm_l_i; r_d <= pcm_r_i;
            if pcm_l_i = l_d and pcm_r_i = r_d then
               if sub = 47 then
                  sub <= 0;
                  if run_ms /= x"FFFF" then run_ms <= run_ms + 1; end if;
               else
                  sub <= sub + 1;
               end if;
               if live and live_smp /= G_HOLD_SMP then live_smp <= live_smp + 1; end if;
            else
               sub <= 0; run_ms <= (others => '0'); live_smp <= 0; counted <= '0';
            end if;
         end if;
         if counted = '0' and live_smp = G_HOLD_SMP then
            counted <= '1'; flag <= '1';
            if episodes /= x"FFFF" then episodes <= episodes + 1; end if;
         end if;
         if counted = '1' and run_ms > longest then longest <= run_ms; end if;
         if run_ms > maxrun then maxrun <= run_ms; end if;

         -- (b) handshakes: samples taken per enable interval and per second
         n := nd;
         if hs_ev and n /= 3 then n := n + 1; end if;
         if rst_i = '1' then
            primed <= '0'; nd <= (others => '0');
         elsif clken_i = '1' then
            if primed = '1' then
               if n = 0 then
                  if swallowed /= x"FFFF" then swallowed <= swallowed + 1; end if;
               elsif n > 1 then
                  if repeated < x"FFFE" then repeated <= repeated + resize(n - 1, 16);
                  else repeated <= x"FFFF"; end if;
               end if;
            end if;
            primed <= '1'; nd <= (others => '0');
         else
            nd <= n;
         end if;
         hs_acc_n := hs_acc; ce_acc_n := ce_acc;
         if hs_ev then hs_acc_n := hs_acc_n + 1; end if;
         if clken_i = '1' then ce_acc_n := ce_acc_n + 1; end if;
         if sec_cnt = G_CLK_HZ - 1 then
            sec_cnt <= 0;
            hs_sec  <= hs_acc_n; ce_sec <= ce_acc_n;
            hs_acc  <= (others => '0'); ce_acc <= (others => '0');
            if secs /= x"FFFF" then secs <= secs + 1; end if;
         else
            sec_cnt <= sec_cnt + 1;
            hs_acc  <= hs_acc_n; ce_acc <= ce_acc_n;
         end if;

         -- arm: everything from the start (the run in progress too)
         if arm then
            sub <= 0; run_ms <= (others => '0'); live_smp <= 0; counted <= '0'; flag <= '0';
            episodes <= (others => '0'); longest <= (others => '0'); maxrun <= (others => '0');
            primed <= '0'; nd <= (others => '0'); swallowed <= (others => '0'); repeated <= (others => '0');
            sec_cnt <= 0; hs_acc <= (others => '0'); ce_acc <= (others => '0');
            hs_sec <= (others => '0'); ce_sec <= (others => '0'); secs <= (others => '0');
         end if;

         -- readout
         word_o(95 downto 64)   <= x"A0D" & flag & lv & counted & primed &
                                   std_logic_vector(episodes);
         word_o(63 downto 32)   <= std_logic_vector(longest) & std_logic_vector(maxrun);
         word_o(31 downto 0)    <= std_logic_vector(hs_sec);
         word_o(191 downto 160) <= std_logic_vector(swallowed) & std_logic_vector(repeated);
         word_o(159 downto 128) <= std_logic_vector(ce_sec);
         word_o(127 downto 96)  <= std_logic_vector(secs) & std_logic_vector(run_ms);
      end if;
   end process;
end architecture rtl;
