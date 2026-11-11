// tb_top.sv -- AGA + 68020 bench (stage-3 groundwork), from the A1200 DDR3 study's trace bench.
// minimig.v + cpu_wrapper.v (fx68k or TG68K, chosen by the 0xF4 config word as in MiSTer:
// minimig's cpucfg output drives cpu_wrapper) + amiga_clk.v, a BRAM-like memory model on minimig's
// SRAM-style port (1-tick read latency, as mega65.vhd), chip48 fed like MiSTer's sdram_ctrl
// (the 3 following words of the 64-bit group), a userio config replay (as amiga_config.vhd),
// and a DPI hook that the C++ side uses to log every memory access with its source.
// Simulation tooling only, not part of the core.
module tb_top (
  input  wire        clk,
  input  wire        rst_ext,
  input  wire [15:0] cfg_chipset,   // 0xF3 payload  (bit4 AGA, bit3 ECS)
  input  wire [15:0] cfg_cpu,       // 0xF4 payload
  input  wire [15:0] cfg_mem,       // 0xF5 payload  (CC=11: 2 MB chip)
  output wire        cfg_done,
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
             7: seq_pl=16'h0008; default: seq_pl=16'h0000; endcase
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

  // ---------------- CPU ----------------
  wire [23:1] cpu_addr;
  wire [15:0] cpu_dout, cpu_din;
  wire [2:0]  cpu_ipl_n;
  wire cpu_as_n, cpu_uds_n, cpu_lds_n, cpu_rw, cpu_dtack_n, cpu_reset_out_n;
  wire [31:0] nmi_addr;

  wire [1:0] mm_cpucfg;
  wire [1:0] cpustate;
  cpu_wrapper i_cpu (
    .reset(cpu_reset_n), .reset_out(cpu_reset_out_n), .clk(clk), .ph1(cpu_ph1), .ph2(cpu_ph2),
    .cpucfg(mm_cpucfg), .fastramcfg(3'b000), .cachecfg(3'b000), .bootrom(1'b0),
    .chip_addr(cpu_addr), .chip_dout(cpu_dout), .chip_din(cpu_din), .chip_as(cpu_as_n),
    .chip_uds(cpu_uds_n), .chip_lds(cpu_lds_n), .chip_rw(cpu_rw), .chip_dtack(cpu_dtack_n),
    .chip_ipl(cpu_ipl_n),
    .fastchip_dout(16'h0), .fastchip_sel(), .fastchip_lds(), .fastchip_uds(), .fastchip_rnw(),
    .fastchip_lw(), .fastchip_selack(1'b0), .fastchip_ready(1'b0),
    .ramsel(), .ramaddr(), .ramdin(), .ramdout(16'h0), .ramready(1'b0), .ramlds(), .ramuds(),
    .ramshared(), .toccata_ena(), .toccata_base(), .cpustate(cpustate), .cacr(), .nmi_addr(nmi_addr));

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
    if (clk7_en) chip48_q <= chip48_n;
    if (!ram_we_n) begin
      if (is_chip) begin
        if (!ram_bhe_n) chipmem[cw][15:8] <= ram_wdata[15:8];
        if (!ram_ble_n) chipmem[cw][7:0]  <= ram_wdata[7:0];
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
    ._cpu_dtack(cpu_dtack_n), ._cpu_reset(cpu_reset_n), ._cpu_reset_in(cpu_reset_out_n),
    .nmi_addr(nmi_addr), .ovr(),
    .ram_data(ram_wdata), .ramdata_in(ram_q), .ram_address({ram_addr23, ram_addr}),
    ._ram_bhe(ram_bhe_n), ._ram_ble(ram_ble_n), ._ram_we(ram_we_n), ._ram_oe(ram_oe_n),
    .chip48(chip48_q),
    .rst_ext(rst_ext), .rst_out(), .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
    .c1(c1), .c3(c3), .cck(cck), .eclk(eclk),
    .rxd(1'b1), .txd(), .cts(1'b1), .rts(), .dtr(), .dsr(1'b1), .cd(1'b1), .ri(1'b1),
    ._joy1(16'hFFFF), ._joy2(16'hFFFF), ._joy3(16'hFFFF), ._joy4(16'hFFFF),
    .joya1(16'h0), .joya2(16'h0), .mouse_btn(3'b000), .kms_level(1'b0), .kbd_mouse_type(2'b00),
    .kbd_mouse_data(8'h00), .kbd_ack(), .pwr_led(), .fdd_led(), .hdd_led(), .rtc(65'h0),
    .IO_UIO(io_uio), .IO_FPGA(1'b0), .IO_STROBE(io_strobe), .IO_WAIT(io_wait), .IO_DIN(io_din),
    .IO_DOUT(io_dout),
    ._hsync(hsync_n), ._vsync(vsync_n), ._csync(), .field1(), .lace(), .hblank(hblank),
    .vblank(vblank), .red(red), .green(green), .blue(blue), .ar(), .scanline(), .ce_pix(),
    .res(), .ntsc(),
    .ldata(ldata), .rdata(rdata), .ldata_okk(), .rdata_okk(), .aud_mix(),
    .toccata_ena(1'b0), .toccata_base(8'h00), .toccata_aud_left(), .toccata_aud_right(),
    .cpucfg(mm_cpucfg), .cachecfg(), .memcfg(), .bootrom(), .ide_ena(),
    .ide_fast(), .ide_ext_irq(1'b0), .ide_req(), .ide_address(5'b0), .ide_write(1'b0),
    .ide_writedata(16'h0), .ide_read(1'b0), .ide_readdata()
  );

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
  assign o_cpu_ack = mm_cpucfg != 2'b00 ? (i_cpu.cpu_req & i_cpu.chipready) : (~cpu_as_n & ~cpu_dtack_n);
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
  // copper debug (+copdbg): state at every start of frame
  reg copdbg = 0;
  initial copdbg = $test$plusargs("copdbg");
  always @(posedge clk) if (copdbg && clk7_en && minimig_inst.AGNUS1.sof)
    $display("SOF v=%0d copst=%0d pc=%06x cop1lc=%06x dmacon=%04x reqcop=%0d ackcop=%0d strobe1=%0d",
      vpos, minimig_inst.AGNUS1.cp1.copper_state, {minimig_inst.AGNUS1.cp1.address_out, 1'b0},
      {minimig_inst.AGNUS1.cp1.cop1lch, minimig_inst.AGNUS1.cp1.cop1lcl, 1'b0}, minimig_inst.AGNUS1.dmacon,
      minimig_inst.AGNUS1.req_cop, minimig_inst.AGNUS1.ack_cop, minimig_inst.AGNUS1.cp1.strobe1);
endmodule
