`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// =============================================================================
//  pe4x4  (fixed / extended)
//   NEW  en      : global advance (freeze) - forwarded to all 16 PEs
//   NEW  k_len   : MACs per output - forwarded to all 16 PEs
//   NEW  colN    : which column (0..3) produced the value on outputbusN.
//          Without it the consumer cannot know which OUTPUT CHANNEL a result
//          belongs to (the 4 PEs of a row share ONE bus, one after the other).
//   FIX  output capture is gated by 'en'.  While frozen the PE state (and so
//          out_valid) stays asserted; capturing it every frozen clock would
//          produce duplicate results.
// =============================================================================
module pe4x4 (
    input clk,
    input rst_n,

    input en,
    input [KLEN_W-1:0] k_len,
    input flush_acc,
    input [FIF_LINES-1:0] in_valid_a,
    input [FIF_LINES-1:0] in_valid_b,

    // inputs from fifo controller
    input [W-1:0] fifo_A0, fifo_A1, fifo_A2, fifo_A3,
    input [W-1:0] fifo_B0, fifo_B1, fifo_B2, fifo_B3,

    // four output buses (one per array row)
    output [OUT_WIDTH-1:0] outputbus1,
    output [OUT_WIDTH-1:0] outputbus2,
    output [OUT_WIDTH-1:0] outputbus3,
    output [OUT_WIDTH-1:0] outputbus4,

    output valid1, output valid2, output valid3, output valid4,
    output [1:0] col1, output [1:0] col2, output [1:0] col3, output [1:0] col4
);

wire [W-1:0] A [0:3][0:4];
wire [W-1:0] B_mat [0:4][0:3];
wire [OUT_WIDTH-1:0] S [0:3][0:3];
wire valid [0:3][0:3];
wire pass_a [0:3][0:4];
wire pass_b [0:4][0:3];

// inputs
assign A[0][0] = fifo_A0;  assign A[1][0] = fifo_A1;
assign A[2][0] = fifo_A2;  assign A[3][0] = fifo_A3;

assign B_mat[0][0] = fifo_B0;  assign B_mat[0][1] = fifo_B1;
assign B_mat[0][2] = fifo_B2;  assign B_mat[0][3] = fifo_B3;

// valid flags enter on the left (A) and on top (B)
assign pass_a[0][0] = in_valid_a[0];  assign pass_a[1][0] = in_valid_a[1];
assign pass_a[2][0] = in_valid_a[2];  assign pass_a[3][0] = in_valid_a[3];

assign pass_b[0][0] = in_valid_b[0];  assign pass_b[0][1] = in_valid_b[1];
assign pass_b[0][2] = in_valid_b[2];  assign pass_b[0][3] = in_valid_b[3];

// PE grid
genvar i, j;
generate
for (i = 0; i < 4; i = i + 1) begin : row
    for (j = 0; j < 4; j = j + 1) begin : colm
        pe_v2 PE (
            .clk(clk), .rst_n(rst_n),
            .en(en), .k_len(k_len),

            .inA(A[i][j]),
            .inB(B_mat[i][j]),
            .outA(A[i][j+1]),
            .outB(B_mat[i+1][j]),

            .outS(S[i][j]),
            .out_valid(valid[i][j]),

            .in_valid_a(pass_a[i][j]),
            .in_valid_b(pass_b[i][j]),
            .pass_valid_a(pass_a[i][j+1]),
            .pass_valid_b(pass_b[i+1][j]),

            .flush_acc(flush_acc)
        );
    end
end
endgenerate

// ================= OUTPUT MUX =================
// For each row: take the first valid PE (lowest column).  Inside one tile the 4
// PEs of a row finish on 4 different clocks, so there is never a clash.
reg [OUT_WIDTH-1:0] obus [0:3];
reg                 ovld [0:3];
reg [1:0]           ocol [0:3];

integer r, c;
always @(posedge clk) begin
    if (!rst_n) begin
        for (r = 0; r < 4; r = r + 1) begin
            obus[r] <= 0; ovld[r] <= 1'b0; ocol[r] <= 2'd0;
        end
    end else begin
        for (r = 0; r < 4; r = r + 1) ovld[r] <= 1'b0;
        if (en) begin
            for (r = 0; r < 4; r = r + 1)
                for (c = 3; c >= 0; c = c - 1)      // lowest column wins (assigned last)
                    if (valid[r][c]) begin
                        obus[r] <= S[r][c];
                        ovld[r] <= 1'b1;
                        ocol[r] <= c[1:0];
                    end
        end
    end
end

assign outputbus1 = obus[0];  assign outputbus2 = obus[1];
assign outputbus3 = obus[2];  assign outputbus4 = obus[3];
assign valid1 = ovld[0];  assign valid2 = ovld[1];
assign valid3 = ovld[2];  assign valid4 = ovld[3];
assign col1 = ocol[0];  assign col2 = ocol[1];
assign col3 = ocol[2];  assign col4 = ocol[3];

endmodule
