// single axi port wrapper

`timescale 1ns / 1ps
//==============================================================================
// Module     : dvp_dma_wrapper
// Description: Integrated DVP RX Camera Controller + Stream DMA Subsystem
//              Features a single AXI4 Slave routed internally via bit 16 select.
//==============================================================================

module dvp_dma_wrapper #(
    parameter ADDR_W            = 32,
    parameter DATA_W            = 32,
    parameter ID_W              = 4,
    parameter DRC_BASE_ADDR     = 32'h6001_0000,
    parameter DMA_BASE_ADDR     = 32'h6000_0000,
    parameter FRM_COL_NUM       = 640,
    parameter FRM_ROW_NUM       = 480
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // -------------------------------------------------------------------------
    // Camera DVP Physical Pins
    // -------------------------------------------------------------------------
    input  wire [7:0]           dvp_d_i,
    input  wire                 dvp_href_i,
    input  wire                 dvp_vsync_i,
    input  wire                 dvp_hsync_i,
    input  wire                 dvp_pclk_i,
    output wire                 dvp_xclk_o,
    output wire                 dvp_pwdn_o,

    // -------------------------------------------------------------------------
    // Unified AXI4 Slave (CPU -> Config Registers)
    // -------------------------------------------------------------------------
    input  wire [ID_W-1:0]      s_axi_awid,
    input  wire [ADDR_W-1:0]    s_axi_awaddr,
    input  wire [7:0]           s_axi_awlen,
    input  wire [2:0]           s_axi_awsize,
    input  wire [1:0]           s_axi_awburst,
    input  wire                 s_axi_awvalid,
    output wire                 s_axi_awready,

    input  wire [DATA_W-1:0]    s_axi_wdata,
    input  wire [DATA_W/8-1:0]  s_axi_wstrb,
    input  wire                 s_axi_wlast,
    input  wire                 s_axi_wvalid,
    output wire                 s_axi_wready,

    output wire [ID_W-1:0]      s_axi_bid,
    output wire [1:0]           s_axi_bresp,
    output wire                 s_axi_bvalid,
    input  wire                 s_axi_bready,

    input  wire [ID_W-1:0]      s_axi_arid,
    input  wire [ADDR_W-1:0]    s_axi_araddr,
    input  wire [7:0]           s_axi_arlen,
    input  wire [2:0]           s_axi_arsize,
    input  wire [1:0]           s_axi_arburst,
    input  wire                 s_axi_arvalid,
    output wire                 s_axi_arready,

    output wire [ID_W-1:0]      s_axi_rid,
    output wire [DATA_W-1:0]    s_axi_rdata,
    output wire [1:0]           s_axi_rresp,
    output wire                 s_axi_rlast,
    output wire                 s_axi_rvalid,
    input  wire                 s_axi_rready,

    // -------------------------------------------------------------------------
    // AXI4 Master Write Port (DMA -> Interconnect -> DTCM)
    // -------------------------------------------------------------------------
    output wire [ID_W-1:0]      m_axi_dma_awid,
    output wire [ADDR_W-1:0]    m_axi_dma_awaddr,
    output wire [7:0]           m_axi_dma_awlen,
    output wire [1:0]           m_axi_dma_awburst,
    output wire                 m_axi_dma_awvalid,
    input  wire                 m_axi_dma_awready,

    output wire [DATA_W-1:0]    m_axi_dma_wdata,
    output wire                 m_axi_dma_wlast,
    output wire                 m_axi_dma_wvalid,
    input  wire                 m_axi_dma_wready,

    input  wire [ID_W-1:0]      m_axi_dma_bid,
    input  wire [1:0]           m_axi_dma_bresp,
    input  wire                 m_axi_dma_bvalid,
    output wire                 m_axi_dma_bready,

    // -------------------------------------------------------------------------
    // Subsystem Interrupts & Traps
    // -------------------------------------------------------------------------
    output wire                 drc_irq,
    output wire                 drc_trap,
    output wire                 dma_irq,
    output wire                 dma_trap,

    // Pixel stream to the camera front end (cam_frontend).  The internal DMA no longer
    // consumes the stream; it stays only for its register map.
    output wire [31:0]          m_axis_pxl_tdata,
    output wire                 m_axis_pxl_tvalid,
    input  wire                 m_axis_pxl_tready
);

    // =========================================================================
    // AXI ROUTING LOGIC (Using Bit 16 as requested)
    // 0x6001_xxxx (DRC) vs 0x6000_xxxx (DMA)
    // =========================================================================
    wire route_drc_aw = s_axi_awaddr[16];
    wire route_drc_ar = s_axi_araddr[16];

    // Internal wires for DRC
    wire s_drc_awready, s_drc_wready, s_drc_bvalid, s_drc_arready, s_drc_rvalid, s_drc_rlast;
    wire [1:0] s_drc_bresp, s_drc_rresp;
    wire [ID_W-1:0] s_drc_bid, s_drc_rid;
    wire [DATA_W-1:0] s_drc_rdata;

    // Internal wires for DMA
    wire s_dma_awready, s_dma_wready, s_dma_bvalid, s_dma_arready, s_dma_rvalid, s_dma_rlast;
    wire [1:0] s_dma_bresp, s_dma_rresp;
    wire [ID_W-1:0] s_dma_bid, s_dma_rid;
    wire [DATA_W-1:0] s_dma_rdata;

    // 1. AW Channel Route
    assign s_axi_awready = route_drc_aw ? s_drc_awready : s_dma_awready;

    // 2. W Channel Route
    // AXI allows WVALID to arrive before or simultaneously with AWVALID.
    // If the testbench asserts both simultaneously, the queue will be empty, 
    // and reading the queue will cause a deadlock.
    // FIX: Add a combinational bypass path if the queue is empty.
    logic w_dest_q [0:15];
    logic [3:0] w_wr_ptr = 0, w_rd_ptr = 0;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            w_wr_ptr <= 0; w_rd_ptr <= 0; 
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                w_dest_q[w_wr_ptr] <= route_drc_aw;
                w_wr_ptr <= w_wr_ptr + 1;
            end
            if (s_axi_wvalid && s_axi_wready && s_axi_wlast) begin
                w_rd_ptr <= w_rd_ptr + 1;
            end
        end
    end
    
    wire w_queue_empty = (w_wr_ptr == w_rd_ptr);
    wire route_drc_w   = w_queue_empty ? route_drc_aw : w_dest_q[w_rd_ptr];
    wire w_can_route   = !w_queue_empty || s_axi_awvalid;
    
    assign s_axi_wready = w_can_route ? (route_drc_w ? s_drc_wready : s_dma_wready) : 1'b0;
    wire s_axi_drc_wvalid = s_axi_wvalid &  route_drc_w & w_can_route;
    wire s_axi_dma_wvalid = s_axi_wvalid & ~route_drc_w & w_can_route;

    // 3. B Channel Route
    logic b_dest_q [0:15];
    logic [3:0] b_wr_ptr = 0, b_rd_ptr = 0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            b_wr_ptr <= 0; b_rd_ptr <= 0; 
        end else begin
            if (s_axi_wvalid && s_axi_wready && s_axi_wlast) begin
                b_dest_q[b_wr_ptr] <= route_drc_w;
                b_wr_ptr <= b_wr_ptr + 1;
            end
            if (s_axi_bvalid && s_axi_bready) begin
                b_rd_ptr <= b_rd_ptr + 1;
            end
        end
    end
    wire route_drc_b = b_dest_q[b_rd_ptr];
    assign s_axi_bvalid = route_drc_b ? s_drc_bvalid : s_dma_bvalid;
    assign s_axi_bresp  = route_drc_b ? s_drc_bresp  : s_dma_bresp;
    assign s_axi_bid    = route_drc_b ? s_drc_bid    : s_dma_bid;
    
    wire s_axi_drc_bready = s_axi_bready &  route_drc_b;
    wire s_axi_dma_bready = s_axi_bready & ~route_drc_b;

    // 4. AR Channel Route
    assign s_axi_arready = route_drc_ar ? s_drc_arready : s_dma_arready;

    // 5. R Channel Route
    logic r_dest_q [0:15];
    logic [3:0] r_wr_ptr = 0, r_rd_ptr = 0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            r_wr_ptr <= 0; r_rd_ptr <= 0; 
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                r_dest_q[r_wr_ptr] <= route_drc_ar;
                r_wr_ptr <= r_wr_ptr + 1;
            end
            if (s_axi_rvalid && s_axi_rready && s_axi_rlast) begin
                r_rd_ptr <= r_rd_ptr + 1;
            end
        end
    end
    wire route_drc_r = r_dest_q[r_rd_ptr];
    assign s_axi_rvalid = route_drc_r ? s_drc_rvalid : s_dma_rvalid;
    assign s_axi_rdata  = route_drc_r ? s_drc_rdata  : s_dma_rdata;
    assign s_axi_rresp  = route_drc_r ? s_drc_rresp  : s_dma_rresp;
    assign s_axi_rlast  = route_drc_r ? s_drc_rlast  : s_dma_rlast;
    assign s_axi_rid    = route_drc_r ? s_drc_rid    : s_dma_rid;
    
    wire s_axi_drc_rready = s_axi_rready &  route_drc_r;
    wire s_axi_dma_rready = s_axi_rready & ~route_drc_r;

    // =========================================================================
    // Internal AXI-Stream Bus (dvp_rx_core -> axi_dma)
    // =========================================================================
    wire [31:0] axis_tdata;
    wire        axis_tvalid;
    wire [3:0]  axis_tkeep;
    wire [3:0]  axis_tstrb;
    wire        axis_tlast;
    wire        axis_tready;

    assign m_axis_pxl_tdata  = axis_tdata;
    assign m_axis_pxl_tvalid = axis_tvalid;
    assign axis_tready       = m_axis_pxl_tready;

    // =========================================================================
    // DVP RX Core
    // =========================================================================
    dvp_rx_core #(
        .INTERNAL_CLK     (100_000_000),
        .DRC_BASE_ADDR    (DRC_BASE_ADDR),
        .S_DATA_W         (DATA_W),
        .S_ADDR_W         (ADDR_W),
        .MST_ID_W         (ID_W),
        .DVP_DATA_W       (8),
        .FRM_COL_NUM      (FRM_COL_NUM),
        .FRM_ROW_NUM      (FRM_ROW_NUM),
        .AXIS_DATA_W      (32)
    ) u_dvp_rx_core (
        .clk              (clk),
        .rst_n            (rst_n),
        .dvp_d_i          (dvp_d_i),
        .dvp_href_i       (dvp_href_i),
        .dvp_vsync_i      (dvp_vsync_i),
        .dvp_hsync_i      (dvp_hsync_i),
        .dvp_pclk_i       (dvp_pclk_i),
        .dvp_xclk_o       (dvp_xclk_o),
        .dvp_pwdn_o       (dvp_pwdn_o),

        .s_awid_i         (s_axi_awid),
        .s_awaddr_i       (s_axi_awaddr),
        .s_awburst_i      (s_axi_awburst),
        .s_awlen_i        (s_axi_awlen),
        .s_awvalid_i      (s_axi_awvalid & route_drc_aw),
        .s_awready_o      (s_drc_awready),

        .s_wdata_i        (s_axi_wdata),
        .s_wlast_i        (s_axi_wlast),
        .s_wvalid_i       (s_axi_drc_wvalid), // USING SAFE ROUTED SIGNAL
        .s_wready_o       (s_drc_wready),

        .s_bid_o          (s_drc_bid),
        .s_bresp_o        (s_drc_bresp),
        .s_bvalid_o       (s_drc_bvalid),
        .s_bready_i       (s_axi_drc_bready),

        .s_arid_i         (s_axi_arid),
        .s_araddr_i       (s_axi_araddr),
        .s_arburst_i      (s_axi_arburst),
        .s_arlen_i        (s_axi_arlen),
        .s_arvalid_i      (s_axi_arvalid & route_drc_ar),
        .s_arready_o      (s_drc_arready),

        .s_rid_o          (s_drc_rid),
        .s_rdata_o        (s_drc_rdata),
        .s_rresp_o        (s_drc_rresp),
        .s_rlast_o        (s_drc_rlast),
        .s_rvalid_o       (s_drc_rvalid),
        .s_rready_i       (s_axi_drc_rready),

        .m_axis_tdata     (axis_tdata),
        .m_axis_tvalid    (axis_tvalid),
        .m_axis_tkeep     (axis_tkeep),
        .m_axis_tstrb     (axis_tstrb),
        .m_axis_tlast     (axis_tlast),
        .m_axis_tready    (axis_tready),

        .drc_irq          (drc_irq),
        .drc_trap         (drc_trap)
    );

    // =========================================================================
    // AXI DMA Core
    // =========================================================================
    axi_dma #(
        .DMA_BASE_ADDR   (DMA_BASE_ADDR),
        .DMA_CHN_NUM     (1),
        .DMA_LENGTH_W    (16),
        .DMA_DESC_DEPTH  (2),
        .DMA_CHN_ARB_W   (3),
        .ROB_EN          (0),
        .DESC_QUEUE_TYPE ("FLIPFLOP-BASED"),
        .SRC_IF_TYPE     ("AXIS"),     
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
    ) u_dvp_dma (
        .aclk            (clk),
        .aresetn         (rst_n),

        .s_awid_i        (s_axi_awid),
        .s_awaddr_i      (s_axi_awaddr),
        .s_awlen_i       (s_axi_awlen),
        .s_awburst_i     (s_axi_awburst),
        .s_awvalid_i     (s_axi_awvalid & ~route_drc_aw),
        .s_awready_o     (s_dma_awready),

        .s_wdata_i       (s_axi_wdata),
        
        .s_wlast_i       (s_axi_wlast),
        .s_wvalid_i      (s_axi_dma_wvalid), // USING SAFE ROUTED SIGNAL
        .s_wready_o      (s_dma_wready),

        .s_bid_o         (s_dma_bid),
        .s_bresp_o       (s_dma_bresp),
        .s_bvalid_o      (s_dma_bvalid),
        .s_bready_i      (s_axi_dma_bready),

        .s_arid_i        (s_axi_arid),
        .s_araddr_i      (s_axi_araddr),
        .s_arlen_i       (s_axi_arlen),
        .s_arburst_i     (s_axi_arburst),
        .s_arvalid_i     (s_axi_arvalid & ~route_drc_ar),
        .s_arready_o     (s_dma_arready),

        .s_rid_o         (s_dma_rid),
        .s_rdata_o       (s_dma_rdata),
        .s_rresp_o       (s_dma_rresp),
        .s_rlast_o       (s_dma_rlast),
        .s_rvalid_o      (s_dma_rvalid),
        .s_rready_i      (s_axi_dma_rready),

        .s_tid_i         ({ID_W{1'b0}}),
        .s_tdest_i       (2'b0),
        .s_tdata_i       (axis_tdata),
        .s_tkeep_i       (axis_tkeep),
        .s_tstrb_i       (axis_tstrb),
        .s_tlast_i       (axis_tlast),
        .s_tvalid_i      (1'b0),
        .s_tready_o      (),

        .m_arid_o        (),
        .m_araddr_o      (),
        .m_arlen_o       (),
        .m_arburst_o     (),
        .m_arvalid_o     (),
        .m_arready_i     (1'b0),
        .m_rid_i         ({ID_W{1'b0}}),
        .m_rdata_i       ({DATA_W{1'b0}}),
        .m_rresp_i       (2'b0),
        .m_rlast_i       (1'b0),
        .m_rvalid_i      (1'b0),
        .m_rready_o      (),

        .m_awid_o        (m_axi_dma_awid),
        .m_awaddr_o      (m_axi_dma_awaddr),
        .m_awlen_o       (m_axi_dma_awlen),
        .m_awburst_o     (m_axi_dma_awburst),
        .m_awvalid_o     (m_axi_dma_awvalid),
        .m_awready_i     (m_axi_dma_awready),

        .m_wdata_o       (m_axi_dma_wdata),
        .m_wlast_o       (m_axi_dma_wlast),
        .m_wvalid_o      (m_axi_dma_wvalid),
        .m_wready_i      (m_axi_dma_wready),

        .m_bid_i         (m_axi_dma_bid),
        .m_bresp_i       (m_axi_dma_bresp),
        .m_bvalid_i      (m_axi_dma_bvalid),
        .m_bready_o      (m_axi_dma_bready),

        .m_tid_o         (),
        .m_tdest_o       (),
        .m_tdata_o       (),
        .m_tkeep_o       (),
        .m_tstrb_o       (),
        .m_tlast_o       (),
        .m_tvalid_o      (),
        .m_tready_i      (1'b1),

        .irq             (dma_irq),
        .trap            (dma_trap)
    );

endmodule
