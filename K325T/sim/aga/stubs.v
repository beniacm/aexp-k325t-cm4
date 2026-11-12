// dpram as K325T's bram.vhd implements it for ide.v (a1200-ide: the IDE buffer is used now; it was a
// stub while IDE was off): true dual port, one clock, 1-cycle read latency, write-first per port
module dpram #(parameter AW=12, DW=16) (input clock, input [AW-1:0] address_a, input [DW-1:0] data_a,
  input wren_a, output reg [DW-1:0] q_a, input [AW-1:0] address_b, input [DW-1:0] data_b,
  input wren_b, output reg [DW-1:0] q_b,
  input enable_a, input cs_a, input enable_b, input cs_b);   // bram.vhd ports (unused here)
  reg [DW-1:0] ram [0:(1<<AW)-1];
  integer i;
  initial for (i = 0; i < (1<<AW); i = i + 1) ram[i] = 0;
  always @(posedge clock) begin
    if (wren_a) begin ram[address_a] <= data_a; q_a <= data_a; end else q_a <= ram[address_a];
    if (wren_b) begin ram[address_b] <= data_b; q_b <= data_b; end else q_b <= ram[address_b];
  end
endmodule
