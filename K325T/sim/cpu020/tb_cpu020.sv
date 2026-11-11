// tb_cpu020.sv -- cpu_wrapper (fx68k or TG68K) with its fast RAM port on amiga_fastram and an
// Avalon memory model, against a simple chip bus (RAM 512 KB at $000000, "ROM" 64 KB at
// $F80000, /DTACK one 7 MHz cycle after /AS).  Runs prog.s (see run.sh); prints the time
// stamps the program writes to $1008 and the result word at $1000.  PASS = $600D at $1004
// with no failure bits.
//   parameters: CPUCFG (0 = 68000, 3 = 68020), FASTCFG (3 = 8 MB Zorro II, 6 = 128 MB Zorro III)
`timescale 1ns/1ps
module tb_cpu020;
parameter [1:0] CPUCFG  = 2'b11;
parameter [2:0] FASTCFG = 3'b011;

reg clk = 0, hr_clk = 0;
always #17.621 clk = ~clk;        // 28.375 MHz
always #5      hr_clk = ~hr_clk;  // 100 MHz

reg reset_n = 0;                  // minimig's CPU reset (active low)
wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk i_clk (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
                 .cck(cck), .eclk(eclk), .reset_n(1'b1));
// fx68k phase enables as in main.vhd
reg ph1 = 0, ph2 = 0;
always @(posedge clk) begin
    if (!reset_n) begin ph1 <= 0; ph2 <= 0; end
    else begin ph2 <= ~c1 & ~c3; ph1 <= c1 & c3; end
end

wire [23:1] chip_addr;
wire [15:0] chip_din;
reg  [15:0] chip_dout;
wire chip_as, chip_uds, chip_lds, chip_rw;
reg  chip_dtack = 1;
wire ramsel, ramlds, ramuds, fast_ready;
wire [28:1] ramaddr;
wire [15:0] ramdin, fast_rdata;
wire [1:0] cpustate;
wire reset_out;

cpu_wrapper dut (
    .reset(reset_n), .reset_out(reset_out), .clk(clk), .ph1(ph1), .ph2(ph2),
    .cpucfg(CPUCFG), .fastramcfg(FASTCFG), .cachecfg(3'b000), .bootrom(1'b0),
    .chip_addr(chip_addr), .chip_dout(chip_dout), .chip_din(chip_din), .chip_as(chip_as),
    .chip_uds(chip_uds), .chip_lds(chip_lds), .chip_rw(chip_rw), .chip_dtack(chip_dtack),
    .chip_ipl(3'b111),
    .fastchip_dout(16'h0), .fastchip_sel(), .fastchip_lds(), .fastchip_uds(), .fastchip_rnw(),
    .fastchip_lw(), .fastchip_selack(1'b0), .fastchip_ready(1'b0),
    .ramsel(ramsel), .ramaddr(ramaddr), .ramdin(ramdin), .ramdout(fast_rdata),
    .ramready(fast_ready), .ramlds(ramlds), .ramuds(ramuds), .ramshared(),
    .toccata_ena(), .toccata_base(), .cpustate(cpustate), .cacr(), .nmi_addr());

// fast RAM: the DDR3 placement of mega65.vhd
wire [26:0] ddr = ramaddr[28] ? {4'b0001, ramaddr[23:1]} : {1'b1, ramaddr[26:1]};
wire avm_write, avm_read;
wire [31:0] avm_addr;
wire [15:0] avm_wd;
wire [1:0]  avm_be;
wire [7:0]  avm_bc;
reg  [15:0] avm_rd = 0;
reg  avm_rdv = 0, avm_wait = 1;
amiga_fastram i_fast (
    .clk_i(clk), .sel_i(ramsel), .pulse_i(CPUCFG != 0), .addr_i(ddr), .we_i(cpustate == 2'b11),
    .uds_n_i(ramuds), .lds_n_i(ramlds), .wdata_i(ramdin), .rdata_o(fast_rdata), .ready_o(fast_ready),
    .hr_clk_i(hr_clk), .hr_rst_i(1'b0),
    .avm_write_o(avm_write), .avm_read_o(avm_read), .avm_address_o(avm_addr),
    .avm_writedata_o(avm_wd), .avm_byteenable_o(avm_be), .avm_burstcount_o(avm_bc),
    .avm_readdata_i(avm_rd), .avm_readdatavalid_i(avm_rdv), .avm_waitrequest_i(avm_wait));

// Avalon memory: 64K words, address bits 15:0 (the test touches < 64 KB of fast RAM)
reg [15:0] ddrmem [0:65535];
integer k;
always @(posedge hr_clk) begin
    if ((avm_write || avm_read) && avm_wait) avm_wait <= 0;      // one wait state
    else avm_wait <= 1;
    if ((avm_write || avm_read) && !avm_wait) begin
        if (avm_write) begin
            if (avm_be[1]) ddrmem[avm_addr[15:0]][15:8] <= avm_wd[15:8];
            if (avm_be[0]) ddrmem[avm_addr[15:0]][7:0]  <= avm_wd[7:0];
        end else begin
            fork : burst
                automatic logic [31:0] a = avm_addr;
                automatic integer n = avm_bc;
                begin
                    repeat (20) @(posedge hr_clk);
                    for (int i = 0; i < n; i++) begin
                        avm_rd <= ddrmem[(a + i) & 16'hffff]; avm_rdv <= 1;
                        @(posedge hr_clk); avm_rdv <= 0;
                    end
                end
            join_none
        end
    end
end

// chip bus: RAM 256K words (mirrored below $F00000), ROM 32K words at $F80000
reg [15:0] ram [0:262143];
reg [15:0] rom [0:32767];
wire is_rom = chip_addr[23:19] == 5'b11111;
always @* chip_dout = is_rom ? rom[chip_addr[15:1]] : ram[chip_addr[18:1]];
always @(posedge clk) if (clk7_en) chip_dtack <= chip_as;

integer cycles = 0;
always @(posedge clk) cycles <= cycles + 1;
reg old_wr = 0;
always @(posedge clk) begin
    old_wr <= !chip_as && !chip_rw && (!chip_uds || !chip_lds);
    if (!chip_as && !chip_rw && (!chip_uds || !chip_lds) && !old_wr && !is_rom &&
        chip_addr[23:20] == 4'h0) begin
        if (!chip_uds) ram[chip_addr[18:1]][15:8] <= chip_din[15:8];
        if (!chip_lds) ram[chip_addr[18:1]][7:0]  <= chip_din[7:0];
        if (chip_addr[18:1] == 18'h804)           // $1008: time stamp
            $display("t=%0d clocks: stamp %0d", cycles, chip_din);
        if (chip_addr[18:1] == 18'h802) begin     // $1004: end
            #1;
            $display("RESULT %04x failbits %08x after %0d clocks (CPUCFG %0d FASTCFG %0d)",
                     chip_din, {ram[18'h800], ram[18'h801]}, cycles, CPUCFG, FASTCFG);
            if (chip_din == 16'h600d && {ram[18'h800], ram[18'h801]} == 0) $display("TB_CPU020_PASS");
            else $display("TB_CPU020_FAIL");
            $finish;
        end
    end
end

initial begin
    for (k = 0; k < 262144; k = k + 1) ram[k] = 0;
    for (k = 0; k < 65536; k = k + 1) ddrmem[k] = 16'h0;
    $readmemh("prog.hex", rom);
    ram[0] = 16'h0007; ram[1] = 16'hfff0;      // SSP $7FFF0
    ram[2] = 16'h00f8; ram[3] = 16'h0000;      // PC  $F80000
    #2000 reset_n = 1;
    #20000000 $display("TB_CPU020_FAIL timeout"); $finish;
end
endmodule
