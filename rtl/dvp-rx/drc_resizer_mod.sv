// =============================================================================
// drc_resizer_mod.sv
//
// Pixel pipeline: optional grayscale → optional 2x2 downscale.
//
// Both operations are now runtime-controlled via single-bit inputs:
//   pxl_grayscale  – 1 → convert RGB565 to 8-bit grayscale; 0 → pass-through
//   frm_downscale  – 1 → 2×2 average/max-pool downscale; 0 → pass-through
//
// Output is always 16 bits wide.  When grayscale is enabled the upper byte
// is zero (0x00GG).  When grayscale is disabled the output carries the full
// RGB565 word.  This fixed 16-bit interface lets drc_frm_downscaler_mod stay
// parameterised at I_PXL_W=16 regardless of the runtime mode.
//
// Bypass paths are pure combinational (zero latency, zero area overhead when
// both features are disabled at runtime).
// =============================================================================
// =============================================================================
// drc_resizer_mod.sv
//
// Pixel pipeline: optional grayscale → optional 2×2 downscale.
// Both operations are runtime-controlled via single-bit inputs.
//
// Power gating strategy
// ---------------------
// Both submodules are always instantiated (no generate-if removal) so the
// synthesis tool retains the same netlist regardless of typical runtime modes.
// Power is saved at the DATA level, not by clock-gating:
//
//  Grayscaler (combinational):
//    When pxl_grayscale=0 the data inputs to the grayscaler are driven to
//    constant 0 and vld is masked to 0.  The adder/shift tree sees no
//    toggling inputs → zero dynamic power from the arithmetic logic.
//
//  Downscaler (FIFOs + registers):
//    When frm_downscale=0 the data inputs to the downscaler are driven to
//    constant 0, vld is masked to 0, and rdy feedback is also masked to 0.
//    - col_ctn_q / row_odd_q: clocked only on bwd_pxl_hsk which is 0 → static.
//    - FIFO write enables: all 0 → write pointers static, memory write disabled.
//    - FIFO data_i buses: tied to 0 → no toggle into the memory input mux.
//    - FIFO read enables: 0 → read pointers static.
//    - Sum/max tree: FIFO outputs stay at 0 (FIFOs empty) → static.
// =============================================================================
// module drc_resizer_mod #(
//     parameter FRM_COL_NUM    = 640,
//     parameter FRM_ROW_NUM    = 480,
//     parameter DOWNSCALE_TYPE = "AVR-POOLING",
//     parameter RGB_PXL_W      = 16,
//     parameter GS_PXL_W       = 8
// ) (
//     input  logic                  clk,
//     input  logic                  rst_n,

//     // Backward pixel stream (RGB565 from ctrl_state)
//     input  logic [RGB_PXL_W-1:0]  i_pxl_dat,
//     input  logic                  i_pxl_last,
//     input  logic                  i_pxl_vld,
//     output logic                  i_pxl_rdy,

//     // Forward pixel stream (to mem_aligner)
//     // Always 16 bits; upper byte = 0x00 when grayscale is active.
//     output logic [15:0]            o_pxl_dat,
//     output logic                  o_pxl_last,
//     output logic                  o_pxl_vld,
//     input  logic                  o_pxl_rdy,

//     // Runtime control (from DRC_PROC_CTRL config register)
//     input  logic                  pxl_grayscale,
//     input  logic                  frm_downscale
// );

//     // =========================================================================
//     // Stage 1 – Grayscale (power-gated when disabled)
//     // =========================================================================
//     // When pxl_grayscale=0:
//     //   gs_dat_in  = 0   → adder tree inputs static → zero dynamic power
//     //   gs_vld_in  = 0   → grayscaler sees no valid data
//     //   gs_rdy_in  = 0   → no backpressure from grayscaler
//     // =========================================================================

//     logic [RGB_PXL_W-1:0] gs_dat_in;
//     logic                  gs_vld_in;
//     logic                  gs_last_in;

//     always_comb begin
//         gs_dat_in  = pxl_grayscale ? i_pxl_dat  : {RGB_PXL_W{1'b0}};
//         gs_vld_in  = pxl_grayscale & i_pxl_vld;
//         gs_last_in = pxl_grayscale & i_pxl_last;
//     end

//     logic [GS_PXL_W-1:0] gs_pxl_dat;
//     logic                  gs_pxl_last;
//     logic                  gs_pxl_vld;
//     logic                  gs_pxl_rdy;

//     drc_pxl_grayscaler pg (
//         .rgb_pxl_i      (gs_dat_in),
//         .rgb_pxl_last_i (gs_last_in),
//         .rgb_pxl_vld_i  (gs_vld_in),
//         .rgb_pxl_rdy_o  (/* unused – rdy is purely combinational pass-through */),
//         .gs_pxl_o       (gs_pxl_dat),
//         .gs_pxl_last_o  (gs_pxl_last),
//         .gs_pxl_vld_o   (gs_pxl_vld),
//         .gs_pxl_rdy_i   (gs_pxl_rdy)
//     );

