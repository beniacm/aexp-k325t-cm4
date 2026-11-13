-- avm_fifo_pass.vhd -- the bench's stand-in for M2M's avm_fifo (xpm FIFOs): one clock on both sides,
-- so the Avalon signals pass straight through.  Simulation tooling only (host_bench.vhd).
library ieee;
use ieee.std_logic_1164.all;
entity avm_fifo is
   generic (G_WR_DEPTH : integer; G_RD_DEPTH : integer; G_FILL_SIZE : natural := 5;
            G_ADDRESS_SIZE : integer; G_DATA_SIZE : integer);
   port (
      s_clk_i, s_rst_i      : in  std_logic;
      s_avm_waitrequest_o   : out std_logic;
      s_avm_write_i         : in  std_logic;
      s_avm_read_i          : in  std_logic;
      s_avm_address_i       : in  std_logic_vector(G_ADDRESS_SIZE-1 downto 0);
      s_avm_writedata_i     : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      s_avm_byteenable_i    : in  std_logic_vector(G_DATA_SIZE/8-1 downto 0);
      s_avm_burstcount_i    : in  std_logic_vector(7 downto 0);
      s_avm_readdata_o      : out std_logic_vector(G_DATA_SIZE-1 downto 0);
      s_avm_readdatavalid_o : out std_logic;
      m_clk_i, m_rst_i      : in  std_logic;
      m_avm_waitrequest_i   : in  std_logic;
      m_avm_write_o         : out std_logic;
      m_avm_read_o          : out std_logic;
      m_avm_address_o       : out std_logic_vector(G_ADDRESS_SIZE-1 downto 0);
      m_avm_writedata_o     : out std_logic_vector(G_DATA_SIZE-1 downto 0);
      m_avm_byteenable_o    : out std_logic_vector(G_DATA_SIZE/8-1 downto 0);
      m_avm_burstcount_o    : out std_logic_vector(7 downto 0);
      m_avm_readdata_i      : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      m_avm_readdatavalid_i : in  std_logic);
end entity;
architecture sim of avm_fifo is
begin
   s_avm_waitrequest_o   <= m_avm_waitrequest_i;
   m_avm_write_o         <= s_avm_write_i;
   m_avm_read_o          <= s_avm_read_i;
   m_avm_address_o       <= s_avm_address_i;
   m_avm_writedata_o     <= s_avm_writedata_i;
   m_avm_byteenable_o    <= s_avm_byteenable_i;
   m_avm_burstcount_o    <= s_avm_burstcount_i;
   s_avm_readdata_o      <= m_avm_readdata_i;
   s_avm_readdatavalid_o <= m_avm_readdatavalid_i;
end architecture;
