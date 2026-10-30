`timescale 1ns / 1ps

// =============================================================================
//  frame_buffer : 320 x 240 x 12-bit simple dual-port RAM (one write, one read port)
//  Written in the standard block-RAM inference style (Vivado maps it to RAMB36).
// =============================================================================
module frame_buffer #(
    parameter int DEPTH = 320 * 240,
    parameter int DW    = 12
)(
    input  logic                     clk,
    input  logic                     we,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [DW-1:0]            wdata,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [DW-1:0]            rdata
);
    (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
