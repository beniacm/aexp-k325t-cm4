// aud_rec.v -- audio flight recorder (K325T a1200-audrec, debug; instantiated in minimig.v by patch 0144)
//
// Watches the machine without driving anything back into it: a ring of the last 1,024 audio-related
// events (block RAM, 1024 x 72 = 2 RAMB36), frozen some time after a trigger, plus a snapshot of every
// audio channel's registers at the trigger.  Read through the stall controller's page 7 (lat_meter.vhd
// rec_i), see "Readout" below and K325T/tools/audrec.py.
//
// Entry (72 bits): [71:42] time stamp = colour clocks (CCK) since power-up, 30 bits (wraps after 303 s)
//                  [41:38] kind, [37:12] payload (26 bits, per kind), [11:0] the four channels' states
//                  (3 bits each, channel 0 in [2:0]; codes 0,1,3,2,6 = Paula states 0,1,2,3,4).
// Kinds:  0 CPU write to a watched register  payload = reg[8:1] (8) | data (16) | src (2) = 0
//         1 CPU READ of a watched register (Minimig writes $FFFF into it)  = reg | data on the bus | 1
//         2 other bus-master write (copper ...) to a watched register, not AUDxDAT = reg | data | 2
//         3 channel state transition (not 3<->4 with DMA on)  = ch (2) | from (3) | to (3) | dmaena |
//           intpen | silence | silence_d | dmareq | lenfin(0) | sample (8) | percnt[3:0] (4)
//         4 DMA word for a channel in state 1 or 2 (the restart fetches) = ch (2) | addr[20:1] (20) | 0 (4)
//         5 every 128th DMA word of a channel = ch (2) | data (16) | addr[8:1] (8)
//         6 IPL change (any change with a level >= 4 on either side; all changes with mode b3)
//           = old level (3) | new level (3) | 0
//         7 CIA-B access to TA/TB/ICR/CRA/CRB = rs (4) | write (1) | data (8) | 0
//         8 trigger = cause (4: b0 mix, b1 channel stuck, b2 channel constant, b3 forced) | channel mask
//           (4) | hold CCK so far [17:0]
//         9 hold end (the mix changed again after the trigger) = 0
//        10 machine reset seen (rising) = 0
//        11 armed = mode (4)
//        12 events lost (pending slot busy) = count since arm [25:0]
//        13 per-channel DMA counters at the hold end = ch (2) | words since the trigger [11:0] |
//           zero words since the trigger [11:0]
// Watched registers: DMACON $096, INTENA $09A, INTREQ $09C, ADKCON $09E, $0A0-$0DF (all audio).
//
// Trigger (mode, default 4'b0011):
//   b0 mix: L and R mixer outputs both unchanged for G_HOLD CCK (100 ms) while some channel's DMA was on with
//      a volume above 0 at some time in that window (a replay that switches DMA on before its first volume
//      write does not fire it).  Normal music never holds both sides constant that long (FS-UAE runs
//      of the demo: no both-channel quiet stretch >= 80 ms); a channel resting alone does not fire it.
//   b1 channel stuck: a channel's DMA on all the time for G_HOLD CCK and no DMA word for it (the longest
//      legal gap is two samples at period 65,536 = 37 ms): never in normal operation.
//   b2 channel constant: one channel's output byte unchanged for G_HOLD CCK while its DMA was on with a volume (fires in
//      every rest of a one-shot instrument: off by default).
//   b3 IPL changes of every level are recorded (not a trigger condition).
// After a trigger the ring keeps recording G_POST entries (384), then freezes until re-armed.
//
// Readout (configuration byte = the bridge VIDEO byte 1rrrvvvv, decoded here as by lat_meter: registers
// r3/r4/r5 are taken while r6 selects page 7; idx = r4 & r5):
//   idx $80-$BF: entry at physical address {r3, idx[5:0]}: W0..W2 = entry (72) | status (24) =
//                frozen | fired | wp (10) | echo of the address (10) | 2'b10
//   idx $C0 + k: snapshot word k (r3 = j selects a sub-word):
//     $C0 status {A19, mode, fired, frozen, wrapped, holdend, 00, wp} | time now (CCK) | lost (16), cause, chmask, 01
//     $C1 trigger time | last mix change before the trigger (the cut) | hold end time   (CCK)
//     $C2 {00, L, R at the trigger} | mix hold at the trigger (clk7_en periods) | mix hold now
//     $C3 live: channel states | 0 | nodat[31:16] of channels 0..3 (16 bits each)
//     $C4/$C6/$C8/$CA (channel 0..3), r3 = 0: the channel's dbg[95:0] at the trigger; r3 = 1: last DMA address
//         (word address, 20 bits) | words fetched / zero words since the cut (16 + 16) | its byte's last change (CCK)
//     $C5/$C7/$C9/$CB: dbg[127:96] at the trigger
//   commands (executed once when the combination appears): idx $CF with r3 = $A: arm (clear the ring and
//   the snapshot, start recording); idx $CF with r3 = $C: force a trigger; idx $CE with r3 = m: mode = m.
// Nothing here is reset by the machine: a frozen ring survives Amiga resets until re-armed.
module aud_rec #(
  parameter G_HOLD = 32'd354690,   // 100 ms of CCK (3,546,895 Hz)
  parameter G_POST = 10'd384
) (
  input  wire         clk,
  input  wire         clk7_en,
  input  wire         cck,
  input  wire         reset,          // machine reset (only recorded)
  input  wire [8:1]   reg_address,
  input  wire [15:0]  data,           // custom_data_in (what the registers latch)
  input  wire         cpu_custom,
  input  wire         dbr,
  input  wire         cpu_rd,
  input  wire         cpu_wr,
  input  wire [20:1]  dma_address,
  input  wire         sel_cia_b,
  input  wire [11:8]  cia_rs,
  input  wire [7:0]   cia_wdata,
  input  wire [7:0]   cia_rdata,
  input  wire [2:0]   ipl_n,
  input  wire [14:0]  ldata,
  input  wire [14:0]  rdata,
  input  wire [511:0] aud_dbg,        // 4 x 128: paula_audio_channel dbg (channel 0 in [127:0])
  input  wire [7:0]   cfg,            // bridge VIDEO byte (asynchronous)
  output reg  [95:0]  rec_out
);

