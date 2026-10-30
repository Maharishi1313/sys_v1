`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// =============================================================================
// Submodule: TFLite Exact Bitwise Requantizer
// Implements gemmlowp SaturatingRoundingDoublingHighMul & RoundingDivideByPOT
// =============================================================================
module tflite_requantizer (
    input  logic signed [31:0] acc_in,
    input  logic signed [31:0] bias,
    input  logic signed [31:0] M_fixed,
    input  logic signed [31:0] shift_val, // FIXED: Now strictly Signed
    input  logic signed [7:0]  Z_out,
    input  logic               relu_en,
    output logic signed [7:0]  q_out
);
    wire signed [31:0] x = acc_in + bias;
    
    // 1. TFLite Left Shift (If shift_val is negative, shift x up before Mul)
    logic signed [31:0] x_shifted;
    always_comb begin
        if (shift_val < 0) x_shifted = x <<< (-shift_val);
        else               x_shifted = x;
    end

    // // 2. SaturatingRoundingDoublingHighMul
    // logic signed [63:0] ab_64;
    // logic signed [63:0] nudge;
    // logic signed [63:0] ab_x2_high64;
    // logic signed [31:0] ab_x2_high32;

    // always_comb begin
    //     ab_64 = x_shifted * M_fixed;
    //     nudge = (ab_64 >= 0) ? 64'h0000000040000000 : 64'hFFFFFFFFC0000001; 
    //     ab_x2_high64 = ab_64 + nudge;
    //     // Truncate towards zero matching C++ behavior
    //     if (ab_x2_high64 >= 0) ab_x2_high32 = 32'(ab_x2_high64 >>> 31);
    //     else                   ab_x2_high32 = -32'((-ab_x2_high64) >>> 31);
    // end

    // 2. SaturatingRoundingDoublingHighMul
    logic signed [63:0] ab_64;
    logic signed [63:0] nudge;
    logic signed [63:0] ab_x2_high64;
    logic signed [31:0] ab_x2_high32;

    always_comb begin
        // FORCE explicit 64-bit sign extension BEFORE multiplying to prevent simulator overflow
        ab_64 = $signed({{32{x_shifted[31]}}, x_shifted}) * $signed({{32{M_fixed[31]}}, M_fixed});
        
        nudge = (ab_64 >= 0) ? 64'h0000000040000000 : 64'hFFFFFFFFC0000001; 
        ab_x2_high64 = ab_64 + nudge;
        
        if (ab_x2_high64 >= 0) ab_x2_high32 = 32'(ab_x2_high64 >>> 31);
        else                   ab_x2_high32 = -32'((-ab_x2_high64) >>> 31);
    end

    // 3. RoundingDivideByPOT (Right Shift)
    logic [31:0] remainder;
    logic [31:0] threshold;
    logic signed [31:0] shifted_base;
    logic signed [31:0] requanted;

    always_comb begin
        if (shift_val > 0) begin
            remainder = ab_x2_high32 & ((32'd1 << shift_val) - 1);
            threshold = (32'd1 << (shift_val - 1)) + ((ab_x2_high32 < 0) ? 32'd1 : 32'd0);
            shifted_base = ab_x2_high32 >>> shift_val; 
            requanted = shifted_base + ((remainder > threshold) ? 32'd1 : 32'd0);
        end else begin
            requanted = ab_x2_high32;
        end
    end

    // 4. Zero Point Addition & Clamping
    logic signed [31:0] res;
    logic signed [7:0]  clamp_min;

    always_comb begin
        res = requanted + 32'(Z_out);
        clamp_min = relu_en ? Z_out : -8'sd128;

        if (res > 32'sd127)       q_out = 8'sd127;
        else if (res < clamp_min) q_out = clamp_min;
        else                      q_out = res[7:0];
    end
endmodule
