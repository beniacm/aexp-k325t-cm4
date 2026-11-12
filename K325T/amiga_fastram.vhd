--------------------------------------------------------------------------------
-- amiga_fastram.vhd -- Zorro II fast RAM (2/4/8 MB) for the 68000 in DDR3
-- (K325T phase 2; AExp port to the QMTech XC7K325T).
--
-- The 68000 (fx68k) reaches fast RAM through cpu_wrapper.v's "ramsel" path, as on
-- MiSTer: while the bus cycle addresses autoconfigured fast RAM, the chip bus sees no
-- address strobe and /DTACK comes from ready_o.  Like a real fast RAM card the memory
-- may insert wait states; it never touches the chip bus (cycle timing of chip RAM,
-- custom chips and DMA is unchanged).
--
-- Cache: 16 KB, direct mapped, 1024 lines of 16 bytes, write-through, distributed RAM
-- (no block RAM is left).  Tags live in the core clock domain (clk_i); the data array
-- is written in the memory clock domain (hr_clk_i: line fills and CPU writes) and read
-- asynchronously in the core clock domain.  A read hit answers 2 core clocks after the
-- data strobe (no wait state for the 68000); a miss fills the line with one 8-word
-- burst.  Writes are posted: /DTACK at once, the next fast-RAM access waits until the
-- write (DDR3 + cache) is done.  Only the CPU accesses fast RAM, so the cache is always
-- coherent with DDR3 (and with itself across Amiga resets).
--
-- Clock crossing: one request at a time; the core side holds the request registers
-- (m_req_*) stable and flips m_req_tgl, the memory side flips hr_ack_tgl when done.
-- A memory-side reset (M2M reset) aborts and repeats the request, never acknowledges it.
-- The constraints for these paths are in qmtech_k325t_cm4.xdc (amiga_fastram).
--
-- K325T stage 3 (fast RAM reset fix, 2026-11-12): rst_i = the M2M resets in clk_i.  An access the
-- reset interrupts is completed on the memory side (a posted write must reach DDR3: completed CPU
-- writes survive a reset, as fast RAM contents do on a real machine; a fill is completed too, so
-- the toggle handshake always ends in a defined idle on both sides), but its result is not handed
-- to the CPU after the reset (m_orphan).  The cache is write-through (lines are always clean), so
-- keeping the lines across the reset is correct.  dbg_o: state and counters for stallmon fdbg.
-- (The hang this belongs to was the hr_core select in mega65.vhd p_fast_sel; see PORTING.)
-- K325T, 68020: the address is the DDR3 word address (the parent maps the Zorro II/III
-- windows, up to 256 MB); with pulse_i = '1' (the TG68K runs) ready_o is high for exactly
-- one clock per access (the TG68K's clock enable) and an access starts on sel_i alone; with
-- pulse_i = '0' (fx68k) it is the 68000's /DTACK as before (held until sel_i drops).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amiga_fastram is
   port (
      -- core clock domain (28 MHz, cpu_wrapper)
      clk_i              : in  std_logic;
      sel_i              : in  std_logic;                      -- ramsel: fast RAM bus cycle
      pulse_i            : in  std_logic := '0';               -- 1 = TG68K handshake (see above)
      addr_i             : in  std_logic_vector(26 downto 0);  -- DDR3 word address
      we_i               : in  std_logic;                      -- 1 = write
      uds_n_i            : in  std_logic;                      -- upper byte (15:8), active low
      lds_n_i            : in  std_logic;                      -- lower byte (7:0), active low
      wdata_i            : in  std_logic_vector(15 downto 0);
      rdata_o            : out std_logic_vector(15 downto 0);
      ready_o            : out std_logic;                      -- /DTACK (inverted), held until sel_i drops
      rst_i              : in  std_logic := '0';               -- M2M resets (clk_i): orphan the access
      dbg_o              : out std_logic_vector(143 downto 0); -- stallmon fdbg (asynchronous)

      -- memory clock domain (MIG ui_clk), Avalon-MM master (16-bit words, word addresses)
      hr_clk_i           : in  std_logic;
      hr_rst_i           : in  std_logic;
      avm_write_o        : out std_logic;
      avm_read_o         : out std_logic;
      avm_address_o      : out std_logic_vector(31 downto 0);
      avm_writedata_o    : out std_logic_vector(15 downto 0);
      avm_byteenable_o   : out std_logic_vector(1 downto 0);
      avm_burstcount_o   : out std_logic_vector(7 downto 0);
      avm_readdata_i     : in  std_logic_vector(15 downto 0);
      avm_readdatavalid_i: in  std_logic;
      avm_waitrequest_i  : in  std_logic
   );
end entity amiga_fastram;

architecture synthesis of amiga_fastram is

   -- data array: 8192 x 16 bit as two byte lanes (byte writes), written in hr_clk_i
   type t_lane is array (0 to 8191) of std_logic_vector(7 downto 0);
   signal dram_u : t_lane := (others => (others => '0'));
   signal dram_l : t_lane := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of dram_u : signal is "distributed";
   attribute ram_style of dram_l : signal is "distributed";

   -- tags: valid & addr(26:14), written in clk_i
   type t_tags is array (0 to 1023) of std_logic_vector(14 downto 0);
   signal tags : t_tags := (others => (others => '0'));
   attribute ram_style of tags : signal is "distributed";

   -- core side
   type t_mstate is (M_IDLE, M_READ, M_FILL, M_SERVED);
   signal m_state      : t_mstate := M_IDLE;
   signal m_req_tgl    : std_logic := '0';
   signal m_req_fill   : std_logic := '0';                         -- 1 = line fill, 0 = write
   signal m_req_hit    : std_logic := '0';                         -- write: update the cache line
   signal m_req_addr   : std_logic_vector(26 downto 0) := (others => '0');
   signal m_req_data   : std_logic_vector(15 downto 0) := (others => '0');
   signal m_req_be     : std_logic_vector(1 downto 0) := "00";
   signal m_ack_d      : std_logic := '0';
   signal m_ack_dd     : std_logic := '0';
   signal m_rd_addr    : std_logic_vector(12 downto 0) := (others => '0');
   signal m_start      : std_logic;
   signal m_rdata      : std_logic_vector(15 downto 0) := (others => '0');
   signal m_ready      : std_logic := '0';
   signal m_orphan     : std_logic := '0';                         -- the reset interrupted this access
   signal m_nreq       : unsigned(15 downto 0) := (others => '0'); -- debug: requests started
   signal m_dbg_in     : std_logic_vector(3 downto 0) := (others => '0'); -- debug: sel, we, pulse, fix
   attribute async_reg : string;
   attribute async_reg of m_ack_d  : signal is "true";
   attribute async_reg of m_ack_dd : signal is "true";

   signal tag_q        : std_logic_vector(14 downto 0);
   signal hit          : std_logic;
   signal busy         : std_logic;

   -- memory side
   type t_hstate is (H_QUIET, H_IDLE, H_FILL_CMD, H_FILL_DATA, H_WRITE_CMD);
   signal hr_state     : t_hstate := H_IDLE;
   signal hr_req_d     : std_logic := '0';
   signal hr_req_dd    : std_logic := '0';
   signal hr_ack_tgl   : std_logic := '0';
   attribute async_reg of hr_req_d  : signal is "true";
   attribute async_reg of hr_req_dd : signal is "true";
   signal hr_beat      : unsigned(2 downto 0) := (others => '0');
   signal hr_quiet     : unsigned(7 downto 0) := (others => '0');
   signal hr_line      : std_logic_vector(9 downto 0) := (others => '0');
   signal hr_we_u      : std_logic;
   signal hr_we_l      : std_logic;
   signal hr_waddr     : std_logic_vector(12 downto 0);
   signal hr_wdata     : std_logic_vector(15 downto 0);
   -- debug (memory side)
   signal hr_rst_d     : std_logic := '0';
   signal hr_nack      : unsigned(15 downto 0) := (others => '0');  -- acknowledges
   signal hr_nabort    : unsigned(7 downto 0) := (others => '0');   -- resets with a request open
   signal hr_nstray    : unsigned(7 downto 0) := (others => '0');   -- read beats outside H_FILL_DATA
   signal hr_age       : unsigned(15 downto 0) := (others => '0');  -- clocks in the current state
   signal hr_state_d   : t_hstate := H_IDLE;
   signal m_state_v    : std_logic_vector(1 downto 0);
   signal avm_rd       : std_logic := '0';
   signal avm_wr       : std_logic := '0';
   signal hr_state_v   : std_logic_vector(2 downto 0);

begin
   avm_read_o  <= avm_rd;
   avm_write_o <= avm_wr;

   ---------------------------------------------------------------------------
   -- core clock domain
   ---------------------------------------------------------------------------
   tag_q <= tags(to_integer(unsigned(addr_i(12 downto 3))));
   hit   <= '1' when tag_q = '1' & addr_i(26 downto 13) else '0';
   busy  <= m_req_tgl xor m_ack_dd;               -- the previous request is not done yet

   -- fx68k: start on a data strobe (see M_IDLE); TG68K: its bus request is complete with sel_i
   m_start <= sel_i and (pulse_i or not uds_n_i or not lds_n_i);

   rdata_o <= m_rdata;
   ready_o <= m_ready;

   core_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         m_ack_d  <= hr_ack_tgl;
         m_dbg_in <= sel_i & we_i & pulse_i & '1';
         m_ack_dd <= m_ack_d;
         -- the data array, read asynchronously (stable: written only for lines this side
         -- is not reading, or before the fill acknowledge arrives)
         m_rdata  <= dram_u(to_integer(unsigned(m_rd_addr))) & dram_l(to_integer(unsigned(m_rd_addr)));

         case m_state is
            when M_IDLE =>
               m_ready   <= '0';
               m_rd_addr <= addr_i(12 downto 0);
               -- start on a data strobe, not on the address strobe: in a 68000 write cycle
               -- /AS falls in S2 but the data bus is driven in S3 and /UDS,/LDS fall in S4
               -- (in a read cycle /AS and /DS fall together)
               if m_start = '1' and busy = '0' then
                  if we_i = '1' then
                     -- posted write: DDR3 and (on a hit) the cache line, in the memory domain
                     m_req_fill <= '0';
                     m_req_hit  <= hit;
                     m_req_addr <= addr_i;
                     m_req_data <= wdata_i;
                     m_req_be   <= (not uds_n_i) & (not lds_n_i);
                     m_req_tgl  <= not m_req_tgl;
                     m_nreq     <= m_nreq + 1;
                     m_ready    <= '1';
                     m_state    <= M_SERVED;
                  elsif hit = '1' then
                     m_state    <= M_READ;          -- m_rd_addr is valid from the next clock
                  else
                     m_req_fill <= '1';
                     m_req_hit  <= '0';
                     m_req_addr <= addr_i;
                     m_req_tgl  <= not m_req_tgl;
                     m_nreq     <= m_nreq + 1;
                     m_state    <= M_FILL;
                  end if;
               elsif m_start = '1' and pulse_i = '1' and we_i = '0' and hit = '1' and
                     m_req_fill = '0' and m_req_addr(12 downto 0) /= addr_i(12 downto 0) then
                  -- TG68K: a read hit need not wait for a posted write to another word (the
                  -- memory side writes only that word of the data array; tags do not change)
                  m_state <= M_READ;
               end if;

            when M_FILL =>
               if busy = '0' then                  -- the line is in the data array
                  tags(to_integer(unsigned(m_req_addr(12 downto 3)))) <= '1' & m_req_addr(26 downto 13);
                  if m_orphan = '1' then          -- the line is complete; nobody waits for it
                     m_orphan <= '0';
                     m_state  <= M_IDLE;
                  else
                     m_state <= M_READ;
                  end if;
               end if;

            when M_READ =>
               -- m_rdata is loaded at this edge from m_rd_addr
               m_state <= M_SERVED;
               m_ready <= '1';

            when M_SERVED =>
               -- fx68k: /DTACK until the strobes go; TG68K: one clock (it moves on with it)
               if sel_i = '0' or pulse_i = '1' then
                  m_ready <= '0';
                  m_state <= M_IDLE;
               end if;
         end case;

         -- an M2M reset: the access in flight is not answered after it (its memory side still
         -- completes); a read hit / an answer being presented is cancelled
         if rst_i = '1' then
            m_ready <= '0';
            if m_state = M_FILL then
               m_orphan <= '1';
            elsif m_state = M_READ or m_state = M_SERVED then
               m_state <= M_IDLE;
            end if;
         end if;
      end if;
   end process core_proc;

   ---------------------------------------------------------------------------
   -- memory clock domain
   ---------------------------------------------------------------------------
   hr_we_u  <= '1' when (hr_state = H_FILL_DATA and avm_readdatavalid_i = '1') or
                        (hr_state = H_WRITE_CMD and avm_waitrequest_i = '0' and m_req_hit = '1' and m_req_be(1) = '1')
               else '0';
   hr_we_l  <= '1' when (hr_state = H_FILL_DATA and avm_readdatavalid_i = '1') or
                        (hr_state = H_WRITE_CMD and avm_waitrequest_i = '0' and m_req_hit = '1' and m_req_be(0) = '1')
               else '0';
   hr_waddr <= hr_line & std_logic_vector(hr_beat) when hr_state = H_FILL_DATA else m_req_addr(12 downto 0);
   hr_wdata <= avm_readdata_i when hr_state = H_FILL_DATA else m_req_data;

   dram_proc : process (hr_clk_i)
   begin
      if rising_edge(hr_clk_i) then
         if hr_we_u = '1' then
            dram_u(to_integer(unsigned(hr_waddr))) <= hr_wdata(15 downto 8);
         end if;
         if hr_we_l = '1' then
            dram_l(to_integer(unsigned(hr_waddr))) <= hr_wdata(7 downto 0);
         end if;
      end if;
   end process dram_proc;

   mem_proc : process (hr_clk_i)
      variable word : unsigned(31 downto 0);
   begin
      if rising_edge(hr_clk_i) then
         hr_req_d  <= m_req_tgl;
         hr_req_dd <= hr_req_d;
         word := resize(unsigned(m_req_addr), 32);

         case hr_state is
            when H_QUIET =>                       -- after a reset: let stray beats of an
               avm_wr <= '0';                -- aborted burst pass, then serve the
               avm_rd  <= '0';                -- pending request again
               hr_quiet    <= hr_quiet - 1;
               if hr_quiet = 0 then
                  hr_state <= H_IDLE;
               end if;

            when H_IDLE =>
               avm_wr <= '0';
               avm_rd  <= '0';
               if hr_req_dd /= hr_ack_tgl then   -- a request; m_req_* are stable now
                  hr_line <= m_req_addr(12 downto 3);
                  hr_beat <= (others => '0');
                  if m_req_fill = '1' then
                     avm_rd       <= '1';
                     avm_address_o    <= std_logic_vector(word(31 downto 3)) & "000";
                     avm_burstcount_o <= x"08";
                     avm_byteenable_o <= "11";
                     hr_state         <= H_FILL_CMD;
                  else
                     avm_wr      <= '1';
                     avm_address_o    <= std_logic_vector(word);
                     avm_writedata_o  <= m_req_data;
                     avm_byteenable_o <= m_req_be;
                     avm_burstcount_o <= x"01";
                     hr_state         <= H_WRITE_CMD;
                  end if;
               end if;

            when H_FILL_CMD =>
               if avm_waitrequest_i = '0' then
                  avm_rd <= '0';
                  hr_state   <= H_FILL_DATA;
               end if;

            when H_FILL_DATA =>
               if avm_readdatavalid_i = '1' then
                  hr_beat <= hr_beat + 1;
                  if hr_beat = 7 then
                     hr_ack_tgl <= not hr_ack_tgl;
                     hr_nack    <= hr_nack + 1;
                     hr_state   <= H_IDLE;
                  end if;
               end if;

            when H_WRITE_CMD =>
               if avm_waitrequest_i = '0' then     -- accepted (and the cache word written)
                  avm_wr <= '0';
                  hr_ack_tgl  <= not hr_ack_tgl;
                  hr_nack     <= hr_nack + 1;
                  hr_state    <= H_IDLE;
               end if;
         end case;

         -- The framework's reset (M2M reset) resets the Avalon arbiters: a transaction in
         -- flight is lost.  Never acknowledge it: abort, wait, and serve the request again
         -- (a fill or a write may be repeated; both are idempotent).
         -- debug counters
         hr_rst_d   <= hr_rst_i;
         hr_state_d <= hr_state;
         if hr_rst_i = '1' and hr_rst_d = '0' and hr_req_dd /= hr_ack_tgl then
            hr_nabort <= hr_nabort + 1;
         end if;
         if avm_readdatavalid_i = '1' and hr_state /= H_FILL_DATA then
            hr_nstray <= hr_nstray + 1;
         end if;
         if hr_state /= hr_state_d then
            hr_age <= (others => '0');
         elsif hr_age /= x"FFFF" then
            hr_age <= hr_age + 1;
         end if;

         if hr_rst_i = '1' then
            avm_wr <= '0';
            avm_rd  <= '0';
            hr_quiet    <= (others => '1');
            hr_state    <= H_QUIET;
         end if;
      end if;
   end process mem_proc;

   ---------------------------------------------------------------------------
   -- debug word (read asynchronously by stallmon fdbg through lat_meter)
   ---------------------------------------------------------------------------
   m_state_v  <= "00" when m_state = M_IDLE else "01" when m_state = M_READ else
                 "10" when m_state = M_FILL else "11";
   hr_state_v <= "000" when hr_state = H_QUIET else "001" when hr_state = H_IDLE else
                 "010" when hr_state = H_FILL_CMD else "011" when hr_state = H_FILL_DATA else "100";
   -- W0: core flags & requests; W1: request address; W2: memory flags & acknowledges;
   -- W3: hr_quiet, aborts, stray beats, 0; then 16 bits: clocks in the current memory state
   dbg_o <= m_state_v & busy & m_req_tgl & m_ack_dd & m_req_fill & m_req_hit & m_ready & m_orphan &
            m_dbg_in & "000" & std_logic_vector(m_nreq) &
            "00000" & m_req_addr &
            hr_state_v & hr_req_dd & hr_ack_tgl & std_logic_vector(hr_beat) & avm_rd & avm_wr &
            avm_waitrequest_i & avm_readdatavalid_i & hr_rst_i & "000" & std_logic_vector(hr_nack) &
            std_logic_vector(hr_quiet) & std_logic_vector(hr_nabort) & std_logic_vector(hr_nstray) & x"00" &
            std_logic_vector(hr_age);

end architecture synthesis;