//     // -------------------------------------------------------------------------
//     // Stage 1 output mux → mid stream
//     // -------------------------------------------------------------------------
//     logic [15:0] mid_pxl_dat;
//     logic        mid_pxl_last;
//     logic        mid_pxl_vld;
//     logic        mid_pxl_rdy;

//     always_comb begin
//         if (pxl_grayscale) begin
//             mid_pxl_dat  = {8'h00, gs_pxl_dat};
//             mid_pxl_last = gs_pxl_last;
//             mid_pxl_vld  = gs_pxl_vld;
//             gs_pxl_rdy   = mid_pxl_rdy;
//             i_pxl_rdy    = 1'b0;
//         end else begin
//             mid_pxl_dat  = i_pxl_dat;
//             mid_pxl_last = i_pxl_last;
//             mid_pxl_vld  = i_pxl_vld;
//             gs_pxl_rdy   = 1'b0;
//             i_pxl_rdy    = mid_pxl_rdy;
//         end
//     end

//     // =========================================================================
//     // Stage 2 – Downscaler (power-gated when disabled)
//     // =========================================================================
//     // When frm_downscale=0:
//     //   ds_dat_in  = 0   → all FIFO data_i buses static → no toggle into
//     //                       the memory input mux of any FIFO
//     //   ds_vld_in  = 0   → bwd_pxl_hsk=0 → col_ctn_q / row_odd_q frozen
//     //                       all pf_wr_vld_map[*]=0 → no FIFO writes
//     //                       fwd_pxl_vld_o=0 (FIFOs empty) → fwd_pxl_hsk=0
//     //                       → no FIFO reads
//     //   ds_rdy_in  = 0   → fwd_pxl_hsk=0 even if somehow vld glitched
//     // =========================================================================

//     logic [15:0] ds_dat_in;
//     logic        ds_vld_in;
//     logic        ds_last_in;
//     logic        ds_rdy_in;

//     always_comb begin
//         ds_dat_in  = frm_downscale ? mid_pxl_dat  : 16'h0000;
//         ds_last_in = frm_downscale & mid_pxl_last;
//         ds_vld_in  = frm_downscale & mid_pxl_vld;
//         ds_rdy_in  = frm_downscale & o_pxl_rdy;
//     end

//     logic [15:0] ds_pxl_dat;
//     logic        ds_pxl_last;
//     logic        ds_pxl_vld;
//     logic        ds_pxl_rdy;

//     drc_frm_downscaler_mod #(
//         .DOWNSCALE_TYPE (DOWNSCALE_TYPE),
//         .I_PXL_W        (16),
//         .COL_NUM        (FRM_COL_NUM),
//         .ROW_NUM        (FRM_ROW_NUM)
//     ) fd (
//         .clk            (clk),
//         .rst_n          (rst_n),
//         .bwd_pxl_data_i (ds_dat_in),    // 0 when bypassed
//         .bwd_pxl_last_i (ds_last_in),   // 0 when bypassed
//         .bwd_pxl_vld_i  (ds_vld_in),    // 0 when bypassed
//         .bwd_pxl_rdy_o  (ds_pxl_rdy),
//         .fwd_pxl_data_o (ds_pxl_dat),
//         .fwd_pxl_last_o (ds_pxl_last),
//         .fwd_pxl_vld_o  (ds_pxl_vld),
//         .fwd_pxl_rdy_i  (ds_rdy_in)     // 0 when bypassed
//     );

//     // -------------------------------------------------------------------------
//     // Stage 2 output mux + mid_pxl_rdy feedback
//     // -------------------------------------------------------------------------
//     always_comb begin
//         if (frm_downscale) begin
//             o_pxl_dat   = ds_pxl_dat;
//             o_pxl_last  = ds_pxl_last;
//             o_pxl_vld   = ds_pxl_vld;
//             mid_pxl_rdy = ds_pxl_rdy;
//         end else begin
//             o_pxl_dat   = mid_pxl_dat;
//             o_pxl_last  = mid_pxl_last;
//             o_pxl_vld   = mid_pxl_vld;
//             mid_pxl_rdy = o_pxl_rdy;
//         end
//     end

// endmodule

