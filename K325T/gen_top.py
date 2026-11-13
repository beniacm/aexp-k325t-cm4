#!/usr/bin/env python3
"""Generate K325T/top_qmtech_k325t_cm4.vhd from M2M's top_mega65-r6.vhd: keep the R6 top's
internal signals and its framework + core instances, remap the R6 board pins.
(AExp: the same script as the C64MEGA65 K325T port.)"""
import re, sys
R6 = sys.argv[1]; OUT = sys.argv[2]
src = open(R6).read().split('\n')

def block(start_pat, end_pat):
    i = next(k for k, l in enumerate(src) if re.search(start_pat, l))
    j = next(k for k in range(i, len(src)) if re.search(end_pat, src[k]))
    return src[i:j + 1]

decl = block(r'^architecture synthesis of mega65_r6', r'^begin')[1:-1]
fw   = block(r'^\s*i_framework : entity work.framework', r'\); -- i_framework')
core = block(r'^\s*CORE : entity work.MEGA65_Core', r'\); -- CORE')

FW = {  # framework formal -> K325T actual
 'clk_i': 'clk100', 'reset_n_i': 'sys_reset_n',
 'uart_rxd_i': 'qnice_uart_rx', 'uart_txd_o': 'qnice_uart_tx',
 'kb_io0_o': 'kio8', 'kb_io1_o': 'open', 'kb_io2_i': 'kio10',
 'sd_reset_o': 'sd_cs_n_s', 'sd_clk_o': 'sd_sclk_s', 'sd_mosi_o': 'sd_mosi_s',
 'sd_miso_i': 'sd_miso_s', 'sd_cd_i': "'0'",            # emulated card is always present
 'sd2_reset_o': 'open', 'sd2_clk_o': 'open', 'sd2_mosi_o': 'open',
 'sd2_miso_i': "'1'", 'sd2_cd_i': "'1'",                # no second (tray) card
 'paddle_i': '"0000"', 'paddle_drain_o': 'open',
 'tmds_data_p_o': 'tmds_data_p', 'tmds_data_n_o': 'tmds_data_n',
 'tmds_clk_p_o': 'tmds_clk_p', 'tmds_clk_n_o': 'tmds_clk_n',
}
for p in ['vga_red_o','vga_green_o','vga_blue_o','vga_hs_o','vga_vs_o','vdac_clk_o','vdac_sync_n_o',
          'vdac_blank_n_o','hr_d_io','hr_rwds_io','hr_reset_o','hr_clk_p_o','hr_cs0_o',
          'hdmi_scl_io','hdmi_sda_io','vga_scl_io','vga_sda_io','audio_scl_io','audio_sda_io',
          'i2c_scl_io','i2c_sda_io','fpga_sda_io','fpga_scl_io','grove_sda_io','grove_scl_io']:
    FW[p] = 'open'
for n, d in ((1, 'a'), (2, 'b')):
    for i, dirn in enumerate(['up', 'down', 'left', 'right', 'fire']):
        FW['joy_%d_%s_n_i' % (n, dirn)] = 'joy%s_n(%d)' % (d, i)
        FW['joy_%d_%s_n_o' % (n, dirn)] = 'open'

CORE = {'clk_i': 'clk100',
 'iec_reset_n_o': 'open', 'iec_atn_n_o': 'open', 'iec_clk_n_i': "'1'", 'iec_clk_n_o': 'open',
 'iec_data_n_i': "'1'", 'iec_data_n_o': 'open', 'iec_srq_n_i': "'1'", 'iec_srq_n_o': 'open',
 'cart_phi2_o': 'open', 'cart_dotclock_o': 'open', 'cart_dma_i': "'1'",
 # pot lines: the Amiga mouse's right / middle buttons (K325T/amiga_mouse.vhd, port 1)
 'main_pot1_x_i': 'core_pots(31 downto 24)', 'main_pot1_y_i': 'core_pots(23 downto 16)',
 'main_pot2_x_i': 'core_pots(15 downto 8)',  'main_pot2_y_i': 'core_pots(7 downto 0)'}

