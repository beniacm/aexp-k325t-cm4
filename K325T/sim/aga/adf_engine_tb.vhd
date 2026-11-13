-- adf_engine_tb.vhd -- the core's adf_track_engine (CORE/vhdl) with the bench's generics, for the
-- GHDL -> Verilog translation of the AGA bench: df0 served from an ADF image held by the C++ driver
-- (Avalon reads answered through DPI in tb_top.sv), exactly the RTL the board uses.
-- Simulation tooling only, not part of the core.
library ieee;
use ieee.std_logic_1164.all;

entity adf_engine_tb is
   port (
      clk                 : in  std_logic;
      reset               : in  std_logic;
      bus_grant           : in  std_logic;
      disk_mounted        : in  std_logic;
      disk_tracks         : in  std_logic_vector(7 downto 0);
      -- a1200-lxshell bench: the write-back path to adf_mount_wrapper (defaults = write protected)
      write_en            : in  std_logic := '0';
      wr_track            : out std_logic_vector(7 downto 0);
      wr_req              : out std_logic;
      wr_ack              : in  std_logic := '0';
      avm_byteenable      : out std_logic_vector(1 downto 0);
      io_fpga             : out std_logic;
      io_strobe           : out std_logic;
      io_din              : out std_logic_vector(15 downto 0);
      io_dout             : in  std_logic_vector(15 downto 0);
      io_wait             : in  std_logic;
      avm_write           : out std_logic;
      avm_read            : out std_logic;
      avm_address         : out std_logic_vector(31 downto 0);
      avm_writedata       : out std_logic_vector(15 downto 0);
      avm_readdata        : in  std_logic_vector(15 downto 0);
      avm_readdatavalid   : in  std_logic;
      avm_waitrequest     : in  std_logic
   );
end entity adf_engine_tb;

architecture sim of adf_engine_tb is
begin
   i_eng : entity work.adf_track_engine
      generic map (
         G_BASE_ADDRESS => (others => '0')
      )
      port map (
         clk_main_i          => clk,
         reset_i             => reset,
         bus_grant_i         => bus_grant,
         disk_mounted_i      => disk_mounted,
         disk_tracks_i       => disk_tracks,
         write_en_i          => write_en,
         wr_track_o          => wr_track,
         wr_req_o            => wr_req,
         wr_ack_i            => wr_ack,
         io_fpga_o           => io_fpga,
         io_strobe_o         => io_strobe,
         io_din_o            => io_din,
         io_dout_i           => io_dout,
         io_wait_i           => io_wait,
         avm_write_o         => avm_write,
         avm_read_o          => avm_read,
         avm_address_o       => avm_address,
         avm_writedata_o     => avm_writedata,
         avm_byteenable_o    => avm_byteenable,
         avm_burstcount_o    => open,
         avm_readdata_i      => avm_readdata,
         avm_readdatavalid_i => avm_readdatavalid,
         avm_waitrequest_i   => avm_waitrequest
      );
end architecture sim;
