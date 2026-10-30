// =============================================================================
// drc_frm_downscaler_mod.sv
//
// 2×2 average-pooling or max-pooling pixel downscaler.
//
// Architecture
// ------------
// Input pixels arrive in raster scan order (left-to-right, top-to-bottom).
// Every 2×2 block of input pixels is reduced to one output pixel.
//
// The four FIFOs capture each of the four positions in the 2×2 block:
//   pf[0] – even column, even row   (top-left)
//   pf[1] – odd  column, even row   (top-right)
//   pf[2] – even column, odd  row   (bottom-left)
//   pf[3] – odd  column, odd  row   (bottom-right)
//
// col_ctn_q counts 0..COL_NUM-1 across every input row; col_ctn_q[0] selects
// left (even) vs right (odd) column within each 2-wide block.
// row_odd_q toggles on every col_last pulse (= end of a full input row),
// selecting top (even) vs bottom (odd) input row within each 2-tall block.
//
// pf[0] and pf[1] need depth = COL_NUM/2 because they buffer an entire even
// row before the matching odd row pixels start arriving.
// pf[2] and pf[3] only need depth = 2 (the block closes as soon as pf[3]
// receives one pixel, which triggers a read of all four FIFOs together).
//
// An output handshake fires when all four FIFOs simultaneously report non-empty
// (fwd_pxl_vld_o = AND of all pf_rd_rdy_map[*]).
//
// Fixes vs. original
// ------------------
//  1. Removed unused localparam ROW_CTN_W (row count is not needed; a single
//     row_odd_q bit is sufficient for 2×2 blocking).
//  2. Removed unused wire array pf_rd_vld_map[0:3] — it was declared but
//     never driven or connected, causing lint warnings and simulator X-values.
// =============================================================================
module drc_frm_downscaler_mod #(
    parameter DOWNSCALE_TYPE = "AVR-POOLING",   // "AVR-POOLING" | "MAX-POOLING"
    parameter I_PXL_W        = 16,
    parameter COL_NUM        = 640,
    parameter ROW_NUM        = 480               // kept for documentation / future use
)(
    input                   clk,
    input                   rst_n,
    // Backward pixel stream (input)
    input   [I_PXL_W-1:0]   bwd_pxl_data_i,
    input                   bwd_pxl_last_i,     // last pixel flag of the frame
    input                   bwd_pxl_vld_i,
    output                  bwd_pxl_rdy_o,
    // Forward pixel stream (output, half resolution)
    output  [I_PXL_W-1:0]   fwd_pxl_data_o,
    output                  fwd_pxl_last_o,
    output                  fwd_pxl_vld_o,
    input                   fwd_pxl_rdy_i
);
    // -------------------------------------------------------------------------
    // Local parameters
    // -------------------------------------------------------------------------
    localparam COL_CTN_W = $clog2(COL_NUM);
    // Note: ROW_CTN_W removed — row parity is fully captured by row_odd_q (1 bit).

    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    wire                    bwd_pxl_hsk;
    wire                    col_last;
    wire [COL_CTN_W-1:0]    col_ctn_d;
    wire                    row_odd_d;
    wire [I_PXL_W-1:0]      pf_data_o_map [0:3];
    wire                    pf_wr_rdy_map [0:3];
    wire                    pf_wr_vld_map [0:3];
    wire                    pf_rd_rdy_map [0:3];
    // pf_rd_vld_map removed — was declared but never driven or used.
    wire [I_PXL_W+1:0]      sum_block_pxl;      // I_PXL_W+2 bits: safe for sum of 4
    wire                    fwd_pxl_hsk;

    reg  [COL_CTN_W-1:0]    col_ctn_q;
    reg                     row_odd_q;

    // -------------------------------------------------------------------------
    // Pixel FIFOs
    // -------------------------------------------------------------------------

    // pf[0] – top-left pixel (even col, even row)
    // Depth = next power of two ≥ COL_NUM/2, to buffer a full even row.
    sync_fifo #(
        .FIFO_TYPE      (1),
        .DATA_WIDTH     (I_PXL_W),
        .FIFO_DEPTH     (1 << $clog2(COL_NUM / 2))
    ) first_pixel_fifo (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_i         (bwd_pxl_data_i),
        .data_o         (pf_data_o_map[0]),
        .wr_valid_i     (pf_wr_vld_map[0]),
        .rd_valid_i     (fwd_pxl_hsk),
        .empty_o        (),
        .full_o         (),
        .wr_ready_o     (pf_wr_rdy_map[0]),
        .rd_ready_o     (pf_rd_rdy_map[0]),
        .almost_empty_o (),
        .almost_full_o  (),
        .counter        ()
    );

    // pf[1] – top-right pixel (odd col, even row)
    // Same depth as pf[0].
    sync_fifo #(
        .FIFO_TYPE      (1),
        .DATA_WIDTH     (I_PXL_W),
        .FIFO_DEPTH     (1 << $clog2(COL_NUM / 2))
    ) second_pixel_fifo (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_i         (bwd_pxl_data_i),
        .data_o         (pf_data_o_map[1]),
        .wr_valid_i     (pf_wr_vld_map[1]),
        .rd_valid_i     (fwd_pxl_hsk),
        .empty_o        (),
        .full_o         (),
        .wr_ready_o     (pf_wr_rdy_map[1]),
        .rd_ready_o     (pf_rd_rdy_map[1]),
        .almost_empty_o (),
        .almost_full_o  (),
        .counter        ()
    );

    // pf[2] – bottom-left pixel (even col, odd row)
    // Depth = 2: a 2×2 block closes as soon as pf[3] gets its first pixel,
    // so pf[2] never holds more than 1 entry at steady state.
    sync_fifo #(
        .FIFO_TYPE      (1),
        .DATA_WIDTH     (I_PXL_W),
        .FIFO_DEPTH     (2)
    ) third_pixel_fifo (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_i         (bwd_pxl_data_i),
        .data_o         (pf_data_o_map[2]),
        .wr_valid_i     (pf_wr_vld_map[2]),
        .rd_valid_i     (fwd_pxl_hsk),
        .empty_o        (),
        .full_o         (),
        .wr_ready_o     (pf_wr_rdy_map[2]),
        .rd_ready_o     (pf_rd_rdy_map[2]),
        .almost_empty_o (),
        .almost_full_o  (),
        .counter        ()
    );

    // pf[3] – bottom-right pixel (odd col, odd row) + frame-last flag
    // DATA_WIDTH = I_PXL_W + 1 to carry bwd_pxl_last_i alongside the pixel.
    sync_fifo #(
        .FIFO_TYPE      (1),
        .DATA_WIDTH     (I_PXL_W + 1),
        .FIFO_DEPTH     (2)
    ) fourth_pixel_fifo (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_i         ({bwd_pxl_last_i, bwd_pxl_data_i}),
        .data_o         ({fwd_pxl_last_o, pf_data_o_map[3]}),
        .wr_valid_i     (pf_wr_vld_map[3]),
        .rd_valid_i     (fwd_pxl_hsk),
        .empty_o        (),
        .full_o         (),
        .wr_ready_o     (pf_wr_rdy_map[3]),
        .rd_ready_o     (pf_rd_rdy_map[3]),
        .almost_empty_o (),
        .almost_full_o  (),
        .counter        ()
    );

    // -------------------------------------------------------------------------
    // Combinational logic
    // -------------------------------------------------------------------------

    // Handshakes
    assign bwd_pxl_hsk   = bwd_pxl_vld_i & bwd_pxl_rdy_o;
    assign fwd_pxl_hsk   = fwd_pxl_vld_o & fwd_pxl_rdy_i;

    // Input ready: select the FIFO that should receive this pixel
    assign bwd_pxl_rdy_o = pf_wr_rdy_map[{row_odd_q, col_ctn_q[0]}];

    // Output valid: all four FIFOs non-empty means a full 2×2 block is ready
    assign fwd_pxl_vld_o = pf_rd_rdy_map[0] & pf_rd_rdy_map[1] &
                           pf_rd_rdy_map[2] & pf_rd_rdy_map[3];

    // Column counter next-value and wrap
    assign col_last      = ~|(col_ctn_q ^ (COL_NUM - 1));
    assign col_ctn_d     = col_last ? {COL_CTN_W{1'b0}} : col_ctn_q + 1'b1;

    // Row parity next-value: toggles once per complete input row
    assign row_odd_d     = row_odd_q ^ col_last;

    // Per-FIFO write enables: steer each incoming pixel to the correct FIFO
    assign pf_wr_vld_map[0] = bwd_pxl_vld_i & (~col_ctn_q[0]) & (~row_odd_q); // top-left
    assign pf_wr_vld_map[1] = bwd_pxl_vld_i & ( col_ctn_q[0]) & (~row_odd_q); // top-right
    assign pf_wr_vld_map[2] = bwd_pxl_vld_i & (~col_ctn_q[0]) &   row_odd_q;  // bot-left
    assign pf_wr_vld_map[3] = bwd_pxl_vld_i & ( col_ctn_q[0]) &   row_odd_q;  // bot-right

    // Output pixel computation
    generate
        if (DOWNSCALE_TYPE == "AVR-POOLING") begin : AVR_POOL
            assign sum_block_pxl  = pf_data_o_map[0] + pf_data_o_map[1] +
                                    pf_data_o_map[2] + pf_data_o_map[3];
            assign fwd_pxl_data_o = sum_block_pxl >> 2;
        end
        else if (DOWNSCALE_TYPE == "MAX-POOLING") begin : MAX_POOL
            wire [I_PXL_W-1:0] pxl_max_01;
            wire [I_PXL_W-1:0] pxl_max_23;
            assign pxl_max_01     = (pf_data_o_map[0] > pf_data_o_map[1]) ?
                                     pf_data_o_map[0] : pf_data_o_map[1];
            assign pxl_max_23     = (pf_data_o_map[2] > pf_data_o_map[3]) ?
                                     pf_data_o_map[2] : pf_data_o_map[3];
            assign fwd_pxl_data_o = (pxl_max_01 > pxl_max_23) ?
                                     pxl_max_01 : pxl_max_23;
            // sum_block_pxl unused in max-pooling mode
            assign sum_block_pxl  = {(I_PXL_W+2){1'b0}};
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Sequential logic
    // -------------------------------------------------------------------------

    // Column counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            col_ctn_q <= {COL_CTN_W{1'b0}};
        else if (bwd_pxl_hsk)  col_ctn_q <= col_ctn_d;
    end

    // Row parity flag
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            row_odd_q <= 1'b0;
        else if (bwd_pxl_hsk)  row_odd_q <= row_odd_d;
    end

endmodule
