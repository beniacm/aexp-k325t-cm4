--------------------------------------------------------------------------------
-- avm_mig.vhd -- M2M memory bus (Avalon-MM, 16-bit words, word addresses,
-- bursts up to 255) on a Xilinx MIG 7-series native UI (x16 DDR3, 4:1, BL8:
-- one command = one 128-bit word = 8 Avalon words; app_addr counts 16-bit
-- units, so Avalon word address n is app_addr n, aligned down to 8).
--
-- Runs entirely in the MIG ui_clk domain (the framework uses ui_clk as its
-- hr_clk), so there is no clock crossing here.
--
-- Read burst: the request is accepted (waitrequest low for one cycle), then
--   waitrequest stays high until all beats are delivered and for one more cycle
--   (M2M's avm_arbit must not see a new command with the last beat).  The MIG commands
--   for every 128-bit word of the burst are issued back-to-back, limited by
--   the free space of a 16-word FIFO that takes app_rd_data; beats are
--   delivered from it (one beat per clock, one bubble per 128-bit word).
-- Write burst: beats are gathered into a 128-bit word with a byte mask and
--   written when the word is complete or the burst ends (waitrequest is high
--   while that write is handed to the MIG).
--
-- ADDR_BITS Avalon word-address bits are used (27 = 256 MB); higher bits wrap.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity avm_mig is
  generic (
    ADDR_BITS : integer := 27
  );
  port (
    clk                 : in  std_logic;   -- MIG ui_clk
    rst                 : in  std_logic;   -- ui_clk_sync_rst or not calibrated
    -- Avalon-MM slave
    avm_write           : in  std_logic;
    avm_read            : in  std_logic;
    avm_address         : in  std_logic_vector(31 downto 0);
    avm_writedata       : in  std_logic_vector(15 downto 0);
    avm_byteenable      : in  std_logic_vector(1 downto 0);
    avm_burstcount      : in  std_logic_vector(7 downto 0);
    avm_readdata        : out std_logic_vector(15 downto 0);
    avm_readdatavalid   : out std_logic;
    avm_waitrequest     : out std_logic;
    -- MIG native UI
    app_addr            : out std_logic_vector(27 downto 0);
    app_cmd             : out std_logic_vector(2 downto 0);
    app_en              : out std_logic;
    app_rdy             : in  std_logic;
    app_wdf_data        : out std_logic_vector(127 downto 0);
    app_wdf_end         : out std_logic;
    app_wdf_wren        : out std_logic;
    app_wdf_mask        : out std_logic_vector(15 downto 0);
    app_wdf_rdy         : in  std_logic;
    app_rd_data         : in  std_logic_vector(127 downto 0);
    app_rd_data_valid   : in  std_logic
  );
end entity;

architecture rtl of avm_mig is
  constant CMD_WR : std_logic_vector(2 downto 0) := "000";
  constant CMD_RD : std_logic_vector(2 downto 0) := "001";

  type st_t is (S_IDLE, S_RD, S_RD_END, S_WR, S_FLUSH);
  signal st : st_t := S_IDLE;

  -- read side
  signal rd_cmd_addr  : unsigned(ADDR_BITS - 4 downto 0) := (others => '0');  -- 128-bit word
  signal rd_cmd_left  : unsigned(5 downto 0) := (others => '0');   -- MIG words still to request
  signal inflight     : unsigned(4 downto 0) := (others => '0');   -- requested, not yet consumed
  signal beats_left   : unsigned(7 downto 0) := (others => '0');
  signal cur_w        : std_logic_vector(127 downto 0) := (others => '0');
  signal cur_valid    : std_logic := '0';
  signal cur_idx      : unsigned(2 downto 0) := (others => '0');
  type fifo_t is array (0 to 15) of std_logic_vector(127 downto 0);
  signal fifo         : fifo_t;
  signal f_wp, f_rp   : unsigned(3 downto 0) := (others => '0');
  signal f_cnt        : unsigned(4 downto 0) := (others => '0');

  -- write side
  signal w_word_addr  : unsigned(ADDR_BITS - 4 downto 0) := (others => '0');
  signal w_pos        : unsigned(2 downto 0) := (others => '0');   -- next beat position
  signal w_left       : unsigned(7 downto 0) := (others => '0');   -- beats still expected
  signal w_data       : std_logic_vector(127 downto 0) := (others => '0');
  signal w_mask       : std_logic_vector(15 downto 0) := (others => '1');  -- 1 = keep
  signal cmd_ok       : std_logic := '0';
  signal dat_ok       : std_logic := '0';

  signal rd_issue     : std_logic;
  signal fifo_pop     : std_logic;
begin

  avm_waitrequest <= '0' when rst = '0' and (st = S_IDLE or st = S_WR) else '1';

  rd_issue <= '1' when st = S_RD and rd_cmd_left /= 0 and inflight < 15 else '0';
  fifo_pop <= '1' when st = S_RD and cur_valid = '0' and f_cnt /= 0 else '0';

  -- Write: the data goes into the MIG's write-data FIFO first; the command follows once
  -- the data has been taken (or in the same cycle).  UG586 allows data at most two
  -- cycles after its command, which app_wdf_rdy back-pressure could otherwise violate
  -- (the controller would then write stale write-buffer contents).
  app_en   <= '1' when rd_issue = '1' or
                       (st = S_FLUSH and cmd_ok = '0' and (dat_ok = '1' or app_wdf_rdy = '1'))
              else '0';
  app_cmd  <= CMD_WR when st = S_FLUSH else CMD_RD;
  app_addr <= "0" & std_logic_vector(resize(rd_cmd_addr, 24)) & "000" when st = S_RD else
              "0" & std_logic_vector(resize(w_word_addr, 24)) & "000";
  app_wdf_wren <= '1' when st = S_FLUSH and dat_ok = '0' else '0';
  app_wdf_end  <= '1' when st = S_FLUSH and dat_ok = '0' else '0';
  app_wdf_data <= w_data;
  app_wdf_mask <= w_mask;

  -- read data FIFO (written by the MIG, read by the beat stage)
  process (clk)
  begin
    if rising_edge(clk) then
      if app_rd_data_valid = '1' then
        fifo(to_integer(f_wp)) <= app_rd_data;
      end if;
    end if;
  end process;

  process (clk)
    variable a       : unsigned(ADDR_BITS - 1 downto 0);
    variable n       : unsigned(8 downto 0);
    variable pos     : integer range 0 to 7;
    variable push    : boolean;
    variable pop     : boolean;
    variable beat_ok : boolean;
  begin
    if rising_edge(clk) then
      avm_readdatavalid <= '0';
      push := app_rd_data_valid = '1';
      pop  := fifo_pop = '1';

      if rst = '1' then
        st        <= S_IDLE;
        cur_valid <= '0';
        f_wp <= (others => '0'); f_rp <= (others => '0'); f_cnt <= (others => '0');
        inflight  <= (others => '0');
        w_mask    <= (others => '1');
        cmd_ok    <= '0'; dat_ok <= '0';
      else
        -- FIFO pointers
        if push then f_wp <= f_wp + 1; end if;
        if pop then
          f_rp      <= f_rp + 1;
          cur_w     <= fifo(to_integer(f_rp));
          cur_valid <= '1';
        end if;
        if push and not pop then f_cnt <= f_cnt + 1;
        elsif pop and not push then f_cnt <= f_cnt - 1; end if;
        -- outstanding read words (requested and not yet moved to cur_w)
        if rd_issue = '1' and app_rdy = '1' and not pop then inflight <= inflight + 1;
        elsif pop and not (rd_issue = '1' and app_rdy = '1') then inflight <= inflight - 1; end if;

        case st is
          when S_IDLE | S_WR =>
            beat_ok := avm_write = '1';
            if st = S_IDLE and avm_read = '1' then
              -- accept a read burst
              a := unsigned(avm_address(ADDR_BITS - 1 downto 0));
              n := resize(unsigned(avm_burstcount), 9);
              rd_cmd_addr <= a(ADDR_BITS - 1 downto 3);
              -- words = ceil((offset + n) / 8)
              rd_cmd_left <= resize(shift_right(resize(a(2 downto 0), 9) + n + 7, 3), 6);
              beats_left  <= unsigned(avm_burstcount);
              cur_idx     <= a(2 downto 0);
              cur_valid   <= '0';
              st          <= S_RD;
            elsif beat_ok then
              if st = S_IDLE then
                -- first beat of a write burst carries address and burst length
                a := unsigned(avm_address(ADDR_BITS - 1 downto 0));
                w_word_addr <= a(ADDR_BITS - 1 downto 3);
                pos    := to_integer(a(2 downto 0));
                n      := resize(unsigned(avm_burstcount), 9) - 1;
                w_left <= n(7 downto 0);
              else
                pos    := to_integer(w_pos);
                n      := resize(w_left, 9) - 1;
                w_left <= w_left - 1;
              end if;
              w_data(16 * pos + 15 downto 16 * pos) <= avm_writedata;
              w_mask(2 * pos)     <= not avm_byteenable(0);
              w_mask(2 * pos + 1) <= not avm_byteenable(1);
              w_pos <= to_unsigned((pos + 1) mod 8, 3);
              if pos = 7 or n = 0 then
                cmd_ok <= '0'; dat_ok <= '0';
                st <= S_FLUSH;                 -- hand the word to the MIG
              else
                st <= S_WR;
              end if;
            end if;

          when S_FLUSH =>
            -- the command is only offered once the data is (being) taken, see app_en
            if app_rdy = '1' and (dat_ok = '1' or app_wdf_rdy = '1') then cmd_ok <= '1'; end if;
            if app_wdf_rdy = '1' then dat_ok <= '1'; end if;
            if (cmd_ok = '1' or (app_rdy = '1' and (dat_ok = '1' or app_wdf_rdy = '1'))) and
               (dat_ok = '1' or app_wdf_rdy = '1') then
              w_mask <= (others => '1');
              if w_left = 0 then
                st <= S_IDLE;
              else
                w_word_addr <= w_word_addr + 1;
                w_pos       <= (others => '0');
                st          <= S_WR;
              end if;
            end if;

          when S_RD_END =>
            st <= S_IDLE;

          when S_RD =>
            if rd_issue = '1' and app_rdy = '1' then
              rd_cmd_addr <= rd_cmd_addr + 1;
              rd_cmd_left <= rd_cmd_left - 1;
            end if;
            if cur_valid = '1' and not pop then
              avm_readdata      <= cur_w(16 * to_integer(cur_idx) + 15 downto 16 * to_integer(cur_idx));
              avm_readdatavalid <= '1';
              beats_left        <= beats_left - 1;
              cur_idx           <= cur_idx + 1;
              if cur_idx = 7 or beats_left = 1 then
                cur_valid <= '0';
              end if;
              if beats_left = 1 then
                -- not straight to S_IDLE: no new command may be accepted in the cycle that
                -- carries the last read beat.  M2M's avm_arbit counts a burst's beats and
                -- releases or re-grants on the last one; a command accepted in that same
                -- cycle (e.g. a pipelined master's next write) corrupts its count, and read
                -- data then reaches the wrong master (the HyperRAM controller never does this).
                st <= S_RD_END;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;

end architecture;
