// =============================================================================
// dvp_rx_core.v
//
// DVP RX core - stripped from dvp_rx_controller.v.
// v1.3 changes:
//   - Added DRC_BASE_ADDR parameter to allow configurable base address.
// =============================================================================
module dvp_rx_core #(
    // System
    parameter INTERNAL_CLK      = 100_000_000,
    parameter DRC_BASE_ADDR     = 32'h6000_0020, // Configurable Base Address
    // AXI4 Slave config interface (from CPU)
    parameter S_DATA_W          = 32,
    parameter S_ADDR_W          = 32,
    parameter MST_ID_W          = 4,
    parameter ATX_LEN_W         = 8,
    parameter ATX_SIZE_W        = 3,
    parameter ATX_RESP_W        = 2,
    // DVP
    parameter DVP_DATA_W        = 8,
    parameter DVP_FIFO_D        = 4,
    parameter DVP_CAPTURE_TYPE  = "PCLK_EDGE",
    // Image geometry
    parameter FRM_COL_NUM       = 56,
    parameter FRM_ROW_NUM       = 56,
    parameter DOWNSCALE_TYPE    = "AVR-POOLING",
    // AXI-Stream output width (must match SoC DMA bus width)
    parameter AXIS_DATA_W       = 32,
    // Derived
    parameter PROC_PXL_W        = 16,
    parameter IMG_DIM_MAX       = (FRM_COL_NUM > FRM_ROW_NUM) ? FRM_COL_NUM : FRM_ROW_NUM,
    parameter IMG_DIM_W         = $clog2(IMG_DIM_MAX)
) (
    input                       clk,
    input                       rst_n,

    // -------------------------------------------------------------------------
    // DVP camera interface
    // -------------------------------------------------------------------------
    input  [DVP_DATA_W-1:0]     dvp_d_i,
    input                       dvp_href_i,
    input                       dvp_vsync_i,
    input                       dvp_hsync_i,
    input                       dvp_pclk_i,

    output                      dvp_xclk_o,
    output                      dvp_pwdn_o,

    // -------------------------------------------------------------------------
    // AXI4 Slave – DRC register map only (CPU configuration)
    // -------------------------------------------------------------------------
    input  [MST_ID_W-1:0]       s_awid_i,
    input  [S_ADDR_W-1:0]       s_awaddr_i,
    input  [1:0]                s_awburst_i,
    input  [ATX_LEN_W-1:0]      s_awlen_i,
    input                       s_awvalid_i,
    output                      s_awready_o,
    input  [S_DATA_W-1:0]       s_wdata_i,
    input                       s_wlast_i,
    input                       s_wvalid_i,
    output                      s_wready_o,
    output [MST_ID_W-1:0]       s_bid_o,
    output [ATX_RESP_W-1:0]     s_bresp_o,
    output                      s_bvalid_o,
    input                       s_bready_i,
    input  [MST_ID_W-1:0]       s_arid_i,
    input  [S_ADDR_W-1:0]       s_araddr_i,
    input  [1:0]                s_arburst_i,
    input  [ATX_LEN_W-1:0]      s_arlen_i,
    input                       s_arvalid_i,
    output                      s_arready_o,
    output [MST_ID_W-1:0]       s_rid_o,
    output [S_DATA_W-1:0]       s_rdata_o,
    output [ATX_RESP_W-1:0]     s_rresp_o,
    output                      s_rlast_o,
    output                      s_rvalid_o,
    input                       s_rready_i,

    // -------------------------------------------------------------------------
    // AXI-Stream Master output – goes directly to SoC DMA source port
    // -------------------------------------------------------------------------
    output [AXIS_DATA_W-1:0]     m_axis_tdata,
    output                       m_axis_tvalid,
    output [(AXIS_DATA_W/8)-1:0] m_axis_tkeep,
    output [(AXIS_DATA_W/8)-1:0] m_axis_tstrb,
    output                       m_axis_tlast,
    input                        m_axis_tready,

    // -------------------------------------------------------------------------
    // Interrupts / traps
    // -------------------------------------------------------------------------
    output                      drc_irq,   // frame capture complete
    output                      drc_trap   // pixel misalignment
);

    // Local parameters
    localparam RGB_PXL_W  = 16;
    localparam GS_PXL_W   = 8;
    localparam PXL_INFO_W = 1 + 1 + DVP_DATA_W;

    // Internal wires
    wire                        cam_rx_en;
    wire                        cam_pwdn;
    wire [1:0]                  cam_rx_mode;
    wire                        cam_rx_start;
    wire                        cam_rx_start_qed;
    wire [2:0]                  cam_rx_state;
    wire [IMG_DIM_W*2-1:0]      cam_rx_len;
    wire                        irq_msk_frm_comp;
    wire                        irq_msk_frm_err;
    wire [IMG_DIM_W-1:0]        img_width;
    wire [IMG_DIM_W-1:0]        img_height;

    wire                        pxl_grayscale;
    wire                        frm_downscale;

    wire [PXL_INFO_W-1:0]       pxl_info_dat;
    wire                        pxl_info_vld;
    wire                        pxl_info_rdy;

    wire [RGB_PXL_W-1:0]        rgb_pxl_dat;
    wire                        rgb_pxl_last;
    wire                        rgb_pxl_vld;
    wire                        rgb_pxl_rdy;

    wire [PROC_PXL_W-1:0]       proc_pxl_dat;
    wire                        proc_pxl_last;
    wire                        proc_pxl_vld;
    wire                        proc_pxl_rdy;

    wire [MST_ID_W-1:0]         int_tid;
    wire                        int_tdest;

    // -- XCLK Generator -------------------------------------------------------
    drc_xclk_gen #(
        .INTL_CLK_PERIOD (INTERNAL_CLK)
    ) u_xclk (
        .clk        (clk),
        .rst_n      (rst_n),
        .cam_rx_en  (cam_rx_en),
        .cam_pwdn   (cam_pwdn),
        .dvp_xclk_o (dvp_xclk_o),
        .dvp_pwdn_o (dvp_pwdn_o)
    );

    // -- DVP Data FIFO --------------------------------------------------------
    drc_dvp_data_fifo #(
        .DVP_DATA_W       (DVP_DATA_W),
        .DVP_CAPTURE_TYPE (DVP_CAPTURE_TYPE),
        .PXL_INFO_W       (PXL_INFO_W),
        .PXL_FIFO_D       (DVP_FIFO_D)
    ) u_fifo (
        .clk          (clk),
        .rst_n        (rst_n),
        .cam_rx_en    (cam_rx_en),
        .dvp_d_i      (dvp_d_i),
        .dvp_href_i   (dvp_href_i),
        .dvp_vsync_i  (dvp_vsync_i),
        .dvp_hsync_i  (dvp_hsync_i),
        .dvp_pclk_i   (dvp_pclk_i),
        .pxl_info_dat (pxl_info_dat),
        .pxl_info_vld (pxl_info_vld),
        .pxl_info_rdy (pxl_info_rdy)
    );

    // -- Control State (FSM + Pixel Merger) -----------------------------------
    drc_ctrl_state #(
        .DVP_DATA_W   (DVP_DATA_W),
        .PXL_INFO_W   (PXL_INFO_W),
        .RGB_PXL_W    (RGB_PXL_W),
        .IMG_DIM_MAX  (IMG_DIM_MAX),
        .IMG_DIM_W    (IMG_DIM_W)
    ) u_ctrl (
        .clk                (clk),
        .rst_n              (rst_n),
        .bwd_pxl_info_dat   (pxl_info_dat),
        .bwd_pxl_info_vld   (pxl_info_vld),
        .bwd_pxl_info_rdy   (pxl_info_rdy),
        .fwd_pxl_dat        (rgb_pxl_dat),
        .fwd_pxl_last       (rgb_pxl_last),
        .fwd_pxl_vld        (rgb_pxl_vld),
        .fwd_pxl_rdy        (rgb_pxl_rdy),
        .cam_rx_en          (cam_rx_en),
        .cam_rx_mode        (cam_rx_mode),
        .cam_rx_start       (cam_rx_start),
        .cam_rx_start_qed   (cam_rx_start_qed),
        .cam_rx_state       (cam_rx_state),
        .cam_rx_len         (cam_rx_len),
        .irq_msk_frm_comp   (irq_msk_frm_comp),
        .irq_msk_frm_err    (irq_msk_frm_err),
        .img_width          (img_width),
        .img_height         (img_height),
        .irq                (drc_irq),
        .trap               (drc_trap)
    );

    // -- DRC Register Map -----------------------------------------------------
    drc_regmap_mod #(
        .DRC_BASE_ADDR (DRC_BASE_ADDR),
        .S_DATA_W      (S_DATA_W),
        .S_ADDR_W      (S_ADDR_W),
        .MST_ID_W      (MST_ID_W),
        .ATX_LEN_W     (ATX_LEN_W),
        .ATX_SIZE_W    (ATX_SIZE_W),
        .ATX_RESP_W    (ATX_RESP_W),
        .IMG_DIM_MAX   (IMG_DIM_MAX),
        .IMG_DIM_W     (IMG_DIM_W)
    ) u_regmap (
        .aclk               (clk),
        .aresetn            (rst_n),
        .s_awid_i           (s_awid_i),
        .s_awaddr_i         (s_awaddr_i),
        .s_awburst_i        (s_awburst_i),
        .s_awlen_i          (s_awlen_i),
        .s_awvalid_i        (s_awvalid_i),
        .s_awready_o        (s_awready_o),
        .s_wdata_i          (s_wdata_i),
        .s_wlast_i          (s_wlast_i),
        .s_wvalid_i         (s_wvalid_i),
        .s_wready_o         (s_wready_o),
        .s_bid_o            (s_bid_o),
        .s_bresp_o          (s_bresp_o),
        .s_bvalid_o         (s_bvalid_o),
        .s_bready_i         (s_bready_i),
        .s_arid_i           (s_arid_i),
        .s_araddr_i         (s_araddr_i),
        .s_arburst_i        (s_arburst_i),
        .s_arlen_i          (s_arlen_i),
        .s_arvalid_i        (s_arvalid_i),
        .s_arready_o        (s_arready_o),
        .s_rid_o            (s_rid_o),
        .s_rdata_o          (s_rdata_o),
        .s_rresp_o          (s_rresp_o),
        .s_rlast_o          (s_rlast_o),
        .s_rvalid_o         (s_rvalid_o),
        .s_rready_i         (s_rready_i),
        .cam_rx_en          (cam_rx_en),
        .cam_pwdn           (cam_pwdn),
        .cam_rx_mode        (cam_rx_mode),
        .cam_rx_start       (cam_rx_start),
        .cam_rx_start_qed   (cam_rx_start_qed),
        .cam_rx_state       (cam_rx_state),
        .cam_rx_len         (cam_rx_len),
        .irq_msk_frm_comp   (irq_msk_frm_comp),
        .irq_msk_frm_err    (irq_msk_frm_err),
        .img_width          (img_width),
        .img_height         (img_height),
        .pxl_grayscale      (pxl_grayscale),
        .frm_downscale      (frm_downscale)
    );

    // -- Resizer --------------------------------------------------------------
    drc_resizer_mod #(
        .FRM_COL_NUM    (FRM_COL_NUM),
        .FRM_ROW_NUM    (FRM_ROW_NUM),
        .DOWNSCALE_TYPE (DOWNSCALE_TYPE),
        .RGB_PXL_W      (RGB_PXL_W),
        .GS_PXL_W       (GS_PXL_W)
    ) u_resize (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_pxl_dat     (rgb_pxl_dat),
        .i_pxl_last    (rgb_pxl_last),
        .i_pxl_vld     (rgb_pxl_vld),
        .i_pxl_rdy     (rgb_pxl_rdy),
        .o_pxl_dat     (proc_pxl_dat),
        .o_pxl_last    (proc_pxl_last),
        .o_pxl_vld     (proc_pxl_vld),
        .o_pxl_rdy     (proc_pxl_rdy),
        .pxl_grayscale (pxl_grayscale),
        .frm_downscale (frm_downscale)
    );

    // -- Memory Aligner -------------------------------------------------------
    drc_mem_aligner #(
        .I_PXL_W     (PROC_PXL_W),
        .AXIS_DATA_W (AXIS_DATA_W),
        .AXIS_TID_W  (MST_ID_W)
    ) u_align (
        .aclk       (clk),
        .aresetn    (rst_n),
        .i_pxl_dat  (proc_pxl_dat),
        .i_pxl_last (proc_pxl_last),
        .i_pxl_vld  (proc_pxl_vld),
        .i_pxl_rdy  (proc_pxl_rdy),
        .tid        (int_tid),
        .tdest      (int_tdest),
        .tdata      (m_axis_tdata),
        .tvalid     (m_axis_tvalid),
        .tkeep      (m_axis_tkeep),
        .tstrb      (m_axis_tstrb),
        .tlast      (m_axis_tlast),
        .tready     (m_axis_tready)
    );

endmodule