// =============================================================================
// drc_resizer_mod.sv
// Fixed: Proper AXI-Stream Ready (Backpressure) chaining
// =============================================================================
module drc_resizer_mod #(
    parameter FRM_COL_NUM    = 640,
    parameter FRM_ROW_NUM    = 480,
    parameter DOWNSCALE_TYPE = "AVR-POOLING",
    parameter RGB_PXL_W      = 16,
    parameter GS_PXL_W       = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [RGB_PXL_W-1:0]  i_pxl_dat,
    input  logic                  i_pxl_last,
    input  logic                  i_pxl_vld,
    output logic                  i_pxl_rdy,

    output logic [15:0]           o_pxl_dat,
    output logic                  o_pxl_last,
    output logic                  o_pxl_vld,
    input  logic                  o_pxl_rdy,

    input  logic                  pxl_grayscale,
    input  logic                  frm_downscale
);

    // =========================================================================
    // Stage 1 – Grayscale 
    // =========================================================================
    logic [RGB_PXL_W-1:0] gs_dat_in;
    logic                 gs_vld_in;
    logic                 gs_last_in;
    logic                 pg_rdy_o;

    always_comb begin
        gs_dat_in  = pxl_grayscale ? i_pxl_dat  : {RGB_PXL_W{1'b0}};
        gs_vld_in  = pxl_grayscale & i_pxl_vld;
        gs_last_in = pxl_grayscale & i_pxl_last;
    end

    logic [GS_PXL_W-1:0] gs_pxl_dat;
    logic                gs_pxl_last;
    logic                gs_pxl_vld;
    logic                gs_pxl_rdy;

    drc_pxl_grayscaler pg (
        .rgb_pxl_i      (gs_dat_in),
        .rgb_pxl_last_i (gs_last_in),
        .rgb_pxl_vld_i  (gs_vld_in),
        .rgb_pxl_rdy_o  (pg_rdy_o),      // Capture grayscaler's ready output
        .gs_pxl_o       (gs_pxl_dat),
        .gs_pxl_last_o  (gs_pxl_last),
        .gs_pxl_vld_o   (gs_pxl_vld),
        .gs_pxl_rdy_i   (gs_pxl_rdy)
    );

    // Stage 1 output mux
    logic [15:0] mid_pxl_dat;
    logic        mid_pxl_last;
    logic        mid_pxl_vld;
    logic        mid_pxl_rdy;

    always_comb begin
        if (pxl_grayscale) begin
            mid_pxl_dat  = {8'h00, gs_pxl_dat};
            mid_pxl_last = gs_pxl_last;
            mid_pxl_vld  = gs_pxl_vld;
            gs_pxl_rdy   = mid_pxl_rdy;
            i_pxl_rdy    = pg_rdy_o;      // FIX: Feed ready backwards
        end else begin
            mid_pxl_dat  = i_pxl_dat;
            mid_pxl_last = i_pxl_last;
            mid_pxl_vld  = i_pxl_vld;
            gs_pxl_rdy   = 1'b0;
            i_pxl_rdy    = mid_pxl_rdy;   // FIX: Bypass ready backwards
        end
    end

    // =========================================================================
    // Stage 2 – Downscaler 
    // =========================================================================
    logic [15:0] ds_dat_in;
    logic        ds_vld_in;
    logic        ds_last_in;
    logic        ds_rdy_in;
    logic        ds_rdy_out; 

    always_comb begin
        ds_dat_in  = frm_downscale ? mid_pxl_dat  : 16'h0000;
        ds_last_in = frm_downscale & mid_pxl_last;
        ds_vld_in  = frm_downscale & mid_pxl_vld;
        ds_rdy_in  = frm_downscale & o_pxl_rdy;
    end

    logic [15:0] ds_pxl_dat;
    logic        ds_pxl_last;
    logic        ds_pxl_vld;

    drc_frm_downscaler_mod #(
        .DOWNSCALE_TYPE (DOWNSCALE_TYPE),
        .I_PXL_W        (16),
        .COL_NUM        (FRM_COL_NUM),
        .ROW_NUM        (FRM_ROW_NUM)
    ) fd (
        .clk            (clk),
        .rst_n          (rst_n),
        .bwd_pxl_data_i (ds_dat_in),    
        .bwd_pxl_last_i (ds_last_in),   
        .bwd_pxl_vld_i  (ds_vld_in),    
        .bwd_pxl_rdy_o  (ds_rdy_out),   // Capture downscaler's ready output
        .fwd_pxl_data_o (ds_pxl_dat),
        .fwd_pxl_last_o (ds_pxl_last),
        .fwd_pxl_vld_o  (ds_pxl_vld),
        .fwd_pxl_rdy_i  (ds_rdy_in)     
    );

    // Stage 2 output mux
    always_comb begin
        if (frm_downscale) begin
            o_pxl_dat   = ds_pxl_dat;
            o_pxl_last  = ds_pxl_last;
            o_pxl_vld   = ds_pxl_vld;
            mid_pxl_rdy = ds_rdy_out; // FIX: Feed ready backwards
        end else begin
            o_pxl_dat   = mid_pxl_dat;
            o_pxl_last  = mid_pxl_last;
            o_pxl_vld   = mid_pxl_vld;
            mid_pxl_rdy = o_pxl_rdy;  // FIX: Bypass ready backwards
        end
    end

endmodule
