`ifndef GLOBAL_SVH
`include "global.svh"
`endif
/* verilator lint_off UNUSEDSIGNAL */
// =============================================================================
//  pe_v2 : Zero-Gated Booth-Multiplier PE with Global Freeze (en) & Dynamic K (k_len)
// =============================================================================
module pe_v2 (
    input clk,
    input rst_n,
    input en,                       // Global advance / freeze from fifo_controller
    input [KLEN_W-1:0] k_len,       // MACs per output tile (>= 1)

    input signed [W-1:0] inA,
    input signed [W-1:0] inB,

    output signed [W-1:0] outA,
    output signed [W-1:0] outB,

    output signed [OUT_WIDTH-1:0] outS,

    output out_valid,
    output reg pass_valid_a,        // travels with outA
    output reg pass_valid_b,        // travels with outB
    input flush_acc,
    input in_valid_a,
    input in_valid_b
);

    // ================= STAGE 1: input registers =================
    reg signed [W-1:0] inA_reg, inB_reg;
    reg in_valid_r_a, in_valid_r_b;

    always @(posedge clk) begin
        if (!rst_n || flush_acc) begin
            inA_reg      <= {W{1'b0}};
            inB_reg      <= {W{1'b0}};
            in_valid_r_a <= 1'b0;
            in_valid_r_b <= 1'b0;
            pass_valid_a <= 1'b0;
            pass_valid_b <= 1'b0;
        end else if (en) begin
            inA_reg      <= inA;
            inB_reg      <= inB;
            in_valid_r_a <= in_valid_a;
            in_valid_r_b <= in_valid_b;
            pass_valid_a <= in_valid_a;
            pass_valid_b <= in_valid_b;
        end
    end

    assign outA = inA_reg;
    assign outB = inB_reg;

    // Zero detection & operand gating (SAURIA Fig. 2)
    wire zero_s1 = ((inA_reg == 0) || (inB_reg == 0));

    // ================= STAGE 2: MULTIPLY (1 cycle) =================
    wire [2*W-1:0] product_comb;
    wire [W-1:0]   mult_A = zero_s1 ? {W{1'b0}} : inA_reg;
    wire [W-1:0]   mult_B = zero_s1 ? {W{1'b0}} : inB_reg;

    Booth_Multiplier mult (
        .M       (mult_A),        // 8-bit signed
        .Q       (mult_B),        // 8-bit signed
        .product (product_comb)   // 16-bit signed result
    );

    reg zero_s2;
    reg signed [2*W-1:0] product_reg;
    reg in_valid_r2_a, in_valid_r2_b;
    reg signed [W-1:0] outA_r, outB_r;

    always @(posedge clk) begin
        if (!rst_n || flush_acc) begin
            product_reg   <= 0;
            outA_r        <= 0;
            outB_r        <= 0;
            in_valid_r2_a <= 1'b0;
            in_valid_r2_b <= 1'b0;
            zero_s2       <= 1'b0;
        end else if (en) begin
            product_reg   <= zero_s1 ? {(2*W){1'b0}} : $signed(product_comb);
            outA_r        <= inA_reg;
            outB_r        <= inB_reg;
            in_valid_r2_a <= in_valid_r_a;
            in_valid_r2_b <= in_valid_r_b; // FIXED: was in_valid_b!
            zero_s2       <= zero_s1;
        end
    end

    // ================= STAGE 3: MAC + COUNTER =================
    reg signed [ACC_WIDTH-1:0] acc;
    reg [KLEN_W-1:0]           counter;

    wire signed [ACC_WIDTH-1:0] product_ext =
        {{(ACC_WIDTH-2*W){product_reg[2*W-1]}}, product_reg};

    wire signed [ACC_WIDTH-1:0] acc_next_i = acc + product_ext;

    localparam signed [ACC_WIDTH-1:0] OUT_MAX =
        {{(ACC_WIDTH-OUT_WIDTH+1){1'b0}}, {(OUT_WIDTH-1){1'b1}}};
    localparam signed [ACC_WIDTH-1:0] OUT_MIN =
        {{(ACC_WIDTH-OUT_WIDTH+1){1'b1}}, {(OUT_WIDTH-1){1'b0}}};

    wire overflow  = (acc_next_i > OUT_MAX);
    wire underflow = (acc_next_i < OUT_MIN);

    reg signed [ACC_WIDTH-1:0] acc_next;
    always @(*) begin
        if      (zero_s2)   acc_next = acc;
        else if (overflow)  acc_next = OUT_MAX;
        else if (underflow) acc_next = OUT_MIN;
        else                acc_next = acc_next_i;
    end

    wire [KLEN_W-1:0] k_last    = k_len - 1'b1;
    wire              mac_valid = in_valid_r2_a & in_valid_r2_b;
    wire              last_mac  = (counter == k_last) & mac_valid;

    always @(posedge clk) begin
        if (!rst_n || flush_acc) begin
            acc     <= 0;
            counter <= 0;
        end else if (en && mac_valid) begin
            if (zero_s2) begin
                acc     <= last_mac ? {ACC_WIDTH{1'b0}} : acc;
                counter <= last_mac ? {KLEN_W{1'b0}}    : counter + 1'b1;
            end else begin
                acc     <= last_mac ? {ACC_WIDTH{1'b0}} : acc_next;
                counter <= last_mac ? {KLEN_W{1'b0}}    : counter + 1'b1;
            end
        end
    end

    // ================= OUTPUT =================
    assign out_valid = last_mac;
    assign outS      = acc_next[OUT_WIDTH-1:0];

endmodule
/* verilator lint_on UNUSEDSIGNAL */
