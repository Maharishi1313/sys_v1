`ifndef GLOBAL_SVH
`include "global.svh"
`endif
/* verilator lint_off UNUSEDSIGNAL */
`timescale 1ns / 1ps
// Radix-4 Booth encoder for 8-bit signed operands.
// Produces 4 sign-extended 16-bit partial products, pre-shifted.
module Booth_Encoder (
    input  wire signed [W-1:0] M,            // multiplicand (signed)
    input  wire signed [W-1:0] Q,            // multiplier   (signed)
    output wire [2*W-1:0] PP1, PP2, PP3, PP4
);
    // ---- sign-extend M to 16 bits ----
    wire signed [2*W-1:0] M_se     = {{W{M[W-1]}}, M};
wire unused_cout_neg;// just for verilator error
    // ---- precompute the five Booth multiples ----
    wire signed [2*W-1:0] PP_zero = {(2*W){1'b0}};
    wire signed [2*W-1:0] PP_pos_M = M_se;
    wire signed [2*W-1:0] PP_neg_M;
    KSA ksa_neg (.a(~M_se),.b({(2*W){1'b0}}),.cin(1'b1),.sum(PP_neg_M), .cout(unused_cout_neg) );
    wire signed [2*W-1:0] PP_pos_2M = M_se << 1;
    wire signed [2*W-1:0] PP_neg_2M = PP_neg_M << 1;

    // ---- extend multiplier with sign + Q(-1) ----
wire [W+1:0] Q_ext;
assign Q_ext = {Q[W-1], Q, 1'b0};

// ---- radix-4 overlapping windows ----
wire [2:0] W1 = Q_ext[2:0];
wire [2:0] W2 = Q_ext[4:2];
wire [2:0] W3 = Q_ext[6:4];
wire [2:0] W4 = Q_ext[8:6];
    // ---- decode window → partial product (combinational) ----
    // Truth table:
    //  W[2] W[1] W[0] | result
    //   0    0    0   |  0
    //   0    0    1   | +M
    //   0    1    0   | +M
    //   0    1    1   | +2M
    //   1    0    0   | -2M
    //   1    0    1   | -M
    //   1    1    0   | -M
    //   1    1    1   |  0
    `define BOOTH_DECODE(We) \
        (We[2] ? (We[1] ? (We[0] ? PP_zero   : PP_neg_M ) \
                      : (We[0] ? PP_neg_M  : PP_neg_2M)) \
              : (We[1] ? (We[0] ? PP_pos_2M : PP_pos_M ) \
                      : (We[0] ? PP_pos_M  : PP_zero  )))

    wire [2*W-1:0] PP1_flag = `BOOTH_DECODE(W1);
    wire [2*W-1:0] PP2_flag = `BOOTH_DECODE(W2);
    wire [2*W-1:0] PP3_flag = `BOOTH_DECODE(W3);
    wire [2*W-1:0] PP4_flag = `BOOTH_DECODE(W4);

    `undef BOOTH_DECODE

    // ---- apply positional shifts ----
    assign PP1 = PP1_flag;          // × 2^0
    assign PP2 = PP2_flag << 2;     // × 2^2
    assign PP3 = PP3_flag << 4;     // × 2^4
    assign PP4 = PP4_flag << 6;     // × 2^6
endmodule
/* verilator lint_on UNUSEDSIGNAL */
