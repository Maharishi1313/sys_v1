`ifndef GLOBAL_SVH
`include "global.svh"
`endif
`timescale 1ns / 1ps
/* verilator lint_off UNUSEDSIGNAL */
// Kogge-Stone parallel-prefix adder, 16-bit.
// P/G propagate through log2(16)=4 prefix stages.
module KSA (
    input  wire [2*W-1:0] a, b,
    input  wire cin,
    output wire [2*W-1:0] sum,
    output wire cout
);
    // ---- pre-processing: bit-level generate / propagate ----
    wire [2*W-1:0] g0 = a & b;
    wire [2*W-1:0] p0 = a ^ b;

    // Inject carry-in into bit 0
    wire [2*W-1:0] G0 = {g0[2*W-1:1], g0[0] | (p0[0] & cin)};
    wire [2*W-1:0] P0 = p0;
    // ---- prefix stages (black-cell: G_ij = G_ik | P_ik & G_(k-1)j) ----
    // Stage 1: stride 1
    wire [2*W-1:0] G1, P1;
    assign G1[0]  = G0[0];  
    assign P1[0]  = P0[0];
    genvar k;
    generate
        for (k = 1; k < 2*W; k = k + 1) begin : ps1
            assign G1[k] = G0[k] | (P0[k] & G0[k-1]);
            assign P1[k] = P0[k] & P0[k-1];
        end
    endgenerate

    // Stage 2: stride 2
    wire [2*W-1:0] G2, P2;
    assign G2[1:0] = G1[1:0]; assign P2[1:0] = P1[1:0];
    generate
        for (k = 2; k < 2*W; k = k + 1) begin : ps2
            assign G2[k] = G1[k] | (P1[k] & G1[k-2]);
            assign P2[k] = P1[k] & P1[k-2];
        end
    endgenerate

    // Stage 3: stride 4
    wire [2*W-1:0] G3, P3;
    assign G3[3:0] = G2[3:0]; assign P3[3:0] = P2[3:0];
    generate
        for (k = 4; k < 2*W; k = k + 1) begin : ps3
            assign G3[k] = G2[k] | (P2[k] & G2[k-4]);
            assign P3[k] = P2[k] & P2[k-4];
        end
    endgenerate

    // Stage 4: stride 8
    wire [2*W-1:0] G4, P4;
    assign G4[7:0] = G3[7:0]; assign P4[7:0] = P3[7:0];
    generate
        for (k = 8; k < 2*W; k = k + 1) begin : ps4
            assign G4[k] = G3[k] | (P3[k] & G3[k-8]);
            assign P4[k] = P3[k] & P3[k-8];
        end
    endgenerate

    // ---- post-processing ----
   wire [2*W-1:0] carry ={G4[2*W-2:0],cin};  // carry[i] = carry into bit i
    assign sum  = p0 ^ carry;
    assign cout = G4[2*W-1];
endmodule
/* verilator lint_on UNUSEDSIGNAL */
