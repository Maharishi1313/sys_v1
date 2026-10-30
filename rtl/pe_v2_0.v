`ifndef GLOBAL_SVH
`include "global.svh"
`endif
/* verilator lint_off UNUSEDSIGNAL */
// =============================================================================
//  pe_v2  (fixed)
//   FIX 1  overflow saturation never worked: the if/else chain was
//          "if(overflow).. ; if(underflow).. else acc_next=acc_next_i", so the
//          final 'else' overwrote the overflow result.  Now a proper else-if.
//   FIX 2  the PE stopped after exactly N MACs (N=array size!).  A 3x3 kernel
//          needs 9 and a pointwise layer needs C_in.  New input k_len = number
//          of MACs per output, set per tile.
//   FIX 3  new input 'en' : global advance. When en=0 every register holds, so
//          the whole array can be frozen for one clock without breaking the
//          diagonal alignment of A and B (needed when a feeder runs dry).
//   CLEANUP removed dead stage-2 copies of outA/outB (never used).
// =============================================================================
module pe_v2 (
    input clk,
    input rst_n,
    input en,                       // NEW  global advance / freeze
    input [KLEN_W-1:0] k_len,       // NEW  MACs per output (>= 1)

    input signed [W-1:0] inA,
    input signed [W-1:0] inB,

    output signed [W-1:0] outA,
    output signed [W-1:0] outB,

    output signed [OUT_WIDTH-1:0] outS,

    output out_valid,
    output reg pass_valid_a, // valid of the data being passed on (travels with outA)
    output reg pass_valid_b, // valid of outB
    input flush_acc,
    input in_valid_a,
    input in_valid_b
);

  // ================= STAGE 1 : input registers (also the pass-on data) =======
  reg signed [W-1:0] inA_reg, inB_reg;
  reg in_valid_r_a, in_valid_r_b;

  always @(posedge clk) begin
    if (!rst_n || flush_acc) begin
        inA_reg <= 0;  inB_reg <= 0;
        in_valid_r_a <= 0;  in_valid_r_b <= 0;
        pass_valid_a <= 0;  pass_valid_b <= 0;
    end else if (en) begin
        inA_reg <= inA;  inB_reg <= inB;
        in_valid_r_a <= in_valid_a;  in_valid_r_b <= in_valid_b;
        pass_valid_a <= in_valid_a;  pass_valid_b <= in_valid_b;
    end
  end

  assign outA = inA_reg;
  assign outB = inB_reg;

  // ================= STAGE 2 : multiply ======================================
  reg signed [2*W-1:0] product_reg;
  reg in_valid_r2_a, in_valid_r2_b;

  always @(posedge clk) begin
    if (!rst_n || flush_acc) begin
        product_reg <= 0;
        in_valid_r2_a <= 0;  in_valid_r2_b <= 0;
    end else if (en) begin
        product_reg <= inA_reg * inB_reg;
        in_valid_r2_a <= in_valid_r_a;
        in_valid_r2_b <= in_valid_r_b;
    end
  end

  // ================= STAGE 3 : accumulate ====================================
  reg signed [ACC_WIDTH-1:0] acc;
  reg [KLEN_W-1:0] counter;

  wire signed [ACC_WIDTH-1:0] product_ext =
      {{(ACC_WIDTH-2*W){product_reg[2*W-1]}}, product_reg};

  wire signed [ACC_WIDTH-1:0] acc_next_i = acc + product_ext;

  localparam signed [ACC_WIDTH-1:0] OUT_MAX =
    {{(ACC_WIDTH-OUT_WIDTH+1){1'b0}}, {(OUT_WIDTH-1){1'b1}}};
  localparam signed [ACC_WIDTH-1:0] OUT_MIN =
    {{(ACC_WIDTH-OUT_WIDTH+1){1'b1}}, {(OUT_WIDTH-1){1'b0}}};

  wire overflow  = (acc_next_i > OUT_MAX);
  wire underflow = (acc_next_i < OUT_MIN);

  wire [KLEN_W-1:0] k_last = k_len - 1'b1;
  wire mac_valid = in_valid_r2_a & in_valid_r2_b;
  wire last_mac  = (counter == k_last) & mac_valid;

  reg signed [ACC_WIDTH-1:0] acc_next;
  always @(*) begin
    if (overflow)       acc_next = OUT_MAX;      // FIX 1: real else-if chain
    else if (underflow) acc_next = OUT_MIN;
    else                acc_next = acc_next_i;
  end

  always @(posedge clk) begin
    if (!rst_n || flush_acc) begin
        acc <= 0;
        counter <= 0;
    end else if (en && mac_valid) begin
        acc     <= last_mac ? {ACC_WIDTH{1'b0}} : acc_next;
        counter <= last_mac ? {KLEN_W{1'b0}}    : counter + 1'b1;
    end
  end

  // ================= OUTPUT ==================================================
  assign out_valid = last_mac;                    // result includes the last product
  assign outS      = acc_next[OUT_WIDTH-1:0];
endmodule
/* verilator lint_on UNUSEDSIGNAL */
