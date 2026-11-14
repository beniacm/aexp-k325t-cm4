// tb_top.sv -- AGA + 68020 bench (stage-3 groundwork), from the A1200 DDR3 study's trace bench.
// minimig.v + cpu_wrapper.v (fx68k or TG68K, chosen by the 0xF4 config word as in MiSTer:
// minimig's cpucfg output drives cpu_wrapper) + amiga_clk.v, a BRAM-like memory model on minimig's
// SRAM-style port (1-tick read latency, as mega65.vhd), chip48 fed like MiSTer's sdram_ctrl
// (the 3 following words of the 64-bit group), a userio config replay (as amiga_config.vhd),
// and a DPI hook that the C++ side uses to log every memory access with its source.
// Simulation tooling only, not part of the core.
module tb_top (
  input  wire        clk,             // the machine clock (gated source clock when use_cache)
  // stage 3: chip RAM through the stage-2 chip_cache RTL (GHDL translation) with a DDR3 line-port
  // model, instead of the ideal memory
  input  wire        use_cache,
  input  wire        stock020,        // stage 3: 68EC020 stock-speed timing (cpucfg b2) + instruction cache
  // a1200-fastcpu: fast RAM (cpu_wrapper's fastramcfg; amiga_fastram RTL with an Avalon DDR3 model in
  // ui_clk, so only with use_cache) and the "fast 68020" setting
  input  wire [2:0]  cfg_fast,
  input  wire        fastcpu,          // cpucfg b3: the stock-speed throttle off (main.vhd: menu line "Fast 68020")
  input  wire        fastclk,          // a1200-fastclk: the fast 68020 is fc_cpu on cpu_clk (main.vhd: cpu_fast)
  input  wire        cpu_clk,          // a1200-fastclk: its clock (51.59 MHz, not gated)
  input  wire [7:0]  fc_opt,           // fc8: fc_cpu's speed options (opt_i; main.cpp --fc-opt)
  // a1200-fastclk fc6: the setting change (main.cpp --switch).  fastclk / fastcpu are the menu bits; main.vhd
  // latches them while the CPU is in reset (cpu_fast).  m2m_rst = the M2M reset (machine clock): the stock
  // fast-RAM instance's rst_i and, synchronised into ui_clk, the framework's hr_rst (both fast-RAM masters,
  // the DDR3 model aborts a read burst: avm_mig drains and discards its beats); 0 = as before
  input  wire        m2m_rst,
  output wire [9:0]  o_hr_fc_out,      // mega65.vhd p_fc_sel: read beats outstanding on the fast-RAM master
  output wire        o_hr_fcsel,       // ... which instance drives it (1 = the fast CPU's)
  output wire        o_fc_qbusy,       // fc_cpu: stores queued or a mailbox access open (not qempty_o)
  output wire        o_fc_mbopen,      // fc_cpu: a mailbox request not yet answered
  output wire        o_cpu_fast,       // main.vhd cpu_fast (the latched setting)
  // fc8 census (main.cpp --fcc): fc_cpu's kernel boundary and controller state, sampled before each cpu_clk edge
  output wire [31:0] o_fcc_b,          // packed state bits (fc_census.h)
  output wire [15:0] o_fcc_c,
  output wire [31:0] o_fcc_a,          // kernel bus address (24-bit masked as on the bus)
  output wire [31:0] o_fcc_pc,         // kernel exe_pc
  output wire [31:0] o_fcc_fa,         // fill line address
  output wire [31:0] o_fcc_mba,        // mailbox request address
  output wire [2:0]  o_fcm_st,         // fc_mbox state (machine clock)
  output wire [15:0] o_fcc_op,         // kernel exe_opcode
  input  wire        fr_quick,         // amiga_fastram quick_i: read hits in 2 clocks (main.vhd: with fastcpu)
  input  wire [7:0]  flat_min, flat_span, flat_wr,   // fast RAM Avalon model: read latency min + random(span), write accept
  input  wire        kick512,         // 512 KB Kickstart (the cache's kick512_i)
  input  wire [6:0]  pf_en,           // stage 2b prefetch enables (bpl, spr, aud, dsk, cop, blt, cpu)
  output wire [671:0] o_pf_stats,     // the cache's prefetch counters (issued / useful / wasted per class)
  input  wire        src_clk,         // ungated source clock (the cache's port A, tags, misses)
  input  wire        ui_clk,          // MIG ui_clk (fill engine, line-port model)
  input  wire        cache_reset,     // the M2M full reset: latches mode and shrink, flushes
  input  wire        cache_on,
  input  wire [1:0]  shrink,
  input  wire [7:0]  lat_min, lat_span,   // line-port latency in ui_clk cycles: min + random(span)
  output wire        miss,            // combinational: the source edge must not reach clk
  output wire [31:0] fills, wbacks,
  output reg  [31:0] chk_bad = 0,     // chip reads whose cache data differ from the shadow memory
  output reg  [31:0] chk48_bad = 0,
  output reg  [31:0] chk_n = 0,
  input  wire        rst_ext,
  input  wire [15:0] cfg_chipset,   // 0xF3 payload  (bit4 AGA, bit3 ECS)
  input  wire [15:0] cfg_cpu,       // 0xF4 payload
  input  wire [15:0] cfg_mem,       // 0xF5 payload  (CC=11: 2 MB chip)
  output wire        cfg_done,
  input  wire [15:0] cfg_floppy,    // 0xF7 payload  (bit 0: floppy turbo)
  // a1200-ide: Gayle IDE (0xF8 = 0x23 when ide_on) and the hard disk SPI of hdd_spi.vhd (main.cpp's
  // SPI master + the shared server core hddsrv_core.c on the other side)
  input  wire        ide_on,
  input  wire        kbd_rst,          // a1200-ide tests: with rst_ext, a reset hdd_spi does not see (the board's
                                        // keyboard reset: amiga_rst only, not main_reset_core/m2m)
  input  wire        cpu_rst,          // a1200-ide tests: the 68k RESET instruction line (minimig _cpu_reset_in)
  input  wire        hd_sck, hd_mosi, hd_cs_n,
  output wire        hd_miso, hd_miso_oe, hd_att,
  // df0: the core's adf_track_engine, image words served by the C++ driver (DPI adf_rd)
  input  wire        disk_mounted,
  input  wire [7:0]  disk_tracks,
  // a1200-lxshell bench link: the host master (host_bench.vhd: qnice_host + the Kickstart port's
  // decode) on its own 50 MHz clock; main.cpp's --host-link feeds its streams from a named pipe
  input  wire        q_clk,
  input  wire        q_rst,
  input  wire        host_on,         // the Kickstart reaches the cache's DDR3 only through the master
  input  wire [7:0]  hs_data,
  input  wire        hs_valid,
  output wire        hs_pop,
  output wire [7:0]  hm_data,
  output wire        hm_push,
  input  wire        hm_full,
  input  wire        h_clr,
  output wire [7:0]  h_flags,
  output wire [5:0]  h_csr,
  output wire [255:0] h_cfm,
  output wire        h_mounted,       // adf_mount_wrapper: a valid image is loaded (df0 follows it with host_on)
  output wire [7:0]  h_tracks,
  output wire        h_wr_en,
  // backdoor memory port (C++ writes test programs while the CPU runs)
  input  wire        bd_we,
  input  wire [20:0] bd_addr,       // chip word address
  input  wire [15:0] bd_data,
  output wire [8:0]  o_hpos,
  output wire [10:0] o_vpos,
  output wire [23:1] o_cpu_addr,
  output wire        o_cpu_as_n,
  output wire [23:0] o_red_green,
  output wire [1:0]  o_cpustate,     // cpu_wrapper's cpustate (0 fetch, 1 idle, 2 read, 3 write)
  output wire [31:0] o_cpu_addr32,   // TG68K address (fx68k: 24 bit)
  output wire        o_cpu_ack,      // the CPU's request is acknowledged in this clock (TG68K clkena)
  output wire        o_hsync_n,
  output wire        o_vsync_n
);

  // ---------------- clocks / enables ----------------
  wire clk7_en, clk7n_en, c1, c3, cck;
  wire [9:0] eclk;
  amiga_clk i_clk (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
                   .cck(cck), .eclk(eclk), .reset_n(~rst_ext));

  wire cpu_reset_n;
  reg  cpu_ph1 = 0, cpu_ph2 = 0;
  always @(posedge clk) begin
    if (!cpu_reset_n) begin cpu_ph1 <= 0; cpu_ph2 <= 0; end
    else begin cpu_ph2 <= ~c1 & ~c3; cpu_ph1 <= c1 & c3; end
  end

  // ---------------- host config replay (amiga_config.vhd semantics) ----------------
  reg        io_uio = 0, io_strobe = 0;
  reg [15:0] io_din = 0;
  wire       io_wait;
  wire [15:0] io_dout;
  reg [3:0]  idx = 0;
  reg [2:0]  st = 0;
  reg [10:0] cnt = 1023;
  reg        done = 0;
  assign cfg_done = done;
  function [7:0] seq_cmd(input [3:0] i);
    case (i) 0: seq_cmd=8'hF1; 1: seq_cmd=8'hF3; 2: seq_cmd=8'hF4; 3: seq_cmd=8'hF5;
             4: seq_cmd=8'hF6; 5: seq_cmd=8'hF7; 6: seq_cmd=8'hF8; 7: seq_cmd=8'hF9;
             8: seq_cmd=8'hF2; default: seq_cmd=8'hF1; endcase
  endfunction
  function [15:0] seq_pl(input [3:0] i);
    case (i) 0: seq_pl=16'h0007; 1: seq_pl=cfg_chipset; 2: seq_pl=cfg_cpu; 3: seq_pl=cfg_mem;
             5: seq_pl=cfg_floppy; 6: seq_pl=ide_on ? 16'h0023 : 16'h0000; 7: seq_pl=16'h0008;
             default: seq_pl=16'h0000; endcase
  endfunction
  always @(posedge clk) begin
    io_strobe <= 0;
    if (rst_ext) begin st <= 0; idx <= 0; cnt <= 1023; io_uio <= 0; done <= 0; end
    else case (st)
      0: if (cnt != 0) cnt <= cnt - 1; else begin cnt <= 63; st <= 1; end
      1: begin io_uio <= 0; if (cnt != 0) cnt <= cnt - 1;
               else begin io_uio <= 1; io_din <= {8'h00, seq_cmd(idx)}; cnt <= 63; st <= 2; end end
      2: if (cnt != 0) cnt <= cnt - 1; else if (!io_wait) begin io_strobe <= 1; cnt <= 63; st <= 3; end
      3: begin io_din <= seq_pl(idx);
               if (cnt != 0) cnt <= cnt - 1; else if (!io_wait) begin io_strobe <= 1; cnt <= 63; st <= 4; end end
      4: if (cnt != 0) cnt <= cnt - 1;
         else begin io_uio <= 0; if (idx == 9) st <= 5; else begin idx <= idx + 1; cnt <= 63; st <= 1; end end
      5: done <= 1;
      default: ;
    endcase
  end

  // ---------------- df0: adf_track_engine (as main.vhd: it owns IO_STROBE/IO_DIN after the replay) ----
  wire        io_fpga, eng_strobe;
  wire [15:0] eng_din;
  wire        avm_read, avm_write;
  wire [31:0] avm_address;
  wire [15:0] avm_writedata;
  reg  [15:0] avm_rdata = 0;
  reg         avm_rvalid = 0;
  import "DPI-C" function int adf_rd(input int addr);
  wire [7:0]  eng_wr_track;
  wire        eng_wr_req, eng_wr_ack;
  wire [1:0]  avm_be;
  adf_engine_tb i_adf (
    .clk(clk), .reset(rst_ext), .bus_grant(done), .disk_mounted(host_on ? h_mounted : disk_mounted),
    .disk_tracks(host_on ? h_tracks : disk_tracks),
    .write_en(host_on & h_wr_en), .wr_track(eng_wr_track), .wr_req(eng_wr_req), .wr_ack(host_on & eng_wr_ack),
    .avm_byteenable(avm_be),
    .io_fpga(io_fpga), .io_strobe(eng_strobe), .io_din(eng_din), .io_dout(io_dout), .io_wait(io_wait),
    .avm_write(avm_write), .avm_read(avm_read), .avm_address(avm_address), .avm_writedata(avm_writedata),
    .avm_readdata(avm_rdata), .avm_readdatavalid(avm_rvalid), .avm_waitrequest(1'b0));
  always @(posedge clk) begin
    avm_rvalid <= 0;
    if (avm_read) begin avm_rdata <= host_on ? adfmem[avm_address[18:0]] : adf_rd(avm_address)[15:0]; avm_rvalid <= 1; end
    // the engine commits verified sectors into the image (the wrapper's write-back reads them there)
    if (host_on && avm_write) begin
      if (avm_be[0]) adfmem[avm_address[18:0]][7:0]  <= avm_writedata[7:0];
      if (avm_be[1]) adfmem[avm_address[18:0]][15:8] <= avm_writedata[15:8];
    end
  end
  // +flpdbg: the first floppy-channel frames and image reads
  reg flpdbg = 0; initial flpdbg = $test$plusargs("flpdbg");
  reg io_fpga_q = 0; integer nfr = 0, nrd = 0, nst = 0;
  always @(posedge clk) if (flpdbg) begin
    io_fpga_q <= io_fpga;
    if (eng_strobe && io_fpga) begin nst <= nst + 1; if (nst < 400 || io_dout != 16'h0000 && io_dout != 16'h4489 && nst < 200000) $display("FLP strobe din=%04x dout=%04x wait=%0d v=%0d", eng_din, io_dout, io_wait, vpos); end
    if (io_fpga && !io_fpga_q) begin nfr <= nfr + 1; if (nfr < 60 || nfr % 1000 == 0) $display("FLP frame open v=%0d", vpos); end
    if (avm_read) begin nrd <= nrd + 1; if (nrd < 8) $display("FLP read %08x", avm_address); end
  end
  wire        mm_strobe = io_strobe | eng_strobe;
  wire [15:0] mm_din    = done ? eng_din : io_din;

  // ---------------- CPU ----------------
  wire [23:1] cpu_addr;
  wire [15:0] cpu_dout, cpu_din;
  wire [2:0]  cpu_ipl_n;
  wire cpu_as_n, cpu_uds_n, cpu_lds_n, cpu_rw, cpu_dtack_n, cpu_reset_out_n;
  wire        mm_rst_out;              // minimig's reset (as main.vhd's ide_reset_o -> hdd_spi mrst on the board)
  wire [31:0] nmi_addr;

  wire [1:0] mm_cpucfg;
  wire chip32_en, cpu_long, ram_long;
  wire [15:0] cpu_din2;
  reg  [15:0] kick2_n = 0; reg kick_q = 0;   // ideal memory: word A+1 of a Kickstart read
  reg  [15:0] dout2_hold = 0;   // word A+1 of a 32-bit CPU read, held from its slot's clk7_en edge
  // +dout2init=HEX: start with a stale word A+1 (the board after a reset: the second word of the last
  // 32-bit read before it; 0 at power-up hid the reset-vector bug, see reset_long_test.sh)
  initial begin : dout2_init
    reg [31:0] v;
    if ($value$plusargs("dout2init=%h", v)) dout2_hold = v[15:0];
  end
  wire [1:0] cpustate;
  wire        fr_sel, fr_ready, fr_lds_n, fr_uds_n;
  wire [28:1] fr_addr;
  wire [15:0] fr_wdata, fr_rdata;
  // a1200-fastclk (declared before their first use)
  wire [31:0] fc_ext_addr, fc_mb_addr, fc_mb_wdata, fc_mb_rdata, fc_fr_a, fc_vbr;
  wire [1:0]  fc_ext_state;
  wire [15:0] fc_ext_dout, fc_ext_din, fc_fr_wd, fc_fr_rd;
  wire        fc_fr_long;           // fc8 b4: a long fast-RAM write in one access
  wire [15:0] fc_fr_wd2;
  wire        fc_ext_uds_n, fc_ext_lds_n, fc_ext_long, fc_ext_ack, fc_rso;
  wire [2:0]  fc_ipl;
  wire [11:0] fc_zcfg;
  wire [3:0]  fc_cacr;
  wire        fc_mb_req, fc_mb_wr, fc_mb_long, fc_mb_uds_n, fc_mb_lds_n, fc_mb_ack, fc_mb_sync;
  wire        fc_fr_sel, fc_fr_we, fc_fr_u, fc_fr_l, fc_fr_ready;
  reg  [31:0] fc_vbr_s = 0, fc_vbr_m = 0;
  reg  [3:0]  fc_cacr_s = 0, fc_cacr_m = 0;
  reg         fc_rso_s = 1, fc_rso_m = 1;
  wire        fc_qempty;
  // fc6: main.vhd cpucfg_proc -- the setting is latched while the CPU is in reset (and at the first clock, so
  // that a static setting is in effect from the start, as before)
  reg         cpu_fast = 0, fastcpu_l = 0, lat0 = 0;
  always @(posedge clk) begin
    lat0 <= 1;
    if (!cpu_reset_n || !lat0) begin cpu_fast <= fastclk; fastcpu_l <= fastcpu; end
  end
  assign o_cpu_fast = cpu_fast;
  // fc7: main.vhd p_fc_cold -- the cold-boot window (from a cold reset until the CPU leaves the reset it causes,
  // while the CPU is held); power-up counts as a cold boot.  On the board every M2M reset is a cold reset
  // (amiga_cold_boot cold_req_i), so here m2m_rst is cold_i.  +noflush: the window never opens (the fc6 machine
  // with fc7's select gate)
  reg         fc_cold = 1, fc_cold_low = 0, fc_flush = 0, noflush = 0;
  initial noflush = $test$plusargs("noflush");
  always @(posedge clk) begin
    if (m2m_rst) begin fc_cold <= 1; fc_cold_low <= 0; end
    else if (fc_cold && !cpu_reset_n) fc_cold_low <= 1;
    else if (fc_cold && fc_cold_low && cpu_reset_n) begin fc_cold <= 0; fc_cold_low <= 0; end
    fc_flush <= fc_cold & ~cpu_reset_n & ~noflush;
  end
  reg fc_flush_d = 0;
  always @(posedge clk) begin
    fc_flush_d <= fc_flush;
    if (fc_flush != fc_flush_d) $display("FLUSH window %s at %0t", fc_flush ? "opens" : "closes", $time);
  end
  wire        fs_write, fs_read, ff_write, ff_read;
  wire [31:0] fs_address, ff_address;
  wire [15:0] fs_writedata, ff_writedata;
  wire [1:0]  fs_be, ff_be;
  wire [7:0]  fs_burst, ff_burst;
  cpu_wrapper i_cpu (
    .reset(cpu_reset_n), .reset_out(cpu_reset_out_n), .clk(clk), .ph1(cpu_ph1), .ph2(cpu_ph2),
    // stage 3: MiSTer's cpucfg (b2 = 68EC020 stock timing), cachecfg b0 = its instruction cache
    .cpucfg({1'b0, fastcpu_l, stock020 & (mm_cpucfg == 2'b11), mm_cpucfg}), .ntsc(1'b0),
    .fastramcfg(cfg_fast), .cachecfg({2'b00, stock020}), .bootrom(1'b0),
    .chip_addr(cpu_addr), .chip_dout(cpu_dout), .chip_din(cpu_din), .chip_as(cpu_as_n),
    .chip_uds(cpu_uds_n), .chip_lds(cpu_lds_n), .chip_rw(cpu_rw), .chip_dtack(cpu_dtack_n),
    .chip_ipl(cpu_ipl_n),
    .chip32_en(chip32_en), .chip_long(cpu_long), .chip_din2(cpu_din2), .chip_dout2(dout2_hold),
    .fastchip_dout(16'h0), .fastchip_sel(), .fastchip_lds(), .fastchip_uds(), .fastchip_rnw(),
    .fastchip_lw(), .fastchip_selack(1'b0), .fastchip_ready(1'b0),
    .ramsel(fr_sel), .ramaddr(fr_addr), .ramdin(fr_wdata), .ramdout(fr_rdata), .ramready(fr_ready),
    .ramlds(fr_lds_n), .ramuds(fr_uds_n),
    .ramshared(), .toccata_ena(), .toccata_base(), .cpustate(cpustate), .cacr(), .nmi_addr(nmi_addr),
    // a1200-fastclk: the external CPU port (main.vhd)
    .ext_en(cpu_fast), .ext_addr(fc_ext_addr), .ext_state(fc_ext_state), .ext_dout(fc_ext_dout),
    .ext_uds_n(fc_ext_uds_n), .ext_lds_n(fc_ext_lds_n), .ext_long(fc_ext_long), .ext_vbr(fc_vbr_m),
    .ext_cacr(fc_cacr_m), .ext_reset_out(fc_rso_m), .ext_ack(fc_ext_ack), .ext_din(fc_ext_din),
    .ext_ipl(fc_ipl), .ext_zcfg(fc_zcfg));

  // ---------------- a1200-fastclk: the fast 68020 on cpu_clk and its mailbox (as main.vhd) ----------------
  always @(posedge clk) begin
    fc_vbr_s <= fc_vbr; fc_vbr_m <= fc_vbr_s; fc_cacr_s <= fc_cacr; fc_cacr_m <= fc_cacr_s;
    fc_rso_s <= fc_rso; fc_rso_m <= fc_rso_s;
  end
  fc_cpu i_fc_cpu (
    .clk(cpu_clk), .rst_n_i(cpu_reset_n & cpu_fast), .flush_i(fc_flush),
    .cfg_z2_i(fc_zcfg[0]), .cfg_z3e0_i(fc_zcfg[1]), .cfg_z3e1_i(fc_zcfg[2]), .cfg_z3b0_i(fc_zcfg[7:3]),
    .cfg_z3b1_i(fc_zcfg[11:8]), .cfg_chipcode_i(1'b1), .cfg_a24_i(stock020 & (mm_cpucfg == 2'b11)), .ipl_i(fc_ipl), .opt_i(fc_opt),
    .mb_req_o(fc_mb_req), .mb_addr_o(fc_mb_addr), .mb_wr_o(fc_mb_wr), .mb_long_o(fc_mb_long), .mb_sync_o(fc_mb_sync),
    .mb_uds_n_o(fc_mb_uds_n), .mb_lds_n_o(fc_mb_lds_n), .mb_wdata_o(fc_mb_wdata),
    .mb_ack_i(fc_mb_ack), .mb_rdata_i(fc_mb_rdata),
    .fr_sel_o(fc_fr_sel), .fr_addr_o(fc_fr_a), .fr_we_o(fc_fr_we), .fr_uds_n_o(fc_fr_u), .fr_lds_n_o(fc_fr_l),
    .fr_wdata_o(fc_fr_wd), .fr_rdata_i(fc_fr_rd), .fr_ready_i(fc_fr_ready), .fr_long_o(fc_fr_long), .fr_wdata2_o(fc_fr_wd2),
    .vbr_o(fc_vbr), .cacr_o(fc_cacr), .resetout_n_o(fc_rso), .qempty_o(fc_qempty));
  fc_mbox i_fc_mbox (
    .clk_i(clk), .flush_i(fc_flush), .mb_req_i(fc_mb_req), .mb_addr_i(fc_mb_addr), .mb_wr_i(fc_mb_wr), .mb_long_i(fc_mb_long), .mb_sync_i(fc_mb_sync),
    .mb_uds_n_i(fc_mb_uds_n), .mb_lds_n_i(fc_mb_lds_n), .mb_wdata_i(fc_mb_wdata), .mb_ack_o(fc_mb_ack),
    .mb_rdata_o(fc_mb_rdata), .ext_addr_o(fc_ext_addr), .ext_state_o(fc_ext_state), .ext_dout_o(fc_ext_dout),
    .ext_uds_n_o(fc_ext_uds_n), .ext_lds_n_o(fc_ext_lds_n), .ext_long_o(fc_ext_long), .ext_ack_i(fc_ext_ack),
    .ext_din_i(fc_ext_din));
  wire [26:0] fc_fr_ddr = fc_fr_a[31:24] == 8'h00 ? {4'b0001, fc_fr_a[23:1]} : {1'b1, fc_fr_a[26:1]};

  // ---------------- a1200-fastcpu: fast RAM (amiga_fastram RTL, as mega65.vhd) ----------------
  // mega65.vhd: main_fast_ddr = "0001" & addr(23:1) for Zorro II, '1' & addr(26:1) for Zorro III
  wire [26:0] fr_ddr = fr_addr[28] ? {4'b0001, fr_addr[23:1]} : {1'b1, fr_addr[26:1]};
  wire        fa_write, fa_read;
  wire [31:0] fa_address;
  wire [15:0] fa_writedata;
  wire [1:0]  fa_be;
  wire [7:0]  fa_burst;
  reg  [15:0] fa_rdata = 0;
  reg         fa_rvalid = 0, fa_acc = 0;
  // fc6: the framework's hr_rst (every M2M reset) = m2m_rst synchronised into ui_clk (framework.vhd ext_rst_sync)
  reg  [2:0]  hr_rst_s = 0;
  always @(posedge ui_clk) hr_rst_s <= {hr_rst_s[1:0], m2m_rst};
  wire        hr_rst = hr_rst_s[2];
  // mega65.vhd p_fc_sel: which instance drives the fast-RAM master follows the setting (cpu_fast), switched
  // only while the master is quiet: no request and no read beats outstanding (hr_fc_out).  +fcsel_old = the
  // select as in fc5 (hr_fc_out not cleared by hr_rst: the beats of a burst that the reset aborts never come)
  reg  [1:0]  hr_fc_s = 0;
  reg         hr_fcsel = 0;
  reg  [9:0]  hr_fc_out = 0;
  reg  [4:0]  hr_fc_q = 0;
  wire        fs_idle, ff_idle, fs_flbusy, ff_flbusy;
  reg         fcsel_old = 0;
  initial fcsel_old = $test$plusargs("fcsel_old");
  wire        fa_wreq = ~(fa_acc & ~hr_rst);     // avm_mig: waitrequest high during avm_rst
  always @(posedge ui_clk) begin
    hr_fc_s <= {hr_fc_s[0], cpu_fast};
    if (fa_read && !fa_wreq) begin
      if (fa_rvalid) hr_fc_out <= hr_fc_out + fa_burst - 1;
      else hr_fc_out <= hr_fc_out + fa_burst;
    end else if (fa_rvalid && (fcsel_old || hr_fc_out != 0)) hr_fc_out <= hr_fc_out - 1;
    // fc7: only after 16 clocks in a row with the selected instance idle (no request, no queued write)
    if (hr_fc_s[1] != hr_fcsel && hr_fc_out == 0 && !fa_read && !fa_write && (fcsel_old || (hr_fcsel ? ff_idle : fs_idle))) begin
      if (fcsel_old || hr_fc_q == 15) begin hr_fcsel <= hr_fc_s[1]; hr_fc_q <= 0; end
      else hr_fc_q <= hr_fc_q + 1;
    end else hr_fc_q <= 0;
    if (hr_rst && !fcsel_old) hr_fc_out <= 0;
  end
  assign o_hr_fc_out = hr_fc_out;
  assign o_hr_fcsel = hr_fcsel;
  assign o_fc_qbusy = ~fc_qempty;
  assign o_fc_mbopen = fc_mb_req ^ fc_mb_ack;
  // fc8 census probes (hierarchical references into the GHDL-converted fc_cpu / fc_mbox; enum codes in declaration order)
  assign o_fcc_b = {fc_mb_req ^ fc_mb_ack, i_fc_mbox.st, i_fc_cpu.kernel.flagssr[5], i_fc_cpu.kernel.stop,
                    i_fc_cpu.kernel.clkena_lw, i_fc_cpu.kernel.decodeopc, i_fc_cpu.k_lack, i_fc_cpu.is_rom,
                    i_fc_cpu.is_chip, i_fc_cpu.is_fast, i_fc_cpu.rst, i_fc_cpu.sync_r, i_fc_cpu.dr, i_fc_cpu.q_full,
                    i_fc_cpu.fill_mb, i_fc_cpu.fill_i, i_fc_cpu.pend_q, i_fc_cpu.dlb_hit, i_fc_cpu.ilb_hit,
                    i_fc_cpu.use_d, i_fc_cpu.use_i, i_fc_cpu.st, i_fc_cpu.k_bs, i_fc_cpu.ack, i_fc_cpu.req, i_fc_cpu.k_ena};
  assign o_fcc_c = {4'b0, i_fc_cpu.ilb2_hit, i_fc_cpu.nb_hit, i_fc_cpu.is_sync, i_fc_cpu.k_skip, i_fc_cpu.q_n, 1'b0, i_fc_cpu.kernel.flagssr[2:0]};
  assign o_fcc_a = i_fc_cpu.k_addr;
  assign o_fcc_pc = i_fc_cpu.kernel.exe_pc;
  assign o_fcc_fa = {i_fc_cpu.fill_a, 4'b0};
  assign o_fcc_mba = i_fc_cpu.mb_a;
  assign o_fcm_st = i_fc_mbox.st;
  assign o_fcc_op = i_fc_cpu.kernel.exe_opcode;
  amiga_fastram i_fastram (
    .clk_i(clk), .sel_i(fr_sel), .pulse_i(mm_cpucfg != 2'b00), .quick_i(fr_quick), .addr_i(fr_ddr), .we_i(cpustate == 2'b11),
    .uds_n_i(fr_uds_n), .lds_n_i(fr_lds_n), .wdata_i(fr_wdata), .rdata_o(fr_rdata), .ready_o(fr_ready),
    .rst_i(m2m_rst), .flush_i(fc_flush), .flush_busy_o(fs_flbusy), .dbg_o(),
    .hr_clk_i(ui_clk), .hr_rst_i(hr_rst), .avm_write_o(fs_write), .avm_read_o(fs_read),
    .avm_address_o(fs_address), .avm_writedata_o(fs_writedata), .avm_byteenable_o(fs_be),
    .avm_burstcount_o(fs_burst), .avm_readdata_i(fa_rdata), .avm_readdatavalid_i(fa_rvalid & ~hr_fcsel),
    .avm_waitrequest_i(fa_wreq | hr_fcsel), .idle_o(fs_idle));
  // a1200-fastclk: the fast 68020's own amiga_fastram (mega65.vhd i_fc_fastram); fc6: on the master as
  // mega65.vhd's select says (static settings: the fast one from the start, the stock one never)
  amiga_fastram_small i_fc_fastram (   // a1200-fastclk: G_IDX_BITS = 7 (256-byte cache)
    .clk_i(cpu_clk), .sel_i(fc_fr_sel), .pulse_i(1'b1), .quick_i(1'b1), .wq_i(1'b1), .addr_i(fc_fr_ddr),
    .we_i(fc_fr_we), .uds_n_i(fc_fr_u), .lds_n_i(fc_fr_l), .wdata_i(fc_fr_wd), .long_i(fc_fr_long), .wdata2_i(fc_fr_wd2), .rdata_o(fc_fr_rd),
    .ready_o(fc_fr_ready), .rst_i(1'b0), .flush_i(fc_flush), .flush_busy_o(ff_flbusy), .dbg_o(),
    .hr_clk_i(ui_clk), .hr_rst_i(hr_rst), .avm_write_o(ff_write), .avm_read_o(ff_read),
    .avm_address_o(ff_address), .avm_writedata_o(ff_writedata), .avm_byteenable_o(ff_be),
    .avm_burstcount_o(ff_burst), .avm_readdata_i(fa_rdata), .avm_readdatavalid_i(fa_rvalid & hr_fcsel),
    .avm_waitrequest_i(fa_wreq | ~hr_fcsel), .idle_o(ff_idle));
  // fc7: an access that waits for a flush sweep (would change the timing after a reset; expected never)
  reg fw_s = 0, fw_f = 0;
  always @(posedge clk) begin
    if (fr_sel && fs_flbusy && !fw_s) $display("FLUSHWAIT stock instance: an access waits for the sweep at %0t", $time);
    fw_s <= fr_sel && fs_flbusy;
  end
  always @(posedge cpu_clk) begin
    if (fc_fr_sel && ff_flbusy && !fw_f) $display("FLUSHWAIT fast instance: an access waits for the sweep at %0t", $time);
    fw_f <= fc_fr_sel && ff_flbusy;
  end
  assign fa_write = hr_fcsel ? ff_write : fs_write;
  assign fa_read = hr_fcsel ? ff_read : fs_read;
  assign fa_address = hr_fcsel ? ff_address : fs_address;
  assign fa_writedata = hr_fcsel ? ff_writedata : fs_writedata;
  assign fa_be = hr_fcsel ? ff_be : fs_be;
  assign fa_burst = hr_fcsel ? ff_burst : fs_burst;
  // DDR3 behind avm_mig, 8 MB of fast RAM (word address bits 21:0): a command is accepted (waitrequest
  // low for one clock) after flat_wr clocks for a write, at once for a read; read data comes
  // flat_min + random(flat_span) clocks after the accept, the 8 beats of a burst back to back.
  // fc6: hr_rst (avm_mig avm_rst): no command is accepted, a read burst in flight is drained and its
  // remaining beats are discarded (avm_mig S_DRAIN)
  reg [15:0] fmem [0:4194303] /*verilator public*/;
  reg [2:0]  fs = 0;
  reg [7:0]  fcnt = 0;
  reg [2:0]  fbeat = 0;
  reg [21:0] faddr = 0;
  reg [31:0] frnd = 32'h9e3779b9;
  reg        fdrop = 0;
  reg [21:0] fwaddr = 0;   // fc8: write bursts
  reg [7:0]  fwleft = 0;
  always @(posedge ui_clk) begin
    fa_acc <= 0; fa_rvalid <= 0;
    frnd <= {frnd[30:0], frnd[31] ^ frnd[21] ^ frnd[1] ^ frnd[0]};
    case (fs)
      0: if ((fa_read | fa_write) && !fa_acc && !hr_rst) begin fcnt <= fa_read ? 8'd0 : flat_wr; fs <= 1; end
      1: if (hr_rst) fs <= 0;
         else if (fcnt != 0) fcnt <= fcnt - 1; else begin fa_acc <= 1; fs <= 2; end
      2: begin   // the master sees waitrequest low at this edge (not during hr_rst: then nothing is accepted)
           if (hr_rst) fs <= 0;
           else if (fa_read) begin
             faddr <= fa_address[21:0]; fbeat <= 0; fs <= 3; fdrop <= 0;
             fcnt <= flat_min + (flat_span == 0 ? 8'd0 : frnd[7:0] % flat_span);
           end else begin
             if (fa_be[1]) fmem[fa_address[21:0]][15:8] <= fa_writedata[15:8];
             if (fa_be[0]) fmem[fa_address[21:0]][7:0]  <= fa_writedata[7:0];
             // fc8: a write burst (amiga_fastram G_LONGW: 2 beats): the next beats one per clock, as avm_mig gathers them
             if (fa_burst > 1) begin fwaddr <= fa_address[21:0] + 1; fwleft <= fa_burst - 1; fa_acc <= 1; fs <= 5; end
             else fs <= 0;
           end
         end
      3: begin if (hr_rst) fdrop <= 1; if (fcnt != 0) fcnt <= fcnt - 1; else fs <= 4; end
      4: begin
           fa_rdata <= fmem[{faddr[21:3], fbeat}]; fa_rvalid <= !(fdrop || hr_rst); fbeat <= fbeat + 1;
           if (hr_rst) fdrop <= 1;
           if (fbeat == 7) fs <= 0;
         end
      5: begin   // fc8: a further write beat (seen accepted at this edge)
           if (hr_rst) fs <= 0;
           else begin
             if (fa_be[1]) fmem[fwaddr][15:8] <= fa_writedata[15:8];
             if (fa_be[0]) fmem[fwaddr][7:0]  <= fa_writedata[7:0];
             fwaddr <= fwaddr + 1; fwleft <= fwleft - 1;
             if (fwleft > 1) fa_acc <= 1; else fs <= 0;
           end
         end
      default: fs <= 0;
    endcase
  end

  // ---------------- memory model ----------------
  wire [15:0] ram_wdata;
  wire [22:1] ram_addr;
  wire        ram_addr23;
  wire ram_bhe_n, ram_ble_n, ram_we_n, ram_oe_n;
  reg  [15:0] ram_q = 0;
  reg  [47:0] chip48_q = 0, chip48_n = 0;

  // word arrays: chip 2 MB, slow 512 KB, ext ROM ($E0) 512 KB, kick ($F8) 512 KB
  reg [15:0] chipmem [0:1048575] /*verilator public*/;
  reg [15:0] slowmem [0:262143];
  reg [15:0] extmem  [0:262143] /*verilator public*/;
  reg [15:0] kickmem [0:262143] /*verilator public*/;

  wire [3:0] reg_bank = ram_addr[22:19];
  wire is_chip = (ram_addr[22:21] == 2'b00);
  wire is_slow = (ram_addr[22:19] == 4'b1000) || (ram_addr[22:19] == 4'b1001) || (ram_addr[22:19] == 4'b1010);
  wire is_ext  = (ram_addr[22:19] == 4'b1100);
  wire is_kick = (ram_addr[22:19] == 4'b1111);
  wire [19:0] cw = ram_addr[20:1];
  wire [17:0] rw18 = ram_addr[18:1];

  // ---------------- stage 3: the chip_cache RTL and the line-port model ----------------
  wire       mm_dma_dbr;              // minimig patch 0002 (stage 2b): Agnus owns the bus, DMA register
  wire [8:1] mm_dma_reg;
  wire [15:0] cc_rdata;
  wire [47:0] cc_rdata48;
  wire        cc_req, cc_we, lp_busy, lp_rvalid, lp_done;
  wire [27:0] cc_addr;
  wire [511:0] cc_wdata;
  wire [127:0] lp_rdata;
  wire        cc_mode;
  wire        hr_write, hr_read;
  wire [31:0] hr_address;
  wire [15:0] hr_writedata;
  wire [1:0]  hr_be;
  reg  [15:0] hr_rdata = 0, hr_rd1 = 0;
  reg         hr_rvalid = 0, hr_rv1 = 0;
  wire        kq_we, kq_wait, kick512_h;
  wire [18:0] kq_addr;
  wire [7:0]  kq_data;
  host_bench i_host (.q_clk(q_clk), .q_rst(q_rst), .s_data(hs_data), .s_valid(hs_valid), .s_pop(hs_pop),
    .m_data(hm_data), .m_push(hm_push), .m_full(hm_full), .clr(h_clr), .flags(h_flags), .csr(h_csr),
    .cfm(h_cfm), .kq_we(kq_we), .kq_addr(kq_addr), .kq_data(kq_data), .kq_wait(kq_wait),
    .kick512(kick512_h),
    .disk_mounted(h_mounted), .disk_tracks(h_tracks), .write_en(h_wr_en),
    .hr_write(hr_write), .hr_read(hr_read), .hr_address(hr_address), .hr_writedata(hr_writedata),
    .hr_byteenable(hr_be), .hr_readdata(hr_rdata), .hr_readdatavalid(hr_rvalid), .hr_waitrequest(1'b0),
    .wrt_track(eng_wr_track), .wrt_req(eng_wr_req), .wrt_ack(eng_wr_ack));
  // the ADF image in "HyperRAM" (adf_mount_wrapper's word 0 = the track engine's word 0 in this bench):
  // written by the wrapper with byte enables, read back by it (2 q_clk latency) and by the engine
  reg  [15:0] adfmem [0:524287] /*verilator public*/;
  always @(posedge q_clk) begin
    hr_rv1 <= 0; hr_rvalid <= hr_rv1; hr_rdata <= hr_rd1;
    if (hr_write) begin
      if (hr_be[0]) adfmem[hr_address[18:0]][7:0]  <= hr_writedata[7:0];
      if (hr_be[1]) adfmem[hr_address[18:0]][15:8] <= hr_writedata[15:8];
    end
    if (hr_read) begin hr_rd1 <= adfmem[hr_address[18:0]]; hr_rv1 <= 1; end
  end
  chip_cache i_cache (
    .clk_i(src_clk), .reset_i(cache_reset), .cache_on_i(cache_on), .shrink_i(shrink), .chip1m_i(1'b0),
    .chip_sel_i(use_cache & is_chip), .slow_sel_i(1'b0),
    // stage 2b: the Kickstart lives in DDR3 behind the cache (bank 2 / the kick lines); the bench
    // preloads it into the DDR3 model where the QNICE load port would put it (backing words 1.25M..)
    .kick_sel_i(use_cache & is_kick), .kick512_i(host_on ? kick512_h : kick512),
    .q_clk_i(q_clk), .q_we_i(kq_we), .q_addr_i(kq_addr), .q_data_i(kq_data), .q_wait_o(kq_wait),
    .dbr_i(mm_dma_dbr), .dreg_i(mm_dma_reg), .pf_en_i(pf_en), .pf_stats_o(pf_stats),
    .addr_i(ram_addr[20:1]), .wdata_i(ram_wdata),
    .we_n_i(ram_we_n), .oe_n_i(ram_oe_n), .bhe_n_i(ram_bhe_n), .ble_n_i(ram_ble_n),
    .long_i(ram_long), .wdata2_i(cpu_din2),
    .rdata_o(cc_rdata), .rdata48_o(cc_rdata48), .miss_o(miss), .fills_o(fills), .wbacks_o(wbacks),
    .mode_o(cc_mode), .ui_clk_i(ui_clk), .lp_req_o(cc_req), .lp_we_o(cc_we), .lp_addr_o(cc_addr),
    .lp_wdata_o(cc_wdata), .lp_busy_i(lp_busy), .lp_rvalid_i(lp_rvalid), .lp_rdata_i(lp_rdata),
    .lp_done_i(lp_done));
  // DDR3 behind mig_arb's line port (word addresses from G_DDR_BASE $2000000): chip RAM 0..1M-1,
  // slow RAM 1M..1.25M-1, Kickstart 1.25M..1.5M-1
  reg [15:0] ddr [0:2097151] /*verilator public*/;
  wire [671:0] pf_stats;
  assign o_pf_stats = pf_stats;
  reg        lp_busy_r = 0, lp_rvalid_r = 0, lp_done_r = 0;
  reg [127:0] lp_rdata_r = 0;
  reg [9:0]  lp_cnt = 0;
  reg [2:0]  lp_beat = 0;
  reg        lp_isw = 0;
  reg [15:0] lp_line = 0;
  reg [1:0]  lp_crit = 0;
  reg [31:0] lp_rnd = 32'h12345678;
  assign lp_busy = lp_busy_r; assign lp_rvalid = lp_rvalid_r; assign lp_done = lp_done_r;
  assign lp_rdata = lp_rdata_r;
  integer k;
  always @(posedge ui_clk) begin
    lp_rvalid_r <= 0; lp_done_r <= 0;
    lp_rnd <= {lp_rnd[30:0], lp_rnd[31] ^ lp_rnd[21] ^ lp_rnd[1] ^ lp_rnd[0]};
    if (!lp_busy_r) begin
      if (cc_req) begin
        // mig_arb: critical word first, the 4 beats are 16-byte words c, c+1, c+2, c+3 (mod 4)
        lp_busy_r <= 1; lp_isw <= cc_we; lp_line <= cc_addr[20:5]; lp_crit <= cc_addr[4:3]; lp_beat <= 0;
        lp_cnt <= {2'b0, lat_min} + (lat_span == 0 ? 10'd0 : {2'b0, lp_rnd[7:0] % lat_span});
        if (cc_we) for (k = 0; k < 32; k = k + 1) ddr[{cc_addr[20:5], k[4:0]}] <= cc_wdata[16*k +: 16];
      end
    end else if (lp_cnt != 0) lp_cnt <= lp_cnt - 1;
    else if (lp_isw) begin lp_done_r <= 1; lp_busy_r <= 0; end
    else begin
      for (k = 0; k < 8; k = k + 1) lp_rdata_r[16*k +: 16] <= ddr[{lp_line, lp_beat[1:0] + lp_crit, k[2:0]}];
      lp_rvalid_r <= 1;
      lp_beat <= lp_beat + 1;
      if (lp_beat == 3) begin lp_done_r <= 1; lp_busy_r <= 0; end
    end
  end
  // shadow check: at the clk7_en edge that ends a chip read slot the cache's data must equal the
  // shadow memory (every chip write is also applied to chipmem below).  Not while the Amiga is held
  // in reset (--reset-at): the bus then shows read strobes without a slot (seen: chip word 0 reading
  // a ROM word; nothing consumes it)
  always @(posedge clk) if (use_cache && clk7_en && !ram_oe_n && is_chip && !rst_ext) begin
    chk_n <= chk_n + 1;
    if (cc_rdata != chipmem[cw]) begin
      chk_bad <= chk_bad + 1;
      if (chk_bad < 16) $display("cache check: chip word %05x cache %04x shadow %04x", cw, cc_rdata, chipmem[cw]);
    end
    if (cc_rdata48 != {chipmem[{cw[19:2], cw[1:0] + 2'd1}], chipmem[{cw[19:2], cw[1:0] + 2'd2}],
                       chipmem[{cw[19:2], cw[1:0] + 2'd3}]}) chk48_bad <= chk48_bad + 1;
  end else if (use_cache && clk7_en && !ram_oe_n && is_kick && !rst_ext) begin
    // stage 2b: the Kickstart through the cache, checked against the bench's ROM model
    chk_n <= chk_n + 1;
    if (cc_rdata != kickmem[rw18]) begin
      chk_bad <= chk_bad + 1;
      if (chk_bad < 16) $display("cache check: ROM word %05x cache %04x rom %04x", rw18, cc_rdata, kickmem[rw18]);
    end
    // stage 3: word A+1 of a 32-bit ROM read (the overlay reset vectors)
    if (ram_long && cc_rdata48[47:32] != kickmem[{rw18[17:2], rw18[1:0] + 2'd1}]) chk48_bad <= chk48_bad + 1;
  end
  // +wdbg: every chip write to the first 4 words, every reset edge (debug of a cache/shadow mismatch)
  reg wdbg = 0; initial wdbg = $test$plusargs("wdbg");
  reg rst_q = 0;
  always @(posedge clk) if (wdbg) begin
    rst_q <= rst_ext;
    if (rst_ext != rst_q) $display("wdbg %0t rst_ext %0d", $time, rst_ext);
    if (!ram_we_n && is_chip && cw < 4)
      $display("wdbg %0t write word %0d data %04x bhe %0d ble %0d long %0d din2 %04x miss %0d cpu_reset_n %0d dbr? oe %0d",
               $time, cw, ram_wdata, ram_bhe_n, ram_ble_n, ram_long, cpu_din2, miss, cpu_reset_n, ram_oe_n);
  end
  reg sel_cache_q = 0;
  always @(posedge clk) sel_cache_q <= use_cache & (is_chip | is_kick);

  wire [15:0] ramdata_mux = sel_cache_q ? cc_rdata : ram_q;

  always @(posedge clk) begin
    if (is_chip) ram_q <= chipmem[cw];
    else if (is_slow) ram_q <= slowmem[rw18];
    else if (is_ext)  ram_q <= extmem[rw18];
    else if (is_kick) ram_q <= kickmem[rw18];
    else ram_q <= 16'h0000;
    // chip48: the other three words of the aligned 64-bit group in MiSTer's SDRAM burst order
    // (sequential burst of 4 from the requested word, wrapping inside the group), read like the
    // 16-bit word (address of the previous tick) and HELD from the clk7_en edge at which the
    // 16-bit word is consumed (Denise: data16 <= data_in) until the next one: Denise copies it
    // into BPLxDAT / the sprite registers two ticks later (clk7n_en).  MiSTer's sdram_ctrl holds
    // its chip48 registers for the slot in the same way.  (The DDR3 study's bench registered it
    // every tick, so by clk7n_en it held the NEXT slot's words: FMODE 1-3 pictures were wrong.)
    chip48_n <= {chipmem[{cw[19:2], cw[1:0] + 2'd1}], chipmem[{cw[19:2], cw[1:0] + 2'd2}],
                 chipmem[{cw[19:2], cw[1:0] + 2'd3}]};
    // with the cache: the same holding register, loaded from the cache's 64-bit read
    if (clk7_en) chip48_q <= use_cache ? cc_rdata48 : chip48_n;
    // stage 3: the second word of a 68EC020 32-bit read (MiSTer's chipRD2), held like chip48
    kick2_n <= kickmem[{rw18[17:2], rw18[1:0] + 2'd1}];
    kick_q  <= is_kick;
    if (clk7_en && ram_long && !ram_oe_n)
      dout2_hold <= use_cache ? cc_rdata48[47:32] : kick_q ? kick2_n : chip48_n[47:32];   // ROM: overlay reset vectors
    if (!ram_we_n) begin
      if (is_chip) begin
        if (!ram_bhe_n) chipmem[cw][15:8] <= ram_wdata[15:8];
        if (!ram_ble_n) chipmem[cw][7:0]  <= ram_wdata[7:0];
        if (ram_long) chipmem[{cw[19:1], 1'b1}] <= cpu_din2;   // stage 3: 68EC020 32-bit write
      end else if (is_slow) begin
        if (!ram_bhe_n) slowmem[rw18][15:8] <= ram_wdata[15:8];
        if (!ram_ble_n) slowmem[rw18][7:0]  <= ram_wdata[7:0];
      end
    end
    if (bd_we) chipmem[bd_addr[19:0]] <= bd_data;
  end

  // ---------------- minimig ----------------
  wire hsync_n, vsync_n, hblank, vblank;
  wire [7:0] red, green, blue;
  wire [14:0] ldata, rdata;

  minimig minimig_inst (
    .cpu_address(cpu_addr), .cpu_data(cpu_dout), .cpudata_in(cpu_din), ._cpu_ipl(cpu_ipl_n),
    ._cpu_as(cpu_as_n), ._cpu_uds(cpu_uds_n), ._cpu_lds(cpu_lds_n), .cpu_r_w(cpu_rw),
    ._cpu_dtack(cpu_dtack_n), ._cpu_reset(cpu_reset_n), ._cpu_reset_in(cpu_reset_out_n & ~cpu_rst),
    .cpu_long(cpu_long), .chip32_en(chip32_en), .ram_long(ram_long),
    .nmi_addr(nmi_addr), .ovr(),
    .ram_data(ram_wdata), .ramdata_in(ramdata_mux), .ram_address({ram_addr23, ram_addr}),
    ._ram_bhe(ram_bhe_n), ._ram_ble(ram_ble_n), ._ram_we(ram_we_n), ._ram_oe(ram_oe_n),
    .chip48(chip48_q),
    .rst_ext(rst_ext), .rst_out(mm_rst_out), .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .c1(c1), .c3(c3), .cck(cck), .eclk(eclk),
    .rxd(1'b1), .txd(), .cts(1'b1), .rts(), .dtr(), .dsr(1'b1), .cd(1'b1), .ri(1'b1),
    ._joy1(16'hFFFF), ._joy2(16'hFFFF), ._joy3(16'hFFFF), ._joy4(16'hFFFF),
    .joya1(16'h0), .joya2(16'h0), .mouse_btn(3'b000), .kms_level(1'b0), .kbd_mouse_type(2'b00),
    .kbd_mouse_data(8'h00), .kbd_ack(), .pwr_led(), .fdd_led(), .hdd_led(), .rtc(65'h0),
    .dma_dbr(mm_dma_dbr), .dma_reg(mm_dma_reg),
    .IO_UIO(io_uio), .IO_FPGA(io_fpga), .IO_STROBE(mm_strobe), .IO_WAIT(io_wait), .IO_DIN(mm_din),
    .IO_DOUT(io_dout),
    ._hsync(hsync_n), ._vsync(vsync_n), ._csync(), .field1(), .lace(), .hblank(hblank),
    .vblank(vblank), .red(red), .green(green), .blue(blue), .ar(), .scanline(), .ce_pix(),
    .res(), .ntsc(),
    .ldata(ldata), .rdata(rdata), .ldata_okk(), .rdata_okk(), .aud_mix(),
    .toccata_ena(1'b0), .toccata_base(8'h00), .toccata_aud_left(), .toccata_aud_right(),
    .cpucfg(mm_cpucfg), .cachecfg(), .memcfg(), .bootrom(), .ide_ena(),
    .ide_fast(), .ide_ext_irq(1'b0), .ide_req(ide_req6), .ide_address({1'b0, ide_address}),
    .ide_write(ide_write), .ide_writedata(ide_writedata), .ide_read(ide_read), .ide_readdata(ide_readdata)
  );

  // a1200-ide: the hard disk link (fclk = ui_clk with --cache, else the machine clock)
  wire [5:0]  ide_req6;
  wire [3:0]  ide_address;
  wire        ide_write, ide_read;
  wire [15:0] ide_writedata, ide_readdata;
  wire        hdd_fclk = use_cache ? ui_clk : clk;
  // the SPI side resets only at power-up (on the board: the MIG's reset), not with the Amiga
  reg hd_frst = 1;
  always @(posedge clk) if (!rst_ext) hd_frst <= 0;
  hdd_spi i_hdd_spi (
    .fclk_i(hdd_fclk), .frst_i(hd_frst), .enable_i(ide_on),
    .spi_sck_i(hd_sck), .spi_mosi_i(hd_mosi), .spi_cs_n_i(hd_cs_n), .spi_miso_o(hd_miso),
    .spi_miso_oe_o(hd_miso_oe), .att_o(hd_att),
    .mclk_i(clk), .mrst_i((rst_ext & ~kbd_rst) | mm_rst_out), .ide_req_i(ide_req6[2:0]), .ide_address_o(ide_address),
    .ide_write_o(ide_write), .ide_writedata_o(ide_writedata), .ide_read_o(ide_read),
    .ide_readdata_i(ide_readdata));

  // ---------------- trace hook ----------------
  // source code: 0 none, 1 cpu, 2 bitplane, 3 sprite, 4 copper, 5 audio, 6 disk, 7 blitter, 8 refresh
  wire s_dsk = minimig_inst.AGNUS1.dma_dsk;
  wire s_ref = minimig_inst.AGNUS1.dma_ref;
  wire s_aud = minimig_inst.AGNUS1.dma_aud;
  wire s_bpl = minimig_inst.AGNUS1.dma_bpl;
  wire s_spr = minimig_inst.AGNUS1.ack_spr;
  wire s_cop = minimig_inst.AGNUS1.ack_cop;
  wire s_blt = minimig_inst.AGNUS1.ack_blt;
  wire [3:0] src = s_dsk ? 4'd6 : s_ref ? 4'd8 : s_aud ? 4'd5 : s_bpl ? 4'd2 : s_spr ? 4'd3 :
                   s_cop ? 4'd4 : s_blt ? 4'd7 : 4'd1;
  wire [1:0] bfm = minimig_inst.AGNUS1.bpd1.fmode[1:0];
  wire [1:0] sfm = minimig_inst.AGNUS1.spr1.fmode[3:2];
  wire [8:0]  hpos = minimig_inst.AGNUS1.hpos;
  wire [10:0] vpos = minimig_inst.AGNUS1.vpos;
  assign o_hpos = hpos;
  assign o_vpos = vpos;
  assign o_cpu_addr = cpu_addr;
  assign o_cpu_as_n = cpu_as_n;
  assign o_red_green = {red, green, blue};
  assign o_cpustate = cpustate;
  assign o_cpu_addr32 = i_cpu.cpu_addr;
  assign o_cpu_ack = mm_cpucfg != 2'b00 ? (i_cpu.cpu_req & (i_cpu.chipready | fr_ready)) : (~cpu_as_n & ~cpu_dtack_n);
  assign o_hsync_n = hsync_n;
  assign o_vsync_n = vsync_n;

  import "DPI-C" function void trace_tick(input int phase, input int addr, input int oe_n,
                                          input int we_n, input int src, input int fm,
                                          input int hpos, input int vpos, input int dbr,
                                          input int c1c3);
  reg [1:0] ph = 0;
  always @(posedge clk) begin
    trace_tick({30'b0, clk7_en, clk7n_en}, {9'b0, ram_addr23, ram_addr}, {31'b0, ram_oe_n},
               {31'b0, ram_we_n}, {28'b0, src}, {28'b0, sfm, bfm}, {23'b0, hpos}, {21'b0, vpos},
               {31'b0, minimig_inst.dbr}, {30'b0, c1, c3});
  end
  // +dskdbg: every disk DMA write to chip RAM (address, data)
  reg dskdbg = 0; initial dskdbg = $test$plusargs("dskdbg");
  reg dsk_we_q = 0;
  always @(posedge clk) if (dskdbg) begin
    dsk_we_q <= s_dsk && !ram_we_n;
    if (s_dsk && !ram_we_n && !dsk_we_q) $display("DSKW %06x %04x", {ram_addr[20:1], 1'b0}, ram_wdata);
  end
  // copper debug (+copdbg): state at every start of frame
  reg copdbg = 0;
  initial copdbg = $test$plusargs("copdbg");
  always @(posedge clk) if (copdbg && clk7_en && minimig_inst.AGNUS1.sof)
    $display("SOF v=%0d copst=%0d pc=%06x cop1lc=%06x dmacon=%04x reqcop=%0d ackcop=%0d strobe1=%0d",
      vpos, minimig_inst.AGNUS1.cp1.copper_state, {minimig_inst.AGNUS1.cp1.address_out, 1'b0},
      {minimig_inst.AGNUS1.cp1.cop1lch, minimig_inst.AGNUS1.cp1.cop1lcl, 1'b0}, minimig_inst.AGNUS1.dmacon,
      minimig_inst.AGNUS1.req_cop, minimig_inst.AGNUS1.ack_cop, minimig_inst.AGNUS1.cp1.strobe1);
endmodule
