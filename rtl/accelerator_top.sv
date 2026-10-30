`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module accelerator_top #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4,
    parameter S_ID_W = ID_W + 2, // Interconnect adds $clog2(MST_AMT) to slave IDs
    parameter RESULT_W   = 7
)(
    input  logic clk,
    input  logic rst_n,

    // External DVP Camera Interface
    input  logic       dvp_pclk_i,
    input  logic       dvp_vsync_i,
    input  logic       dvp_hsync_i,
    input  logic       dvp_href_i,
    input  logic [7:0] dvp_d_i,
    output logic       dvp_xclk_o,
    output logic       dvp_pwdn_o,

    // External QSPI Flash Interface
    output logic       qspi_sck,
    output logic       qspi_cs_n,
    inout  wire  [3:0] qspi_io,

    // External MCU / Host Interface (SPI Slave)
    input  logic       mcu_spi_sck,
    input  logic       mcu_spi_cs_n,
    input  logic       mcu_spi_mosi,
    output logic       mcu_spi_miso,
    output logic       host_irq,          // inference done (CSR IRQ, level until cleared)

    // Inference result pins: binary class id + strobe (CSR PIN_CFG[0], default on).
    // RESULT_W = 7 covers up to 128 classes; for more, read RESULT over SPI.
    output logic [RESULT_W-1:0] result_o,
    output logic                result_valid_o,
    output logic                busy_o
);

    // =========================================================================
    // 0. Reset synchroniser (asynchronous assert, synchronous release)
    // =========================================================================
    logic [1:0] rst_sync;
    logic       rst_n_s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    end
    assign rst_n_s = rst_sync[1];

    // =========================================================================
    // 1. AXI4 Interconnect Wires
    // =========================================================================
    // Masters: M0 (SysCtrl), M1 (DVP Camera via PixelConv), M2 (Sys DMA), M3 (MCU SPI)
    logic [ADDR_W-1:0]   m_awaddr  [0:3];
    logic [7:0]          m_awlen   [0:3];
    logic [2:0]          m_awsize  [0:3];
    logic [1:0]          m_awburst [0:3];
    logic [0:3]          m_awvalid;
    logic [0:3]          m_awready;
    logic [DATA_W-1:0]   m_wdata   [0:3];
    logic [DATA_W/8-1:0] m_wstrb   [0:3];
    logic [0:3]          m_wlast;
    logic [0:3]          m_wvalid;
    logic [0:3]          m_wready;
    logic [1:0]          m_bresp   [0:3];
    logic [0:3]          m_bvalid;
    logic [0:3]          m_bready;
    logic [ADDR_W-1:0]   m_araddr  [0:3];
    logic [7:0]          m_arlen   [0:3];
    logic [2:0]          m_arsize  [0:3];
    logic [1:0]          m_arburst [0:3];
    logic [0:3]          m_arvalid;
    logic [0:3]          m_arready;
    logic [DATA_W-1:0]   m_rdata   [0:3];
    logic [1:0]          m_rresp   [0:3];
    logic [0:3]          m_rlast;
    logic [0:3]          m_rvalid;
    logic [0:3]          m_rready;
    logic [ID_W-1:0]     m_awid    [0:3];
    logic [ID_W-1:0]     m_arid    [0:3];
    logic [ID_W-1:0]     m_bid     [0:3];
    logic [ID_W-1:0]     m_rid     [0:3];

    // Slaves: S0(DVP_CFG), S1(QSPI), S2(DMA_CFG), S3(PP_SRAM), S4(W_SRAM), S5(SPI)
    logic [ADDR_W-1:0]   s_awaddr  [0:5];
    logic [7:0]          s_awlen   [0:5];
    logic [2:0]          s_awsize  [0:5];
    logic [1:0]          s_awburst [0:5];
    logic [0:5]          s_awvalid;
    logic [0:5]          s_awready;
    logic [DATA_W-1:0]   s_wdata   [0:5];
    logic [DATA_W/8-1:0] s_wstrb   [0:5];
    logic [0:5]          s_wlast;
    logic [0:5]          s_wvalid;
    logic [0:5]          s_wready;
    logic [1:0]          s_bresp   [0:5];
    logic [0:5]          s_bvalid;
    logic [0:5]          s_bready;
    logic [ADDR_W-1:0]   s_araddr  [0:5];
    logic [7:0]          s_arlen   [0:5];
    logic [2:0]          s_arsize  [0:5];
    logic [1:0]          s_arburst [0:5];
    logic [0:5]          s_arvalid;
    logic [0:5]          s_arready;
    logic [DATA_W-1:0]   s_rdata   [0:5];
    logic [1:0]          s_rresp   [0:5];
    logic [0:5]          s_rlast;
    logic [0:5]          s_rvalid;
    logic [0:5]          s_rready;
    logic [S_ID_W-1:0]   s_awid    [0:5];
    logic [S_ID_W-1:0]   s_arid    [0:5];
    logic [S_ID_W-1:0]   s_bid     [0:5];
    logic [S_ID_W-1:0]   s_rid     [0:5];

    // =========================================================================
    // 2. AXI WSTRB
    // =========================================================================
    // The interconnect does not carry WSTRB.  Every master in this SoC
    // (sys_controller, camera DMA, sys-DMA, SPI bridge) only issues full-word
    // writes, so all slaves see WSTRB = 4'hF.
    for (genvar sl = 0; sl < 6; sl++) begin : g_wstrb
        assign s_wstrb[sl] = 4'hF;
    end

    // =========================================================================
    // 3. FSM Control Wires (Driven by sys_controller)
    // =========================================================================
    logic sys_axi_ctrl, core_start, layer_done, flush_acc;
    
    logic [KLEN_W-1:0] cfg_k_len;                 
    logic [23:0]       cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last;
    logic [7:0]        cfg_stride;
    logic [15:0]       cfg_kpat, cfg_pool_x_chunks, cfg_pool_y_rows;
    logic [23:0]       cfg_x_tile_step, cfg_y_tile_step, cfg_ntx, cfg_nty;
    logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base;
    logic [31:0]       reqt_total_tiles, reqt_oc_base;
    logic signed [31:0] reqt_bias [0:3], reqt_mult [0:3], reqt_shift [0:3];
    logic signed [7:0] reqt_z_out;
    logic              reqt_relu_en, cfg_maxpool_en, cfg_pool_nopad;
    logic [3:0]        cfg_pool_stride;
    logic              sys_dma_irq;
    logic              drc_trap, dvp_dma_trap, sys_dma_trap;
    logic [23:0]       cfg_out_base, cfg_out_ch_stride;
    logic [15:0]       cfg_out_row_stride, cfg_out_words_per_row, cfg_out_oc_off, cfg_out_valid_w, cfg_out_rows;
    logic              cfg_out_pad, fill_start, fill_done;
    logic [15:0]       fill_channels;

    // =========================================================================
    // 4. AXI4 Interconnect (3 Masters x 6 Slaves)
    // =========================================================================
    // Memory Map [31:29]: 
    // 000 (0x0...): DVP DMA Config
    // 001 (0x2...): QSPI Controller (Flash)
    // 010 (0x4...): Sys DMA Config
    // 011 (0x6...): Ping-Pong SRAM
    // 100 (0x8...): Weight SRAM
    // 101 (0xA...): MCU SPI Slave


    axi_interconnect #(
        .MST_AMT(4),
        .SLV_AMT(6),
        .TRANS_MST_ID_W(ID_W),
        .TRANS_DATA_LEN_W(8),
        .TRANS_DATA_SIZE_W(3),
        .SLV_ID_MSB_IDX(31),
        .SLV_ID_LSB_IDX(29) 
    ) main_interconnect (
        .ACLK_i(clk), .ARESETn_i(rst_n_s),

        // Masters (Packed Arrays)
        .m_AWID_i   ({m_awid[3], m_awid[2], m_awid[1], m_awid[0]}),
        .m_AWADDR_i ({m_awaddr[3], m_awaddr[2], m_awaddr[1], m_awaddr[0]}),
        .m_AWBURST_i({m_awburst[3], m_awburst[2], m_awburst[1], m_awburst[0]}),
        .m_AWLEN_i  ({m_awlen[3], m_awlen[2], m_awlen[1], m_awlen[0]}),
        .m_AWSIZE_i ({m_awsize[3], m_awsize[2], m_awsize[1], m_awsize[0]}),
        .m_AWVALID_i({m_awvalid[3], m_awvalid[2], m_awvalid[1], m_awvalid[0]}),
        .m_AWREADY_o({m_awready[3], m_awready[2], m_awready[1], m_awready[0]}),
        
        .m_WDATA_i  ({m_wdata[3], m_wdata[2], m_wdata[1], m_wdata[0]}),
        .m_WLAST_i  ({m_wlast[3], m_wlast[2], m_wlast[1], m_wlast[0]}),
        .m_WVALID_i ({m_wvalid[3], m_wvalid[2], m_wvalid[1], m_wvalid[0]}),
        .m_WREADY_o ({m_wready[3], m_wready[2], m_wready[1], m_wready[0]}),
        
        .m_BID_o    ({m_bid[3], m_bid[2], m_bid[1], m_bid[0]}),
        .m_BRESP_o  ({m_bresp[3], m_bresp[2], m_bresp[1], m_bresp[0]}),
        .m_BVALID_o ({m_bvalid[3], m_bvalid[2], m_bvalid[1], m_bvalid[0]}),
        .m_BREADY_i ({m_bready[3], m_bready[2], m_bready[1], m_bready[0]}),

        .m_ARID_i   ({m_arid[3], m_arid[2], m_arid[1], m_arid[0]}),
        .m_ARADDR_i ({m_araddr[3], m_araddr[2], m_araddr[1], m_araddr[0]}),
        .m_ARBURST_i({m_arburst[3], m_arburst[2], m_arburst[1], m_arburst[0]}),
        .m_ARLEN_i  ({m_arlen[3], m_arlen[2], m_arlen[1], m_arlen[0]}),
        .m_ARSIZE_i ({m_arsize[3], m_arsize[2], m_arsize[1], m_arsize[0]}),
        .m_ARVALID_i({m_arvalid[3], m_arvalid[2], m_arvalid[1], m_arvalid[0]}),
        .m_ARREADY_o({m_arready[3], m_arready[2], m_arready[1], m_arready[0]}),

        .m_RID_o    ({m_rid[3], m_rid[2], m_rid[1], m_rid[0]}),
        .m_RDATA_o  ({m_rdata[3], m_rdata[2], m_rdata[1], m_rdata[0]}),
        .m_RRESP_o  ({m_rresp[3], m_rresp[2], m_rresp[1], m_rresp[0]}),
        .m_RLAST_o  ({m_rlast[3], m_rlast[2], m_rlast[1], m_rlast[0]}),
        .m_RVALID_o ({m_rvalid[3], m_rvalid[2], m_rvalid[1], m_rvalid[0]}),
        .m_RREADY_i ({m_rready[3], m_rready[2], m_rready[1], m_rready[0]}),

        // Slaves (Packed Arrays)
        .s_AWREADY_i({s_awready[5], s_awready[4], s_awready[3], s_awready[2], s_awready[1], s_awready[0]}),
        .s_AWID_o   ({s_awid[5], s_awid[4], s_awid[3], s_awid[2], s_awid[1], s_awid[0]}),
        .s_AWADDR_o ({s_awaddr[5], s_awaddr[4], s_awaddr[3], s_awaddr[2], s_awaddr[1], s_awaddr[0]}),
        .s_AWBURST_o({s_awburst[5], s_awburst[4], s_awburst[3], s_awburst[2], s_awburst[1], s_awburst[0]}),
        .s_AWLEN_o  ({s_awlen[5], s_awlen[4], s_awlen[3], s_awlen[2], s_awlen[1], s_awlen[0]}),
        .s_AWSIZE_o ({s_awsize[5], s_awsize[4], s_awsize[3], s_awsize[2], s_awsize[1], s_awsize[0]}),
        .s_AWVALID_o({s_awvalid[5], s_awvalid[4], s_awvalid[3], s_awvalid[2], s_awvalid[1], s_awvalid[0]}),
        
        .s_WREADY_i ({s_wready[5], s_wready[4], s_wready[3], s_wready[2], s_wready[1], s_wready[0]}),
        .s_WDATA_o  ({s_wdata[5], s_wdata[4], s_wdata[3], s_wdata[2], s_wdata[1], s_wdata[0]}),
        .s_WLAST_o  ({s_wlast[5], s_wlast[4], s_wlast[3], s_wlast[2], s_wlast[1], s_wlast[0]}),
        .s_WVALID_o ({s_wvalid[5], s_wvalid[4], s_wvalid[3], s_wvalid[2], s_wvalid[1], s_wvalid[0]}),

        .s_BID_i    ({s_bid[5], s_bid[4], s_bid[3], s_bid[2], s_bid[1], s_bid[0]}),
        .s_BRESP_i  ({s_bresp[5], s_bresp[4], s_bresp[3], s_bresp[2], s_bresp[1], s_bresp[0]}),
        .s_BVALID_i ({s_bvalid[5], s_bvalid[4], s_bvalid[3], s_bvalid[2], s_bvalid[1], s_bvalid[0]}),
        .s_BREADY_o ({s_bready[5], s_bready[4], s_bready[3], s_bready[2], s_bready[1], s_bready[0]}),

        .s_ARREADY_i({s_arready[5], s_arready[4], s_arready[3], s_arready[2], s_arready[1], s_arready[0]}),
        .s_ARID_o   ({s_arid[5], s_arid[4], s_arid[3], s_arid[2], s_arid[1], s_arid[0]}),
        .s_ARADDR_o ({s_araddr[5], s_araddr[4], s_araddr[3], s_araddr[2], s_araddr[1], s_araddr[0]}),
        .s_ARBURST_o({s_arburst[5], s_arburst[4], s_arburst[3], s_arburst[2], s_arburst[1], s_arburst[0]}),
        .s_ARLEN_o  ({s_arlen[5], s_arlen[4], s_arlen[3], s_arlen[2], s_arlen[1], s_arlen[0]}),
        .s_ARSIZE_o ({s_arsize[5], s_arsize[4], s_arsize[3], s_arsize[2], s_arsize[1], s_arsize[0]}),
        .s_ARVALID_o({s_arvalid[5], s_arvalid[4], s_arvalid[3], s_arvalid[2], s_arvalid[1], s_arvalid[0]}),

        .s_RID_i    ({s_rid[5], s_rid[4], s_rid[3], s_rid[2], s_rid[1], s_rid[0]}),
        .s_RDATA_i  ({s_rdata[5], s_rdata[4], s_rdata[3], s_rdata[2], s_rdata[1], s_rdata[0]}),
        .s_RRESP_i  ({s_rresp[5], s_rresp[4], s_rresp[3], s_rresp[2], s_rresp[1], s_rresp[0]}),
        .s_RLAST_i  ({s_rlast[5], s_rlast[4], s_rlast[3], s_rlast[2], s_rlast[1], s_rlast[0]}),
        .s_RVALID_i ({s_rvalid[5], s_rvalid[4], s_rvalid[3], s_rvalid[2], s_rvalid[1], s_rvalid[0]}),
        .s_RREADY_o ({s_rready[5], s_rready[4], s_rready[3], s_rready[2], s_rready[1], s_rready[0]})
    );

    // =========================================================================
    // 5. Camera: DVP-RX (S0 registers) -> cam_frontend (M1)
    // =========================================================================
    localparam DVP_DMA_BASE_ADDR = 32'h0000_0000;
    localparam DRC_BASE_ADDR = 32'h0001_0000;

    logic [31:0] pxl_tdata;
    logic        pxl_tvalid, pxl_tready;
    logic        cam_arm, cam_consume, cam_frame_done, cam_overrun, cam_raw;
    logic [15:0] cam_rows_done, cam_frame_w, cam_frame_h, cam_x0, cam_y0, cam_w, cam_h, cam_adv, cam_rowstr;
    logic [31:0] cam_buf, cam_slot;
    logic [7:0]  cam_halo, cam_slots;

    dvp_dma_wrapper #(
        .ID_W(S_ID_W),
        .DRC_BASE_ADDR(DRC_BASE_ADDR),
        .DMA_BASE_ADDR(DVP_DMA_BASE_ADDR),
        .FRM_COL_NUM(320),
        .FRM_ROW_NUM(240)
        
        ) dvp_rx_inst (
        .clk(clk), .rst_n(rst_n_s),
        .dvp_d_i(dvp_d_i), .dvp_href_i(dvp_href_i), .dvp_vsync_i(dvp_vsync_i),
        .dvp_hsync_i(dvp_hsync_i), .dvp_pclk_i(dvp_pclk_i),
        .dvp_xclk_o(dvp_xclk_o), .dvp_pwdn_o(dvp_pwdn_o),

        .s_axi_awid(s_awid[0]), .s_axi_awaddr(s_awaddr[0]), .s_axi_awlen(s_awlen[0]), .s_axi_awsize(s_awsize[0]),
        .s_axi_awburst(s_awburst[0]), .s_axi_awvalid(s_awvalid[0]), .s_axi_awready(s_awready[0]),
        .s_axi_wdata(s_wdata[0]), .s_axi_wstrb(s_wstrb[0]), .s_axi_wlast(s_wlast[0]),
        .s_axi_wvalid(s_wvalid[0]), .s_axi_wready(s_wready[0]),
        .s_axi_bid(s_bid[0]), .s_axi_bresp(s_bresp[0]), .s_axi_bvalid(s_bvalid[0]), .s_axi_bready(s_bready[0]),
        .s_axi_arid(s_arid[0]), .s_axi_araddr(s_araddr[0]), .s_axi_arlen(s_arlen[0]), .s_axi_arsize(s_arsize[0]),
        .s_axi_arburst(s_arburst[0]), .s_axi_arvalid(s_arvalid[0]), .s_axi_arready(s_arready[0]),
        .s_axi_rid(s_rid[0]), .s_axi_rdata(s_rdata[0]), .s_axi_rresp(s_rresp[0]), .s_axi_rlast(s_rlast[0]),
        .s_axi_rvalid(s_rvalid[0]), .s_axi_rready(s_rready[0]),

        // the wrapper's own DMA is idle (no stream, never programmed)
        .m_axi_dma_awid(), .m_axi_dma_awaddr(), .m_axi_dma_awlen(), .m_axi_dma_awburst(),
        .m_axi_dma_awvalid(), .m_axi_dma_awready(1'b0),
        .m_axi_dma_wdata(), .m_axi_dma_wlast(), .m_axi_dma_wvalid(), .m_axi_dma_wready(1'b0),
        .m_axi_dma_bid('0), .m_axi_dma_bresp(2'b00), .m_axi_dma_bvalid(1'b0), .m_axi_dma_bready(),
        .drc_irq(), .drc_trap(drc_trap), .dma_irq(), .dma_trap(dvp_dma_trap),

        .m_axis_pxl_tdata(pxl_tdata), .m_axis_pxl_tvalid(pxl_tvalid), .m_axis_pxl_tready(pxl_tready)
    );

    // M1: camera front end (write-only master)
    assign m_arid[1] = 0; assign m_araddr[1] = 0; assign m_arlen[1] = 0;
    assign m_arsize[1] = 0; assign m_arburst[1] = 0; assign m_arvalid[1] = 0;
    assign m_rready[1] = 1'b0;

    cam_frontend #(.ADDR_W(ADDR_W), .ID_W(ID_W), .MAX_W(320)) cam_fe (
        .clk(clk), .rst_n(rst_n_s),
        .s_tdata(pxl_tdata), .s_tvalid(pxl_tvalid), .s_tready(pxl_tready),
        .arm(cam_arm), .mode_raw(cam_raw), .frame_w(cam_frame_w),
        .crop_x0(cam_x0), .crop_y0(cam_y0), .crop_w(cam_w), .crop_h(cam_h),
        .buf_base(cam_buf), .slot_stride(cam_slot), .row_stride(cam_rowstr),
        .adv(cam_adv), .halo(cam_halo), .nslots(cam_slots), .consume(cam_consume),
        .rows_done(cam_rows_done), .frame_done(cam_frame_done), .overrun(cam_overrun),
        .m_awid(m_awid[1]), .m_awaddr(m_awaddr[1]), .m_awlen(m_awlen[1]), .m_awsize(m_awsize[1]),
        .m_awburst(m_awburst[1]), .m_awvalid(m_awvalid[1]), .m_awready(m_awready[1]),
        .m_wdata(m_wdata[1]), .m_wstrb(m_wstrb[1]), .m_wlast(m_wlast[1]),
        .m_wvalid(m_wvalid[1]), .m_wready(m_wready[1]),
        .m_bresp(m_bresp[1]), .m_bvalid(m_bvalid[1]), .m_bready(m_bready[1])
    );

    // =========================================================================
    // 6. System DMA (Mem2Mem) (S2 & M2)
    // =========================================================================

    localparam DMA_BASE_ADDR = 32'h4000_0000;

    logic [ADDR_W-1:0] sdma_araddr_word, sdma_awaddr_word;

    // The DMA config slave is built with ID_W-bit IDs; the interconnect puts the
    // master index in the top ID bits, so restore them on B/R (one master at a time).
    logic [ID_W-1:0]        sdma_bid, sdma_rid;
    logic [S_ID_W-ID_W-1:0] sdma_bmst, sdma_rmst;
    always_ff @(posedge clk) begin
        if (s_awvalid[2] && s_awready[2]) sdma_bmst <= s_awid[2][S_ID_W-1:ID_W];
        if (s_arvalid[2] && s_arready[2]) sdma_rmst <= s_arid[2][S_ID_W-1:ID_W];
    end
    assign s_bid[2] = {sdma_bmst, sdma_bid};
    assign s_rid[2] = {sdma_rmst, sdma_rid};
    assign m_araddr[2] = {sdma_araddr_word[ADDR_W-3:0], 2'b00};   // word -> byte address
    assign m_awaddr[2] = {sdma_awaddr_word[ADDR_W-3:0], 2'b00};
    assign m_arsize[2] = 3'd2;
    assign m_awsize[2] = 3'd2;
    assign m_wstrb[2]  = 4'hF;

    axi_dma #(
        .DMA_BASE_ADDR   (DMA_BASE_ADDR),
        .DMA_CHN_NUM     (1),
        .DMA_LENGTH_W    (16),
        .DMA_DESC_DEPTH  (2),
        .DMA_CHN_ARB_W   (3),
        .ROB_EN          (0),
        .DESC_QUEUE_TYPE ("FLIPFLOP-BASED"),
        .SRC_IF_TYPE     ("AXI4"),     
        .DST_IF_TYPE     ("AXI4"),     
        .ATX_SRC_DATA_W  (32),
        .ATX_DST_DATA_W  (DATA_W),
        .S_DATA_W        (DATA_W),
        .S_ADDR_W        (ADDR_W),
        .SRC_ADDR_W      (ADDR_W),
        .SRC_TDEST_W     (2),
        .DST_ADDR_W      (ADDR_W),
        .DST_TDEST_W     (2),
        .MST_ID_W        (ID_W),
        .ATX_LEN_W       (8),
        .ATX_RESP_W      (2),
        .ATX_NUM_OSTD    (2),
        .ATX_INTL_DEPTH  (16)
    ) sys_dma (
        .aclk(clk), .aresetn(rst_n_s),
        
        // Config Slave (S2)
        .s_awid_i(s_awid[2][ID_W-1:0]), .s_awaddr_i(s_awaddr[2]), .s_awlen_i(s_awlen[2]), .s_awburst_i(s_awburst[2]),
        .s_awvalid_i(s_awvalid[2]), .s_awready_o(s_awready[2]),
        .s_wdata_i(s_wdata[2]), .s_wlast_i(s_wlast[2]), .s_wvalid_i(s_wvalid[2]), .s_wready_o(s_wready[2]),
        .s_bid_o(sdma_bid), .s_bresp_o(s_bresp[2]), .s_bvalid_o(s_bvalid[2]), .s_bready_i(s_bready[2]),
        .s_arid_i(s_arid[2][ID_W-1:0]), .s_araddr_i(s_araddr[2]), .s_arlen_i(s_arlen[2]), .s_arburst_i(s_arburst[2]),
        .s_arvalid_i(s_arvalid[2]), .s_arready_o(s_arready[2]),
        .s_rid_o(sdma_rid), .s_rdata_o(s_rdata[2]), .s_rresp_o(s_rresp[2]), .s_rlast_o(s_rlast[2]),
        .s_rvalid_o(s_rvalid[2]), .s_rready_i(s_rready[2]),

        // Master Output (M2)
        .m_arid_o(m_arid[2]), .m_araddr_o(sdma_araddr_word), .m_arlen_o(m_arlen[2]), .m_arburst_o(m_arburst[2]),
        .m_arvalid_o(m_arvalid[2]), .m_arready_i(m_arready[2]),
        .m_rid_i(m_rid[2]), .m_rdata_i(m_rdata[2]), .m_rresp_i(m_rresp[2]), .m_rlast_i(m_rlast[2]),
        .m_rvalid_i(m_rvalid[2]), .m_rready_o(m_rready[2]),
        
        .m_awid_o(m_awid[2]), .m_awaddr_o(sdma_awaddr_word), .m_awlen_o(m_awlen[2]), .m_awburst_o(m_awburst[2]),
        .m_awvalid_o(m_awvalid[2]), .m_awready_i(m_awready[2]),
        .m_wdata_o(m_wdata[2]), .m_wlast_o(m_wlast[2]), .m_wvalid_o(m_wvalid[2]), .m_wready_i(m_wready[2]),
        .m_bid_i(m_bid[2]), .m_bresp_i(m_bresp[2]), .m_bvalid_i(m_bvalid[2]), .m_bready_o(m_bready[2]),

        // Unused stream ports (tied off)
        .m_tid_o(), .m_tdest_o(), .m_tdata_o(), .m_tkeep_o(), .m_tstrb_o(), .m_tlast_o(), .m_tvalid_o(), .m_tready_i(1'b1),
        .s_tid_i(0), .s_tdest_i(0), .s_tdata_i(0), .s_tkeep_i(0), .s_tstrb_i(0), .s_tlast_i(0), .s_tvalid_i(0), .s_tready_o(),
        .irq(sys_dma_irq), .trap(sys_dma_trap)
    );

    // =========================================================================
    // 7. QSPI Flash Controller (S1 Demux: Config vs Mem)
    // =========================================================================
    wire qspi_is_cfg_read = s_araddr[1][27]; // 1 = 0x28... (CFG), 0 = 0x20... (MEM)
    
    logic [31:0] qspi_cfg_rdata, qspi_mem_rdata;
    logic        qspi_cfg_arready, qspi_mem_arready;
    logic [3:0]  qspi_io_o, qspi_io_oe;
    logic        qspi_cfg_rvalid, qspi_mem_rvalid, qspi_cfg_rlast, qspi_mem_rlast;
    logic [1:0]  qspi_cfg_rresp, qspi_mem_rresp;
    
    assign s_rdata[1]  = qspi_is_cfg_read ? qspi_cfg_rdata  : qspi_mem_rdata;
    assign s_rvalid[1] = qspi_is_cfg_read ? qspi_cfg_rvalid : qspi_mem_rvalid;
    assign s_rlast[1]  = qspi_is_cfg_read ? qspi_cfg_rlast  : qspi_mem_rlast;
    assign s_rresp[1]  = qspi_is_cfg_read ? qspi_cfg_rresp  : qspi_mem_rresp;
    // The QSPI wrapper has no ID ports: echo the IDs so the interconnect can
    // route B/R back (single outstanding transaction per direction)
    always_ff @(posedge clk) begin
        if (s_awvalid[1] && s_awready[1]) s_bid[1] <= s_awid[1];
        if (s_arvalid[1] && s_arready[1]) s_rid[1] <= s_arid[1];
    end
    assign s_arready[1] = qspi_is_cfg_read ? qspi_cfg_arready : qspi_mem_arready;

    // Flash pads: the controller drives the lanes it owns, the flash drives the rest
    for (genvar q = 0; q < 4; q++) begin : g_qspi_io
        assign qspi_io[q] = qspi_io_oe[q] ? qspi_io_o[q] : 1'bz;
    end

    axi_qspi_wrapper qspi_inst (
        .i_qspi_aclk(clk), .i_qspi_aresetn(rst_n_s),
        
        .i_qspi_s_awaddr(s_awaddr[1][7:0]), .i_qspi_s_awlen(s_awlen[1]), .i_qspi_s_awsize(s_awsize[1]),
        .i_qspi_s_awburst(s_awburst[1]), .i_qspi_s_awvalid(s_awvalid[1]), .o_qspi_s_awready(s_awready[1]),
        .i_qspi_s_wdata(s_wdata[1]), .i_qspi_s_wstrb(s_wstrb[1]), .i_qspi_s_wlast(s_wlast[1]),
        .i_qspi_s_wvalid(s_wvalid[1]), .o_qspi_s_wready(s_wready[1]),
        .o_qspi_s_bresp(s_bresp[1]), .o_qspi_s_bvalid(s_bvalid[1]), .i_qspi_s_bready(s_bready[1]),
        
        .i_qspi_s_araddr(s_araddr[1][7:0]), .i_qspi_s_arlen(s_arlen[1]), .i_qspi_s_arsize(s_arsize[1]),
        .i_qspi_s_arburst(s_arburst[1]), .i_qspi_s_arvalid(s_arvalid[1] & qspi_is_cfg_read),
        .o_qspi_s_arready(qspi_cfg_arready),
        .o_qspi_s_rdata(qspi_cfg_rdata), .o_qspi_s_rresp(qspi_cfg_rresp), .o_qspi_s_rlast(qspi_cfg_rlast),
        .o_qspi_s_rvalid(qspi_cfg_rvalid), .i_qspi_s_rready(s_rready[1]),

        .i_qspi_m_araddr(s_araddr[1]), .i_qspi_m_arlen(s_arlen[1]), .i_qspi_m_arsize(s_arsize[1]),
        .i_qspi_m_arburst(s_arburst[1]), .i_qspi_m_arvalid(s_arvalid[1] & ~qspi_is_cfg_read),
        .o_qspi_m_arready(qspi_mem_arready),
        .o_qspi_m_rdata(qspi_mem_rdata), .o_qspi_m_rresp(qspi_mem_rresp), .o_qspi_m_rlast(qspi_mem_rlast),
        .o_qspi_m_rvalid(qspi_mem_rvalid), .i_qspi_m_rready(s_rready[1]),

        .o_qspi_sclk(qspi_sck), .o_qspi_cs_n(qspi_cs_n), 
        .i_qspi_io_i({qspi_io[3], qspi_io[2], qspi_io[1], qspi_io[0]}),
        .o_qspi_io_o(qspi_io_o), .o_qspi_io_oe(qspi_io_oe), .o_qspi_irq()
    );

    // =========================================================================
    // 8. SRAM Wrappers & Compute Engine (S3 & S4)
    // =========================================================================
    logic [15:0]              ifmap_raddr;
    logic                     act_cq_overflow;
    logic [31:0]              ifmap_waddr;
    logic [W*B-1:0]           ifmap_rdata;
    logic [31:0]              ifmap_wdata;
    logic                     ifmap_ren, ifmap_rvalid, ifmap_wen;
    logic [$clog2(WBUF_SIZE)-1:0] wbuf_raddr;
    logic [W*B-1:0]               wbuf_rdata;
    logic                         wbuf_ren, wbuf_rvalid;

    // Unified activation memory: 160 KB, compute and AXI (camera / DMA / SPI) concurrently
    act_mem #(.ADDR_W(ADDR_W), .ID_W(S_ID_W)) act (
        .clk(clk), .rst_n(rst_n_s),
        .s_awid(s_awid[3]), .s_awaddr(s_awaddr[3]), .s_awlen(s_awlen[3]), .s_awvalid(s_awvalid[3]), .s_awready(s_awready[3]),
        .s_wdata(s_wdata[3]), .s_wlast(s_wlast[3]), .s_wvalid(s_wvalid[3]), .s_wready(s_wready[3]),
        .s_bid(s_bid[3]), .s_bresp(s_bresp[3]), .s_bvalid(s_bvalid[3]), .s_bready(s_bready[3]),
        .s_arid(s_arid[3]), .s_araddr(s_araddr[3]), .s_arlen(s_arlen[3]), .s_arvalid(s_arvalid[3]), .s_arready(s_arready[3]),
        .s_rid(s_rid[3]), .s_rdata(s_rdata[3]), .s_rresp(s_rresp[3]), .s_rlast(s_rlast[3]), .s_rvalid(s_rvalid[3]), .s_rready(s_rready[3]),
        .c_raddr(ifmap_raddr), .c_ren(ifmap_ren), .c_rdata(ifmap_rdata), .c_rvalid(ifmap_rvalid),
        .c_waddr(ifmap_waddr[15:0]), .c_wen(ifmap_wen), .c_wdata(ifmap_wdata),
        .cq_overflow(act_cq_overflow)
    );

    wbuf_axi_wrapper #(.ADDR_WIDTH(ADDR_W), .DATA_WIDTH(DATA_W), .ID_W(S_ID_W)) weight_sram (
        .clk(clk), .rst_n(rst_n_s), .sys_axi_ctrl(sys_axi_ctrl),
        .s_axi_awid(s_awid[4]), .s_axi_bid(s_bid[4]), .s_axi_arid(s_arid[4]), .s_axi_rid(s_rid[4]),
        
        .s_axi_awaddr(s_awaddr[4]), .s_axi_awlen(s_awlen[4]), .s_axi_awvalid(s_awvalid[4]), .s_axi_awready(s_awready[4]),
        .s_axi_wdata(s_wdata[4]), .s_axi_wlast(s_wlast[4]), .s_axi_wvalid(s_wvalid[4]), .s_axi_wready(s_wready[4]),
        .s_axi_bresp(s_bresp[4]), .s_axi_bvalid(s_bvalid[4]), .s_axi_bready(s_bready[4]),
        .s_axi_araddr(s_araddr[4]), .s_axi_arlen(s_arlen[4]), .s_axi_arvalid(s_arvalid[4]), .s_axi_arready(s_arready[4]),
        .s_axi_rdata(s_rdata[4]), .s_axi_rresp(s_rresp[4]), .s_axi_rlast(s_rlast[4]), .s_axi_rvalid(s_rvalid[4]), .s_axi_rready(s_rready[4]),

        .mme_raddr(wbuf_raddr), .mme_ren(wbuf_ren), .mme_rdata(wbuf_rdata), .mme_rvalid(wbuf_rvalid)
    );

    compute_top compute_core (
        .clk(clk), .rst_n(rst_n_s), .start(core_start), .flush_acc(flush_acc), .ext_stall(1'b0),
        .k_len(cfg_k_len), .cfg_base(cfg_base), .cfg_chstep(cfg_chstep), .cfg_ystep(cfg_ystep),
        .cfg_nch(cfg_nch), .cfg_nky(cfg_nky), .cfg_last(cfg_last), .cfg_stride(cfg_stride),
        .cfg_kpat(cfg_kpat), .cfg_x_tile_step(cfg_x_tile_step), .cfg_y_tile_step(cfg_y_tile_step),
        .cfg_ntx(cfg_ntx), .cfg_nty(cfg_nty), .cfg_b_base(cfg_b_base),
        .reqt_total_tiles(reqt_total_tiles), .reqt_oc_base(reqt_oc_base), .reqt_bias(reqt_bias),
        .reqt_mult(reqt_mult), .reqt_shift(reqt_shift), .reqt_z_out(reqt_z_out), .reqt_relu_en(reqt_relu_en),
        .cfg_maxpool_en(cfg_maxpool_en), .cfg_pool_x_chunks(cfg_pool_x_chunks),
        .cfg_pool_y_rows(cfg_pool_y_rows), .cfg_pool_stride(cfg_pool_stride), .cfg_pool_nopad(cfg_pool_nopad),
        .cfg_out_base(cfg_out_base), .cfg_out_ch_stride(cfg_out_ch_stride),
        .cfg_out_row_stride(cfg_out_row_stride), .cfg_out_words_per_row(cfg_out_words_per_row),
        .cfg_out_pad(cfg_out_pad), .cfg_out_oc_off(cfg_out_oc_off), .cfg_out_valid_w(cfg_out_valid_w),
        .cfg_out_rows(cfg_out_rows), .fill_start(fill_start), .fill_channels(fill_channels), .fill_done(fill_done),
        
        .ibuf_a_raddr(ifmap_raddr), .ibuf_a_rdata(ifmap_rdata), .ibuf_a_ren(ifmap_ren), .ibuf_a_rvalid(ifmap_rvalid),
        .ibuf_b_raddr(wbuf_raddr),  .ibuf_b_rdata(wbuf_rdata),  .ibuf_b_ren(wbuf_ren),  .ibuf_b_rvalid(wbuf_rvalid),
        .final_sram_waddr(ifmap_waddr), .final_sram_wdata(ifmap_wdata), .final_sram_wen(ifmap_wen),
        
        .layer_done(layer_done), .busy()
    );

    // =========================================================================
    // 9. MCU SPI bridge (M3), system CSRs (S5) & Sys Controller (M0)
    // =========================================================================
    logic        csr_cfg_we;
    logic [31:0] csr_cfg_addr, csr_cfg_wdata;
    logic [15:0] head_classes, head_words, result_class;
    logic [31:0] head_base;
    logic signed [31:0] result_score;
    logic        infer_done, sys_busy, result_valid, pins_en, spi_miso_oe;
    logic [7:0]  cur_layer, cur_pass;

    spi_slave_axi #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) mcu_spi (
        .clk(clk), .rst_n(rst_n_s),
        .spi_sck(mcu_spi_sck), .spi_cs_n(mcu_spi_cs_n), .spi_mosi(mcu_spi_mosi),
        .spi_miso(mcu_spi_miso), .spi_miso_oe(spi_miso_oe),
        .m_awid(m_awid[3]), .m_awaddr(m_awaddr[3]), .m_awlen(m_awlen[3]), .m_awsize(m_awsize[3]),
        .m_awburst(m_awburst[3]), .m_awvalid(m_awvalid[3]), .m_awready(m_awready[3]),
        .m_wdata(m_wdata[3]), .m_wstrb(m_wstrb[3]), .m_wlast(m_wlast[3]),
        .m_wvalid(m_wvalid[3]), .m_wready(m_wready[3]),
        .m_bid(m_bid[3]), .m_bresp(m_bresp[3]), .m_bvalid(m_bvalid[3]), .m_bready(m_bready[3]),
        .m_arid(m_arid[3]), .m_araddr(m_araddr[3]), .m_arlen(m_arlen[3]), .m_arsize(m_arsize[3]),
        .m_arburst(m_arburst[3]), .m_arvalid(m_arvalid[3]), .m_arready(m_arready[3]),
        .m_rid(m_rid[3]), .m_rdata(m_rdata[3]), .m_rresp(m_rresp[3]), .m_rlast(m_rlast[3]),
        .m_rvalid(m_rvalid[3]), .m_rready(m_rready[3]),
        .rd_late()
    );

    sys_csr #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(S_ID_W)) csr (
        .clk(clk), .rst_n(rst_n_s),
        .s_awid(s_awid[5]), .s_awaddr(s_awaddr[5]), .s_awvalid(s_awvalid[5]), .s_awready(s_awready[5]),
        .s_wdata(s_wdata[5]), .s_wvalid(s_wvalid[5]), .s_wready(s_wready[5]),
        .s_bid(s_bid[5]), .s_bresp(s_bresp[5]), .s_bvalid(s_bvalid[5]), .s_bready(s_bready[5]),
        .s_arid(s_arid[5]), .s_araddr(s_araddr[5]), .s_arvalid(s_arvalid[5]), .s_arready(s_arready[5]),
        .s_rid(s_rid[5]), .s_rdata(s_rdata[5]), .s_rresp(s_rresp[5]), .s_rlast(s_rlast[5]),
        .s_rvalid(s_rvalid[5]), .s_rready(s_rready[5]),
        .cfg_we(csr_cfg_we), .cfg_addr(csr_cfg_addr), .cfg_wdata(csr_cfg_wdata),
        .head_classes(head_classes), .head_words(head_words), .head_base(head_base),
        .busy(sys_busy), .infer_done(infer_done), .result_valid(result_valid),
        .result_class(result_class), .result_score(result_score),
        .cur_layer(cur_layer), .cur_pass(cur_pass),
        .traps({sys_dma_trap | act_cq_overflow, dvp_dma_trap, drc_trap}),
        .cam_frame_w(cam_frame_w), .cam_frame_h(cam_frame_h), .cam_x0(cam_x0), .cam_y0(cam_y0),
        .cam_w(cam_w), .cam_h(cam_h), .cam_raw(cam_raw), .cam_buf(cam_buf), .cam_slot(cam_slot),
        .cam_adv(cam_adv), .cam_rowstr(cam_rowstr), .cam_halo(cam_halo), .cam_slots(cam_slots),
        .cam_rows_done(cam_rows_done), .cam_frame_done(cam_frame_done), .cam_overrun(cam_overrun),
        .host_irq(host_irq), .pins_en(pins_en)
    );

    assign result_o       = pins_en ? result_class[RESULT_W-1:0] : '0;
    assign result_valid_o = pins_en & result_valid;
    assign busy_o         = sys_busy;

    sys_controller #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
        .DESC_BASE(32'hA001_0000), .START_ADDR(32'hA000_0000)
    ) sys_ctrl (
        .clk(clk), .rst_n(rst_n_s),
        .cfg_we(csr_cfg_we), .cfg_addr(csr_cfg_addr), .cfg_wdata(csr_cfg_wdata),

        .m_awid(m_awid[0]), .m_awaddr(m_awaddr[0]), .m_awlen(m_awlen[0]), .m_awsize(m_awsize[0]),
        .m_awburst(m_awburst[0]), .m_awvalid(m_awvalid[0]), .m_awready(m_awready[0]),
        .m_wdata(m_wdata[0]), .m_wstrb(m_wstrb[0]), .m_wlast(m_wlast[0]),
        .m_wvalid(m_wvalid[0]), .m_wready(m_wready[0]),
        .m_bid(m_bid[0]), .m_bresp(m_bresp[0]), .m_bvalid(m_bvalid[0]), .m_bready(m_bready[0]),
        .m_arid(m_arid[0]), .m_araddr(m_araddr[0]), .m_arlen(m_arlen[0]), .m_arsize(m_arsize[0]),
        .m_arburst(m_arburst[0]), .m_arvalid(m_arvalid[0]), .m_arready(m_arready[0]),
        .m_rid(m_rid[0]), .m_rdata(m_rdata[0]), .m_rresp(m_rresp[0]), .m_rlast(m_rlast[0]),
        .m_rvalid(m_rvalid[0]), .m_rready(m_rready[0]),

        .sys_dma_irq({1'b0, sys_dma_irq}),

        .sys_axi_ctrl(sys_axi_ctrl), .core_start(core_start), .flush_acc(flush_acc),
        .layer_done(layer_done),
        .cam_arm(cam_arm), .cam_consume(cam_consume), .cam_rows_done(cam_rows_done),
        .cam_frame_w(cam_frame_w), .cam_frame_h(cam_frame_h),

        .cfg_k_len(cfg_k_len), .cfg_base(cfg_base), .cfg_chstep(cfg_chstep), .cfg_ystep(cfg_ystep),
        .cfg_nch(cfg_nch), .cfg_nky(cfg_nky), .cfg_last(cfg_last), .cfg_stride(cfg_stride),
        .cfg_kpat(cfg_kpat), .cfg_x_tile_step(cfg_x_tile_step), .cfg_y_tile_step(cfg_y_tile_step),
        .cfg_ntx(cfg_ntx), .cfg_nty(cfg_nty), .cfg_b_base(cfg_b_base),
        .reqt_total_tiles(reqt_total_tiles), .reqt_oc_base(reqt_oc_base), .reqt_bias(reqt_bias),
        .reqt_mult(reqt_mult), .reqt_shift(reqt_shift), .reqt_z_out(reqt_z_out), .reqt_relu_en(reqt_relu_en),
        .cfg_maxpool_en(cfg_maxpool_en), .cfg_pool_x_chunks(cfg_pool_x_chunks),
        .cfg_pool_y_rows(cfg_pool_y_rows), .cfg_pool_stride(cfg_pool_stride), .cfg_pool_nopad(cfg_pool_nopad),
        .cfg_out_base(cfg_out_base), .cfg_out_ch_stride(cfg_out_ch_stride),
        .cfg_out_row_stride(cfg_out_row_stride), .cfg_out_words_per_row(cfg_out_words_per_row),
        .cfg_out_pad(cfg_out_pad), .cfg_out_oc_off(cfg_out_oc_off), .cfg_out_valid_w(cfg_out_valid_w),
        .cfg_out_rows(cfg_out_rows), .fill_start(fill_start), .fill_channels(fill_channels), .fill_done(fill_done),

        .head_classes(head_classes), .head_words(head_words), .head_base(head_base),
        .infer_done(infer_done), .busy(sys_busy), .result_valid(result_valid),
        .result_class_id(result_class), .result_score(result_score),
        .cur_layer(cur_layer), .cur_pass(cur_pass)
    );

endmodule