def remap(lines, table, extra_generics):
    out, used = [], set()
    for l in lines:
        m = re.match(r'^(\s*)(\w+)(\s*=>\s*)([^,]*?)(,?)(\s*--.*)?$', l)
        if m and m.group(2) in table:
            used.add(m.group(2))
            l = '%s%s%s%s%s' % (m.group(1), m.group(2), m.group(3), table[m.group(2)], m.group(5))
        if re.match(r'^\s*G_BOARD\s*=>', l) and extra_generics:
            l = l.rstrip().rstrip(',') + ',\n' + extra_generics
        out.append(l)
    missing = set(table) - used
    assert not missing, missing
    return out

fw = remap(fw, FW, '''         G_EXT_HR      => true,       -- memory bus from avm_mig (DDR3)
         G_TMDS_INVERT => "1010",     -- J11: green (D1) and clock pairs have P/N swapped
         G_NO_I2C      => true,
         G_AUDIO_EXT_CLK => true,     -- the core's audio comes from its ungated source clock
         G_QNICE_LOCAL => not G_LXSHELL  -- a1200-lxshell: the menu processor on the Linux module''')
# framework: external memory ports (inserted before the last port line)
last = max(k for k, l in enumerate(fw) if '=>' in l)
fw[last] = fw[last].rstrip() + ','
fw.insert(last + 1, '''      ext_hr_clk_i            => mig_ui_clk,
      ext_hr_rst_i            => mem_not_ready,
      ext_avm_write_o         => mem_write,
      ext_avm_read_o          => mem_read,
      ext_avm_address_o       => mem_address,
      ext_avm_writedata_o     => mem_writedata,
      ext_avm_byteenable_o    => mem_byteenable,
      ext_avm_burstcount_o    => mem_burstcount,
      ext_avm_readdata_i      => mem_readdata,
      ext_avm_readdatavalid_i => mem_readdatavalid,
      ext_avm_waitrequest_i   => mem_waitrequest,
      main_audio_clk_i        => amiga_audio_clk''')
core = remap(core, CORE, None)
# core: the K325T stall machinery (stall_clk.vhd): configuration byte from the bridge, diagnostics
last = max(k for k, l in enumerate(core) if '=>' in l)
core[last] = core[last].rstrip() + ','
core.insert(last + 1, '''         k325t_stall_cfg_i       => rk_vid_sel,
         k325t_stall_diag_o      => stall_diag,
         k325t_probe_i           => mig_dbg,
         k325t_stall_mode_o      => stall_mode,
         k325t_lp_req_o          => cc_req,
         k325t_lp_we_o           => cc_we,
         k325t_lp_addr_o         => cc_addr,
         k325t_lp_wdata_o        => cc_wdata,
         k325t_lp_busy_i         => cc_busy,
         k325t_lp_rvalid_i       => cc_rvalid,
         k325t_lp_rdata_i        => lp_rdata,
         k325t_lp_done_i         => cc_done,
         k325t_mbox_o            => amiga_mbox,
         k325t_pf_stats_o        => amiga_pf_stats,
         k325t_fast_dbg_o        => amiga_fast_dbg,
         k325t_audio_clk_o       => amiga_audio_clk,
         k325t_hd_clk_i          => clk162,
         k325t_hd_sck_i          => hd_sck_c,
         k325t_hd_mosi_i         => hd_mosi_c,
         k325t_hd_cs_n_i         => hd_cs_n_c,
         k325t_hd_miso_o         => hd_miso_s,
         k325t_hd_miso_oe_o      => hd_miso_oe,
         k325t_hd_att_o          => hd_att_s,
         k325t_hd_en_o           => hd_en''')

tpl = open(sys.argv[3]).read()
tpl = tpl.replace('--@R6_DECLARATIONS@', '\n'.join(decl))
tpl = tpl.replace('--@FRAMEWORK@', '\n'.join(fw))
tpl = tpl.replace('--@CORE@', '\n'.join(core))
open(OUT, 'w').write(tpl)
print("ok", len(decl), len(fw), len(core))
