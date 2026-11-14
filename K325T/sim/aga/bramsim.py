#!/usr/bin/env python3
"""bramsim.py FILE.v -- a1200-fastclk fc5: model the stock amiga_fastram's data array as the block RAM Vivado
makes of it (G_DRAM_STYLE "block"): a read whose address is written in the same window -- at one of the
last two memory-clock edges or at the next one (the write enable is up now) -- returns deliberately WRONG
data (inverted), in both read-during-write senses (the write just before or just after the read edge,
asynchronous clocks).  Counts: bram_coll (collisions at a read edge), bram_used (a corrupted word handed to
the CPU: ready_o with a read).  Printed in a final block; every used one is reported at once."""
import re, sys
p = sys.argv[1]
s = open(p).read()
i = s.index("module amiga_fastram"); j = s.index("endmodule", i)
m = s[i:j]
q = re.search(r"m_rdata = (n\d+_q);", m).group(1)
a = re.search(re.escape(q) + r" <= (n\d+_o);", m)
assert a, "m_rdata's register assignment not found"
m = m.replace(a.group(0), "%s <= bram_coll ? ~%s : %s;" % (q, a.group(1), a.group(1)), 1)
m += """
  // ---- bramsim.py: block-RAM read-during-write model (simulation only) ----
  reg [12:0] bw0a = 0, bw1a = 0; reg bw0v = 0, bw1v = 0;
  always @(posedge hr_clk_i) begin
    bw0v <= hr_we_u | hr_we_l; bw0a <= hr_waddr; bw1v <= bw0v; bw1a <= bw0a;
  end
  wire bram_coll = ((hr_we_u | hr_we_l) && hr_waddr == m_rd_a) || (bw0v && bw0a == m_rd_a) || (bw1v && bw1a == m_rd_a);
  reg bram_cq = 0; reg [31:0] bram_ncoll = 0, bram_nused = 0, bram_nread = 0;
  always @(posedge clk_i) begin
    bram_cq <= bram_coll;
    if (bram_coll) bram_ncoll <= bram_ncoll + 1;
    if (m_ready && !we_i) begin
      bram_nread <= bram_nread + 1;
      if (bram_cq) begin bram_nused <= bram_nused + 1; $display("BRAMSIM: corrupted word used at %0t, address %h", $time, m_rd_addr); end
    end
  end
  final $display("BRAMSIM: collisions %0d, read answers %0d, corrupted words used %0d", bram_ncoll, bram_nread, bram_nused);
"""
open(p, "w").write(s[:i] + m + s[j:])
print("bramsim: patched", p, "register", q)
