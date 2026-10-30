`ifndef GLOBAL_SVH
`include "global.svh"
`endif
`timescale 1ns / 1ps
module CSA (
    input  wire [2*W-1:0] A, B_in, D,
    output wire [2*W-1:0] PS, PC   // Partial Sum, Partial Carry
);
    genvar i;
    generate
        for (i = 0; i < 2*W; i = i + 1) begin : csa_bits
            FA fa (
                .a   (A[i]),
                .b   (B_in[i]),
                .cin (D[i]),
                .sum (PS[i]),
                .cout(PC[i])
            );
        end
    endgenerate
endmodule
