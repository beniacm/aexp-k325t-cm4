--------------------------------------------------------------------------------
-- hdmi_audio_bench.vhd -- bench only (a1200-audrec 2): the board's audio path from Paula's mix to the
-- HDMI encoder's sample intake, with the real framework blocks, and the hold detector on it.
--   main.vhd        audio = ldata & '0'
--   audio_fifo.vhd  bypassed (afifo = 0): one register in the core's ungated source clock
--   framework       i_main2audio cdc_stable (G_REGISTER_SRC, 32 bits) into the 12.288-MHz audio clock
--   av_pipeline     filter off, mute off: the crossing's output as it is
--   digital_pipeline the 48-kHz clk_synthetic_enable and vga_to_hdmi (its sample handshake into the
--                   pixel clock and the audio-probe toggle; the video inputs tied off)
--   K325T top       aud_hold on the encoder input (K325T/aud_hold.vhd)
-- inj_i (bench only, audio clock) holds the crossing's output at its last value: the "hold between the
-- mixer and the encoder" that the detector must report.  build.sh converts this with GHDL to Verilog.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.types_pkg.all;

entity hdmi_audio_bench is
   port (
      src_clk_i  : in  std_logic;                        -- the core's audio source clock
      a_clk_i    : in  std_logic;                        -- the framework's audio clock (12.288 MHz)
      h_clk_i    : in  std_logic;                        -- the HDMI pixel clock
      l_i        : in  std_logic_vector(14 downto 0);    -- Paula's mix (machine clock)
      r_i        : in  std_logic_vector(14 downto 0);
      inj_i      : in  std_logic;                        -- bench: hold the crossing's output
      live_tog_i : in  std_logic;                        -- aud_rec.v live_tog
      cfg_i      : in  std_logic_vector(7 downto 0);     -- the bridge configuration byte
      word_o     : out std_logic_vector(191 downto 0)    -- aud_hold readout ($CD & $CC)
   );
end entity hdmi_audio_bench;

architecture sim of hdmi_audio_bench is
   signal fifo_l, fifo_r   : std_logic_vector(15 downto 0) := (others => '0');
   signal cdc_l, cdc_r     : std_logic_vector(15 downto 0);
   signal held_l, held_r   : std_logic_vector(15 downto 0) := (others => '0');
   signal enc_l, enc_r     : std_logic_vector(15 downto 0);
   signal clken, hs_tog    : std_logic;
   signal tmds             : slv_9_0_t(0 to 2);
begin
   -- audio_fifo bypass (mega65.vhd, afifo = 0): l_o <= l_i in the source clock
   process (src_clk_i)
   begin
      if rising_edge(src_clk_i) then
         fifo_l <= l_i & '0';
         fifo_r <= r_i & '0';
      end if;
   end process;

   i_main2audio : entity work.cdc_stable
      generic map (G_REGISTER_SRC => true, G_DATA_SIZE => 32)
      port map (
         src_clk_i                => src_clk_i,
         src_data_i(15 downto 0)  => fifo_l,
         src_data_i(31 downto 16) => fifo_r,
         dst_clk_i                => a_clk_i,
         dst_data_o(15 downto 0)  => cdc_l,
         dst_data_o(31 downto 16) => cdc_r
      );

   -- bench only: the injected hold (the crossing's output frozen while inj_i = 1)
   process (a_clk_i)
   begin
      if rising_edge(a_clk_i) then
         if inj_i = '0' then
            held_l <= cdc_l; held_r <= cdc_r;
         end if;
      end if;
   end process;
   enc_l <= cdc_l when inj_i = '0' else held_l;
   enc_r <= cdc_r when inj_i = '0' else held_r;

   i_clk_synthetic_enable : entity work.clk_synthetic_enable
      port map (clk_i => a_clk_i, src_speed_i => 12_288_000, dst_speed_i => 48_000, enable_o => clken);

   i_vga_to_hdmi : entity work.vga_to_hdmi
      port map (
         select_44100 => '0', dvi => '0', vic => x"11", aspect => "01", pix_rep => '0',
         vs_pol => '0', hs_pol => '0',
         vga_rst => '0', vga_clk => h_clk_i, vga_vs => '0', vga_hs => '0', vga_de => '0',
         vga_r => x"00", vga_g => x"00", vga_b => x"00",
         pcm_rst => '0', pcm_clk => a_clk_i, pcm_clken => clken, pcm_l => enc_l, pcm_r => enc_r,
         pcm_acr => '0', pcm_n => std_logic_vector(to_unsigned(6144, 20)),
         pcm_cts => std_logic_vector(to_unsigned(27000, 20)),
         tmds => tmds, pcm_hs_tog => hs_tog
      );

   i_aud_hold : entity work.aud_hold
      port map (
         clk_i => a_clk_i, rst_i => '0', clken_i => clken, pcm_l_i => enc_l, pcm_r_i => enc_r,
         hs_tog_i => hs_tog, live_tog_i => live_tog_i, cfg_i => cfg_i, word_o => word_o
      );
end architecture sim;
