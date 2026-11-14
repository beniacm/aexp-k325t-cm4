-- fc_cpu: the fast 68020 of the A1200 core on its own clock (K325T, a1200-fastclk), cpu_clk side.
--
-- TG68K (68020, s21_en: aligned data longs in one access, no MMU030) with
--  * an instruction cache, 16 KB direct mapped, 16-byte lines (block RAM, 1024 x 128 + tags), for fast
--    RAM, Kickstart ROM and (cfg_chipcode_i) chip RAM, enabled by CACR.E, cleared by CACR.C / CACR.CE;
--  * a data cache, 8 KB direct mapped, 16-byte lines (512 x 128 with byte writes), for fast RAM and the
--    Kickstart ROM, write-through, no write-allocate;
--  * a line buffer in front of each array: the current line in flip-flops, a hit answers in the clock
--    of the request (TG68K's bus address is combinational, a block RAM cannot be read in that clock);
--    an array hit costs one clock (the arrays are read every clock with the current address);
--  * every store also updates a D line it hits and invalidates an I line it hits (self-modifying code);
--  * a posted store queue (8 entries, 32 bits + lanes): stores are acknowledged in the clock of the
--    request; fast-RAM entries drain into the fast RAM port, the others into the chip mailbox, in order;
--    reads that leave the caches (fills, uncached reads) wait until the queue is empty; the queue is
--    not cleared by a CPU reset (accepted stores always reach memory);
--  * a mailbox to the machine clock for everything else (custom chips, CIAs, chip RAM data, Gayle, the
--    NMI vector): toggle handshake, one request at a time, request fields stable while it is open.
--  * accesses that can change the interrupt level (writes to $DFF090-$DFF09F: INTENA, INTREQ, DMACON;
--    any access to a CIA's ICR) are not posted: the machine side answers them after the bus cycle and
--    the time Paula / the CIA need to show the new level on IPL, and the kernel continues only after
--    the IPL synchroniser here has sampled it (else a handler's acknowledge followed by RTE takes the
--    same interrupt again: music ran ahead in Domination, fc2 on the board);
-- TG68K has one bus request at a time, so one controller serves both caches.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fc_cpu is
   generic (
      G_CPU030  : integer   := 0;                          -- TG68K's CPU030 input: 0 = 68020, 1 = 68030
      G_MMU030  : integer   := 0                           -- 1 = TG68K_MMU030 present (needed for a 68030 with MMU)
   );
   port (
      clk            : in  std_logic;
      rst_n_i        : in  std_logic;                       -- CPU reset, any clock (synchronised here)
      -- configuration from the machine clock (quasi-static; synchronised here)
      cfg_z2_i       : in  std_logic;
      cfg_z3e0_i     : in  std_logic;
      cfg_z3e1_i     : in  std_logic;
      cfg_z3b0_i     : in  std_logic_vector(4 downto 0);
      cfg_z3b1_i     : in  std_logic_vector(3 downto 0);
      cfg_chipcode_i : in  std_logic;                       -- 1 = cache instructions from chip RAM
      cfg_a24_i      : in  std_logic := '0';                -- 1 = 24-bit address bus (68EC020: cpu_wrapper's ec020)
      ipl_i          : in  std_logic_vector(2 downto 0);    -- machine clock, active low as TG68K's IPL
      -- mailbox to the machine clock
      mb_req_o       : out std_logic;                       -- toggles once per request
      mb_addr_o      : out std_logic_vector(31 downto 0);
      mb_wr_o        : out std_logic;
      mb_long_o      : out std_logic;                       -- 1 = aligned longword (32 bits)
      mb_sync_o      : out std_logic;                       -- 1 = an interrupt register: answered only when its effect is visible
      mb_uds_n_o     : out std_logic;
      mb_lds_n_o     : out std_logic;
      mb_wdata_o     : out std_logic_vector(31 downto 0);   -- word: 15..0
      mb_ack_i       : in  std_logic;                       -- toggles once per answer
      mb_rdata_i     : in  std_logic_vector(31 downto 0);   -- word: 15..0; stable from the toggle on
      -- fast RAM port (amiga_fastram core side in this clock, TG68K handshake: pulse_i = 1)
      fr_sel_o       : out std_logic;
      fr_addr_o      : out std_logic_vector(31 downto 0);   -- CPU byte address (mapped outside)
      fr_we_o        : out std_logic;
      fr_uds_n_o     : out std_logic;
      fr_lds_n_o     : out std_logic;
      fr_wdata_o     : out std_logic_vector(15 downto 0);
      fr_rdata_i     : in  std_logic_vector(15 downto 0);
      fr_ready_i     : in  std_logic;
      -- status
      vbr_o          : out std_logic_vector(31 downto 0);
      cacr_o         : out std_logic_vector(3 downto 0);
      resetout_n_o   : out std_logic;                       -- RESET instruction (low while active)
      qempty_o       : out std_logic                        -- store queue empty and nothing open
   );
end entity fc_cpu;

architecture rtl of fc_cpu is

   -- kernel
   signal k_nreset   : std_logic;
   signal k_cpu030   : std_logic;
   signal k_ena      : std_logic;
   signal k_din      : std_logic_vector(15 downto 0);
   signal k_dinhi    : std_logic_vector(15 downto 0);
   signal k_lack     : std_logic;
   signal hold_din, hold_dinhi : std_logic_vector(15 downto 0) := (others => '0');
   signal k_araw     : std_logic_vector(31 downto 0);         -- the kernel's address
   signal k_addr     : std_logic_vector(31 downto 0);         -- on the bus (24 bits with cfg_a24_i)
   signal k_dw       : std_logic_vector(15 downto 0);
   signal k_dwlo     : std_logic_vector(15 downto 0);
   signal k_nwr      : std_logic;
   signal k_uds_n    : std_logic;
   signal k_lds_n    : std_logic;
   signal k_bs       : std_logic_vector(1 downto 0);
   signal k_lcand    : std_logic;
   signal k_skip     : std_logic;
   signal k_cacrx    : std_logic_vector(13 downto 0);
   signal k_cacrwr   : std_logic;
   signal k_vbr      : std_logic_vector(31 downto 0);

   signal rst_s      : std_logic_vector(2 downto 0) := (others => '0');
   signal rst        : std_logic;                            -- synchronous, active high
   signal ipl_s1, ipl_s2, ipl_s3, ipl_k : std_logic_vector(2 downto 0) := (others => '1');
   signal cfg_s1, cfg_s2 : std_logic_vector(13 downto 0) := (others => '0');
   signal z2, z3e0, z3e1, chipcode, a24 : std_logic;
   signal z3b0       : std_logic_vector(4 downto 0);
   signal z3b1       : std_logic_vector(3 downto 0);
   signal nmi_a      : std_logic_vector(31 downto 2) := (others => '1');
   signal nmi_m      : std_logic_vector(31 downto 2);
   signal cacr_e     : std_logic := '0';

   -- request decode
   signal req, rd, wr, fe : std_logic;
   signal is_fast, is_rom, is_chip, is_nmi : std_logic;
   signal is_sync    : std_logic;
   signal mb_s       : std_logic := '0';
   signal sync_r     : std_logic := '0';
   signal iplw       : unsigned(2 downto 0) := (others => '0');
   signal ic_ok, dc_ok   : std_logic;
   signal use_i, use_d   : std_logic;

   -- arrays
   type i_data_t is array(0 to 1023) of std_logic_vector(127 downto 0);
   type i_tag_t  is array(0 to 1023) of std_logic_vector(17 downto 0);
   type d_data_t is array(0 to 511) of std_logic_vector(127 downto 0);
   type d_tag_t  is array(0 to 511) of std_logic_vector(18 downto 0);
   signal i_data : i_data_t;
   signal i_tag  : i_tag_t;
   signal d_data : d_data_t;
   signal d_tag  : d_tag_t;
   attribute ram_style : string;
   attribute ram_style of i_data, i_tag, d_data, d_tag : signal is "block";
   signal i_val  : std_logic_vector(1023 downto 0) := (others => '0');
   signal d_val  : std_logic_vector(511 downto 0) := (others => '0');
   signal i_dq   : std_logic_vector(127 downto 0);
   signal i_tq   : std_logic_vector(17 downto 0);
   signal i_vq   : std_logic;
   signal d_dq   : std_logic_vector(127 downto 0);
   signal d_tq   : std_logic_vector(18 downto 0);
   signal d_vq   : std_logic;
   signal i_we   : std_logic;
   signal i_widx : unsigned(9 downto 0);
   signal i_wtag : std_logic_vector(17 downto 0);
   signal d_bwe  : std_logic_vector(15 downto 0);
   signal d_widx : unsigned(8 downto 0);
   signal d_wtag : std_logic_vector(18 downto 0);
   signal d_tagwe: std_logic;
   signal d_wd   : std_logic_vector(127 downto 0);
   signal coll_i, coll_d : std_logic := '0';
   signal pend_q : std_logic := '0';
   signal orph   : std_logic := '0';                         -- the open fill / mailbox read began before a CPU reset

   -- line buffers
   signal ilb_v, dlb_v : std_logic := '0';
   signal ilb_t, dlb_t : std_logic_vector(31 downto 4);
   signal ilb_d, dlb_d : std_logic_vector(127 downto 0);
   signal ilb_hit, dlb_hit : std_logic;
   signal i_hit, d_hit : std_logic;

   -- store after-check (the arrays' outputs in the clock after a store belong to its address)
   signal st_v   : std_logic := '0';
   signal st_d   : std_logic := '0';                         -- 1 = update D (fast RAM), 0 = invalidate D (ROM)
   signal st_a   : std_logic_vector(31 downto 0);
   signal st_be  : std_logic_vector(15 downto 0);
   signal st_wd  : std_logic_vector(127 downto 0);

   -- controller
   type st_t is (S_RUN, S_FILLQ, S_FILL, S_FILLD, S_MBQ, S_MB, S_IPLW, S_MBD);
   signal st     : st_t := S_RUN;
   signal ack    : std_logic;
   signal fill_i : std_logic;                                -- 1 = I line, 0 = D line
   signal fill_mb: std_logic;                                -- 1 = from the mailbox (ROM / chip)
   signal fill_a : std_logic_vector(31 downto 4);
   signal fill_b : std_logic_vector(127 downto 0);
   signal fill_n : unsigned(2 downto 0);
   signal fill_go: std_logic;
   signal mb_long_r : std_logic;
   signal mb_q   : std_logic_vector(31 downto 0);

   -- store queue
   type q_a_t is array(0 to 7) of std_logic_vector(31 downto 0);
   type q_c_t is array(0 to 7) of std_logic_vector(3 downto 0);  -- fast, long, uds_n, lds_n
   signal q_a, q_d : q_a_t;
   signal q_c    : q_c_t;
   signal q_wp, q_rp : unsigned(2 downto 0) := (others => '0');
   signal q_n    : unsigned(3 downto 0) := (others => '0');
   signal q_push, q_pop : std_logic;
   signal q_full, q_empty : std_logic;
   type dr_t is (D_IDLE, D_FR1, D_FR2, D_MB);
   signal dr     : dr_t := D_IDLE;
   signal dr_fr_go, dr_mb_go : std_logic := '0';
   signal st_qd  : std_logic_vector(31 downto 0);
   signal st_qc  : std_logic_vector(3 downto 0);

   -- ports
   signal fr_sel, fr_we, fr_uds_n, fr_lds_n : std_logic := '0';
   signal fr_addr : std_logic_vector(31 downto 0);
   signal fr_wd  : std_logic_vector(15 downto 0);
   signal mb_t   : std_logic := '0';
   signal mb_open: std_logic := '0';
   signal mb_a   : std_logic_vector(31 downto 0);
   signal mb_w, mb_l, mb_u, mb_lo : std_logic := '0';
   signal mb_wd  : std_logic_vector(31 downto 0);
   signal ack_s  : std_logic_vector(2 downto 0) := (others => '0');
   signal mb_ev  : std_logic;

   function wsel(l : std_logic_vector(127 downto 0); a : std_logic_vector(3 downto 1)) return std_logic_vector is
      variable r : std_logic_vector(15 downto 0);
   begin
      r := l(127 downto 112);
      for i in 1 to 7 loop
         if to_integer(unsigned(a)) = i then r := l(127 - 16 * i downto 112 - 16 * i); end if;
      end loop;
      return r;
   end function;

begin

   ---------------------------------------------------------------------------------------------------
   -- reset, interrupts, configuration
   ---------------------------------------------------------------------------------------------------
   process (clk, rst_n_i) begin
      if rst_n_i = '0' then
         rst_s <= (others => '0');
      elsif rising_edge(clk) then
         rst_s <= rst_s(1 downto 0) & '1';
      end if;
   end process;
   rst      <= not rst_s(2);
   k_nreset <= rst_s(2);

   process (clk) begin
      if rising_edge(clk) then
         ipl_s1 <= ipl_i; ipl_s2 <= ipl_s1; ipl_s3 <= ipl_s2;
         if ipl_s2 = ipl_s3 then ipl_k <= ipl_s3; end if;      -- the 3 bits may change one by one
         cfg_s1 <= cfg_a24_i & cfg_chipcode_i & cfg_z3b1_i & cfg_z3b0_i & cfg_z3e1_i & cfg_z3e0_i & cfg_z2_i;
         cfg_s2 <= cfg_s1;
         nmi_a  <= std_logic_vector(unsigned(k_vbr(31 downto 2)) + 31);   -- vbr + $7C
         if rst = '1' then
            cacr_e <= '0';
         elsif k_cacrwr = '1' then
            cacr_e <= k_cacrx(0) and not k_cacrx(1);              -- E, frozen = no fills: treated as off
         end if;
      end if;
   end process;
   z2 <= cfg_s2(0); z3e0 <= cfg_s2(1); z3e1 <= cfg_s2(2);
   z3b0 <= cfg_s2(7 downto 3); z3b1 <= cfg_s2(11 downto 8); chipcode <= cfg_s2(12); a24 <= cfg_s2(13);

   ---------------------------------------------------------------------------------------------------
   -- the kernel
   ---------------------------------------------------------------------------------------------------
   kernel: entity work.TG68KdotC_Kernel
   generic map(SR_Read => 2, VBR_Stackframe => 2, extAddr_Mode => 2, MUL_Mode => 2, DIV_Mode => 2,
               BitField => 2, MMU030_Present => G_MMU030)
   port map(
      clk => clk, nReset => k_nreset, clkena_in => k_ena, data_in => k_din, IPL => ipl_k,
      IPL_autovector => '1', CPU => "11", CPU030 => k_cpu030, EC030 => '0',
      addr_out => k_araw, data_write => k_dw, nWr => k_nwr, nUDS => k_uds_n, nLDS => k_lds_n,
      busstate => k_bs, longword => open, s21_en => '1', long_cand => k_lcand, long_ack => k_lack,
      data_in_hi => k_dinhi, data_write_lo => k_dwlo, nResetOut => resetout_n_o, FC => open,
      skipFetch => k_skip, regin_out => open, CACR_out => cacr_o, D_CACHE_out => open, VBR_out => k_vbr,
      opc_start => open, opc_out => open, opc_cond => open, opc_snd => open, opc_dbx => open,
      opc_cacr => k_cacrx, opc_cacr_wr => k_cacrwr, opc_caar => open, mmu_busy => open);
   vbr_o <= k_vbr;
   k_cpu030 <= '1' when G_CPU030 /= 0 else '0';
   -- the 68EC020's address bus has 24 lines: an address with a non-zero high byte IS the 24-bit address (fast
   -- RAM, ROM, chip ...).  Without this such an access went to the mailbox, past the D-cache, and cpu_wrapper's
   -- 24-bit mask sent it to the stock fast-RAM instance, which is off the DDR3 port in this setting: the machine
   -- hung (fc5: the CPU instruction test, ADDQ.B #1,(d8,A6,D6.L*4) to $0141FFBA, on the board).
   k_addr <= x"00" & k_araw(23 downto 0) when a24 = '1' else k_araw;
   nmi_m  <= x"00" & nmi_a(23 downto 2) when a24 = '1' else nmi_a;

   ---------------------------------------------------------------------------------------------------
   -- request decode (combinational from the kernel's bus address)
   ---------------------------------------------------------------------------------------------------
   req <= '1' when k_bs /= "01" else '0';
   fe  <= '1' when k_bs = "00" else '0';
   rd  <= '1' when k_bs = "10" else '0';
   wr  <= '1' when k_bs = "11" else '0';
   is_fast <= '1' when (k_addr(31 downto 24) = x"00" and (k_addr(23) xor (k_addr(22) or k_addr(21))) = '1' and z2 = '1') or
                       (k_addr(31 downto 27) = z3b0 and z3e0 = '1') or (k_addr(31 downto 28) = z3b1 and z3e1 = '1') else '0';
   is_rom  <= '1' when k_addr(31 downto 24) = x"00" and (k_addr(23 downto 19) = "11111" or k_addr(23 downto 19) = "11100") else '0';
   is_chip <= '1' when k_addr(31 downto 21) = "00000000000" else '0';
   is_nmi  <= '1' when k_addr(31 downto 2) = nmi_m else '0';
   is_sync <= '1' when k_addr(31 downto 24) = x"00" and
                       ((k_addr(23 downto 4) = x"DFF09" and wr = '1') or
                        (k_addr(23 downto 16) = x"BF" and k_addr(11 downto 8) = "1101")) else '0';
   ic_ok   <= cacr_e and (is_rom or (is_chip and chipcode));
   dc_ok   <= (is_fast or is_rom) and not is_nmi;
   -- fast RAM is always cached: a fetch with the I-cache off (or no I-cache) goes through the D side
   use_i   <= fe and (ic_ok or (cacr_e and is_fast));
   use_d   <= (rd and dc_ok) or (fe and (is_fast or is_rom) and not cacr_e);

   ilb_hit <= '1' when ilb_v = '1' and ilb_t = k_addr(31 downto 4) else '0';
   dlb_hit <= '1' when dlb_v = '1' and dlb_t = k_addr(31 downto 4) else '0';
   i_hit   <= '1' when pend_q = '1' and coll_i = '0' and i_vq = '1' and i_tq = k_addr(31 downto 14) else '0';
   d_hit   <= '1' when pend_q = '1' and coll_d = '0' and d_vq = '1' and d_tq = k_addr(31 downto 13) else '0';

   q_full  <= '1' when q_n >= 7 else '0';
   q_empty <= '1' when q_n = 0 and dr = D_IDLE else '0';
   qempty_o <= q_empty and not mb_open;

   -- acknowledge and data (combinational: the clock enable of the whole kernel)
   process (st, req, use_i, use_d, rd, wr, fe, k_skip, ilb_hit, dlb_hit, i_hit, d_hit, q_full, k_lcand,
            is_fast, is_chip, is_rom, ilb_d, dlb_d, i_dq, d_dq, k_addr, fill_b, mb_q, mb_long_r, hold_din, hold_dinhi, orph)
      variable line : std_logic_vector(127 downto 0);
      variable a3   : std_logic_vector(3 downto 1);
   begin
      ack     <= '0';
      k_lack  <= '0';
      line    := dlb_d;
      if use_i = '1' then
         line := i_dq;
         if ilb_hit = '1' then line := ilb_d; end if;
      elsif dlb_hit = '0' then
         line := d_dq;
      end if;
      if st = S_FILLD then line := fill_b; end if;
      a3 := k_addr(3 downto 1);
      k_dinhi <= hold_dinhi;
      k_din   <= hold_din;
      if req = '1' and wr = '0' then                       -- the bus answer; between answers data_in
         k_dinhi <= wsel(line, a3(3 downto 2) & '0');      -- keeps the last one (as cpu_wrapper's chip
         k_din   <= wsel(line, a3);                        -- data register: TG68K shifts data_in into
         if k_lcand = '1' then                             -- last_data_in on every enabled clock)
            k_din <= wsel(line, a3(3 downto 2) & '1');
         end if;
      end if;
      case st is
         when S_RUN =>
            if req = '1' then
               if use_i = '1' then
                  ack <= ilb_hit or i_hit;
               elsif use_d = '1' then
                  ack <= dlb_hit or d_hit;
                  k_lack <= k_lcand;
               elsif rd = '1' and k_skip = '1' then
                  ack <= '1';                                -- a discarded read: no bus cycle (as MiSTer)
               elsif wr = '1' and is_sync = '0' then
                  ack <= not q_full;
                  k_lack <= k_lcand and (is_fast or is_chip);   -- custom chips / CIAs: word by word
               end if;
            end if;
         when S_FILLD =>                                   -- (an orphan answers nobody: the kernel's
            ack <= not orph;                                -- request is a new one, after the reset)
            k_lack <= k_lcand and not fe and not orph;
         when S_MBD =>
            ack <= not orph;
            k_lack <= mb_long_r and not orph;
            k_dinhi <= mb_q(31 downto 16);
            k_din   <= mb_q(15 downto 0);
         when others => null;
      end case;
   end process;
   k_ena <= not req or ack;
   process (clk) begin
      if rising_edge(clk) then
         if req = '1' and ack = '1' and wr = '0' then
            hold_din <= k_din; hold_dinhi <= k_dinhi;
         end if;
      end if;
   end process;

   -- array write ports (combinational: valid bit, tag and data change at the same edge)
   i_we   <= '1' when st = S_FILLD and fill_i = '1' and orph = '0' else '0';
   i_widx <= unsigned(fill_a(13 downto 4));
   i_wtag <= fill_a(31 downto 14);
   d_tagwe <= '1' when st = S_FILLD and fill_i = '0' and orph = '0' else '0';
   d_wtag <= fill_a(31 downto 13);
   d_bwe  <= (others => '1') when st = S_FILLD and fill_i = '0' and orph = '0' else
             st_be when st_v = '1' and st_d = '1' and d_vq = '1' and d_tq = st_a(31 downto 13) else (others => '0');
   d_wd   <= fill_b when st = S_FILLD else st_wd;
   d_widx <= unsigned(fill_a(12 downto 4)) when st = S_FILLD else unsigned(st_a(12 downto 4));

   ---------------------------------------------------------------------------------------------------
   -- arrays (read every clock with the current bus address)
   ---------------------------------------------------------------------------------------------------
   process (clk) begin
      if rising_edge(clk) then
         i_dq <= i_data(to_integer(unsigned(k_addr(13 downto 4))));
         i_tq <= i_tag(to_integer(unsigned(k_addr(13 downto 4))));
         if i_we = '1' then
            i_data(to_integer(i_widx)) <= fill_b;
            i_tag(to_integer(i_widx))  <= i_wtag;
         end if;
      end if;
   end process;

   process (clk) begin
      if rising_edge(clk) then
         d_dq <= d_data(to_integer(unsigned(k_addr(12 downto 4))));
         d_tq <= d_tag(to_integer(unsigned(k_addr(12 downto 4))));
         for b in 0 to 15 loop
            if d_bwe(b) = '1' then
               d_data(to_integer(d_widx))(127 - 8 * b downto 120 - 8 * b) <= d_wd(127 - 8 * b downto 120 - 8 * b);
            end if;
         end loop;
         if d_tagwe = '1' then
            d_tag(to_integer(d_widx)) <= d_wtag;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------------------------------
   -- controller
   ---------------------------------------------------------------------------------------------------
   process (clk)
      variable be  : std_logic_vector(15 downto 0);
      variable wd  : std_logic_vector(127 downto 0);
      variable i_clr_idx, d_clr_idx : integer;
      variable i_clr, d_clr : std_logic;
   begin
      if rising_edge(clk) then
         q_push  <= '0';
         i_clr := '0'; d_clr := '0';
         i_clr_idx := to_integer(unsigned(st_a(13 downto 4)));
         d_clr_idx := to_integer(unsigned(st_a(12 downto 4)));
         i_vq <= i_val(to_integer(unsigned(k_addr(13 downto 4))));
         d_vq <= d_val(to_integer(unsigned(k_addr(12 downto 4))));
         pend_q <= '0';
         coll_i <= '0';
         coll_d <= '0';

         -- the store after-check: array outputs now belong to the store's address
         st_v <= '0';
         if st_v = '1' then
            if i_vq = '1' and i_tq = st_a(31 downto 14) then i_clr := '1'; end if;
            if d_vq = '1' and d_tq = st_a(31 downto 13) then
               coll_d <= '1';                                -- the update below is written at this edge
               if st_d = '0' then d_clr := '1'; end if;
            end if;
         end if;

         case st is
            when S_RUN =>
               if req = '1' and ack = '0' then
                  pend_q <= '1';
                  if i_we = '1' then coll_i <= '1'; end if;    -- (a write at this edge: re-read)
                  if d_bwe /= x"0000" then coll_d <= '1'; end if;
               end if;
               if req = '1' and ack = '0' and pend_q = '1' then
                  if (use_i = '1' and coll_i = '0' and i_hit = '0') or (use_d = '1' and coll_d = '0' and d_hit = '0') then
                     st <= S_FILLQ;
                     fill_i  <= use_i;
                     fill_mb <= not is_fast;
                     fill_a  <= k_addr(31 downto 4);
                     pend_q  <= '0';
                  elsif use_i = '0' and use_d = '0' and (wr = '0' or is_sync = '1') and
                        not (rd = '1' and k_skip = '1') then
                     st <= S_MBQ;
                     pend_q <= '0';
                  end if;
               end if;
               -- array hit: the line goes into the line buffer
               if req = '1' and ack = '1' then
                  if use_i = '1' and ilb_hit = '0' then
                     ilb_v <= '1'; ilb_t <= k_addr(31 downto 4); ilb_d <= i_dq;
                  end if;
                  if use_d = '1' and dlb_hit = '0' then
                     dlb_v <= '1'; dlb_t <= k_addr(31 downto 4); dlb_d <= d_dq;
                  end if;
               end if;
               -- a store: queue it, update the D line buffer, check the arrays in the next clock
               if wr = '1' and ack = '1' then
                  q_push <= '1';
                  -- be(b) = byte b of the line (b = 0: bits 127..120); words w = 0..7 of the line
                  be := (others => '0');
                  wd := (others => '0');
                  for w in 0 to 7 loop
                     if to_integer(unsigned(k_addr(3 downto 1))) = w then
                        wd(127 - 16 * w downto 112 - 16 * w) := k_dw;
                        if k_lack = '1' then
                           be(2 * w) := '1'; be(2 * w + 1) := '1';
                        else
                           be(2 * w) := not k_uds_n; be(2 * w + 1) := not k_lds_n;
                        end if;
                     end if;
                     if k_lack = '1' and to_integer(unsigned(k_addr(3 downto 1))) + 1 = w then
                        wd(127 - 16 * w downto 112 - 16 * w) := k_dwlo;
                        be(2 * w) := '1'; be(2 * w + 1) := '1';
                     end if;
                  end loop;
                  st_v <= is_fast or is_rom or is_chip;
                  st_d <= is_fast;
                  st_a <= k_addr; st_be <= be; st_wd <= wd;
                  if dlb_hit = '1' then
                     if is_fast = '1' then
                        for b in 0 to 15 loop
                           if be(b) = '1' then dlb_d(127 - 8 * b downto 120 - 8 * b) <= wd(127 - 8 * b downto 120 - 8 * b); end if;
                        end loop;
                     else
                        dlb_v <= '0';
                     end if;
                  end if;
                  if ilb_hit = '1' then ilb_v <= '0'; end if;
               end if;

            when S_FILLQ =>
               if q_empty = '1' and mb_open = '0' then
                  st <= S_FILL;
                  fill_n <= (others => '0');
                  fill_go <= '1';
               end if;

            when S_FILL =>
               fill_go <= '0';
               if fill_mb = '0' then
                  if fr_ready_i = '1' then
                     for w in 0 to 7 loop
                        if to_integer(fill_n) = w then fill_b(127 - 16 * w downto 112 - 16 * w) <= fr_rdata_i; end if;
                     end loop;
                     fill_n <= fill_n + 1;
                     if fill_n = 7 then st <= S_FILLD; end if;
                  end if;
               else
                  if mb_ev = '1' then
                     for w in 0 to 3 loop
                        if to_integer(fill_n(1 downto 0)) = w then fill_b(127 - 32 * w downto 96 - 32 * w) <= mb_rdata_i; end if;
                     end loop;
                     fill_n <= fill_n + 1;
                     if fill_n = 3 then st <= S_FILLD; else fill_go <= '1'; end if;
                  end if;
               end if;

            when S_FILLD =>
               st <= S_RUN;
               orph <= '0';
               coll_i <= '1'; coll_d <= '1';                 -- the arrays are written at this edge
               if orph = '1' then
                  null;                                      -- read before the reset: not installed
               elsif fill_i = '1' then
                  i_val(to_integer(unsigned(fill_a(13 downto 4)))) <= '1';
                  ilb_v <= '1'; ilb_t <= fill_a; ilb_d <= fill_b;
               else
                  d_val(to_integer(unsigned(fill_a(12 downto 4)))) <= '1';
                  dlb_v <= '1'; dlb_t <= fill_a; dlb_d <= fill_b;
               end if;

            when S_MBQ =>
               if q_empty = '1' and mb_open = '0' then
                  st <= S_MB;
                  mb_long_r <= k_lcand and is_chip and rd;
                  sync_r <= is_sync;
               end if;

            when S_MB =>
               if mb_ev = '1' then
                  mb_q <= mb_rdata_i;
                  if sync_r = '1' then
                     st <= S_IPLW;
                     iplw <= (others => '0');
                  else
                     st <= S_MBD;
                  end if;
               end if;

            when S_IPLW =>                                   -- the IPL synchroniser samples the new level
               iplw <= iplw + 1;
               if iplw = 5 then st <= S_MBD; end if;

            when S_MBD =>
               st <= S_RUN;
               orph <= '0';
         end case;

         if i_clr = '1' then i_val(i_clr_idx) <= '0'; coll_i <= '1'; end if;
         if d_clr = '1' then d_val(d_clr_idx) <= '0'; coll_d <= '1'; end if;
         if rst = '1' or (k_cacrwr = '1' and (k_cacrx(3) = '1' or k_cacrx(2) = '1')) then
            i_val <= (others => '0');
            ilb_v <= '0';
            coll_i <= '1';                                   -- i_vq of the next clock was read before the clear
         end if;
         if rst = '1' then
            d_val <= (others => '0');
            dlb_v <= '0';
            pend_q <= '0';
            coll_d <= '1';
            -- an open fill or mailbox read completes (its port answers later, the mailbox possibly only after
            -- the machine reset, when the kernel runs again): it is an orphan, its answer is given to nobody
            -- (else the kernel's first read after the reset, the reset SSP, took the old read's data) and a
            -- fill is not installed (fc5: the CPU did not come back from a reset during fast-RAM store traffic)
            if st = S_FILL or st = S_MB or st = S_IPLW then
               orph <= '1';
            elsif st = S_FILLD or st = S_MBD then
               st <= S_RUN; orph <= '0';
            else
               st <= S_RUN;
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------------------------------
   -- store queue and its drain (not reset by the CPU reset: accepted stores always complete)
   ---------------------------------------------------------------------------------------------------
   process (clk) begin
      if rising_edge(clk) then
         if req = '1' and ack = '1' and wr = '1' and st = S_RUN then
            if k_lack = '1' then st_qd <= k_dw & k_dwlo; else st_qd <= x"0000" & k_dw; end if;
            st_qc <= is_fast & k_lack & k_uds_n & k_lds_n;
         end if;
         if q_push = '1' then
            q_a(to_integer(q_wp)) <= st_a;
            q_d(to_integer(q_wp)) <= st_qd;
            q_c(to_integer(q_wp)) <= st_qc;
            q_wp <= q_wp + 1;
         end if;
         if q_pop = '1' then q_rp <= q_rp + 1; end if;
         if q_push = '1' and q_pop = '0' then q_n <= q_n + 1;
         elsif q_push = '0' and q_pop = '1' then q_n <= q_n - 1;
         end if;
      end if;
   end process;

   -- drain: fast-RAM entries word by word into the fast RAM port, the others through the mailbox
   process (clk)
      variable h_a : std_logic_vector(31 downto 0);
      variable h_d : std_logic_vector(31 downto 0);
      variable h_c : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk) then
         q_pop <= '0';
         h_a := q_a(to_integer(q_rp)); h_d := q_d(to_integer(q_rp)); h_c := q_c(to_integer(q_rp));
         dr_mb_go <= '0';
         case dr is
            when D_IDLE =>
               if q_n /= 0 and q_pop = '0' and st /= S_FILL and st /= S_MB and mb_open = '0' then
                  if h_c(3) = '1' then
                     dr <= D_FR1;
                     dr_fr_go <= '1';
                  else
                     dr <= D_MB;
                     dr_mb_go <= '1';
                  end if;
               end if;
            when D_FR1 =>
               dr_fr_go <= '0';
               if fr_ready_i = '1' then
                  if h_c(2) = '1' then dr <= D_FR2; dr_fr_go <= '1';
                  else dr <= D_IDLE; q_pop <= '1'; end if;
               end if;
            when D_FR2 =>
               dr_fr_go <= '0';
               if fr_ready_i = '1' then dr <= D_IDLE; q_pop <= '1'; end if;
            when D_MB =>
               if mb_ev = '1' then dr <= D_IDLE; q_pop <= '1'; end if;
         end case;
      end if;
   end process;

   ---------------------------------------------------------------------------------------------------
   -- the fast RAM port (registered; TG68K handshake: a new access in the clock after ready)
   ---------------------------------------------------------------------------------------------------
   process (clk)
      variable h_a : std_logic_vector(31 downto 0);
      variable h_d : std_logic_vector(31 downto 0);
      variable h_c : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk) then
         h_a := q_a(to_integer(q_rp)); h_d := q_d(to_integer(q_rp)); h_c := q_c(to_integer(q_rp));
         if fr_ready_i = '1' then fr_sel <= '0'; end if;
         if dr = D_IDLE and q_n /= 0 and q_pop = '0' and h_c(3) = '1' and st /= S_FILL and st /= S_MB and mb_open = '0' then
            -- first (or only) word of a queued fast-RAM store
            fr_sel <= '1'; fr_we <= '1'; fr_addr <= h_a;
            fr_uds_n <= h_c(1) and not h_c(2); fr_lds_n <= h_c(0) and not h_c(2);
            if h_c(2) = '1' then fr_wd <= h_d(31 downto 16); else fr_wd <= h_d(15 downto 0); end if;
         elsif dr = D_FR1 and fr_ready_i = '1' and h_c(2) = '1' then
            fr_sel <= '1'; fr_we <= '1'; fr_addr <= std_logic_vector(unsigned(h_a) + 2);
            fr_uds_n <= '0'; fr_lds_n <= '0'; fr_wd <= h_d(15 downto 0);
         elsif st = S_FILLQ and q_empty = '1' and mb_open = '0' and fill_mb = '0' then
            fr_sel <= '1'; fr_we <= '0'; fr_addr <= fill_a & "0000"; fr_uds_n <= '0'; fr_lds_n <= '0';
         elsif st = S_FILL and fill_mb = '0' and fr_ready_i = '1' and fill_n /= 7 then
            fr_sel <= '1'; fr_we <= '0'; fr_addr <= fill_a & std_logic_vector(fill_n + 1) & '0';
         end if;
      end if;
   end process;
   fr_sel_o <= fr_sel; fr_we_o <= fr_we; fr_addr_o <= fr_addr;
   fr_uds_n_o <= fr_uds_n; fr_lds_n_o <= fr_lds_n; fr_wdata_o <= fr_wd;

   ---------------------------------------------------------------------------------------------------
   -- the mailbox (registered request fields, toggle handshake both ways)
   ---------------------------------------------------------------------------------------------------
   process (clk)
      variable h_a : std_logic_vector(31 downto 0);
      variable h_d : std_logic_vector(31 downto 0);
      variable h_c : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk) then
         ack_s <= ack_s(1 downto 0) & mb_ack_i;
         h_a := q_a(to_integer(q_rp)); h_d := q_d(to_integer(q_rp)); h_c := q_c(to_integer(q_rp));
         if mb_ev = '1' then mb_open <= '0'; end if;
         if mb_open = '0' then
            if dr_mb_go = '1' then
               mb_a <= h_a; mb_w <= '1'; mb_l <= h_c(2); mb_u <= h_c(1); mb_lo <= h_c(0); mb_wd <= h_d; mb_s <= '0';
               mb_t <= not mb_t; mb_open <= '1';
            elsif st = S_FILL and fill_mb = '1' and fill_go = '1' then
               mb_a <= fill_a & std_logic_vector(fill_n(1 downto 0)) & "00"; mb_w <= '0'; mb_l <= '1'; mb_s <= '0';
               mb_u <= '0'; mb_lo <= '0';
               mb_t <= not mb_t; mb_open <= '1';
            elsif st = S_MBQ and q_empty = '1' then
               mb_a <= k_addr; mb_w <= wr; mb_l <= k_lcand and is_chip and rd;
               mb_u <= k_uds_n; mb_lo <= k_lds_n; mb_wd <= x"0000" & k_dw; mb_s <= is_sync;
               mb_t <= not mb_t; mb_open <= '1';
            end if;
         end if;
      end if;
   end process;
   mb_ev <= ack_s(2) xor ack_s(1);
   mb_req_o <= mb_t; mb_addr_o <= mb_a; mb_wr_o <= mb_w; mb_long_o <= mb_l;
   mb_uds_n_o <= mb_u; mb_lds_n_o <= mb_lo; mb_wdata_o <= mb_wd; mb_sync_o <= mb_s;
end architecture rtl;
