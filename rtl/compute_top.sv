`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module compute_top (
    input  logic clk,
    input  logic rst_n,
    
    // Global Control
    input  logic start,
    input  logic flush_acc,
    input  logic ext_stall,
    
    // MME Configs
    input  logic [KLEN_W-1:0] k_len,                 
    input  logic [23:0] cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last,
    input  logic [7:0]  cfg_stride,
    input  logic [15:0] cfg_kpat,
    input  logic [23:0] cfg_x_tile_step, cfg_y_tile_step, cfg_ntx, cfg_nty,
    input  logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base,
    
    // Requant Configs
    input  logic [31:0]        reqt_total_tiles, reqt_oc_base,
    input  logic signed [31:0] reqt_bias [0:3], reqt_mult [0:3], reqt_shift [0:3],
    input  logic signed [7:0]  reqt_z_out,
    input  logic               reqt_relu_en,
    
    // MaxPool Configs
    input  logic        cfg_maxpool_en, 
    input  logic [15:0] cfg_pool_x_chunks, cfg_pool_y_rows,
    input  logic [3:0]  cfg_pool_stride,
    input  logic        cfg_pool_nopad,

    // Output frame placement (see out_writer)
    input  logic [23:0] cfg_out_base, cfg_out_ch_stride,
    input  logic [15:0] cfg_out_row_stride, cfg_out_words_per_row,
    input  logic        cfg_out_pad,
    input  logic [15:0] cfg_out_oc_off, cfg_out_valid_w, cfg_out_rows,
    input  logic        fill_start,
    input  logic [15:0] fill_channels,
    output logic        fill_done,

    // SRAM Interface: IFMAP Read (From Ping-Pong Bank A)
    output logic [15:0]              ibuf_a_raddr,   // act_mem word address
    input  logic [W*B-1:0]           ibuf_a_rdata,
    output logic                     ibuf_a_ren,
    input  logic                     ibuf_a_rvalid,
    
    // SRAM Interface: Weight Read (From WBUF)
    output logic [$clog2(WBUF_SIZE)-1:0] ibuf_b_raddr,
    input  logic [W*B-1:0]               ibuf_b_rdata,
    output logic                         ibuf_b_ren,
    input  logic                         ibuf_b_rvalid,
    
    // SRAM Interface: Activations Write (To Ping-Pong Bank B)
    output logic [31:0] final_sram_wdata,
    output logic [31:0] final_sram_waddr,
    output logic        final_sram_wen,
    
    // Status
    output logic layer_done,
    output logic busy
);

    logic signed [OUT_WIDTH-1:0] ob1, ob2, ob3, ob4;
    logic valid1, valid2, valid3, valid4;
    logic [1:0] c1, c2, c3, c4;
    logic tile_done;

    logic [31:0] reqt_wdata, reqt_waddr;
    logic        reqt_wen;
    logic [1:0]  reqt_wch, pool_wch;
    logic [31:0] pool_wdata, pool_waddr;
    logic        pool_wen;

    mme mme_inst (
        .clk(clk), .rst_n(rst_n), .start(start), .k_len(k_len),
        .cfg_base(cfg_base), .cfg_chstep(cfg_chstep), .cfg_ystep(cfg_ystep),
        .cfg_nch(cfg_nch), .cfg_nky(cfg_nky), .cfg_last(cfg_last),
        .cfg_stride(cfg_stride), .cfg_kpat(cfg_kpat), .cfg_b_base(cfg_b_base),
        .cfg_x_tile_step(cfg_x_tile_step), .cfg_y_tile_step(cfg_y_tile_step),
        .cfg_ntx(cfg_ntx), .cfg_nty(cfg_nty),
        .ibuf_a_raddr(ibuf_a_raddr), .ibuf_a_din(ibuf_a_rdata), .ibuf_a_ren(ibuf_a_ren), .ibuf_a_rvalid(ibuf_a_rvalid),
        .ibuf_b_raddr(ibuf_b_raddr), .ibuf_b_din(ibuf_b_rdata), .ibuf_b_ren(ibuf_b_ren), .ibuf_b_rvalid(ibuf_b_rvalid),
        .outputbus1(ob1), .outputbus2(ob2), .outputbus3(ob3), .outputbus4(ob4),
        .valid1(valid1), .valid2(valid2), .valid3(valid3), .valid4(valid4),
        .col1(c1), .col2(c2), .col3(c3), .col4(c4),
        .tile_done(tile_done), .layer_done(layer_done), .busy(busy), .ext_stall(ext_stall), .flush_acc(flush_acc)
    );

    requant_and_pack reqt_inst (
        .clk(clk), .rst_n(rst_n), .start(start),
        .total_tiles(reqt_total_tiles), .oc_base(reqt_oc_base),
        .bias(reqt_bias), .M_fixed(reqt_mult), .shift_val(reqt_shift), .Z_out(reqt_z_out), .relu_en(reqt_relu_en),
        .ob1(ob1), .ob2(ob2), .ob3(ob3), .ob4(ob4),
        .valid1(valid1), .valid2(valid2), .valid3(valid3), .valid4(valid4),
        .c1(c1), .c2(c2), .c3(c3), .c4(c4),
        .sram_wdata(reqt_wdata), .sram_waddr(reqt_waddr), .sram_wen(reqt_wen), .sram_wch(reqt_wch)
    );

    maxpool_inline #(.MAX_DL_WORDS(56)) maxpool_inst (
        .clk(clk), .rst_n(rst_n), .start(start),
        .oc_base(reqt_oc_base), .pad_val(reqt_z_out),
        .cfg_pool_x_chunks(cfg_pool_x_chunks), .cfg_pool_y_rows(cfg_pool_y_rows), .cfg_pool_stride(cfg_pool_stride),
        .cfg_pool_nopad(cfg_pool_nopad),
        .in_data(reqt_wdata), .in_val(reqt_wen), .in_c(c4),
        .out_data(pool_wdata), .out_addr(pool_waddr), .out_val(pool_wen), .out_ch(pool_wch)
    );

    out_writer out_wr (
        .clk(clk), .rst_n(rst_n), .start(start), .oc_base(reqt_oc_base),
        .out_base(cfg_out_base), .ch_stride(cfg_out_ch_stride), .row_stride(cfg_out_row_stride),
        .words_per_row(cfg_out_words_per_row), .out_pad(cfg_out_pad), .oc_off(cfg_out_oc_off),
        .valid_w(cfg_out_valid_w), .out_rows(cfg_out_rows), .z_out(reqt_z_out),
        .in_wdata(cfg_maxpool_en ? pool_wdata : reqt_wdata),
        .in_wen  (cfg_maxpool_en ? pool_wen   : reqt_wen),
        .in_ch   (cfg_maxpool_en ? pool_wch   : reqt_wch),
        .fill_start(fill_start), .fill_channels(fill_channels), .fill_busy(), .fill_done(fill_done),
        .waddr(final_sram_waddr), .wdata(final_sram_wdata), .wen(final_sram_wen)
    );

endmodule