// ---------------------------------------------------------------- channel debug fields
wire [2:0]  st   [0:3];
wire [7:0]  smp  [0:3];
wire        don  [0:3];
wire        ipen [0:3];
wire        sil  [0:3];
wire        sild [0:3];
wire        dreq [0:3];
wire [15:0] pcnt [0:3];
wire        dv   [0:3];      // DMA on with a volume above 0 (a fault's channel: the replay writes the volume every tick)
genvar g;
generate for (g = 0; g < 4; g = g + 1) begin : g_ch
  assign st[g]   = aud_dbg[128 * g + 2  : 128 * g];
  assign smp[g]  = aud_dbg[128 * g + 10 : 128 * g + 3];
  assign don[g]  = aud_dbg[128 * g + 11];
  assign ipen[g] = aud_dbg[128 * g + 12];
  assign sil[g]  = aud_dbg[128 * g + 13];
  assign sild[g] = aud_dbg[128 * g + 14];
  assign dreq[g] = aud_dbg[128 * g + 16];
  assign pcnt[g] = aud_dbg[128 * g + 34 : 128 * g + 19];
  assign dv[g]   = aud_dbg[128 * g + 11] && aud_dbg[128 * g + 89 : 128 * g + 83] != 7'd0;
end endgenerate
wire [11:0] states = {st[3], st[2], st[1], st[0]};

// ---------------------------------------------------------------- configuration byte (as lat_meter)
reg  [7:0] cfg_s1 = 8'd0, cfg_s2 = 8'd0, cfg_s3 = 8'd0;
reg  [3:0] stable = 4'd0;
reg  [3:0] r3 = 4'd0, r4 = 4'd0, r5 = 4'd0, r6 = 4'd0;
wire [7:0] idx = {r4, r5};
always @(posedge clk) begin
  cfg_s1 <= cfg; cfg_s2 <= cfg_s1; cfg_s3 <= cfg_s2;
  if (cfg_s2 != cfg_s3) stable <= 4'd0; else if (stable != 4'd15) stable <= stable + 4'd1;
  if (stable == 4'd15 && cfg_s3[7]) begin
    case (cfg_s3[6:4])
      3'd6: r6 <= cfg_s3[3:0];
      3'd3: if (r6[2:0] == 3'd7) r3 <= cfg_s3[3:0];
      3'd4: if (r6[2:0] == 3'd7) r4 <= cfg_s3[3:0];
      3'd5: if (r6[2:0] == 3'd7) r5 <= cfg_s3[3:0];
      default: ;
    endcase
  end
