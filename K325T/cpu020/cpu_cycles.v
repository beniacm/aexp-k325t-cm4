// cpu_cycles.v -- MiSTer-devel/Minimig-AGA_MiSTer master 7d5d3c2 rtl/cpu_cycles.v (Roberto Lari, #276
// "Cycle exact 68EC020 (A1200 speed)", GPL as Minimig), K325T copy: the three .vh tables inlined, the
// two cycle-index ROMs loaded with $readmemh from K325T/cpu020/*.mem (made from MiSTer's .mif by
// sim/aga/mister/mif2hex.py).  Logic unchanged.

module cpu_cycles
(
	input             clk,
	input             reset,

	input             ntsc,
	input       [1:0] mode,

	input             opc_start,
	input      [15:0] opc,
	input             opc_cond,
	input      [15:0] opc_snd,
	input             opc_dbx,
	input             cpu_ena,

	input             bus_ack,
	input       [1:0] bus_state,
	input      [31:0] bus_addr,
	input             bus_long,
	input             bus_l1,
	input      [13:0] cacr,
	input             cacr_clr,

	output reg        hold
);

reg [13:0] rate;
reg  [5:0] chip_c;
reg  [5:0] rom_c;
always @* begin
	rate = 14'd0;
	chip_c = 6'd0;
	rom_c = 6'd0;
	if (mode == 2'd1) begin
		rate = 14'd2048;
		chip_c = 6'd9;
	end
	else if (mode == 2'd2) begin
		rate = ntsc ? 14'd5721 : 14'd5774;
		chip_c = 6'd21;
		rom_c = 6'd7;
	end
	else if (mode == 2'd3) begin
		rate = ntsc ? 14'd7152 : 14'd7218;
		chip_c = 6'd27;
		rom_c = 6'd8;
	end
end

wire run  = |rate;
wire m020 = (mode == 2'd1);
wire go   = opc_start & cpu_ena & run;

reg [5:0] cyc_rom[16384];
reg [4:0] ea_rom[2048];
// K325T: the tables of MiSTer's .mif files (Quartus ram_init_file) as $readmemh files; the path is
// relative to the synthesis run directory (CORE/CORE-K325T.runs/synth_1, like fx68k's microcode) and to
// the simulation bench's run directory
initial begin
	$readmemh("../../../K325T/cpu020/m68k_cyc_idx.mem", cyc_rom);
	$readmemh("../../../K325T/cpu020/m68k_ea_idx.mem", ea_rom);
end


reg [15:0] opc_p, opc_l, opc_q;
reg [15:0] snd_l, snd_q;
reg [19:0] op_q;
reg  [2:0] v;

wire [13:0] cyc_a = (opc_p[5:3] == 3'b111) ? {opc_p[15:6], 1'b1, opc_p[2:0]}
                                           : {opc_p[15:6], 1'b0, opc_p[5:3]};

wire movem = (opc_l[15:12] == 4'h4) & opc_l[11] & ~opc_l[9] & ~opc_l[8]
           & opc_l[7] & |opc_l[5:3];

reg [4:0] rn;
integer i;
always @* begin
	rn = 5'd0;
	for (i = 0; i < 16; i = i + 1) rn = rn + {4'd0, snd_l[i]};
end

wire  [7:0] mv_cc   = opc_l[10] ? (8'd8 + {1'b0, rn, 2'b00}) : (8'd4 + {2'b00, rn, 1'b0});
wire [19:0] movem_e = {1'b1, 3'd4, 2'd0, 5'd2, mv_cc, 1'b0};

wire misc = (opc_l[15:3] == 13'h09CE);

reg  [5:0] cyc_i;
reg  [4:0] ea_i;
reg [19:0] cyc_e;
reg [19:0] misc_e;
reg [15:0] ea_e;
// ---- m68k_cyc_pal.vh (inlined, K325T) ----
always @* case(cyc_i)
	6'd0: cyc_e = 20'h00000;
	6'd1: cyc_e = 20'h80004;
	6'd2: cyc_e = 20'h80008;
	6'd3: cyc_e = 20'h8000A;
	6'd4: cyc_e = 20'h8000C;
	6'd5: cyc_e = 20'h80010;
	6'd6: cyc_e = 20'h80024;
	6'd7: cyc_e = 20'h80058;
	6'd8: cyc_e = 20'h80070;
	6'd9: cyc_e = 20'h801FE;
	6'd10: cyc_e = 20'h80404;
	6'd11: cyc_e = 20'h80408;
	6'd12: cyc_e = 20'h8040C;
	6'd13: cyc_e = 20'h80414;
	6'd14: cyc_e = 20'h8041C;
	6'd15: cyc_e = 20'h80438;
	6'd16: cyc_e = 20'h80458;
	6'd17: cyc_e = 20'h80470;
	6'd18: cyc_e = 20'h80808;
	6'd19: cyc_e = 20'h8080C;
	6'd20: cyc_e = 20'h80810;
	6'd21: cyc_e = 20'h80818;
	6'd22: cyc_e = 20'h8081C;
	6'd23: cyc_e = 20'h80C0C;
	6'd24: cyc_e = 20'h80C10;
	6'd25: cyc_e = 20'h81010;
	6'd26: cyc_e = 20'h81414;
	6'd27: cyc_e = 20'h81418;
	6'd28: cyc_e = 20'h81818;
	6'd29: cyc_e = 20'h81C1C;
	6'd30: cyc_e = 20'h82828;
	6'd31: cyc_e = 20'h84412;
	6'd32: cyc_e = 20'h84416;
	6'd33: cyc_e = 20'h8441A;
	6'd34: cyc_e = 20'h90004;
	6'd35: cyc_e = 20'h90008;
	6'd36: cyc_e = 20'h9000C;
	6'd37: cyc_e = 20'h90010;
	6'd38: cyc_e = 20'h90058;
	6'd39: cyc_e = 20'h90070;
	6'd40: cyc_e = 20'h90408;
	6'd41: cyc_e = 20'h90438;
	6'd42: cyc_e = 20'h90618;
	6'd43: cyc_e = 20'h9080C;
	6'd44: cyc_e = 20'h94006;
	6'd45: cyc_e = 20'h9400A;
	6'd46: cyc_e = 20'h98008;
	6'd47: cyc_e = 20'hA0004;
	6'd48: cyc_e = 20'hA009C;
	6'd49: cyc_e = 20'hA0404;
	6'd50: cyc_e = 20'hA0458;
	6'd51: cyc_e = 20'hA4006;
	6'd52: cyc_e = 20'hB0404;
	6'd53: cyc_e = 20'hB0C14;
	6'd54: cyc_e = 20'hB0C18;
	6'd55: cyc_e = 20'hB0C1C;
	6'd56: cyc_e = 20'hB0C2C;
	6'd57: cyc_e = 20'hB8008;
	6'd58: cyc_e = 20'hD0008;
	6'd59: cyc_e = 20'hD0808;
	default: cyc_e = 20'd0;
endcase
// ---- end of m68k_cyc_pal.vh ----
// ---- m68k_ea_pal.vh (inlined, K325T) ----
always @* case(ea_i)
	5'd0: ea_e = 16'h0000;
	5'd1: ea_e = 16'h8000;
	5'd2: ea_e = 16'h8200;
	5'd3: ea_e = 16'h8210;
	5'd4: ea_e = 16'h8211;
	5'd5: ea_e = 16'h8302;
	5'd6: ea_e = 16'h830A;
	5'd7: ea_e = 16'h8408;
	5'd8: ea_e = 16'h8410;
	5'd9: ea_e = 16'h8414;
	5'd10: ea_e = 16'h8420;
	5'd11: ea_e = 16'h8421;
	5'd12: ea_e = 16'h8512;
	5'd13: ea_e = 16'h8618;
	5'd14: ea_e = 16'h8620;
	5'd15: ea_e = 16'h8624;
	5'd16: ea_e = 16'h8631;
	5'd17: ea_e = 16'h8722;
	5'd18: ea_e = 16'h8828;
	5'd19: ea_e = 16'h8834;
	5'd20: ea_e = 16'h8841;
	5'd21: ea_e = 16'h8A44;
	default: ea_e = 16'd0;
endcase
// ---- end of m68k_ea_pal.vh ----
// ---- m68k_misc_030.vh (inlined, K325T) ----
always @* case(opc_l[2:0])
	3'd0: misc_e = 20'h801FE;
	3'd1: misc_e = 20'h80004;
	3'd2: misc_e = 20'h80010;
	3'd3: misc_e = 20'h80224;
	3'd4: misc_e = 20'h80414;
	3'd5: misc_e = 20'h80212;
	3'd6: misc_e = 20'h80808;
	3'd7: misc_e = 20'h80218;
endcase
// ---- end of m68k_misc_030.vh ----

wire [19:0] op_e = misc ? misc_e : movem ? movem_e : cyc_e;

always @(posedge clk) begin
	if (~reset | ~run) v <= 0;
	else v <= {v[1:0], go};
	if (go) opc_p <= opc;
	opc_l <= opc_p;
	snd_l <= opc_snd;
	cyc_i <= cyc_rom[cyc_a];
	opc_q <= opc_l;
	snd_q <= snd_l;
	op_q  <= op_e;
	ea_i  <= ea_rom[{op_e[18:16], movem ? 2'b01 : opc_l[7:6], opc_l[5:0]}];
end

wire [2:0] eacl  = op_q[18:16];
wire [1:0] op_t  = op_q[15:14];
wire [4:0] op_h  = op_q[13:9];
wire       divsl = (opc_q[15:6] == 10'h131) & snd_q[11];
wire       divsw = ~m020 & (opc_q[15:12] == 4'h8) & (opc_q[8:6] == 3'b111);
wire [7:0] op_cc = op_q[8:1] + (divsl ? 8'd12 : 8'd0) - (divsw ? 8'd6 : 8'd0);

wire       ea_v  = ea_e[15] & |eacl;

wire ff_pre = (opc_q[15:8] == 8'h08)
           || (opc_q[15:12] == 4'hE && opc_q[11] && &opc_q[7:6]);
wire ff = ea_v & eacl[0] & snd_q[8] & ~ff_pre
        & ((opc_q[5:3] == 3'b110) | (opc_q[5:0] == 6'b111011));

wire       ff_mi = |snd_q[1:0];
wire       ff_od = ff_mi & (snd_q[1:0] != 2'b01);
wire [1:0] ff_bd = snd_q[5:4];
wire [6:0] ff_cc = (ff_mi ? (ff_bd == 2'b10 ? 7'd12 : ff_bd == 2'b11 ? 7'd16 : 7'd10)
                          : (ff_bd == 2'b10 ? 7'd8  : ff_bd == 2'b11 ? 7'd12 : 7'd6))
                 + (ff_od ? 7'd2 : 7'd0);
wire       ff_ph = ~ff_mi & (ff_bd != 2'b10) & (ff_bd != 2'b11) & (eacl != 3'd1);

wire [6:0] ea_cc = ff ? ff_cc : ea_v ? ea_e[14:8] : 7'd0;
wire [4:0] ea_h  = ff ? (ff_ph ? 5'd6 : 5'd4) : ea_v ? ea_e[7:3] : 5'd0;
wire [1:0] ea_t  = ff ? 2'd0 : ea_v ? ea_e[2:1] : 2'd0;
wire       ea_ph = ff ? ff_ph : (ea_v & ea_e[0]);
wire       model = op_q[19] & (~|eacl | ea_e[15]);

wire bcc_b = (opc_q[15:12] == 4'h6) && (opc_q[11:8] > 4'h1)
          && (opc_q[7:0] != 8'h00) && (opc_q[7:0] != 8'hFF);
wire bcc_o = (opc[15:12] == 4'h6) && (opc[11:8] > 4'h1)
          && (opc[7:0] != 8'h00) && (opc[7:0] != 8'hFF);

reg  [1:0] prev_t;
wire [4:0] ov1  = (op_h < {3'b0, ea_t}) ? op_h : {3'b0, ea_t};
wire [8:0] cc   = {1'b0, op_cc} + {2'b0, ea_cc} - {4'b0, ov1};
wire [5:0] head = ea_v ? ({1'b0, ea_h} + (ea_ph ? {1'b0, op_h} : 6'd0)) : {1'b0, op_h};
wire [5:0] ov2  = (head < {4'b0, prev_t}) ? head : {4'b0, prev_t};
wire [8:0] net  = cc - {3'b0, ov2};
wire [8:0] cost = model ? (bcc_b ? net - 9'd2 : net) : 9'd2;

reg  [1:0] b_v;
reg  [3:0] b_st;
reg [63:0] b_a;
reg  [1:0] b_lw;
reg  [1:0] b_l1;
reg        e_l1;
always @(posedge clk) begin
	b_l1 <= {b_l1[0], bus_l1};
	e_l1 <= b_l1[1];
end
reg [27:0] b_cr;
reg  [1:0] b_cc;
reg        e_v;
reg  [1:0] e_st;
reg [31:0] e_a;
reg        e_lw;
always @(posedge clk) begin
	b_v  <= {b_v[0], bus_ack & run};
	b_st <= {b_st[1:0], bus_state};
	b_a  <= {b_a[31:0], bus_addr};
	b_lw <= {b_lw[0], bus_long};
	b_cr <= {b_cr[13:0], cacr};
	b_cc <= {b_cc[0], cacr_clr};
	e_v  <= b_v[1];
	e_st <= b_st[3:2];
	e_a  <= b_a[63:32];
	e_lw <= b_lw[1];
end
wire [13:0] cr_d  = b_cr[27:14];

wire        e24   = m020 | ~|e_a[31:24];
wire        r_io  = e24 & (e_a[23:19] == 5'b11101);
wire        r_chp = e24 & ((e_a[23:21] == 3'd0) | (e_a[23:21] == 3'd5) | (e_a[23:21] == 3'd6) | r_io);
wire        r_rom = e24 & (e_a[23:21] == 3'd7) & ~r_io;
wire        r_fst = ~r_chp & ~r_rom;
wire  [5:0] c_mem = r_chp ? chip_c : (~m020 & r_rom) ? rom_c : m020 ? 6'd3 : 6'd2;

wire [23:0] tg = e_a[31:8];
wire  [3:0] ln = e_a[7:4];
wire  [1:0] lw = e_a[3:2];
wire  [5:0] sl = e_a[7:2];

reg  [23:0] itag[16];
reg  [23:0] dtag[16];
reg  [23:0] ctag[64];
reg  [63:0] ivl, dvl, cvl;

wire  [3:0] i_v   = (itag[ln] == tg) ? ivl[{ln, 2'b00} +: 4] : 4'd0;
wire  [3:0] d_v   = (dtag[ln] == tg) ? dvl[{ln, 2'b00} +: 4] : 4'd0;
wire        c_hit = cvl[sl] & (ctag[sl] == tg);

reg  [29:0] last_f;
wire        f_ev  = e_v & (e_st == 2'd0) & (e_a[31:2] != last_f);
wire        d_ev  = e_v & e_st[1] & (~e_lw | e_l1);
wire        r_cr  = e24 & ((e_a[23:21] == 3'd0) | ((e_a[23:21] == 3'd6) & ~&e_a[20:19]));
wire        r_nc  = r_chp & ~r_cr;
wire        ie    = cr_d[0] & ~cr_d[1] & ~r_nc;
wire        i_hit = cr_d[0] & (m020 ? c_hit : (i_v[lw] & ~r_nc));
wire        i_bst = ~m020 & ie & cr_d[4] & ~r_chp & ~|lw & ~|i_v;
wire        de    = ~m020 & cr_d[8] & ~r_chp;
wire        d_hit = de & d_v[lw] & ~e_st[0];
wire        d_bst = de & ~cr_d[9] & cr_d[12] & ~|lw & ~|d_v & ~e_st[0];
wire        d_all = de & ~cr_d[9] & (~e_st[0] | cr_d[13]) & ~d_hit;

wire        fst3  = ~m020 & r_fst;
localparam [5:0] K_FS = 6'd0;
localparam [5:0] K_FN = 6'd1;
localparam [5:0] K_IB = 6'd0;
localparam [5:0] K_DR = 6'd0;
localparam [5:0] K_DN = 6'd1;
localparam [5:0] K_DW = 6'd2;
localparam [5:0] K_DB = 6'd4;
wire  [5:0] f_c = (~f_ev | i_hit) ? 6'd0
                : i_bst ? (r_fst ? K_IB : 6'd5)
                : fst3  ? (cr_d[0] ? K_FS : K_FN) : c_mem;
wire signed [7:0] d_c = ~d_ev  ? 8'sd0
                      : d_hit  ? -8'sd1
                      : d_bst  ? (r_fst ? $signed({2'd0, K_DB}) : 8'sd3)
                      : r_chp  ? $signed({2'd0, c_mem}) - 8'sd2
                      : (~m020 & r_rom) ? $signed({2'd0, c_mem})
                      : m020   ? $signed({2'd0, c_mem}) - 8'sd2
                      : e_st[0] ? $signed({2'd0, K_DW}) : $signed({2'd0, cr_d[8] ? K_DR : K_DN});

reg         clr_d;
always @(posedge clk) begin
	clr_d <= b_cc[1];
	if (~reset | (b_cc[1] & ~clr_d)) begin
		ivl <= 0;
		dvl <= 0;
		cvl <= 0;
		last_f <= 30'h3FFFFFFF;
	end
	else begin
		if (f_ev) last_f <= e_a[31:2];
		if (f_ev & ~i_hit & ie) begin
			if (m020) begin
				ctag[sl] <= tg;
				cvl[sl] <= 1'b1;
			end
			else begin
				itag[ln] <= tg;
				ivl[{ln, 2'b00} +: 4] <= i_bst ? 4'hF : (i_v | (4'd1 << lw));
			end
		end
		if (d_ev & d_all) begin
			dtag[ln] <= tg;
			dvl[{ln, 2'b00} +: 4] <= d_bst ? 4'hF : (d_v | (4'd1 << lw));
		end
	end
end

reg         bl;
reg   [5:0] ovc;
reg         dbx_d;
reg  [11:0] acc;
reg  [12:0] debt;

reg   [2:0] add_b;
wire [14:0] acc_n = {3'b000, acc} + {1'b0, rate};
wire        wr_e  = d_ev & e_st[0] & ~d_c[7];
wire        dr_e  = d_ev & ~e_st[0] & ~d_hit;
wire        fm_e  = f_ev & ~i_hit;
wire  [6:0] cr_n  = (wr_e ? d_c[6:0] : 7'd0) + (fm_e ? {1'b0, f_c} : 7'd0);
wire [11:0] ab_x  = {cost, 3'd0} - {3'd0, cost};
wire  [5:0] ab    = (m020 & v[2]) ? ((ab_x[11:3] > {3'd0, ovc}) ? ovc : ab_x[8:3]) : 6'd0;
wire  [8:0] add_t = v[2] ? cost - {3'd0, ab} : 9'd0;
wire  [2:0] add_d = (opc_dbx & ~dbx_d & run) ? 3'd4 : 3'd0;
wire signed [13:0] dn = {debt[12], debt} - {11'd0, acc_n[14:12]} + {5'd0, add_t} + {8'd0, f_c} + {{6{d_c[7]}}, d_c}
                      + {11'd0, add_b} + {11'd0, add_d};

always @(posedge clk) begin
	dbx_d <= opc_dbx;
	add_b <= (go & bl & opc_cond) ? 3'd2 : 3'd0;
	if (~reset | ~run) begin
		acc    <= 0;
		ovc    <= 0;
		debt   <= 0;
		prev_t <= 0;
		bl     <= 0;
		hold   <= 0;
	end
	else begin
		acc  <= acc_n[11:0];
		ovc  <= (~m020 | dr_e) ? 6'd0 : |cr_n ? (cr_n[6] ? 6'd63 : cr_n[5:0]) : ovc - ab;
		debt <= (dn < -14'sd255) ? -13'sd255 : dn[12:0];
		hold <= (dn > 14'sd0);
		if (go) bl <= bcc_o;
		if (v[2]) prev_t <= model ? op_t : 2'd0;
	end
end

endmodule
