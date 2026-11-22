// tb_fmeas.v -- unit bench of K325T/fmeas.v (a500-bacon).  Run: K325T/sim/run_fmeas.sh
// A synthetic PAL-like raster (14 MHz enable every 2nd clock, 908 pixels per line with 154 blanked,
// 313 lines with 26 blanked, vsync in lines 2..4), pseudo-random 12-bit pixels (nibbles duplicated
// as OCS does).  The bench writes every visible pixel the DUT sees (frame, v, h, pixel) to
// fmeas_pix.txt and the readout words to fmeas_q.txt; check_fmeas.py recomputes everything.
`timescale 1ns/1ps
module tb_fmeas;
  reg clk = 0;
  always #17.6 clk = ~clk;
  reg e14 = 0, hblank = 1, vblank = 1, vs = 0, mreset = 0;
  reg [7:0] r = 0, g = 0, b = 0, cfg = 8'h00;
  reg [31:0] rbus = 32'h00FF0000;
  wire [95:0] q;
  fmeas dut (.clk(clk), .e14(e14), .hblank(hblank), .vblank(vblank), .vs(vs), .r(r), .g(g), .b(b),
             .mreset(mreset), .cfg(cfg), .rbus(rbus), .q(q));

  // the register bus: 313 lines x 227 colour clocks x 8 clocks; cck high for 4 clocks of 8; sol (+ sof in
  // line 0) for the 4 clocks of colour clock 0; every 7th line a copper move to BPLCON1 at cck 40 (logged),
  // a BPL1DAT DMA write at cck 41 (must not be recorded) and a CPU write to BPLCON0 at cck 60..61 (logged)
  integer rl, rc, rk, fr2;
  reg [7:0] rreg; reg [15:0] rdat; reg rcpu, rdbr;
  initial begin
    fr2 = $fopen("fmeas_rbus.txt", "w");
    forever for (rl = 0; rl < 313; rl = rl + 1) for (rc = 0; rc < 227; rc = rc + 1) begin
      rreg = 8'hFF; rdat = 16'h0000; rcpu = 0; rdbr = 0;
      if (rl % 7 == 3 && rc == 40) begin rreg = 8'h81; rdat = {rl[7:0], 8'h40}; rdbr = 1; end
      if (rl % 7 == 3 && rc == 41) begin rreg = 8'h88; rdat = 16'h1234; rdbr = 1; end
      if (rl % 7 == 3 && (rc == 60 || rc == 61)) begin rreg = 8'h80; rdat = {7'd0, rl[8:0]}; rcpu = 1; end
      if (rreg != 8'hFF && rreg != 8'h88 && !(rcpu && rc == 61))
        $fwrite(fr2, "%0d %0d %0d %0d %02x %04x\n", $time, rl, rc, rdbr & !rcpu, rreg, rdat);
      for (rk = 0; rk < 8; rk = rk + 1) begin
        @(posedge clk);
        rbus <= {1'b0, rk < 4, rc == 0 && rk < 4, rl == 0 && rc == 0 && rk < 4, rcpu, rdbr, 2'b00, rreg, rdat};
      end
    end
  end
  reg cap_d = 0; integer fc;
  initial fc = $fopen("fmeas_capwin.txt", "w");
  always @(posedge clk) begin
    cap_d <= dut.capturing;
    if (dut.capturing && !cap_d) $fwrite(fc, "start %0d\n", $time);
    if (!dut.capturing && cap_d) $fwrite(fc, "end %0d\n", $time);
  end

  integer fp, fq, line, px, frame;
  reg [31:0] lfsr = 32'h1234_5678;
  reg [11:0] p;

  task wr(input [2:0] rg, input [3:0] val);   // one bridge register write (held long enough)
    begin
      cfg = {1'b1, rg, val};
      repeat (40) @(posedge clk);
      cfg = 8'h01;                              // m65d-style byte with bit 7 = 0 in between
      repeat (40) @(posedge clk);
    end
  endtask
  task setidx(input [7:0] i, input [3:0] a3);
    begin wr(3'd4, i[7:4]); wr(3'd5, i[3:0]); wr(3'd3, a3); repeat (8) @(posedge clk); end
  endtask
  task param(input [3:0] n, input [15:0] val);
    integer k;
    begin
      wr(3'd4, 4'hD); wr(3'd5, 4'h9);
      for (k = 3; k >= 0; k = k - 1) begin
        wr(3'd3, val[4*k +: 4]);
        wr(3'd5, (k % 2) ? 4'h8 : 4'h9);
      end
      wr(3'd3, n); wr(3'd5, 4'hA); wr(3'd5, 4'hC);
    end
  endtask

  // the raster runs in its own process
  initial begin
    fp = $fopen("fmeas_pix.txt", "w");
    for (frame = 0; frame < 6; frame = frame + 1)
      for (line = 0; line < 313; line = line + 1)
        for (px = 0; px < 908; px = px + 1) begin
          @(posedge clk); e14 <= 0;
          @(posedge clk);
          vs <= (line >= 2 && line <= 4);
          vblank <= (line < 26);
          hblank <= (px < 154);
          lfsr = lfsr[0] ? (lfsr >> 1) ^ 32'hA3000000 : lfsr >> 1;
          p = (px % 97 == 5) ? 12'h000 : lfsr[11:0];
          r <= {p[11:8], p[11:8]}; g <= {p[7:4], p[7:4]}; b <= {p[3:0], p[3:0]};
          e14 <= 1;
          if (line >= 26 && px >= 154) $fwrite(fp, "%0d %0d %0d %03x\n", frame, line - 26, px - 154, p);
        end
    $fclose(fp);
  end

  integer i;
  initial begin
    fq = $fopen("fmeas_q.txt", "w");
    // window: h 3..700, v 2..280, grab line 7; arm during frame 2 -> frame 3 captured
    #1000;
    wr(3'd6, 4'h7);
    param(4'd0, 16'd3); param(4'd1, 16'd700); param(4'd2, 16'd2); param(4'd3, 16'd280); param(4'd4, 16'd7);
    wait (frame == 2);
    wr(3'd4, 4'hD); wr(3'd3, 4'd1); wr(3'd5, 4'hB); wr(3'd5, 4'hC);
    wait (frame == 5);
    for (i = 0; i < 4; i = i + 1) begin setidx(8'hDC, i); $fwrite(fq, "S%0d %024x\n", i, q); end
    for (i = 0; i < 3; i = i + 1) begin setidx(8'h80, i); $fwrite(fq, "R%0d %024x\n", i, q); end
    for (i = 0; i < 144; i = i + 1) begin setidx(8'hC0 | (i >> 4), i & 15); $fwrite(fq, "L%0d %024x\n", i, q); end
    for (i = 0; i < 128; i = i + 1) begin setidx(8'hD0 | (i >> 4), i & 15); $fwrite(fq, "G%0d %024x\n", i, q); end
    for (i = 0; i < 100; i = i + 1) begin setidx(i >> 4, i & 15); $fwrite(fq, "W%0d %024x\n", i, q); end
    $fclose(fr2); $fclose(fc);
    $fclose(fq);
    $finish;
  end
endmodule
