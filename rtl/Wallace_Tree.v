`ifndef GLOBAL_SVH
`include "global.svh"
`endif

/* verilator lint_off UNUSEDSIGNAL */
`timescale 1ns / 1ps
// Wallace tree reduction for 4 × 16-bit partial products → 16-bit product.
//
//  Level 0:  PP1  PP2  PP3  PP4   (4 values)
//  CSA-1:    (PP1+PP2+PP3) → S1, C1   (3 → 2, plus PP4)
//  CSA-2:    (S1 + C1<<1 + PP4) → S2, C2   (3 → 2)
//  KSA:      S2 + C2<<1 → product
module Wallace_Tree (
    input  wire [2*W-1:0] PP1, PP2, PP3, PP4,
    output wire [2*W-1:0] product
);
    wire [2*W-1:0] S1, C1;
    CSA csa1 (.A(PP1), .B_in(PP2), .D(PP3), .PS(S1), .PC(C1));
wire unused_cout_final;// for verilator error
    wire [2*W-1:0] S2, C2;
    CSA csa2 (.A(S1), .B_in({C1[2*W-2:0], 1'b0}), .D(PP4), .PS(S2), .PC(C2));  // C1[15] is the carry out of bit 15 from CSA1.
// For INT8 inputs, PP1+PP2+PP3 always fits in 16-bit signed range,
// so C1[15] is always 0 — dropping it is safe.
// {C1[2*W-2:0], 1'b0} = C1<<1 (mod 2^16), which is correct.

    KSA ksa  (.a(S2), .b({C2[2*W-2:0], 1'b0}), .cin(1'b0),.sum(product), .cout(unused_cout_final));
endmodule
/* verilator lint_on UNUSEDSIGNAL */
