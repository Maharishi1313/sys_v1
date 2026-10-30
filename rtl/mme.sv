`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// =============================================================================
//  mme : matrix-multiply engine = ifmap_feeder + fifo_controller + pe4x4
//
//   ifmap buffer ("ibuf_a") --> ifmap_feeder --> A FIFOs --\
//                                                           >-- stagger --> pe4x4 --> 4 result buses
//   weight buffer ("ibuf_b") ----------------> B FIFOs ----/
//
//  One 'start' pulse runs ONE TILE = a 4 (pixels) x 4 (columns) block of
//  results, each being a dot product of K values.  tile_done pulses when all 16
//  results have come out.
//
//  What a tile means (this is what a "uop" configures):
//     row i    (lane i)   <- window of pixel (x0 + i*stride)   [ifmap side]
//     column j            <- weight stream j                    [weight side]
//     PE(i,j) = sum over the K steps of  A_i[t] * B_j[t]
// =============================================================================



module mme (
    input logic clk,
    input logic rst_n,

    // ---------------- command: tile or full 2D layer ----------------
    input  logic start,
    input  logic [KLEN_W-1:0] k_len,                 // K (= nch * kernel_h * kernel_w)
    // ifmap-side 3 intra-context configs
    // input  logic [15:0] cfg_base,
    // input  logic [15:0] cfg_chstep,
    // input  logic [15:0] cfg_ystep,
    // input  logic [15:0] cfg_nch,
    // input  logic [15:0] cfg_nky,
    // input  logic [15:0] cfg_last,
    // input  logic [7:0]  cfg_stride,
    // input  logic [15:0] cfg_kpat,
    // // NEW: ifmap-side 2 inter-context (5-counter) configs (default to 1 tile for backward compatibility)
    // input  logic [15:0] cfg_x_tile_step = 16'd0,
    // input  logic [15:0] cfg_y_tile_step = 16'd0,
    // input  logic [15:0] cfg_ntx         = 16'd1,
    // input  logic [15:0] cfg_nty         = 16'd1,

    // UPGRADED TO 24-BIT POINTERS
    input  logic [23:0] cfg_base,
    input  logic [23:0] cfg_chstep,
    input  logic [23:0] cfg_ystep,
    input  logic [23:0] cfg_nch,
    input  logic [23:0] cfg_nky,
    input  logic [23:0] cfg_last,
    input  logic [7:0]  cfg_stride,
    input  logic [15:0] cfg_kpat,
    input  logic [23:0] cfg_x_tile_step,
    input  logic [23:0] cfg_y_tile_step,
    input  logic [23:0] cfg_ntx     = 24'd1,
    input  logic [23:0] cfg_nty     = 24'd1,
    // weight-side config
    input  logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base,

    // ---------------- ibuf_a (ifmap) read interface ----------------
    output logic [$clog2(IBUF_SIZE)-1:0] ibuf_a_raddr,
    input  logic [B*W-1:0] ibuf_a_din,
    output logic ibuf_a_ren,
    input  logic ibuf_a_rvalid,

    // ---------------- ibuf_b (weights) read interface ----------------
    output logic [$clog2(WBUF_SIZE)-1:0] ibuf_b_raddr,
    input  logic [B*W-1:0] ibuf_b_din,
    output logic ibuf_b_ren,
    input  logic ibuf_b_rvalid,

    // ---------------- results ----------------
    output logic [OUT_WIDTH-1:0] outputbus1, outputbus2, outputbus3, outputbus4,
    output logic valid1, valid2, valid3, valid4,
    output logic [1:0] col1, col2, col3, col4,

    output logic tile_done,                          // pulses with the 16th result of EVERY tile
    output logic layer_done,                         // NEW: pulses when ALL (cfg_ntx * cfg_nty) tiles finish
    output logic busy,
    input  logic ext_stall,
    input  logic flush_acc
);
    localparam int IDX_W = 24;
    localparam int PAT_W = 16;

    wire [15:0] eff_ntx = (cfg_ntx == 0) ? 16'd1 : cfg_ntx;
    wire [15:0] eff_nty = (cfg_nty == 0) ? 16'd1 : cfg_nty;
    wire [31:0] total_tiles = 32'(eff_ntx) * 32'(eff_nty);

    // ---------------- A path: 5-counter feeder ----------------
    logic [IDX_W-1:0] fd_addr;
    logic             fd_ready, fd_pop, fd_busy, fd_tile_pop_done, fd_done, fd_deadlock;
    logic [N*W-1:0]   fd_head;

    ifmap_feeder #(.Y(N), .DATA_W(W), .BUS_N(B), .IDX_W(IDX_W), .PAT_W(PAT_W), .QDEPTH(16)) feeder (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cfg_base(cfg_base), .cfg_chstep(cfg_chstep), .cfg_ystep(cfg_ystep),
        .cfg_nch(cfg_nch), .cfg_nky(cfg_nky), .cfg_last(cfg_last),
        .cfg_stride(cfg_stride), .cfg_kpat(cfg_kpat), .cfg_total(IDX_W'(k_len)),
        .cfg_x_tile_step(cfg_x_tile_step), .cfg_y_tile_step(cfg_y_tile_step),
        .cfg_ntx(eff_ntx), .cfg_nty(eff_nty),
        .sram_word_addr(fd_addr), .sram_re(ibuf_a_ren), .sram_rdata(ibuf_a_din),
        .o_ready(fd_ready), .i_pop(fd_pop), .o_head(fd_head),
        .busy(fd_busy), .tile_pop_done(fd_tile_pop_done), .done(fd_done), .o_deadlock(fd_deadlock));
    assign ibuf_a_raddr = fd_addr[$clog2(IBUF_SIZE)-1:0];

    // ---------------- FIFOs + skew ----------------
    logic [W-1:0] fifo_out_a [0:FIF_LINES-1];
    logic [FIF_LINES-1:0] fifo_out_valid_a;
    logic [W-1:0] fifo_out_b [0:FIF_LINES-1];
    logic [FIF_LINES-1:0] fifo_out_valid_b;
    logic adv, feed_done, ctl_busy;

    fifo_controller fifo_controller_inst (
        .clk(clk), .rst_n(rst_n),
        .start(start), .k_steps(k_len), .num_tiles(total_tiles), .b_base(cfg_b_base), .hold(ext_stall),

        .buf_addr_b(ibuf_b_raddr), .buf_req_b(ibuf_b_ren),
        .buffer_in_b(ibuf_b_din), .buffer_in_valid_b(ibuf_b_rvalid),

        .src_a(fd_head), .src_a_valid(fd_ready), .src_a_pop(fd_pop),

        .fifo_out_a(fifo_out_a), .fifo_out_valid_a(fifo_out_valid_a),
        .fifo_out_b(fifo_out_b), .fifo_out_valid_b(fifo_out_valid_b),
        .adv(adv), .feed_done(feed_done), .busy(ctl_busy));

    // ---------------- PE array ----------------
    pe4x4 pe4x4_inst (
        .clk(clk), .rst_n(rst_n), .en(adv), .k_len(k_len), .flush_acc(flush_acc),
        .in_valid_a(fifo_out_valid_a), .in_valid_b(fifo_out_valid_b),
        .fifo_A0(fifo_out_a[0]), .fifo_A1(fifo_out_a[1]), .fifo_A2(fifo_out_a[2]), .fifo_A3(fifo_out_a[3]),
        .fifo_B0(fifo_out_b[0]), .fifo_B1(fifo_out_b[1]), .fifo_B2(fifo_out_b[2]), .fifo_B3(fifo_out_b[3]),
        .outputbus1(outputbus1), .outputbus2(outputbus2), .outputbus3(outputbus3), .outputbus4(outputbus4),
        .valid1(valid1), .valid2(valid2), .valid3(valid3), .valid4(valid4),
        .col1(col1), .col2(col2), .col3(col3), .col4(col4));

    // ---------------- tile & layer bookkeeping ----------------
    logic [4:0]  res_cnt;
    logic [31:0] done_tiles_cnt;
    wire  [2:0]  n_new = 3'(valid1) + 3'(valid2) + 3'(valid3) + 3'(valid4);

    assign tile_done  = (n_new != 0) && ((res_cnt + 5'(n_new)) == 5'(N*N));
    assign layer_done = tile_done && ((done_tiles_cnt + 32'd1) == total_tiles);

    always_ff @(posedge clk) begin
        if (!rst_n || start || tile_done) res_cnt <= '0;
        else                              res_cnt <= res_cnt + 5'(n_new);
    end

    always_ff @(posedge clk) begin
        if (!rst_n || start || layer_done) done_tiles_cnt <= '0;
        else if (tile_done)                done_tiles_cnt <= done_tiles_cnt + 32'd1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || layer_done) busy <= 1'b0;
        else if (start)           busy <= 1'b1;
    end
endmodule
