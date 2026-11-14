--------------------------------------------------------------------------------
-- fc_mbox.vhd -- the machine-clock side of the fast 68020's mailbox (K325T a1200-fastclk)
--
-- fc_cpu (cpu_clk) opens one request at a time: it toggles mb_req_i with the request fields stable
-- (address, write, word with UDS/LDS or an aligned longword, data) and keeps them until the answer.
-- This side replays the request on cpu_wrapper's CPU boundary exactly as a TG68K would issue it
-- (PORTING "The CPU boundary of cpu_wrapper"): a word as one access; a longword as two word
-- accesses with `longword` set, the high word first (so the chip-bus FSM merges an aligned chip-RAM
-- longword into one 32-bit AGA cycle, as for the stock 68EC020).  Each access is held until
-- cpu_wrapper's one-clock acknowledge (ext_ack_i).  A write is acknowledged as soon as it is captured
-- (posted: the next request crosses while the bus cycle runs; the chip bus, not the crossing, sets the
-- write rate); a read is acknowledged with its data.  One request is executed at a time, in order; a
-- request that arrives while one is executing waits (its fields stay stable until its acknowledge).
-- During a machine reset an open access simply waits (the chip-bus FSM answers after it).
--
-- Audio retrigger guard (a deliberate compatibility aid of the fast setting): when a DMACON write has
-- switched an audio channel's DMA off, a later DMACON write that switches the same channel on again is
-- held until G_RETRIG machine clocks (two raster lines) have passed since the off-write.  Paula's audio
-- state machine needs that long to return to idle and reload the sample pointer; replay routines wait
-- with fixed dbf loops that the fast CPU runs ~6x too fast (a retrigger was lost: silences in
-- Domination).  Per channel; other bits and other writes are not affected.  DMACON writes are
-- synchronous (fc_cpu), so the CPU simply waits; the cost is at most two lines per retrigger.
--
-- fc7: flush_i (machine clock) = the cold-boot window (main.vhd fc_flush: a cold reset -- a CPU-setting change,
-- an M2M reset -- while the CPU is held; cpu_wrapper's chip-bus FSM is in reset then, no access is under way).
-- While it is high no request is executed: an open one is abandoned (its acknowledge is given if it was still
-- owed), a request that arrives is acknowledged without a bus access, the retrigger guards are cleared.  So no
-- chip-bus access of the fast CPU survives a cold boot (before fc7 an open access waited for the chip bus and ran
-- after the reset -- in the stock setting not at all until the next change to fast, then as the first access).
-- fc_cpu is in reset throughout the window and takes such answers as orphans.  flush_i = '0': as before.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fc_mbox is
   generic (
      G_SYNC       : integer := 8;    -- machine clocks after an interrupt-register access before the answer:
                                      -- cpu_wrapper registers the chip IPL at ph2 (every 4 clocks) + 1
      G_RETRIG     : integer := 3632  -- audio retrigger guard: machine clocks an audio channel's DMA stays
                                      -- off before a DMACON write may switch it on again (2 PAL lines)
   );
   port (
      clk_i        : in  std_logic;                       -- main_clk (the machine clock)
      flush_i      : in  std_logic := '0';                -- fc7: the cold-boot window (see above)
      -- from fc_cpu (cpu_clk): toggle + fields stable while the request is open
      mb_req_i     : in  std_logic;
      mb_addr_i    : in  std_logic_vector(31 downto 0);
      mb_wr_i      : in  std_logic;
      mb_long_i    : in  std_logic;
      mb_sync_i    : in  std_logic;                       -- answer after the bus cycle + G_SYNC clocks
      mb_uds_n_i   : in  std_logic;
      mb_lds_n_i   : in  std_logic;
      mb_wdata_i   : in  std_logic_vector(31 downto 0);
      mb_ack_o     : out std_logic;                       -- toggles once per answer
      mb_rdata_o   : out std_logic_vector(31 downto 0);   -- stable from the toggle on
      -- to cpu_wrapper's external-CPU port
      ext_addr_o   : out std_logic_vector(31 downto 0);
      ext_state_o  : out std_logic_vector(1 downto 0);    -- 01 idle, 10 read, 11 write
      ext_dout_o   : out std_logic_vector(15 downto 0);
      ext_uds_n_o  : out std_logic;
      ext_lds_n_o  : out std_logic;
      ext_long_o   : out std_logic;
      ext_ack_i    : in  std_logic;
      ext_din_i    : in  std_logic_vector(15 downto 0)
   );
end entity fc_mbox;

architecture rtl of fc_mbox is
   signal req_s   : std_logic_vector(2 downto 0) := (others => '0');
   type st_t is (S_IDLE, S_GUARD, S_W1, S_W2, S_SYNC);
   type cnt_t is array (0 to 3) of integer range 0 to G_RETRIG;
   signal aud_off : cnt_t := (others => 0);          -- clocks left before channel i may be switched on
   signal st      : st_t := S_IDLE;
   signal ack_t   : std_logic := '0';
   signal a       : std_logic_vector(31 downto 0) := (others => '0');
   signal state   : std_logic_vector(1 downto 0) := "01";
   signal dout    : std_logic_vector(15 downto 0) := (others => '0');
   signal u, l, lg: std_logic := '1';
   signal rdata   : std_logic_vector(31 downto 0) := (others => '0');
   signal wlo     : std_logic_vector(15 downto 0) := (others => '0');
   signal pend    : std_logic := '0';
   signal wr      : std_logic := '0';
   signal sy      : std_logic := '0';
   signal scnt    : integer range 0 to 15 := 0;
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of req_s : signal is "TRUE";
begin
   process (clk_i) begin
      if rising_edge(clk_i) then
         req_s <= req_s(1 downto 0) & mb_req_i;
         for i in 0 to 3 loop
            if aud_off(i) /= 0 then aud_off(i) <= aud_off(i) - 1; end if;
         end loop;
         if (req_s(2) xor req_s(1)) = '1' then pend <= '1'; end if;
         case st is
            when S_IDLE =>
               state <= "01";
               if (req_s(2) xor req_s(1)) = '1' or pend = '1' then   -- fields stable until acknowledged
                  pend <= '0';
                  wr <= mb_wr_i;
                  sy <= mb_sync_i;
                  wlo <= mb_wdata_i(15 downto 0);
                  if mb_wr_i = '1' and mb_sync_i = '0' then ack_t <= not ack_t; end if;   -- a write is posted
                  a  <= mb_addr_i(31 downto 1) & '0';
                  lg <= mb_long_i;
                  if mb_long_i = '1' then
                     u <= '0'; l <= '0';
                     dout <= mb_wdata_i(31 downto 16);
                  else
                     u <= mb_uds_n_i; l <= mb_lds_n_i;
                     dout <= mb_wdata_i(15 downto 0);
                  end if;
                  state <= '1' & mb_wr_i;                  -- 10 read, 11 write
                  st <= S_W1;
                  -- DMACON ($DFF096) writes: audio channels switched off start their guard; a write that
                  -- switches a guarded channel on waits (state stays idle on the bus meanwhile)
                  if mb_wr_i = '1' and mb_long_i = '0' and mb_addr_i(23 downto 1) = "11011111111100001001011" then   -- $DFF096
                     if mb_wdata_i(15) = '0' then
                        for i in 0 to 3 loop
                           if mb_wdata_i(i) = '1' then aud_off(i) <= G_RETRIG; end if;
                        end loop;
                     else
                        for i in 0 to 3 loop
                           if mb_wdata_i(i) = '1' and aud_off(i) /= 0 then
                              state <= "01";
                              st <= S_GUARD;
                           end if;
                        end loop;
                     end if;
                  end if;
               end if;
            when S_GUARD =>                              -- the audio retrigger guard (see above)
               if (aud_off(0) = 0 or wlo(0) = '0') and (aud_off(1) = 0 or wlo(1) = '0') and
                  (aud_off(2) = 0 or wlo(2) = '0') and (aud_off(3) = 0 or wlo(3) = '0') then
                  state <= "11";
                  st <= S_W1;
               end if;
            when S_W1 =>
               if ext_ack_i = '1' then
                  if lg = '1' then
                     rdata(31 downto 16) <= ext_din_i;
                     a <= std_logic_vector(unsigned(a) + 2);
                     dout <= wlo;
                     st <= S_W2;
                  else
                     rdata <= x"0000" & ext_din_i;
                     state <= "01";
                     if sy = '1' then
                        scnt <= G_SYNC; st <= S_SYNC;
                     else
                        if wr = '0' then ack_t <= not ack_t; end if;
                        st <= S_IDLE;
                     end if;
                  end if;
               end if;
            when S_SYNC =>                                -- the new interrupt level reaches cpu_ipl
               if scnt = 0 then
                  ack_t <= not ack_t;
                  st <= S_IDLE;
               else
                  scnt <= scnt - 1;
               end if;
            when S_W2 =>
               if ext_ack_i = '1' then
                  rdata(15 downto 0) <= ext_din_i;
                  state <= "01";
                  if sy = '1' then
                     scnt <= G_SYNC; st <= S_SYNC;
                  else
                     if wr = '0' then ack_t <= not ack_t; end if;
                     st <= S_IDLE;
                  end if;
               end if;
         end case;
         -- fc7: the cold-boot window: nothing is executed, every request is answered once
         if flush_i = '1' then
            state <= "01";
            aud_off <= (others => 0);
            if st /= S_IDLE then
               if not (wr = '1' and sy = '0') then ack_t <= not ack_t; end if;   -- a posted write had its answer
               st <= S_IDLE;                         -- (pend keeps a request that arrived meanwhile)
            elsif (req_s(2) xor req_s(1)) = '1' or pend = '1' then
               pend  <= '0';
               ack_t <= not ack_t;
               st    <= S_IDLE;                      -- (the capture above is undone)
            end if;
         end if;
      end if;
   end process;

   ext_addr_o  <= a;
   ext_state_o <= state;
   ext_dout_o  <= dout;
   ext_uds_n_o <= u;
   ext_lds_n_o <= l;
   ext_long_o  <= lg;
   mb_ack_o    <= ack_t;
   mb_rdata_o  <= rdata;
end architecture rtl;
