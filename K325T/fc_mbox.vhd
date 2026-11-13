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
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fc_mbox is
   generic (
      G_SYNC       : integer := 8     -- machine clocks after an interrupt-register access before the answer:
                                      -- cpu_wrapper registers the chip IPL at ph2 (every 4 clocks) + 1
   );
   port (
      clk_i        : in  std_logic;                       -- main_clk (the machine clock)
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
   type st_t is (S_IDLE, S_W1, S_W2, S_SYNC);
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
