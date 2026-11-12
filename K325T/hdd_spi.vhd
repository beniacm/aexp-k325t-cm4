--------------------------------------------------------------------------------
-- hdd_spi.vhd -- the A1200 hard disk's link to the Linux module (K325T, branch a1200-ide), own code.
--
-- Gayle's IDE unit (MiSTer's ide.v) leaves the ATA command set to a host: on a command it raises
-- `request` and waits for the host to read the task file, fill or drain its sector buffer and write
-- the status through its mgmt port.  Here the host is `hddsrv` on the Linux module, reached over a
-- second SPI of its own (Radxa CM3: SPI0 M0), not over rk_bridge, so disk traffic never delays the
-- floppy, keyboard, mouse or menu.
--
--   SPI slave (fclk, the free-running 100 MHz MIG ui_clk; SCK oversampled, mode 0, MSB first)
--     -> commands into an engine (mclk = the Amiga's main clock, gated by the stall controller)
--        that performs the mgmt accesses on ide.v
--     <- results, the mailboxes (one sector each way, LUT RAM), the ide request
--   att_o: '1' while ide.v requests something or an engine command has finished (the server
--          sleeps on its edge).
--
-- One SPI transaction = CS low .. CS high, byte 0 = command:
--   x"00" STATUS -> bytes 1..4: x"A1" (version), flags {busy, done, att, 0, 0, req[2:0]},
--                   result word (hi, lo) of the last engine command
--   x"1a" REGRD  (a = mgmt address 0..15): engine reads mgmt register a into the result word
--   x"2a" REGWR  + bytes 1, 2 = the value (hi, lo): engine writes mgmt register a
--   x"30" PUT    + bytes 1..512: the sector into the inbound mailbox (word i = bytes 2i+1, 2i+2,
--                   high byte first); no engine
--   x"31" COMMIT : engine writes the inbound mailbox into ide.v's buffer (mgmt address 15, 256 words)
--   x"32" PTR0   : engine resets ide.v's buffer pointer (a read strobe on mgmt address 0)
--   x"40" FETCH  : engine reads 256 words of ide.v's buffer into the outbound mailbox
--   x"41" GET    -> bytes 1..512: the outbound mailbox
--   x"01" ACK    : clears done (att then follows the ide request alone)
-- An engine command is taken at the end of its last byte; busy until the engine has acknowledged,
-- then done (and att) until the next engine command.  Commands sent while busy are ignored (the host
-- polls STATUS / waits for att first).  Bytes beyond a command's length are ignored / answer 0.
--
-- Clock domains: every crossing is a toggle handshake (request fclk -> mclk, acknowledge back) or a
-- slowly changing level (req) through two flip-flops; the mailboxes are written in one domain and
-- read in the other only while the handshake keeps the writer idle.  The engine moves only on
-- main-clock edges, so a stalled Amiga clock delays a transfer and never loses or repeats a word.
-- An Amiga reset (mrst_i) while the engine runs ends the command at once (acknowledged, result
-- x"DEAD"), so the host is never left waiting.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hdd_spi is
   port (
      fclk_i        : in  std_logic;                       -- 100 MHz, free-running
      frst_i        : in  std_logic;
      enable_i      : in  std_logic;                       -- the menu's IDE bit (static; synchronised here)
      spi_sck_i     : in  std_logic;
      spi_mosi_i    : in  std_logic;
      spi_cs_n_i    : in  std_logic;
      spi_miso_o    : out std_logic;
      spi_miso_oe_o : out std_logic;                       -- drive MISO only while selected
      att_o         : out std_logic;

      mclk_i        : in  std_logic;                       -- the Amiga's main clock (gated)
      mrst_i        : in  std_logic;                       -- Amiga reset (ide.v's units reset too)
      ide_req_i     : in  std_logic_vector(2 downto 0);
      ide_address_o : out std_logic_vector(3 downto 0);
      ide_write_o   : out std_logic;
      ide_writedata_o : out std_logic_vector(15 downto 0);
      ide_read_o    : out std_logic;
      ide_readdata_i  : in  std_logic_vector(15 downto 0)
   );
end entity hdd_spi;

architecture rtl of hdd_spi is

   type t_mbox is array (0 to 255) of std_logic_vector(15 downto 0);
   signal mbox_in  : t_mbox;                               -- written in fclk (PUT), read in mclk
   signal mbox_out : t_mbox;                               -- written in mclk (FETCH), read in fclk
   attribute ram_style : string;
   attribute ram_style of mbox_in  : signal is "distributed";
   attribute ram_style of mbox_out : signal is "distributed";

   -- fclk: SPI front end
   signal sck_s, mosi_s, cs_s : std_logic_vector(2 downto 0) := (others => '0');
   signal bitcnt   : unsigned(2 downto 0) := (others => '0');
   signal bytecnt  : unsigned(9 downto 0) := (others => '0');
   signal rx       : std_logic_vector(7 downto 0) := (others => '0');
   signal tx       : std_logic_vector(7 downto 0) := (others => '0');
   signal cmd      : std_logic_vector(7 downto 0) := (others => '0');
   signal wr_hi    : std_logic_vector(7 downto 0) := (others => '0');

   -- fclk: engine command register + handshake
   signal e_op     : std_logic_vector(2 downto 0) := (others => '0');  -- 1 REGRD 2 REGWR 3 COMMIT 4 PTR0 5 FETCH
   signal e_addr   : std_logic_vector(3 downto 0) := (others => '0');
   signal e_data   : std_logic_vector(15 downto 0) := (others => '0');
   signal req_tgl  : std_logic := '0';
   signal ack_s    : std_logic_vector(2 downto 0) := (others => '0');
   signal busy     : std_logic := '0';
   signal done     : std_logic := '0';
   signal idereq_s1, idereq_s2 : std_logic_vector(2 downto 0) := (others => '0');
   signal en_s     : std_logic_vector(1 downto 0) := (others => '0');
   signal en       : std_logic;

   -- mclk: engine
   signal req_m    : std_logic_vector(2 downto 0) := (others => '0');
   signal ack_tgl  : std_logic := '0';
   signal result   : std_logic_vector(15 downto 0) := (others => '0');
   type t_state is (S_IDLE, S_RD, S_WR, S_COMMIT, S_PTR0, S_FETCH, S_ACK);
   signal st       : t_state := S_IDLE;
   signal widx     : unsigned(8 downto 0) := (others => '0');
   signal phase    : unsigned(2 downto 0) := (others => '0');
   signal m_addr   : std_logic_vector(3 downto 0) := (others => '0');
   signal m_wr, m_rd : std_logic := '0';
   signal m_wdata  : std_logic_vector(15 downto 0) := (others => '0');
   -- asynchronous mailbox reads by explicit address (one LUT RAM read port each)
   signal out_word : std_logic_vector(15 downto 0);
   signal in_word  : std_logic_vector(15 downto 0);

   -- the byte to send as byte n of command c (w = the outbound mailbox word for that byte)
   function txbyte(c : std_logic_vector(7 downto 0); n : unsigned(9 downto 0);
                   flags : std_logic_vector(7 downto 0); res : std_logic_vector(15 downto 0);
                   w : std_logic_vector(15 downto 0)) return std_logic_vector is
   begin
      if c = x"00" then
         case to_integer(n) is
            when 1      => return x"A1";
            when 2      => return flags;
            when 3      => return res(15 downto 8);
            when 4      => return res(7 downto 0);
            when others => return x"00";
         end case;
      elsif c = x"41" and n >= 1 and n <= 512 then
         if n(0) = '1' then
            return w(15 downto 8);
         else
            return w(7 downto 0);
         end if;
      end if;
      return x"00";
   end function;

begin

   ide_address_o   <= m_addr;
   ide_write_o     <= m_wr;
   ide_read_o      <= m_rd;
   ide_writedata_o <= m_wdata;

   ------------------------------------------------------------------ fclk side
   p_spi : process (fclk_i)
      variable rxb   : std_logic_vector(7 downto 0);
      variable flags : std_logic_vector(7 downto 0);
      variable nb    : unsigned(9 downto 0);
   begin
      if rising_edge(fclk_i) then
         sck_s  <= sck_s(1 downto 0) & spi_sck_i;
         mosi_s <= mosi_s(1 downto 0) & spi_mosi_i;
         cs_s   <= cs_s(1 downto 0) & spi_cs_n_i;
         ack_s  <= ack_s(1 downto 0) & ack_tgl;
         en_s      <= en_s(0) & enable_i;
         idereq_s1 <= ide_req_i;
         idereq_s2 <= idereq_s1;

         if busy = '1' and ack_s(2) /= ack_s(1) then       -- engine finished
            busy <= '0';
            done <= '1';
         end if;
         flags := busy & done & (done or (idereq_s2(2) or idereq_s2(1) or idereq_s2(0))) & "00" & idereq_s2;

         if frst_i = '1' or en = '0' then
            bitcnt  <= (others => '0');
            bytecnt <= (others => '0');
            tx      <= x"A1";
            busy    <= '0';
            done    <= '0';
         elsif cs_s(1) = '1' then                          -- deselected: ready for byte 0
            bitcnt  <= (others => '0');
            bytecnt <= (others => '0');
            tx      <= x"A1";                              -- byte 0 answers the version (sync)
         elsif sck_s(2) = '0' and sck_s(1) = '1' then      -- rising edge: sample, then present the next bit
            rxb    := rx(6 downto 0) & mosi_s(1);
            rx     <= rxb;
            bitcnt <= bitcnt + 1;
            if bitcnt = 7 then                             -- a byte is complete
               nb      := bytecnt + 1;
               bytecnt <= nb;
               if bytecnt = 0 then
                  cmd <= rxb;
                  tx  <= txbyte(rxb, nb, flags, result, out_word);
                  if rxb = x"01" then
                     done <= '0';
                  end if;
                  if busy = '0' then                       -- single-byte engine commands
                     if rxb(7 downto 4) = x"1" then
                        e_op <= "001"; e_addr <= rxb(3 downto 0);
                        req_tgl <= not req_tgl; busy <= '1'; done <= '0';
                     elsif rxb = x"31" then
                        e_op <= "011";
                        req_tgl <= not req_tgl; busy <= '1'; done <= '0';
                     elsif rxb = x"32" then
                        e_op <= "100";
                        req_tgl <= not req_tgl; busy <= '1'; done <= '0';
                     elsif rxb = x"40" then
                        e_op <= "101";
                        req_tgl <= not req_tgl; busy <= '1'; done <= '0';
                     end if;
                  end if;
               else
                  tx <= txbyte(cmd, nb, flags, result, out_word);
                  if cmd(7 downto 4) = x"2" then           -- REGWR
                     if bytecnt = 1 then
                        wr_hi <= rxb;
                     elsif bytecnt = 2 and busy = '0' then
                        e_op <= "010"; e_addr <= cmd(3 downto 0); e_data <= wr_hi & rxb;
                        req_tgl <= not req_tgl; busy <= '1'; done <= '0';
                     end if;
                  elsif cmd = x"30" and bytecnt <= 512 then -- PUT
                     if bytecnt(0) = '1' then
                        wr_hi <= rxb;
                     elsif busy = '0' or e_op /= "011" then
                        mbox_in(to_integer(bytecnt - 2) / 2) <= wr_hi & rxb;
                     end if;
                  end if;
               end if;
            else
               tx <= tx(6 downto 0) & '0';
            end if;
         end if;
      end if;
   end process p_spi;

   -- for the byte after byte bytecnt: word (bytecnt + 1 - 1) / 2 = bytecnt / 2 of the GET data
   out_word      <= mbox_out(to_integer(bytecnt(8 downto 1)));
   in_word       <= mbox_in(to_integer(widx(7 downto 0)));
   spi_miso_o    <= tx(7);
   en            <= en_s(1);
   spi_miso_oe_o <= en and not cs_s(1);
   att_o         <= en and (done or idereq_s2(2) or idereq_s2(1) or idereq_s2(0));

   ------------------------------------------------------------------ mclk side: the engine
   p_engine : process (mclk_i)
   begin
      if rising_edge(mclk_i) then
         req_m <= req_m(1 downto 0) & req_tgl;
         m_wr  <= '0';
         m_rd  <= '0';
         case st is
            when S_IDLE =>
               phase <= (others => '0');
               widx  <= (others => '0');
               if req_m(2) /= req_m(1) then
                  if mrst_i = '1' then
                     result <= x"DEAD";
                     st     <= S_ACK;
                  else
                     case e_op is
                        when "001"  => m_addr <= e_addr; st <= S_RD;
                        when "010"  => m_addr <= e_addr; m_wdata <= e_data; st <= S_WR;
                        when "011"  => m_addr <= x"F"; st <= S_COMMIT;
                        when "100"  => m_addr <= x"0"; st <= S_PTR0;
                        when others => m_addr <= x"F"; st <= S_FETCH;
                     end case;
                  end if;
               end if;

            -- register read: mgmt_readdata follows mgmt_address (registered); no read strobe, so
            -- the buffer pointer stays where it is (PTR0 resets it explicitly)
            when S_RD =>
               phase <= phase + 1;
               if phase = 3 then
                  result <= ide_readdata_i;
                  st     <= S_ACK;
               end if;

            when S_WR =>
               phase <= phase + 1;
               if phase = 0 then
                  m_wr <= '1';
               elsif phase = 2 then
                  result <= x"0000";
                  st     <= S_ACK;
               end if;

            when S_PTR0 =>
               phase <= phase + 1;
               if phase = 0 then
                  m_rd <= '1';
               elsif phase = 2 then
                  st <= S_ACK;
               end if;

            -- 256 words into the buffer: write strobe one clock (ide.v writes the word at its
            -- pointer), low one clock (the falling strobe advances the pointer)
            when S_COMMIT =>
               if mrst_i = '1' then
                  result <= x"DEAD";
                  st     <= S_ACK;
               elsif phase = 0 then
                  m_wdata <= in_word;
                  phase   <= "001";
               elsif phase = 1 then
                  m_wr  <= '1';
                  phase <= "010";
               else
                  phase <= "000";
                  if widx = 255 then
                     result <= x"0000";
                     st     <= S_ACK;
                  end if;
                  widx <= widx + 1;
               end if;

            -- 256 words out of the buffer: the word at the pointer appears on mgmt_readdata two
            -- clocks after the pointer moved (block RAM + output register); then a read strobe
            -- advances the pointer
            when S_FETCH =>
               if mrst_i = '1' then
                  result <= x"DEAD";
                  st     <= S_ACK;
               else
                  phase <= phase + 1;
                  if phase = 3 then
                     mbox_out(to_integer(widx(7 downto 0))) <= ide_readdata_i;
                     m_rd <= '1';
                  elsif phase = 4 then
                     phase <= "000";
                     if widx = 255 then
                        result <= x"0000";
                        st     <= S_ACK;
                     end if;
                     widx <= widx + 1;
                  end if;
               end if;

            when S_ACK =>
               ack_tgl <= not ack_tgl;
               st      <= S_IDLE;
         end case;
      end if;
   end process p_engine;

end architecture rtl;
