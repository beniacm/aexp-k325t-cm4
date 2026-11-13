--------------------------------------------------------------------------------
-- hdd_spi.vhd -- the A1200 hard disk's link to the Linux module (K325T, branch a1200-ide), own code.
--
-- Gayle's IDE unit (MiSTer's ide.v) leaves the ATA command set to a host: on a command it raises
-- `request` and waits for the host to read the task file, fill or drain its sector buffer and write
-- the status through its mgmt port.  Here the host is `hddsrv` on the Linux module, reached over a
-- second SPI of its own (Radxa CM3: SPI0 M0), not over rk_bridge, so disk traffic never delays the
-- floppy, keyboard, mouse or menu.
--
--   SPI slave (fclk = the top's 162.7 MHz bridge clock; SCK oversampled, mode 0, MSB first; like
--   rk_bridge the next MISO bit leaves while the SCK edge is still in the first synchroniser stage,
--   so the link runs at 33 MHz)
--     -> commands into an engine (mclk = the Amiga's main clock, gated by the stall controller)
--        that performs the mgmt accesses on ide.v
--     <- results, the ide request, and a 16-sector buffer (one block RAM: SPI side in fclk, engine
--        side in mclk) between the two
--   att_o: '1' while ide.v requests something or an engine command has finished (the server
--          sleeps on its edge).
--
-- Protocol version 2 (x"A2").  One SPI transaction = CS low .. CS high, byte 0 = command; byte 1 of
-- every answer is x"A2" (fixed, so MISO never depends on the MOSI bit sampled on the same edge):
--   x"00" STATUS -> bytes 1..4: x"A2", flags {busy, done, att, coll, 0, req[2:0]}, result (hi, lo)
--   x"01" ACK    : clears done and coll
--   x"1a" REGRD  (a = mgmt address 0..15): engine reads mgmt register a into the result word
--   x"2a" REGWR  + bytes 1, 2 = the value (hi, lo): engine writes mgmt register a
--   x"30" PUT    + byte 1 = first sector s (0..15) + bytes 2..: words into the buffer from word
--                   256 s (word i = bytes 2i+2, 2i+3, high byte first); no engine; allowed while
--                   the engine runs (the host keeps PUT and COMMIT on different sectors)
--   x"31" COMMIT + byte 1 = s, byte 2 = n (1..16): engine writes n x 256 buffer words from sector s
--                   into ide.v's buffer at its pointer (mgmt address 15)
--   x"32" PTR0   : engine resets ide.v's buffer pointer (a read strobe on mgmt address 0)
--   x"40" FETCH  + s, n: engine reads n x 256 words of ide.v's buffer into the buffer from sector s
--   x"41" GET    + byte 1 = s, byte 2 dummy -> bytes 3..: the buffer words from sector s
-- An engine command is taken at the end of its last byte; busy until the engine has acknowledged,
-- then done (and att) until the next engine command.  An engine command sent while busy is ignored
-- and sets coll (sticky until ACK), so a host that batches commands learns that one was lost.
--
-- Clock domains: every crossing is a toggle handshake (request fclk -> mclk, acknowledge back) or a
-- slowly changing level (req, enable) through two flip-flops; the buffer is a dual-clock block RAM.
-- The engine moves only on main-clock edges, so a stalled Amiga clock delays a transfer and never
-- loses or repeats a word.  An Amiga reset (mrst_i) while the engine runs ends the command at once
-- (acknowledged, result x"DEAD"), so the host is never left waiting.  With enable_i low (IDE off in
-- the menu) the SPI side is held idle, MISO/att are not driven and no engine command can start.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hdd_spi is
   port (
      fclk_i        : in  std_logic;                       -- 162.7 MHz, free-running
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

   constant C_VERSION : std_logic_vector(7 downto 0) := x"A2";

   -- the 16-sector buffer: 4096 x 16, port A fclk (SPI), port B mclk (engine)
   type t_buf is array (0 to 4095) of std_logic_vector(15 downto 0);
   shared variable sbuf : t_buf;
   attribute ram_style : string;
   attribute ram_style of sbuf : variable is "block";
   signal a_addr   : unsigned(11 downto 0) := (others => '0');
   signal a_we     : std_logic := '0';
   signal a_din    : std_logic_vector(15 downto 0) := (others => '0');
   signal a_q      : std_logic_vector(15 downto 0) := (others => '0');
   signal b_addr   : unsigned(11 downto 0) := (others => '0');
   signal b_we     : std_logic := '0';
   signal b_din    : std_logic_vector(15 downto 0) := (others => '0');
   signal b_q      : std_logic_vector(15 downto 0) := (others => '0');

   -- fclk: SPI front end
   signal sck_s, mosi_s, cs_s : std_logic_vector(2 downto 0) := (others => '0');
   signal bitcnt   : unsigned(2 downto 0) := (others => '0');
   signal bytecnt  : unsigned(12 downto 0) := (others => '0');
   signal rx       : std_logic_vector(7 downto 0) := (others => '0');
   signal tx       : std_logic_vector(7 downto 0) := (others => '0');
   signal nxt      : std_logic_vector(7 downto 0) := (others => '0');   -- the byte after this one
   signal mbit     : std_logic := '0';                                  -- the bit after this one
   signal miso_r   : std_logic := '0';
   signal cmd      : std_logic_vector(7 downto 0) := (others => '0');
   signal wr_hi    : std_logic_vector(7 downto 0) := (others => '0');
   signal sbase    : unsigned(3 downto 0) := (others => '0');           -- PUT / GET first sector

   -- fclk: engine command register + handshake
   signal e_op     : std_logic_vector(2 downto 0) := (others => '0');  -- 1 REGRD 2 REGWR 3 COMMIT 4 PTR0 5 FETCH
   signal e_addr   : std_logic_vector(3 downto 0) := (others => '0');
   signal e_data   : std_logic_vector(15 downto 0) := (others => '0');  -- REGWR value / {s, n} of COMMIT, FETCH
   signal req_tgl  : std_logic := '0';
   signal ack_s    : std_logic_vector(2 downto 0) := (others => '0');
   signal busy     : std_logic := '0';
   signal done     : std_logic := '0';
   signal coll     : std_logic := '0';
   signal idereq_s1, idereq_s2 : std_logic_vector(2 downto 0) := (others => '0');
   signal en_s     : std_logic_vector(1 downto 0) := (others => '0');
   signal frst_s   : std_logic_vector(1 downto 0) := (others => '1');
   signal en       : std_logic;
   signal flags    : std_logic_vector(7 downto 0);

   -- mclk: engine
   signal req_m    : std_logic_vector(2 downto 0) := (others => '0');
   signal ack_tgl  : std_logic := '0';
   signal result   : std_logic_vector(15 downto 0) := (others => '0');
   type t_state is (S_IDLE, S_RD, S_WR, S_COMMIT, S_PTR0, S_FETCH, S_ACK);
   signal st       : t_state := S_IDLE;
   signal widx     : unsigned(12 downto 0) := (others => '0');          -- words moved
   signal wend     : unsigned(12 downto 0) := (others => '0');          -- n x 256
   signal phase    : unsigned(2 downto 0) := (others => '0');
   signal m_addr   : std_logic_vector(3 downto 0) := (others => '0');
   signal m_wr, m_rd : std_logic := '0';
   signal m_wdata  : std_logic_vector(15 downto 0) := (others => '0');

   function engine_cmd(c : std_logic_vector(7 downto 0)) return boolean is
   begin
      return c(7 downto 4) = x"1" or c(7 downto 4) = x"2" or c = x"31" or c = x"32" or c = x"40";
   end function;

   -- the length (bytes) after which an engine command is complete
   function engine_len(c : std_logic_vector(7 downto 0)) return integer is
   begin
      if c(7 downto 4) = x"2" or c = x"31" or c = x"40" then
         return 3;
      end if;
      return 1;
   end function;

begin

   ide_address_o   <= m_addr;
   ide_write_o     <= m_wr;
   ide_read_o      <= m_rd;
   ide_writedata_o <= m_wdata;

   ------------------------------------------------------------------ the buffer
   p_buf_a : process (fclk_i)
   begin
      if rising_edge(fclk_i) then
         if a_we = '1' then
            sbuf(to_integer(a_addr)) := a_din;
         end if;
         a_q <= sbuf(to_integer(a_addr));
      end if;
   end process p_buf_a;

   p_buf_b : process (mclk_i)
   begin
      if rising_edge(mclk_i) then
         if b_we = '1' then
            sbuf(to_integer(b_addr)) := b_din;
         end if;
         b_q <= sbuf(to_integer(b_addr));
      end if;
   end process p_buf_b;

   ------------------------------------------------------------------ fclk side
   flags <= busy & done & (done or idereq_s2(2) or idereq_s2(1) or idereq_s2(0)) & coll & '0' & idereq_s2;

   p_spi : process (fclk_i)
      variable rxb : std_logic_vector(7 downto 0);
      variable nb  : unsigned(12 downto 0);
      variable go  : boolean;
   begin
      if rising_edge(fclk_i) then
         sck_s  <= sck_s(1 downto 0) & spi_sck_i;
         mosi_s <= mosi_s(1 downto 0) & spi_mosi_i;
         cs_s   <= cs_s(1 downto 0) & spi_cs_n_i;
         ack_s  <= ack_s(1 downto 0) & ack_tgl;
         en_s      <= en_s(0) & enable_i;
         frst_s    <= frst_s(0) & frst_i;
         idereq_s1 <= ide_req_i;
         idereq_s2 <= idereq_s1;
         a_we      <= '0';

         if busy = '1' and ack_s(2) /= ack_s(1) then       -- engine finished
            busy <= '0';
            done <= '1';
         end if;

         -- the byte after the current one (bytecnt = the byte being received): byte 1 is fixed
         if bytecnt = 0 then
            nxt <= C_VERSION;
         elsif cmd = x"00" then
            case to_integer(bytecnt) is
               when 1      => nxt <= flags;
               when 2      => nxt <= result(15 downto 8);
               when 3      => nxt <= result(7 downto 0);
               when others => nxt <= x"00";
            end case;
         elsif cmd = x"41" and bytecnt >= 2 then           -- GET data from byte 3: word (n - 3) / 2
            if bytecnt(0) = '0' then
               nxt <= a_q(15 downto 8);                    -- next byte odd = high byte
            else
               nxt <= a_q(7 downto 0);
            end if;
         else
            nxt <= x"00";
         end if;
         -- the GET read address: the word of byte bytecnt + 1 (one block RAM clock + nxt ahead)
         if cmd = x"41" then
            a_addr <= (sbase & x"00") + resize((bytecnt - 2) / 2, 12);
         end if;
         -- early MISO: the bit after this edge, put out while the edge is in the first stage
         if bitcnt /= 7 then
            mbit <= tx(6);
         else
            mbit <= nxt(7);
         end if;

         if frst_s(1) = '1' or en = '0' then
            bitcnt  <= (others => '0');
            bytecnt <= (others => '0');
            tx      <= x"00";
            miso_r  <= '0';
            busy    <= '0';
            done    <= '0';
            coll    <= '0';
            cmd     <= x"FF";
         elsif cs_s(1) = '1' then                          -- deselected: ready for byte 0
            bitcnt  <= (others => '0');
            bytecnt <= (others => '0');
            tx      <= x"00";
            miso_r  <= '0';
         else
            if sck_s(1) = '0' and sck_s(0) = '1' then
               miso_r <= mbit;
            end if;
            if sck_s(2) = '0' and sck_s(1) = '1' then      -- rising edge: sample, then present the next bit
               rxb    := rx(6 downto 0) & mosi_s(1);
               rx     <= rxb;
               bitcnt <= bitcnt + 1;
               if bitcnt = 7 then                          -- a byte is complete
                  nb      := bytecnt + 1;
                  bytecnt <= nb;
                  tx      <= nxt;
                  miso_r  <= nxt(7);
                  go      := false;
                  if bytecnt = 0 then
                     cmd <= rxb;
                     if rxb = x"01" then
                        done <= '0';
                        coll <= '0';
                     end if;
                     if engine_cmd(rxb) and engine_len(rxb) = 1 then
                        go := true;
                        if rxb(7 downto 4) = x"1" then
                           e_op <= "001"; e_addr <= rxb(3 downto 0);
                        else
                           e_op <= "100";                  -- PTR0
                        end if;
                     end if;
                  else
                     if bytecnt = 1 then
                        wr_hi <= rxb;
                        sbase <= unsigned(rxb(3 downto 0));
                     end if;
                     if engine_cmd(cmd) and bytecnt = 2 then
                        go := true;
                        e_data <= wr_hi & rxb;
                        if cmd(7 downto 4) = x"2" then
                           e_op <= "010"; e_addr <= cmd(3 downto 0);
                        elsif cmd = x"31" then
                           e_op <= "011";
                        else
                           e_op <= "101";                  -- FETCH
                        end if;
                     end if;
                     if cmd = x"30" and bytecnt >= 2 then  -- PUT data
                        if bytecnt(0) = '0' then
                           wr_hi <= rxb;
                        else
                           a_addr <= (sbase & x"00") + resize((bytecnt - 2) / 2, 12);
                           a_din  <= wr_hi & rxb;
                           a_we   <= '1';
                        end if;
                     end if;
                  end if;
                  if go then
                     if busy = '0' then
                        req_tgl <= not req_tgl; busy <= '1'; done <= '0';
                     else
                        coll <= '1';                       -- the engine is busy: command lost
                     end if;
                  end if;
               else
                  tx     <= tx(6 downto 0) & '0';
                  miso_r <= tx(6);
               end if;
            end if;
         end if;
      end if;
   end process p_spi;

   spi_miso_o    <= miso_r;
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
         b_we  <= '0';
         case st is
            when S_IDLE =>
               phase <= (others => '0');
               widx  <= (others => '0');
               -- COMMIT / FETCH: sector s = e_data(11:8), n = e_data(4:0) (1..16; 0 = 16)
               b_addr <= unsigned(e_data(11 downto 8)) & x"00";
               if e_data(4 downto 0) = "00000" or unsigned(e_data(4 downto 0)) > 16 then
                  wend <= to_unsigned(4096, 13);
               else
                  wend <= unsigned(e_data(4 downto 0)) & x"00";
               end if;
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

            -- n x 256 words into ide.v's buffer, 3 clocks per word: the block RAM word of b_addr
            -- (b_q, one clock after the address), write strobe one clock, low one clock (the
            -- falling strobe advances ide.v's pointer) while the next address is read
            when S_COMMIT =>
               if mrst_i = '1' then
                  result <= x"DEAD";
                  st     <= S_ACK;
               elsif phase = 0 then
                  phase <= "001";                          -- b_q follows b_addr
               elsif phase = 1 then
                  m_wdata <= b_q;
                  m_wr    <= '1';
                  phase   <= "010";
               else
                  phase  <= "000";
                  widx   <= widx + 1;
                  b_addr <= b_addr + 1;
                  if widx + 1 = wend then
                     result <= x"0000";
                     st     <= S_ACK;
                  end if;
               end if;

            -- n x 256 words out of ide.v's buffer: the word at the pointer appears on mgmt_readdata
            -- two clocks after the pointer moved (block RAM + output register); then a read strobe
            -- advances the pointer and the word goes into the block RAM
            when S_FETCH =>
               if mrst_i = '1' then
                  result <= x"DEAD";
                  st     <= S_ACK;
               else
                  phase <= phase + 1;
                  if phase = 3 then
                     b_din <= ide_readdata_i;
                     b_we  <= '1';
                     m_rd  <= '1';
                  elsif phase = 4 then
                     phase  <= "000";
                     widx   <= widx + 1;
                     b_addr <= b_addr + 1;
                     if widx + 1 = wend then
                        result <= x"0000";
                        st     <= S_ACK;
                     end if;
                  end if;
               end if;

            when S_ACK =>
               ack_tgl <= not ack_tgl;
               st      <= S_IDLE;
         end case;
      end if;
   end process p_engine;

end architecture rtl;
