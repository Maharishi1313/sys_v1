`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// =============================================================================
// Top Module: Requantization and Output SRAM Packer
// =============================================================================
module requant_and_pack (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    
    input  logic [31:0]        total_tiles, 
    input  logic [31:0]        oc_base,     
    input  logic signed [31:0] bias       [0:3],
    input  logic signed [31:0] M_fixed    [0:3],
    input  logic signed [31:0] shift_val  [0:3], // FIXED: Now Signed
    input  logic signed [7:0]  Z_out,
    input  logic               relu_en,
    
    input  logic signed [OUT_WIDTH-1:0] ob1, ob2, ob3, ob4,
    input  logic valid1, valid2, valid3, valid4,
    input  logic [1:0] c1, c2, c3, c4,
    
    output logic [31:0] sram_wdata,
    output logic [31:0] sram_waddr,
    output logic        sram_wen,
    output logic [1:0]  sram_wch        // channel (0..3 of the pass) of sram_wdata
);

    logic signed [7:0] q_out [1:4];
    
    tflite_requantizer req1 (.acc_in({{32-OUT_WIDTH{ob1[OUT_WIDTH-1]}} ,ob1}), .bias(bias[c1]), .M_fixed(M_fixed[c1]), .shift_val(shift_val[c1]), .Z_out(Z_out), .relu_en(relu_en), .q_out(q_out[1]));
    tflite_requantizer req2 (.acc_in({{32-OUT_WIDTH{ob2[OUT_WIDTH-1]}} ,ob2}), .bias(bias[c2]), .M_fixed(M_fixed[c2]), .shift_val(shift_val[c2]), .Z_out(Z_out), .relu_en(relu_en), .q_out(q_out[2]));
    tflite_requantizer req3 (.acc_in({{32-OUT_WIDTH{ob3[OUT_WIDTH-1]}} ,ob3}), .bias(bias[c3]), .M_fixed(M_fixed[c3]), .shift_val(shift_val[c3]), .Z_out(Z_out), .relu_en(relu_en), .q_out(q_out[3]));
    tflite_requantizer req4 (.acc_in({{32-OUT_WIDTH{ob4[OUT_WIDTH-1]}} ,ob4}), .bias(bias[c4]), .M_fixed(M_fixed[c4]), .shift_val(shift_val[c4]), .Z_out(Z_out), .relu_en(relu_en), .q_out(q_out[4]));

    // The systolic array outputs results DIAGONALLY (not simultaneously):
    // row i produces column j at cycle K+i+j.  So when valid4 fires for
    // column c, valid1/2/3 already fired for the SAME column c at cycles
    // K+c, K+1+c, K+2+c -- their cache entries are settled before valid4.
    // Direct write on valid4 is therefore correct; no extra delay needed.
    logic [7:0] cache [0:3][0:2];  // [output-channel][PE row 0..2]

    always_ff @(posedge clk) begin
        if (valid1) cache[c1][0] <= q_out[1];
        if (valid2) cache[c2][1] <= q_out[2];
        if (valid3) cache[c3][2] <= q_out[3];
    end

    logic [31:0] addr_cnt [0:3];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sram_wen   <= 1'b0;
            sram_waddr <= 32'd0;
            sram_wdata <= 32'd0;
            for(int i=0; i<4; i++) addr_cnt[i] <= 0;
        end else if (start) begin
            sram_wen <= 1'b0;
            for(int i=0; i<4; i++) addr_cnt[i] <= (oc_base + i) * total_tiles;
        end else if (valid4) begin
            sram_wdata   <= {q_out[4], cache[c4][2], cache[c4][1], cache[c4][0]};
            sram_wch     <= c4;
            sram_waddr   <= addr_cnt[c4];
            sram_wen     <= 1'b1;
            addr_cnt[c4] <= addr_cnt[c4] + 1;
        end else begin
            sram_wen <= 1'b0;
        end
    end
endmodule
