// fmeas.v -- frame measure of the Amiga's native picture (K325T a500-bacon; instantiated in main.vhd)
//
// Watches the core's video output exactly as Minimig produces it (before the framework's scaler) and
// drives nothing back into the machine.  Per frame (vsync start to vsync start) a CRC-32 of every
// visible pixel at the hires pixel rate (14.19 MHz: clk7_en | clk7n_en; a lores pixel counts twice,
// as in an emulator's hires-wide picture), so that a frame can be compared with an emulator's frame
// bit for bit without moving the picture through HDMI.  Read through the stall controller's page 7
// (lat_meter.vhd meas_i) by K325T/tools/fmeas.py on the module.
//
// Pixel value: 12 bits {R[7:4], G[7:4], B[7:4]} (the OCS/ECS colour; a pixel whose low nibbles are
// not copies of the high nibbles sets the "nib" flag: then the 12-bit reduction lost information).
// CRC: reflected CRC-32 (polynomial $EDB88320), init $FFFFFFFF, final inversion, the 12 bits fed
// LSB first (bit 0 = B[4] first, bit 11 = R[7] last) -- K325T/tools/fmeas.py crc12() is the reference.
// Visible pixel: hblank = 0 and vblank = 0 at a 14 MHz enable.  h = index of the pixel in its line
// (0 at the first visible pixel), v = index of the visible line in the frame (0 = first visible line).
// Window (parameters, below): only pixels with XLO <= h <= XHI and YLO <= v <= YHI enter the CRCs.
//
// Per frame k (counted from the FPGA configuration; the frame ends at the rising vsync):
//   ring[k mod 2048] = frame CRC (2 x 1024 x 32 block RAM)
// On an "arm" command, the next whole frame is captured as well:
//   line table: the CRC of each window line v (0..511) of that frame (2 x 256 x 32 block RAM)
//   line grab : the 12-bit pixels h = 0..1023 of line GRAB of that frame (8 x 128 x 12 LUT RAM)
//
// Register write recorder (same captured frame): every write on the custom register bus whose register
// is in an enabled group (group = register address bits 8..5, i.e. $000-$01E = group 0 .. $1E0-$1FE = 15;
// enable mask = parameter 5, default $0390 = groups 4 ($080-$09E: DIW/DDF/DMACON..), 7 ($0E0: BPLxPT),
// 8 ($100: BPLCON/BPLxMOD), 9 ($120: SPRxPT)) by the CPU or the copper -- DMA data writes (BPLxDAT,
// SPRxPOS..DATB, AUDxDAT, during a DMA cycle) are left out -- up to 2048 entries (block RAM):
// {dma (1, the copper when the register is not a DMA data register), line since the frame start (9),
// colour clock since the line start (8), register (8), data (16)}.  Lines/clocks count from Agnus' sof/sol.
//
// Configuration: the bridge VIDEO byte 1rrrvvvv (asynchronous), decoded as lat_meter does: registers
// r3/r4/r5 are taken while r6 selects page 7; idx = r4 & r5.
// Readout (q, quasi-static: changes only when the index or the measured data changes):
//   idx $00-$7F, a = {idx[6:0], r3} (11 bits): register write a: W0 = {dma, 6'b0, line (9), cck (8),
//                register (8)}, W1 = {data (16), a (11), 5'b0}, W2 = {count (12), overflow, 19'b0}
//   idx $80-$BF, a = {idx[5:0], r3} (10 bits): W0 = ring[2a], W1 = ring[2a+1],
//                W2 = {a (10), 6'b0, frame count [15:0]}
//   idx $C0-$CF, a = {idx[3:0], r3} (8 bits): W0 = line CRC [2a], W1 = line CRC [2a+1],
//                W2 = {a (8), 8'b0, captured frame [15:0]}
//   idx $D0-$D7, a = {idx[2:0], r3} (7 bits): pixels 8a .. 8a+7 (12 bits each, 8a in W0[95:84])
//   idx $DC, r3 = 0: W0 = frame count (frames finished), W1 = captured frame number,
//                    W2 = {captured, armed, capturing, nib, 2'b0, lines of the last frame (10),
//                          pixels of the last frame's first visible line (16)}
//            r3 = 1: W0 = $FEA50001 (id), W1 = frame count at the last machine reset (rising),
//                    W2 = window pixels of the last frame
//            r3 = 2: W0 = {XLO, XHI}, W1 = {YLO, YHI}, W2 = {GRAB, shift register [15:0]}
//            r3 = 3: W0 = CRC of the last finished frame, W1 = window pixels of the captured frame,
//                    W2 = {lines of the captured frame (16), register writes recorded (12), overflow, 3'b0}
// Commands (side effects only on CHANGES of r5 while r4 = $D):
//   r5 9 -> 8 or 8 -> 9 : shift register := shift register << 4 | r3
//   r5 -> $A            : parameter r3 := shift register [15:0]   (0 XLO, 1 XHI, 2 YLO, 3 YHI, 4 GRAB,
//                                                                    5 register group mask)
//   r5 -> $B            : action r3: 1 = arm (capture the next whole frame), 3 = clear the nib flag
// Defaults: XLO 0, XHI 1023, YLO 0, YHI 511, GRAB 100.
module fmeas (
  input  wire        clk,
  input  wire        e14,          // one hires pixel (clk7_en | clk7n_en)
  input  wire        hblank,
  input  wire        vblank,
  input  wire        vs,           // vertical sync, active high
  input  wire [7:0]  r,
  input  wire [7:0]  g,
  input  wire [7:0]  b,
  input  wire        mreset,       // machine reset (only recorded)
  input  wire [7:0]  cfg,          // bridge VIDEO byte (asynchronous)
  input  wire [31:0] rbus,         // minimig's register bus (patch 0146): {0, cck, sol, sof, cpuw, dbr, 00, reg, data}
  output reg  [95:0] q
);

  function [31:0] crc12(input [31:0] c, input [11:0] d);
    integer i;
    reg [31:0] x;
    begin
      x = c;
      for (i = 0; i < 12; i = i + 1)
        x = (x[0] ^ d[i]) ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
      crc12 = x;
    end
  endfunction

  // ---------------------------------------------------------------- configuration byte
  (* ASYNC_REG = "TRUE" *) reg [7:0] cfg_s1 = 8'h00, cfg_s2 = 8'h00;
  reg [7:0] cfg_s3 = 8'h00;
  reg [3:0] stable = 4'd0;
  reg [3:0] r3 = 4'd0, r4 = 4'd0, r5 = 4'd0, r6 = 4'd0, r5_prev = 4'd0;
  reg [31:0] sr = 32'd0;
  reg [15:0] xlo = 16'd0, xhi = 16'd1023, ylo = 16'd0, yhi = 16'd511, grab = 16'd100, gmask = 16'h0390;
  reg        arm_cmd = 1'b0, clrnib_cmd = 1'b0;
  wire [7:0] idx = {r4, r5};

  always @(posedge clk) begin
    cfg_s1 <= cfg; cfg_s2 <= cfg_s1; cfg_s3 <= cfg_s2;
    if (cfg_s2 != cfg_s3) stable <= 4'd0;
    else if (stable != 4'd15) stable <= stable + 4'd1;
    if (stable == 4'd14 && cfg_s3[7]) begin       // once per accepted byte
      case (cfg_s3[6:4])
        3'b110: r6 <= cfg_s3[3:0];
        3'b011: if (r6[2:0] == 3'b111) r3 <= cfg_s3[3:0];
        3'b100: if (r6[2:0] == 3'b111) r4 <= cfg_s3[3:0];
        3'b101: if (r6[2:0] == 3'b111) r5 <= cfg_s3[3:0];
        default: ;
      endcase
    end
    r5_prev <= r5;
    arm_cmd <= 1'b0; clrnib_cmd <= 1'b0;
    if (r4 == 4'hD && r5 != r5_prev) begin
      if ((r5 == 4'h8 && r5_prev == 4'h9) || (r5 == 4'h9 && r5_prev == 4'h8))
        sr <= {sr[27:0], r3};
      else if (r5 == 4'hA)
        case (r3)
          4'd0: xlo  <= sr[15:0];
          4'd1: xhi  <= sr[15:0];
          4'd2: ylo  <= sr[15:0];
          4'd3: yhi  <= sr[15:0];
          4'd4: grab <= sr[15:0];
          4'd5: gmask <= sr[15:0];
          default: ;
        endcase
      else if (r5 == 4'hB) begin
        if (r3 == 4'd1) arm_cmd <= 1'b1;
        if (r3 == 4'd3) clrnib_cmd <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------- measurement
  reg        hb_d = 1'b1, vs_d = 1'b0, mr_d = 1'b0;
  reg        line_vis = 1'b0;               // the current line has visible pixels (vblank = 0 at its start)
  reg [15:0] h = 16'd0, v = 16'd0;
  reg [31:0] crc = 32'hFFFFFFFF, lcrc = 32'hFFFFFFFF;
  reg [31:0] frame_cnt = 32'd0, cap_frame = 32'd0, reset_frame = 32'd0, last_crc = 32'd0;
  reg [31:0] wpix = 32'd0, wpix_last = 32'd0, wpix_cap = 32'd0;
  reg [15:0] lines_last = 16'd0, lines_cap = 16'd0, hpix_first = 16'd0, hpix_last = 16'd0;
  reg        armed = 1'b0, capturing = 1'b0, captured = 1'b0, nib = 1'b0;

  // ring: frame k -> even/odd bank by k[0], address k[10:1]
  reg [31:0] ring_e [0:1023];
  reg [31:0] ring_o [0:1023];
  reg [31:0] lt_e [0:255];
  reg [31:0] lt_o [0:255];
  (* ram_style = "distributed" *) reg [11:0] gb0 [0:127];
  (* ram_style = "distributed" *) reg [11:0] gb1 [0:127];
  (* ram_style = "distributed" *) reg [11:0] gb2 [0:127];
  (* ram_style = "distributed" *) reg [11:0] gb3 [0:127];
  (* ram_style = "distributed" *) reg [11:0] gb4 [0:127];
  (* ram_style = "distributed" *) reg [11:0] gb5 [0:127];
  (* ram_style = "distributed" *) reg [11:0] gb6 [0:127];
  (* ram_style = "distributed" *) reg [11:0] gb7 [0:127];

  reg        ring_we = 1'b0, ring_odd = 1'b0;
  reg [9:0]  ring_wa = 10'd0;
  reg [31:0] ring_wd = 32'd0;
  reg        lt_we = 1'b0, lt_odd = 1'b0;
  reg [7:0]  lt_wa = 8'd0;
  reg [31:0] lt_wd = 32'd0;
  reg        gb_we = 1'b0;
  reg [2:0]  gb_bank = 3'd0;
  reg [6:0]  gb_wa = 7'd0;
  reg [11:0] gb_wd = 12'd0;

  wire [11:0] pix = {r[7:4], g[7:4], b[7:4]};
  wire        pnib = (r[3:0] != r[7:4]) || (g[3:0] != g[7:4]) || (b[3:0] != b[7:4]);
  wire        vis = e14 && !hblank && !vblank;
  // a visible line starts at the falling hblank; its first pixel may come in that same clock
  wire        lstart = !hblank && hb_d && !vblank;
  wire        lv = line_vis || lstart;
  wire [15:0] hc = lstart ? 16'd0 : h;
  wire [31:0] lcrc_in = lstart ? 32'hFFFFFFFF : lcrc;
  wire        inwin = (hc >= xlo) && (hc <= xhi) && (v >= ylo) && (v <= yhi);

  always @(posedge clk) begin
    hb_d <= hblank; vs_d <= vs; mr_d <= mreset;
    ring_we <= 1'b0; lt_we <= 1'b0; gb_we <= 1'b0;
    if (mreset && !mr_d) reset_frame <= frame_cnt;
    if (arm_cmd) armed <= 1'b1;
    if (clrnib_cmd) nib <= 1'b0;

    if (vs && !vs_d) begin
      // end of frame frame_cnt
      ring_we   <= 1'b1;
      ring_odd  <= frame_cnt[0];
      ring_wa   <= frame_cnt[10:1];
      ring_wd   <= ~crc;
      last_crc  <= ~crc;
      wpix_last <= wpix;
      lines_last <= v;
      hpix_last <= hpix_first;
      if (capturing) begin
        capturing <= 1'b0;
        captured  <= 1'b1;
        wpix_cap  <= wpix;
        lines_cap <= v;
      end
      if (armed && !capturing) begin           // the frame that starts now is captured
        armed     <= 1'b0;
        capturing <= 1'b1;
        captured  <= 1'b0;
        cap_frame <= frame_cnt + 32'd1;
      end
      frame_cnt <= frame_cnt + 32'd1;
      crc  <= 32'hFFFFFFFF;
      wpix <= 32'd0;
      v    <= 16'd0;
      line_vis <= 1'b0;
    end else begin
      if (lstart) begin                         // a visible line starts
        h <= 16'd0;
        lcrc <= 32'hFFFFFFFF;
        line_vis <= 1'b1;
      end
      if (hblank && !hb_d && line_vis) begin   // the visible line ends
        line_vis <= 1'b0;
        if (v == 16'd0) hpix_first <= h;
        if (capturing && v < 16'd512) begin
          lt_we  <= 1'b1;
          lt_odd <= v[0];
          lt_wa  <= v[8:1];
          lt_wd  <= ~lcrc;
        end
        v <= v + 16'd1;
      end
      if (vis && lv) begin
        if (inwin) begin
          crc  <= crc12(crc, pix);
          lcrc <= crc12(lcrc_in, pix);
          wpix <= wpix + 32'd1;
        end
        if (pnib) nib <= 1'b1;
        if (capturing && v == grab && hc < 16'd1024) begin
          gb_we   <= 1'b1;
          gb_bank <= hc[2:0];
          gb_wa   <= hc[9:3];
          gb_wd   <= pix;
        end
        h <= hc + 16'd1;
      end
    end
  end

  always @(posedge clk) begin
    if (ring_we && !ring_odd) ring_e[ring_wa] <= ring_wd;
    if (ring_we &&  ring_odd) ring_o[ring_wa] <= ring_wd;
    if (lt_we && !lt_odd) lt_e[lt_wa] <= lt_wd;
    if (lt_we &&  lt_odd) lt_o[lt_wa] <= lt_wd;
  end
  always @(posedge clk) begin
    if (gb_we) case (gb_bank)
      3'd0: gb0[gb_wa] <= gb_wd;  3'd1: gb1[gb_wa] <= gb_wd;
      3'd2: gb2[gb_wa] <= gb_wd;  3'd3: gb3[gb_wa] <= gb_wd;
      3'd4: gb4[gb_wa] <= gb_wd;  3'd5: gb5[gb_wa] <= gb_wd;
      3'd6: gb6[gb_wa] <= gb_wd;  3'd7: gb7[gb_wa] <= gb_wd;
    endcase
  end


  // ---------------------------------------------------------------- register write recorder
  wire        rb_cck = rbus[30], rb_sol = rbus[29], rb_sof = rbus[28], rb_cpuw = rbus[27], rb_dbr = rbus[26];
  wire [7:0]  rb_reg = rbus[23:16];
  wire [15:0] rb_dat = rbus[15:0];
  // DMA data registers: BPLxDAT $110-$11E (88-8F), SPRxPOS..DATB $140-$17E (A0-BF), AUDxDAT, DSKDAT
  wire        rb_dmadata = (rb_reg[7:3] == 5'b10001) || (rb_reg[7:5] == 3'b101) || rb_reg == 8'h55 || rb_reg == 8'h5D ||
                           rb_reg == 8'h65 || rb_reg == 8'h6D || rb_reg == 8'h13;
  wire        rb_idle = rb_reg == 8'hFF;
  reg  [8:0]  rb_line = 9'd0;
  reg  [7:0]  rb_hc = 8'd0;
  reg         rb_cck_d = 1'b0;
  reg  [23:0] rb_last = 24'hFFFFFF;
  reg  [12:0] rcnt = 13'd0;
  reg         rovf = 1'b0;
  reg         rr_we = 1'b0;
  reg  [10:0] rr_wa = 11'd0;
  reg  [47:0] rr_wd = 48'd0;
  reg  [47:0] rrec [0:2047];
  reg         cap_d = 1'b0;
  reg         rb_sol_d = 1'b0;
  reg         rb_key_ok_d = 1'b0;
  wire        rb_solr = rb_sol && !rb_sol_d;
  wire [7:0]  rb_hc_now = rb_solr ? 8'd0 : (rb_cck && !rb_cck_d) ? rb_hc + 8'd1 : rb_hc;
  wire [8:0]  rb_line_now = rb_solr ? (rb_sof ? 9'd0 : rb_line + 9'd1) : rb_line;
  wire        rb_take = !rb_idle && (rb_cpuw || (rb_dbr && !rb_dmadata)) && gmask[rb_reg[7:4]];
  always @(posedge clk) begin
    rr_we <= 1'b0;
    cap_d <= capturing;
    rb_cck_d <= rb_cck;
    rb_sol_d <= rb_sol;
    if (capturing && !cap_d) begin rcnt <= 13'd0; rovf <= 1'b0; end
    // cck is a level (one 7 MHz period high, one low): count its rising edges; sol / sof are one 7 MHz
    // period long: count the rising edge of sol
    rb_hc   <= rb_hc_now;
    rb_line <= rb_line_now;
    // one entry per access: the (register, data) pair changed since the previous clock, or the bus was
    // somewhere else in between
    rb_key_ok_d <= rb_take;
    if (rb_take && (!rb_key_ok_d || {rb_reg, rb_dat} != rb_last)) begin
      if (capturing) begin
        if (rcnt == 13'd2048) rovf <= 1'b1;
        else begin
          rr_we <= 1'b1;
          rr_wa <= rcnt[10:0];
          rr_wd <= {rb_dbr & !rb_cpuw, 6'b0, rb_line_now, rb_hc_now, rb_reg, rb_dat};
          rcnt  <= rcnt + 13'd1;
        end
      end
    end
    rb_last <= {rb_reg, rb_dat};
  end
  always @(posedge clk)
    if (rr_we) rrec[rr_wa] <= rr_wd;
  wire [10:0] rra = {idx[6:0], r3};
  reg  [47:0] rr_q = 48'd0;
  always @(posedge clk) rr_q <= rrec[rra];

  // ---------------------------------------------------------------- readout
  wire [9:0] ra = {idx[5:0], r3};
  wire [7:0] la = {idx[3:0], r3};
  wire [6:0] ga = {idx[2:0], r3};
  reg  [31:0] re_q = 32'd0, ro_q = 32'd0, le_q = 32'd0, lo_q = 32'd0;
  always @(posedge clk) begin
    re_q <= ring_e[ra];
    ro_q <= ring_o[ra];
    le_q <= lt_e[la];
    lo_q <= lt_o[la];
  end
  reg [7:0] idx_d = 8'd0;
  reg [3:0] r3_d = 4'd0;
  always @(posedge clk) begin
    idx_d <= idx; r3_d <= r3;
    if (idx_d[7] == 1'b0)
      q <= {rr_q[47], 6'b0, rr_q[40:16], rr_q[15:0], {idx_d[6:0], r3_d}, 5'b0, rcnt[11:0], rovf, 19'b0};
    else if (idx_d[7:6] == 2'b10)
      q <= {re_q, ro_q, {idx_d[5:0], r3_d}, 6'b0, frame_cnt[15:0]};
    else if (idx_d[7:4] == 4'hC)
      q <= {le_q, lo_q, {idx_d[3:0], r3_d}, 8'b0, cap_frame[15:0]};
    else if (idx_d[7:3] == 5'b11010)
      q <= {gb0[{idx_d[2:0], r3_d}], gb1[{idx_d[2:0], r3_d}], gb2[{idx_d[2:0], r3_d}], gb3[{idx_d[2:0], r3_d}],
            gb4[{idx_d[2:0], r3_d}], gb5[{idx_d[2:0], r3_d}], gb6[{idx_d[2:0], r3_d}], gb7[{idx_d[2:0], r3_d}]};
    else if (idx_d == 8'hDC)
      case (r3_d)
        4'd0: q <= {frame_cnt, cap_frame, captured, armed, capturing, nib, 2'b00, lines_last[9:0], hpix_last};
        4'd1: q <= {32'hFEA50001, reset_frame, wpix_last};
        4'd2: q <= {xlo, xhi, ylo, yhi, grab, sr[15:0]};
        4'd4: q <= {gmask, 16'd0, 64'd0};
        4'd3: q <= {last_crc, wpix_cap, lines_cap, rcnt[11:0], rovf, 3'b0};
        default: q <= 96'd0;
      endcase
    else
      q <= 96'd0;
  end

endmodule
