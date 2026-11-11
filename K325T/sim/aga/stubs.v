// stub for the IDE buffer RAM (IDE is disabled in the traced configuration)
module dpram #(parameter AW=12, DW=16) (input clock, input [AW-1:0] address_a, input [DW-1:0] data_a,
  input wren_a, output reg [DW-1:0] q_a, input [AW-1:0] address_b, input [DW-1:0] data_b,
  input wren_b, output reg [DW-1:0] q_b);
  always @(posedge clock) begin q_a <= 0; q_b <= 0; end
endmodule
