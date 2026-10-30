`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`timescale 1ns / 1ps
// Fully COMBINATIONAL 8×8 signed Booth multiplier.
// No registers inside — let the caller's pipeline stage register the result.
module Booth_Multiplier (
    input  wire signed [W-1:0]  M,   // multiplicand
    input  wire signed [W-1:0]  Q,   // multiplier
    output wire signed [2*W-1:0] product
);
    wire [2*W-1:0] PP1, PP2, PP3, PP4;
    Booth_Encoder enc (
        .M(M), .Q(Q),
        .PP1(PP1), .PP2(PP2), .PP3(PP3), .PP4(PP4)
    );

    Wallace_Tree wt (
        .PP1(PP1), .PP2(PP2), .PP3(PP3), .PP4(PP4),
        .product(product)
    );
endmodule
