module drc_ctrl_state #(
    parameter DVP_DATA_W        = 8,
    parameter PXL_INFO_W        = DVP_DATA_W + 1 + 1,   // FIFO_W =  VSYNC + HSYNC + PIXEL_W
    parameter RGB_PXL_W         = 16,
    // Image configure
    parameter IMG_DIM_MAX       = 640,
    parameter IMG_DIM_W         = $clog2(IMG_DIM_MAX)
) (
    // -- Global
    input                       clk,
    input                       rst_n,
    // Backward
    input   [PXL_INFO_W-1:0]    bwd_pxl_info_dat,
    input                       bwd_pxl_info_vld,
    output                      bwd_pxl_info_rdy,
    // Forward
    output  [RGB_PXL_W-1:0]     fwd_pxl_dat,
    output                      fwd_pxl_last,
    output                      fwd_pxl_vld,
    input                       fwd_pxl_rdy,
    // -- DRC CSRs  
    input                       cam_rx_en,      // Enable camera RX
    input   [1:0]               cam_rx_mode,    // Camera RX mode
    input                       cam_rx_start,   // Start camera RX
    output                      cam_rx_start_qed,// Start signal is queued
    output  [2:0]               cam_rx_state,   // Camera RX state
    output  [IMG_DIM_W*2-1:0]   cam_rx_len,     // Camera RX pixel length
    input                       irq_msk_frm_comp, // IRQ mask Frame completion
    input                       irq_msk_frm_err,  // IRQ mask Frame error
    input   [IMG_DIM_W-1:0]     img_width,      // Image width
    input   [IMG_DIM_W-1:0]     img_height,     // Image height
    // Interrupt
    output                      irq, // Caused by frame completion
    output                      trap // Caused by pixel misalignment
);
    // Internal signal
    // Forward (Half pixel data)
    wire [DVP_DATA_W-1:0]   mid_hpxl_dat;   
    wire                    mid_hpxl_last;
    wire                    mid_hpxl_vld;
    wire                    mid_hpxl_rdy;
    wire                    fwd_pxl_last_1; // From first half of a pixel
    wire                    fwd_pxl_last_2; // From second half of a pixel
    // Module instantiation
    // -- DRC State Machine
    drc_cs_state_machine #(
        .DVP_DATA_W         (DVP_DATA_W),
        .PXL_INFO_W         (PXL_INFO_W),
        .IMG_DIM_MAX        (IMG_DIM_MAX),
        .IMG_DIM_W          (IMG_DIM_W)
    ) sm (
        .clk                (clk),
        .rst_n              (rst_n),
        .bwd_pxl_info_dat   (bwd_pxl_info_dat),
        .bwd_pxl_info_vld   (bwd_pxl_info_vld),
        .bwd_pxl_info_rdy   (bwd_pxl_info_rdy),

        .fwd_hpxl_dat       (mid_hpxl_dat),
        .fwd_hpxl_last      (mid_hpxl_last),
        .fwd_hpxl_vld       (mid_hpxl_vld),
        .fwd_hpxl_rdy       (mid_hpxl_rdy),

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
        .irq                (irq),
        .trap               (trap)
    ); 
    // -- Pixel Merger
    sync_fifo 
    #(
        .FIFO_TYPE          (3),            // Concat FIFO
        .DATA_WIDTH         ((1 + DVP_DATA_W) + (1 + DVP_DATA_W)),  // Output data width: Last[1] + Data[1] + Last[0] + Data[0]
        .IN_DATA_WIDTH      (1 + DVP_DATA_W),                       // Input data width:  Last + Data
        .CONCAT_ORDER       ("MSB")
    ) pm (
        .clk                (clk),
        .data_i             ({mid_hpxl_last, mid_hpxl_dat}),
        .wr_valid_i         (mid_hpxl_vld),
        .wr_ready_o         (mid_hpxl_rdy),

        .data_o             ({fwd_pxl_last_2, fwd_pxl_dat[RGB_PXL_W-1-:DVP_DATA_W], fwd_pxl_last_1, fwd_pxl_dat[DVP_DATA_W-1:0]}),
        .rd_ready_o         (fwd_pxl_vld),
        .rd_valid_i         (fwd_pxl_rdy),
        .empty_o            (),
        .full_o             (),
        .almost_empty_o     (),
        .almost_full_o      (),
        .counter            (),
        .rst_n              (rst_n)
    );
    assign fwd_pxl_last = fwd_pxl_last_1 | fwd_pxl_last_2; 
endmodule
