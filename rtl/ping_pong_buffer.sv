`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module ping_pong_buffer #(
    parameter WIDTH = 32,
    parameter SIZE  = 20480 // 80 KB per bank
)(
    input  logic clk,
    input  logic rst_n,
    input  logic bank_sel,  // 0: A=In/B=Out, 1: A=Out/B=In

    // Read Port (To MME / ifmap_feeder)
    input  logic [$clog2(SIZE)-1:0] raddr,
    input  logic                    ren,
    output logic [WIDTH-1:0]        rdata,
    output logic                    rvalid,

    // Write Port (From Requant & Pack)
    input  logic [$clog2(SIZE)-1:0] waddr,
    input  logic                    wen,
    input  logic [WIDTH-1:0]        wdata
);

    logic [WIDTH-1:0] bank_a [0:SIZE-1];
    logic [WIDTH-1:0] bank_b [0:SIZE-1];
    
    logic valid_a, valid_b;

    // Bank A memory operations
    always_ff @(posedge clk) begin
        valid_a <= 1'b0;
        if (bank_sel == 1'b0) begin
            if (ren) begin
                rdata   <= bank_a[raddr];
                valid_a <= 1'b1;
            end
        end else begin
            if (wen) bank_a[waddr] <= wdata;
        end
    end

    // Bank B memory operations
    always_ff @(posedge clk) begin
        valid_b <= 1'b0;
        if (bank_sel == 1'b1) begin
            if (ren) begin
                rdata   <= bank_b[raddr];
                valid_b <= 1'b1;
            end
        end else begin
            if (wen) bank_b[waddr] <= wdata;
        end
    end

    assign rvalid = (bank_sel == 1'b0) ? valid_a : valid_b;

endmodule