end
wire cmd_arm   = idx == 8'hCF && r3 == 4'hA;
wire cmd_force = idx == 8'hCF && r3 == 4'hC;
wire cmd_mode  = idx == 8'hCE;
reg  cmd_arm_d = 1'b0, cmd_force_d = 1'b0;

// ---------------------------------------------------------------- time and state
reg  [31:0] ts = 32'd0;              // CCK since power-up
reg  [3:0]  mode = 4'b0011;
reg         armed = 1'b1;            // recording
reg         fired = 1'b0;            // trigger seen
reg         frozen = 1'b0;
reg         holdend = 1'b0;
reg         wrapped = 1'b0;
reg  [9:0]  wp = 10'd0;
reg  [9:0]  post = 10'd0;
reg  [3:0]  cause = 4'd0, chmask = 4'd0;
reg  [15:0] lost = 16'd0;
reg  [31:0] t_trig = 32'd0, t_mix = 32'd0, t_end = 32'd0, t_cut = 32'd0;   // t_cut = t_mix at the trigger
reg  [29:0] l_trig = 30'd0;          // L/R at the trigger
reg  [31:0] hold_trig = 32'd0;

// ---------------------------------------------------------------- watched registers on the bus
// reg_address is the word address bits 8:1; $096 = 4B, $09A = 4D, $09C = 4E, $09E = 4F, $0A0-$0DF = 50-6F
wire watched = reg_address == 8'h4B || reg_address == 8'h4D || reg_address == 8'h4E || reg_address == 8'h4F ||
               (reg_address >= 8'h50 && reg_address <= 8'h6F);
// AUDxDAT word addresses: $0AA/$0BA/$0CA/$0DA -> 55, 5D, 65, 6D
wire [3:0] dat_ch = {reg_address == 8'h6D, reg_address == 8'h65, reg_address == 8'h5D, reg_address == 8'h55};
reg  [7:0]  acc_reg = 8'hFF;
reg  [15:0] acc_dat = 16'd0;
reg         acc_done = 1'b0;          // the CPU access in progress is recorded
wire cpu_acc = cpu_custom && (cpu_rd || cpu_wr) && watched;
wire dma_acc = dbr && watched && dat_ch == 4'd0;


