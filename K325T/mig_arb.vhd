--------------------------------------------------------------------------------
-- mig_arb.vhd -- two clients on one MIG 7-series native UI (A1200 study stage 2, condition C2):
--   client 0 = the "line port" (64-byte lines = 4 BL8 commands of 128 bits; the future chip-RAM
--              cache's fill / write-back engine, now the latency meter), PRIORITY;
--   client 1 = avm_mig (the M2M Avalon bus: ascal, QNICE, ADF, fast RAM).
-- All in the MIG ui_clk.  Rules kept:
--   * a write is data first, then its command (UG586: data may precede the command; avm_mig's rule);
--     the grant is locked from a client's accepted write-data word until its write command is
--     accepted, so data and command of different clients never pair up;
--   * read data comes back in command order: a 1-bit tag per accepted read command (FIFO) routes
--     app_rd_data_valid to the client that asked.
-- Grant: per command; client 0 whenever it has something to offer and client 1 is not locked.
--
-- Line port (client 0): lp_req with lp_we / lp_addr (app_addr units = 16-bit words, as avm_mig;
-- the 64-byte line's address) / lp_wdata (512 bits, word 0 = bytes 0..15); lp_busy is '1' from the
-- request until the line is done.  Reads: lp_addr bits 4..3 name the 16-byte word to fetch first
-- (critical word first; bits 2..0 ignored): the 4 commands go out as words c, c+1, c+2, c+3 (mod 4)
-- and the data arrives in that order as 4 x 128 bits on lp_rvalid / lp_rdata.  Writes: bits 4..0
-- ignored, word 0 first.  lp_done pulses with the last read word, or when the last write command
-- is accepted.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mig_arb is
   port (
      clk            : in  std_logic;
      rst            : in  std_logic;
      -- line port (client 0, priority)
      lp_req         : in  std_logic;
      lp_we          : in  std_logic;
      lp_addr        : in  std_logic_vector(27 downto 0);   -- 16-bit-word address (app_addr units)
      lp_wdata       : in  std_logic_vector(511 downto 0);
      lp_busy        : out std_logic;
      lp_rvalid      : out std_logic;
      lp_rdata       : out std_logic_vector(127 downto 0);
      lp_done        : out std_logic;
      -- client 1: avm_mig's UI side
      c1_app_addr    : in  std_logic_vector(27 downto 0);
      c1_app_cmd     : in  std_logic_vector(2 downto 0);
      c1_app_en      : in  std_logic;
      c1_app_rdy     : out std_logic;
      c1_wdf_data    : in  std_logic_vector(127 downto 0);
      c1_wdf_end     : in  std_logic;
      c1_wdf_wren    : in  std_logic;
      c1_wdf_mask    : in  std_logic_vector(15 downto 0);
      c1_wdf_rdy     : out std_logic;
      c1_rd_data     : out std_logic_vector(127 downto 0);
      c1_rd_valid    : out std_logic;
      -- MIG
      app_addr       : out std_logic_vector(27 downto 0);
      app_cmd        : out std_logic_vector(2 downto 0);
      app_en         : out std_logic;
      app_rdy        : in  std_logic;
      app_wdf_data   : out std_logic_vector(127 downto 0);
      app_wdf_end    : out std_logic;
      app_wdf_wren   : out std_logic;
      app_wdf_mask   : out std_logic_vector(15 downto 0);
      app_wdf_rdy    : in  std_logic;
      app_rd_data    : in  std_logic_vector(127 downto 0);
      app_rd_valid   : in  std_logic
   );
end entity mig_arb;

architecture rtl of mig_arb is
   constant CMD_WR : std_logic_vector(2 downto 0) := "000";
   constant CMD_RD : std_logic_vector(2 downto 0) := "001";

   -- line engine (client 0)
   type lst_t is (L_IDLE, L_RD, L_WR_DATA, L_WR_CMD, L_WAIT_RD);
   signal lst        : lst_t := L_IDLE;
   signal l_addr     : unsigned(27 downto 0) := (others => '0');
   signal l_wdata    : std_logic_vector(511 downto 0) := (others => '0');
   signal l_cmd_n    : unsigned(2 downto 0) := (others => '0');   -- commands issued (0..4)
   signal l_rd_n     : unsigned(2 downto 0) := (others => '0');   -- read words received
   signal l_offer_cmd, l_offer_dat : std_logic;
   signal l_cmd      : std_logic_vector(2 downto 0);

   -- grant: '1' = client 1 owns the UI (locked between its write data and its write command)
   signal lock1      : std_logic := '0';
   signal sel0       : std_logic;          -- this cycle the UI belongs to client 0

   -- read tags (FIFO of the owner of every accepted read command, in order)
   type tag_t is array (0 to 63) of std_logic;
   signal tags       : tag_t := (others => '0');
   signal t_wp, t_rp : unsigned(5 downto 0) := (others => '0');
begin
   lp_busy <= '0' when lst = L_IDLE else '1';

   l_offer_cmd <= '1' when lst = L_RD or lst = L_WR_CMD else '0';
   l_offer_dat <= '1' when lst = L_WR_DATA else '0';
   -- client 0 gets the UI unless client 1 is in the middle of a data/command pair
   sel0 <= '1' when lock1 = '0' and (l_offer_cmd = '1' or l_offer_dat = '1') else '0';

   app_en       <= l_offer_cmd when sel0 = '1' else c1_app_en;
   l_cmd        <= CMD_RD when lst = L_RD else CMD_WR;
   app_cmd      <= l_cmd when sel0 = '1' else c1_app_cmd;
   app_addr     <= std_logic_vector(l_addr) when sel0 = '1' else c1_app_addr;
   app_wdf_wren <= l_offer_dat when sel0 = '1' else c1_wdf_wren;
   app_wdf_end  <= l_offer_dat when sel0 = '1' else c1_wdf_end;
   app_wdf_data <= l_wdata(127 downto 0) when sel0 = '1' else c1_wdf_data;
   app_wdf_mask <= (others => '0') when sel0 = '1' else c1_wdf_mask;
   c1_app_rdy   <= app_rdy when sel0 = '0' else '0';
   c1_wdf_rdy   <= app_wdf_rdy when sel0 = '0' else '0';

   -- read data routing
   c1_rd_data  <= app_rd_data;
   lp_rdata    <= app_rd_data;
   c1_rd_valid <= app_rd_valid when tags(to_integer(t_rp)) = '0' else '0';
   lp_rvalid   <= app_rd_valid when tags(to_integer(t_rp)) = '1' else '0';

   process (clk)
      variable ca : boolean;   -- client 0's command accepted
   begin
      if rising_edge(clk) then
         lp_done <= '0';
         if rst = '1' then
            lst <= L_IDLE; lock1 <= '0'; t_wp <= (others => '0'); t_rp <= (others => '0');
         else
            -- tags
            if app_en = '1' and app_rdy = '1' and
               ((sel0 = '1' and lst = L_RD) or (sel0 = '0' and c1_app_cmd = CMD_RD)) then
               tags(to_integer(t_wp)) <= sel0;
               t_wp <= t_wp + 1;
            end if;
            if app_rd_valid = '1' then
               t_rp <= t_rp + 1;
            end if;
            -- client 1's lock: from its accepted write data to its accepted write command
            if sel0 = '0' then
               if c1_wdf_wren = '1' and app_wdf_rdy = '1' then
                  lock1 <= '1';
               end if;
               if c1_app_en = '1' and app_rdy = '1' and c1_app_cmd = CMD_WR then
                  lock1 <= '0';
               end if;
            end if;
            -- line engine
            ca := sel0 = '1' and l_offer_cmd = '1' and app_rdy = '1';
            case lst is
               when L_IDLE =>
                  if lp_req = '1' then
                     if lp_we = '1' then
                        l_addr <= unsigned(lp_addr(27 downto 5)) & "00000";
                     else
                        l_addr <= unsigned(lp_addr(27 downto 3)) & "000";   -- critical word first
                     end if;
                     l_wdata <= lp_wdata;
                     l_cmd_n <= (others => '0');
                     l_rd_n  <= (others => '0');
                     if lp_we = '1' then lst <= L_WR_DATA; else lst <= L_RD; end if;
                  end if;
               when L_RD =>
                  if ca then
                     l_addr(4 downto 3) <= l_addr(4 downto 3) + 1;          -- wraps inside the line
                     l_cmd_n <= l_cmd_n + 1;
                     if l_cmd_n = 3 then lst <= L_WAIT_RD; end if;
                  end if;
               when L_WR_DATA =>
                  if sel0 = '1' and app_wdf_rdy = '1' then
                     lst <= L_WR_CMD;
                  end if;
               when L_WR_CMD =>
                  if ca then
                     l_addr  <= l_addr + 8;
                     l_wdata <= x"00000000000000000000000000000000" & l_wdata(511 downto 128);
                     l_cmd_n <= l_cmd_n + 1;
                     if l_cmd_n = 3 then
                        lst <= L_IDLE; lp_done <= '1';
                     else
                        lst <= L_WR_DATA;
                     end if;
                  end if;
               when L_WAIT_RD =>
                  null;
            end case;
            if app_rd_valid = '1' and tags(to_integer(t_rp)) = '1' then
               l_rd_n <= l_rd_n + 1;
               if l_rd_n = 3 then
                  lst <= L_IDLE; lp_done <= '1';
               end if;
            end if;
         end if;
      end if;
   end process;
end architecture rtl;
