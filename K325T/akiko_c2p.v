// akiko_c2p.v -- K325T a1200-akiko: an Akiko-style chunky-to-planar helper (own design).
//
// Opt-in expansion of the A1200 machine (menu line "Akiko C2P", default off).  It answers two CD32
// Akiko registers on the 68020's "fastchip" port of cpu_wrapper.v (MiSTer's path for CPU-clock
// devices, no chip-bus cycle):
//
//   $B80000.L  ID, reads $C0CACAFE ($B80000.W = $C0CA, $B80002.W = $CAFE); writes are ignored
//   $B80038.L  C2P: write 8 longwords of chunky pixels (4 pixels each, the first pixel in bits 31..24),
//              then read 8 longwords of planar data: longword p = bitplane p, bit 31 = pixel 0 ...
//              bit 0 = pixel 31 (pixel n = byte n of the 32 written bytes)
//
// Nothing else is claimed: every other address (also the rest of $B80000-$B8FFFF) goes the way it
// went before.  With enable_i = 0 the unit never acknowledges (hit_o = 0), so cpu_wrapper takes the
// chip bus exactly as without it.  The fastchip port exists only for the 68020 (cpucfg != 0); the
// 68000 never reaches this unit.
//
// Sequencing (the 68020's longword is two word cycles here, high word first):
//   write $B80038 (high word) -> bytes 0/1 of longword W; write $B8003A (low word) -> bytes 2/3 of W,
//   then W = W + 1 (mod 8); any write sets the read index R = 0.
//   read $B80038 -> bits 31..16 of plane R; read $B8003A -> bits 15..0 of plane R, then R = R + 1
//   (mod 8); any read sets the write index W = 0.
//   Byte accesses select their byte (uds = bits 15..8, lds = bits 7..0); the index moves on any
//   access to the low word.  The conversion is combinational from the 32 stored bytes: reading is
//   non-destructive, and reading fewer than 8 planes (as the V40 autodoc allows) is fine.
// One access completes in the clock it is presented (ready = select), like MiSTer's fastchip
// devices; the 68EC020 cycle model (cpu_cycles.v) charges $B8xxxx like a chip-region access.
//
// Interface (cpu_wrapper fastchip port; MiSTer's fastchip.v decodes chip_addr/chip_din instead,
// which show a posted 32-bit chip write's address/data while one is pending: here the CPU's own
// address (fastchip_addr, patch 0137) and data out (ramdin = cpu_dout) are used)
module akiko_c2p
(
	input             clk,
	input             reset,      // active high: indexes to 0
	input             enable_i,   // menu bit (topology: changes only with a cold boot)
	input             sel_i,      // cpu_wrapper fastchip_sel: a 68020 request, 24-bit address, not held
	input      [23:1] addr_i,     // the CPU's address (cpu_wrapper fastchip_addr)
	input             rnw_i,      // 1 = read (cpu_wrapper fastchip_rnw)
	input             uds_n_i,    // cpu_wrapper fastchip_uds (active low)
	input             lds_n_i,    // cpu_wrapper fastchip_lds (active low)
	input      [15:0] din_i,      // the CPU's write data (cpu_wrapper ramdin)
	output            hit_o,      // fastchip_selack and fastchip_ready
	output reg [15:0] dout_o      // fastchip_dout (only looked at with hit_o)
);

wire base   = (addr_i[23:6] == 18'h2E000);           // $B80000 .. $B8003F
wire sel_id = base & (addr_i[5:2] == 4'h0);          // $B80000 .. $B80003
wire sel_cp = base & (addr_i[5:2] == 4'hE);          // $B80038 .. $B8003B
assign hit_o = enable_i & sel_i & (sel_id | sel_cp);

wire acc = hit_o & sel_cp;      // a C2P access completes in this clock
wire lo  = addr_i[1];           // 0 = high word (bytes 0/1 of the longword), 1 = low word (bytes 2/3)

reg [7:0] px [0:31];            // the 32 chunky pixels
reg [2:0] wi, ri;               // longword write index, plane read index

always @(posedge clk) begin
	if (reset) begin
		wi <= 3'd0;
		ri <= 3'd0;
	end
	else if (acc) begin
		if (!rnw_i) begin
			if (!uds_n_i) px[{wi, lo, 1'b0}] <= din_i[15:8];
			if (!lds_n_i) px[{wi, lo, 1'b1}] <= din_i[7:0];
			if (lo) wi <= wi + 3'd1;
			ri <= 3'd0;
		end
		else begin
			if (lo) ri <= ri + 3'd1;
			wi <= 3'd0;
		end
	end
end

integer k;
always @* begin
	dout_o = 16'h0000;
	if (sel_id)
		dout_o = lo ? 16'hCAFE : 16'hC0CA;
	else
		for (k = 0; k < 16; k = k + 1)
			dout_o[15 - k] = px[{lo, k[3:0]}][ri];
end

endmodule