// ---------------------------------------------------------------- pending event slots (one per source)
// 0 register access, 1-4 channel transitions, 5 DMA word, 6 IPL, 7 CIA-B, 8 marker.  Each clock the lowest
// pending slot is written into the ring (one source event per machine clock-enable period at most, four
// clocks apart: the slots drain long before the next one); a source finding its slot still full counts as lost.
localparam NS = 9;
localparam [31:0] H7 = G_HOLD * 2;   // the hold in clk7_en periods
reg  [NS-1:0] pv = {NS{1'b0}};
reg  [29:0]   pk [0:NS-1];           // kind (4) | payload (26)
reg  [29:0]   pts [0:NS-1];
integer i;
initial for (i = 0; i < NS; i = i + 1) begin pk[i] = 30'd0; pts[i] = 30'd0; end

reg  [2:0]  st_d [0:3];
reg  [6:0]  wcnt [0:3];              // DMA word counters (mod 128) for kind 5
reg  [15:0] wsince [0:3], zsince [0:3];      // words / zero words since the last mix change
reg  [11:0] wtrig [0:3], ztrig [0:3];        // since the trigger
reg  [19:0] lastaddr [0:3];
reg  [31:0] chg_ts   [0:3];          // CCK of the last change of the channel's output byte
reg  [7:0]  smp_d    [0:3];
reg  [31:0] nodat    [0:3];          // clk7_en periods with DMA on and no word
reg  [31:0] ccon     [0:3];          // clk7_en periods with the channel's byte constant
reg  [3:0]  cdma = 4'd0;             // DMA on seen in the channel's constant window
reg  [127:0] snap [0:3];
reg  [19:0] snap_addr [0:3];
reg  [15:0] snap_w [0:3], snap_z [0:3];
reg  [31:0] snap_chg [0:3];
initial for (i = 0; i < 4; i = i + 1) begin
  st_d[i] = 3'd0; wcnt[i] = 7'd0; wsince[i] = 16'd0; zsince[i] = 16'd0; wtrig[i] = 12'd0; ztrig[i] = 12'd0;
  lastaddr[i] = 20'd0; chg_ts[i] = 32'd0; smp_d[i] = 8'd0; nodat[i] = 32'd0; ccon[i] = 32'd0;
  snap[i] = 128'd0; snap_addr[i] = 20'd0; snap_w[i] = 16'd0; snap_z[i] = 16'd0; snap_chg[i] = 32'd0;
end
reg  [14:0] l_d = 15'd0, r_d = 15'd0;
reg  [31:0] mixcon = 32'd0;          // clk7_en periods with L and R unchanged
reg         mixdma = 1'b0;
reg  [2:0]  ipl_d = 3'b111;
reg         cia_d = 1'b0;
reg         reset_d = 1'b0;
reg  [3:0]  endq = 4'd0;             // hold-end counter events still to post

// ring: 1024 x 72 (block RAM)
reg  [71:0] mem [0:1023];
reg         we = 1'b0;
reg  [71:0] wd = 72'd0;
reg  [9:0]  wa = 10'd0;
reg  [71:0] rd = 72'd0;
wire [9:0]  ra = {r3, idx[5:0]};
always @(posedge clk) begin
  if (we) mem[wa] <= wd;
  rd <= mem[ra];
end

wire [2:0] ipl_old = ~ipl_d, ipl_new = ~ipl_n;
function [1:0] c2(input integer n); c2 = n; endfunction   // a channel number as 2 bits
wire       cpu_strobe = cpu_rd || cpu_wr;

reg [3:0]    trig_now, trig_ch;
reg [NS-1:0] pv_n;
reg          found;
integer s;
always @(posedge clk) begin
  we <= 1'b0;
  cmd_arm_d <= cmd_arm; cmd_force_d <= cmd_force;
  if (cmd_mode) mode <= r3;

  // ------------------------------------------------ drain: the lowest pending slot into the ring
  pv_n = pv;
  found = 1'b0;
  for (s = 0; s < NS; s = s + 1)
    if (!found && pv[s]) begin
      found = 1'b1;
      pv_n[s] = 1'b0;
      if (armed && !frozen) begin
        we <= 1'b1; wa <= wp; wd <= {pts[s], pk[s], states};
        wp <= wp + 10'd1;
        if (wp == 10'd1023) wrapped <= 1'b1;
        if (fired) begin
          if (post == 10'd1) frozen <= 1'b1;
          if (post != 10'd0) post <= post - 10'd1;
        end
      end
    end

  // ------------------------------------------------ sources (machine clock enable)
  if (clk7_en) begin
    if (cck) ts <= ts + 32'd1;
    // register accesses: a CPU access once (its first clock on the register bus; it may be interrupted
    // by DMA slots), other bus masters every clock
    if (!cpu_strobe || (cpu_custom && (reg_address != acc_reg || data != acc_dat))) acc_done <= 1'b0;
    if (cpu_acc && !(acc_done && reg_address == acc_reg && data == acc_dat)) begin
      acc_done <= 1'b1; acc_reg <= reg_address; acc_dat <= data;
      if (pv_n[0]) lost <= lost + 16'd1;
      pv_n[0] = 1'b1; pts[0] <= ts[29:0];
      pk[0] <= {cpu_rd ? 4'd1 : 4'd0, reg_address, data, cpu_rd ? 2'd1 : 2'd0};
    end else if (dma_acc) begin
      if (pv_n[0]) lost <= lost + 16'd1;
      pv_n[0] = 1'b1; pts[0] <= ts[29:0];
      pk[0] <= {4'd2, reg_address, data, 2'd2};
    end
    // channels: state transitions, DMA words
    for (i = 0; i < 4; i = i + 1) begin
      st_d[i] <= st[i];
      if (st[i] != st_d[i] && !(don[i] && ((st_d[i] == 3'b010 && st[i] == 3'b110) || (st_d[i] == 3'b110 && st[i] == 3'b010)))) begin
        if (pv_n[1 + i]) lost <= lost + 16'd1;
        pv_n[1 + i] = 1'b1; pts[1 + i] <= ts[29:0];
        pk[1 + i] <= {4'd3, c2(i), st_d[i], st[i], don[i], ipen[i], sil[i], sild[i], dreq[i], 1'b0, smp[i], pcnt[i][3:0]};
      end
      if (dbr && dat_ch[i]) begin
        wcnt[i] <= wcnt[i] + 7'd1;
        lastaddr[i] <= dma_address;
        if (wsince[i] != 16'hFFFF) wsince[i] <= wsince[i] + 16'd1;
        if (data == 16'd0 && zsince[i] != 16'hFFFF) zsince[i] <= zsince[i] + 16'd1;
        if (wtrig[i] != 12'hFFF) wtrig[i] <= wtrig[i] + 12'd1;
        if (data == 16'd0 && ztrig[i] != 12'hFFF) ztrig[i] <= ztrig[i] + 12'd1;
        if (st[i] == 3'b001 || st[i] == 3'b011) begin
          if (pv_n[5]) lost <= lost + 16'd1;
          pv_n[5] = 1'b1; pts[5] <= ts[29:0];
          pk[5] <= {4'd4, c2(i), dma_address, 4'd0};
        end else if (wcnt[i] == 7'd0) begin
          if (pv_n[5]) lost <= lost + 16'd1;
          pv_n[5] = 1'b1; pts[5] <= ts[29:0];
          pk[5] <= {4'd5, c2(i), data, dma_address[8:1]};
        end
      end
      // hold detectors of the channel (clk7_en periods)
      if (!don[i] || (dbr && dat_ch[i])) nodat[i] <= 32'd0;
      else if (nodat[i] != 32'hFFFFFFFF) nodat[i] <= nodat[i] + 32'd1;
      smp_d[i] <= smp[i];
      if (smp[i] != smp_d[i]) begin ccon[i] <= 32'd0; cdma[i] <= dv[i]; chg_ts[i] <= ts; end
      else begin
        if (ccon[i] != 32'hFFFFFFFF) ccon[i] <= ccon[i] + 32'd1;
        if (dv[i]) cdma[i] <= 1'b1;
      end
    end
    // IPL
    ipl_d <= ipl_n;
    if (ipl_n != ipl_d && (mode[3] || ipl_old >= 3'd4 || ipl_new >= 3'd4)) begin
      if (pv_n[6]) lost <= lost + 16'd1;
      pv_n[6] = 1'b1; pts[6] <= ts[29:0];
      pk[6] <= {4'd6, ipl_old, ipl_new, 20'd0};
    end
    // CIA-B: the first clock of each access to TA/TB (4-7), ICR (D), CRA/CRB (E/F); a read records the
    // register's value in that clock (the ICR read clears the flags at its end)
    cia_d <= sel_cia_b && cpu_strobe;
    if (sel_cia_b && cpu_strobe && !cia_d &&
        (cia_rs[11:10] == 2'b01 || cia_rs == 4'hD || cia_rs == 4'hE || cia_rs == 4'hF)) begin
      if (pv_n[7]) lost <= lost + 16'd1;
      pv_n[7] = 1'b1; pts[7] <= ts[29:0];
      pk[7] <= {4'd7, cia_rs, cpu_wr, cpu_wr ? cia_wdata : cia_rdata, 13'd0};
    end
    reset_d <= reset;
    if (reset && !reset_d) begin
      pv_n[8] = 1'b1; pts[8] <= ts[29:0]; pk[8] <= {4'd10, 26'd0};
    end
    // the mix (L, R)
    l_d <= ldata; r_d <= rdata;
    if (ldata != l_d || rdata != r_d) begin
      mixcon <= 32'd0; mixdma <= dv[0] | dv[1] | dv[2] | dv[3];
      t_mix <= ts;
      for (i = 0; i < 4; i = i + 1) begin wsince[i] <= 16'd0; zsince[i] <= 16'd0; end
      if (fired && !holdend) begin
        holdend <= 1'b1; t_end <= ts; endq <= 4'b1111;
        pv_n[8] = 1'b1; pts[8] <= ts[29:0]; pk[8] <= {4'd9, 26'd0};
      end
    end else begin
      if (mixcon != 32'hFFFFFFFF) mixcon <= mixcon + 32'd1;
      if (dv[0] | dv[1] | dv[2] | dv[3]) mixdma <= 1'b1;
    end
  end

  // ------------------------------------------------ trigger
  trig_now = 4'd0; trig_ch = 4'd0;
  if (mode[0] && mixcon >= H7 && mixdma) trig_now[0] = 1'b1;
  for (i = 0; i < 4; i = i + 1) begin
    if (mode[1] && nodat[i] >= H7) begin trig_now[1] = 1'b1; trig_ch[i] = 1'b1; end
    if (mode[2] && ccon[i] >= H7 && cdma[i]) begin trig_now[2] = 1'b1; trig_ch[i] = 1'b1; end
  end
  if (cmd_force && !cmd_force_d) trig_now[3] = 1'b1;
  if (armed && !fired && trig_now != 4'd0) begin
    fired <= 1'b1; post <= G_POST; cause <= trig_now; chmask <= trig_ch;
    t_trig <= ts; t_cut <= t_mix; l_trig <= {ldata, rdata}; hold_trig <= mixcon;
    for (i = 0; i < 4; i = i + 1) begin
      snap[i] <= aud_dbg[128 * i +: 128];
      snap_addr[i] <= lastaddr[i]; snap_w[i] <= wsince[i]; snap_z[i] <= zsince[i]; snap_chg[i] <= chg_ts[i];
      wtrig[i] <= 12'd0; ztrig[i] <= 12'd0;
    end
    pv_n[8] = 1'b1; pts[8] <= ts[29:0]; pk[8] <= {4'd8, trig_now, trig_ch, mixcon[18:1]};
  end else if (endq != 4'd0 && !pv_n[8]) begin
    // per-channel counters after the hold end, one per clock through the marker slot
    for (s = 3; s >= 0; s = s - 1)
      if (endq[s]) begin
        pv_n[8] = 1'b1; pts[8] <= ts[29:0]; pk[8] <= {4'd13, c2(s), wtrig[s], ztrig[s]};
      end
    endq <= endq & (endq - 4'd1);
  end
  pv <= pv_n;

  // ------------------------------------------------ arm: clear and restart, an "armed" entry first
  if (cmd_arm && !cmd_arm_d) begin
    armed <= 1'b1; fired <= 1'b0; frozen <= 1'b0; holdend <= 1'b0; wrapped <= 1'b0; wp <= 10'd0;
    cause <= 4'd0; chmask <= 4'd0; lost <= 16'd0; endq <= 4'd0;
    pv <= {1'b1, {(NS-1){1'b0}}}; pts[8] <= ts[29:0]; pk[8] <= {4'd11, mode, 22'd0};
  end
end

// ---------------------------------------------------------------- readout
wire [3:0] k = idx[3:0];
wire [1:0] sch = (k - 4'd4) >> 1;    // $C4/$C5 channel 0 .. $CA/$CB channel 3
always @(posedge clk) begin
  if (idx[7:6] == 2'b10)
    rec_out <= {rd, frozen, fired, wp, ra, 2'b10};
  else if (idx[7:4] == 4'hC) begin
    case (k)
      4'h0: rec_out <= {12'hA19, mode, fired, frozen, wrapped, holdend, 2'b00, wp, ts, lost, cause, chmask, 8'h01};
      4'h1: rec_out <= {t_trig, t_cut, t_end};
      4'h2: rec_out <= {2'b00, l_trig, hold_trig, mixcon};
      4'h3: rec_out <= {states, 4'd0, 16'd0, nodat[0][31:16], nodat[1][31:16], nodat[2][31:16], nodat[3][31:16]};
      4'h4, 4'h6, 4'h8, 4'hA: rec_out <= r3 == 4'd0 ? snap[sch][95:0] :
                                         {12'd0, snap_addr[sch], snap_w[sch], snap_z[sch], snap_chg[sch]};
      4'h5, 4'h7, 4'h9, 4'hB: rec_out <= {snap[sch][127:96], 64'd0};
      default: rec_out <= 96'd0;
    endcase
  end else
    rec_out <= 96'd0;
end

endmodule
