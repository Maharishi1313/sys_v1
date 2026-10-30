module drc_cs_state_machine #(
    parameter DVP_DATA_W        = 8,
    parameter PXL_INFO_W        = DVP_DATA_W + 1 + 1,   // FIFO_W =  VSYNC + HSYNC + PIXEL_W
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
    // Forward (Half pixel data)
    output  [DVP_DATA_W-1:0]    fwd_hpxl_dat,   
    output                      fwd_hpxl_last,
    output                      fwd_hpxl_vld,
    input                       fwd_hpxl_rdy,
    // DRC CSRs  
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
    // Local parameters 
    // -- DRC State Machine
    localparam SLEEP_ST         = 3'd0;
    localparam IDLE_ST          = 3'd1; // IDLE state between frame transactions
    localparam PXL_ALIGN_ST     = 3'd2;
    localparam PXL_CAPTURE_ST   = 3'd3;
    localparam ERR_CORRECT_ST   = 3'd4;
    localparam STATE_W          = 3;
    // -- DRC mode
    localparam SLEEP_MODE       = 2'd0;
    localparam SINGLE_SHOT_MODE = 2'd1;
    localparam STREAM_MODE      = 2'd2;


    // Internal signals 
    // -- Wire  
    wire                    drc_slp_mode;   // DRC in sleep mode
    wire                    drc_sng_mode;   // DRC in single-shot mode
    wire                    drc_str_mode;   // DRC in stream mode
    wire                    bwd_pxl_vsync;
    wire                    bwd_pxl_hsync;
    wire [DVP_DATA_W-1:0]   bwd_pxl_data;
    wire                    bwd_pxl_hsk;    // Backward pixel handshaking
    wire                    bwd_pred_hsync;
    wire                    fwd_hpxl_hsk;    // Forward half-pixel handshaking
    wire                    w_cnt_wrap; // Width counter == img_width
    wire                    h_cnt_wrap; // Height counter == img_height
    reg [STATE_W-1:0]       drc_st_d;
    reg                     pxl_ack_d;   // 
    reg [IMG_DIM_W-1:0]     w_cnt_d;  // Width counter
    reg [IMG_DIM_W-1:0]     h_cnt_d;  // Heigth counter
    reg [IMG_DIM_W*2-1:0]   pxl_cnt_d;
    reg                     int_hpxl_vld;
    reg                     int_pxl_info_rdy;
    reg                     int_start_qed;  // Start-signal is queued
    reg                     int_irq;
    reg                     int_trap;
    
    // -- Flip-flop
    reg [STATE_W-1:0]       drc_st_q;
    reg                     pxl_ack_q;// 1 pixel is acknownledged completely (because DVP data width is 8bit only, the RGB pixel width is upto 16bit) 
    reg [IMG_DIM_W-1:0]     w_cnt_q;  // Width counter
    reg [IMG_DIM_W-1:0]     h_cnt_q;  // Height counter
    reg [IMG_DIM_W*2-1:0]   pxl_cnt_q;

    assign irq              = int_irq; 
    assign trap             = int_trap;
    assign cam_rx_state     = drc_st_q;
    assign cam_rx_len       = pxl_cnt_d;
    assign cam_rx_start_qed = int_start_qed;
    assign bwd_pxl_info_rdy = int_pxl_info_rdy;
    assign bwd_pxl_hsk      = bwd_pxl_info_vld & bwd_pxl_info_rdy;
    assign fwd_hpxl_dat     = bwd_pxl_data;
    assign fwd_hpxl_last    = h_cnt_wrap;   // Assert when height is wrapped (reach limitation)
    assign fwd_hpxl_vld     = int_hpxl_vld;    
    assign fwd_hpxl_hsk     = fwd_hpxl_vld & fwd_hpxl_rdy;
    assign {bwd_pxl_vsync, bwd_pxl_hsync, bwd_pxl_data} = bwd_pxl_info_dat;
    assign bwd_pred_hsync   = (~|w_cnt_q) & (~pxl_ack_q); // (The first pixel in a row) & (The first half pixel in a entire pixel)
    assign w_cnt_wrap   = ~|(w_cnt_q^(img_width-1'b1));
    assign h_cnt_wrap   = ~|(h_cnt_q^(img_height-1'b1));
    assign drc_slp_mode = ~|(cam_rx_mode^SLEEP_MODE);
    assign drc_sng_mode = ~|(cam_rx_mode^SINGLE_SHOT_MODE);
    assign drc_str_mode = ~|(cam_rx_mode^STREAM_MODE);
    
    always @(*) begin
        drc_st_d            = drc_st_q;
        w_cnt_d             = w_cnt_q;
        h_cnt_d             = h_cnt_q;
        pxl_cnt_d           = pxl_cnt_q;
        pxl_ack_d           = pxl_ack_q;
        int_pxl_info_rdy    = 1'b0;
        int_hpxl_vld        = 1'b0;
        int_start_qed       = 1'b0;
        int_irq             = 1'b0;
        int_trap            = 1'b0;
        case(drc_st_q)
            SLEEP_ST: begin
                int_pxl_info_rdy = 1'b1;    // Skip all pixels
                if(cam_rx_en & cam_rx_start & (~drc_slp_mode)) begin
                    drc_st_d = PXL_ALIGN_ST;
                    int_start_qed = drc_sng_mode;    // Pop the start-signal queue when DRC is in single-shot mode ONLY (Do not pop if in stream mode)
                end
            end
            PXL_ALIGN_ST: begin
                /*
                - Skip (fake handshaking) all inter-pixels until the start pixel of the frame is valid
                */
                int_pxl_info_rdy = 1'b1; // Fake handshaking
                if(bwd_pxl_vsync & bwd_pxl_info_vld) begin  // Start pixel is valid
                    drc_st_d = PXL_CAPTURE_ST;
                    int_pxl_info_rdy = 1'b0; // Deassert pop signal
                    // Reset all counters
                    w_cnt_d = {IMG_DIM_W{1'b0}};
                    h_cnt_d = {IMG_DIM_W{1'b0}};
                    pxl_cnt_d = {(IMG_DIM_W*2){1'b0}};
                    pxl_ack_d = 1'b0;
                end
            end
            PXL_CAPTURE_ST: begin
                /*
                - Capture the pixels until 1 frame is received completely
                - Compare the reference HSYNC with predicted HSYNC -> To check pixel misalignment 
                */
                int_pxl_info_rdy = fwd_hpxl_rdy;
                int_hpxl_vld     = bwd_pxl_info_vld;
                if(bwd_pxl_hsk) begin
                    pxl_ack_d = ~pxl_ack_q;
                    if(pxl_ack_q) begin // Update counters 
                        w_cnt_d = w_cnt_wrap ? {IMG_DIM_W{1'b0}} : w_cnt_q + 1'b1;
                        h_cnt_d = w_cnt_wrap ? (h_cnt_wrap ? {IMG_DIM_W{1'b0}} : h_cnt_q + 1'b1) : h_cnt_q;
                        pxl_cnt_d = (w_cnt_wrap & h_cnt_wrap) ? {(IMG_DIM_W*2){1'b0}} : pxl_cnt_q + 1'b1;
                    end
                    if(bwd_pxl_hsync ^ bwd_pred_hsync) begin   // reference HSYNC != predicted HSYNC -> Error
                        drc_st_d = ERR_CORRECT_ST;
                        int_trap = irq_msk_frm_err;    // Assert Trap signal (1 cycle) if this interrupt is enable
                    end
                    else begin  // The current frame is received successfully
                        if(pxl_ack_q & w_cnt_wrap & h_cnt_wrap) begin   // End of a frame - (second half pixel) & (end of row) & (end of col)
                            drc_st_d = IDLE_ST;
                            int_irq  = irq_msk_frm_comp;    // Assert interrupt signal (1 cycle) if this interrupt is enable
                        end
                    end
                end
            end
            IDLE_ST: begin
                /*
                - Check if the capturing is enable/disable 
                */
                if(cam_rx_en & cam_rx_start & (~drc_slp_mode)) begin    // Has new start-signal in the queue
                    drc_st_d = PXL_CAPTURE_ST;
                    int_start_qed = drc_sng_mode;    // Pop the start-signal queue when DRC is in single-shot mode ONLY (Do not pop if in stream mode)
                end
                else begin // The capturing is disable or No more start-signal in the queue
                    drc_st_d = SLEEP_ST;
                end
            end
            ERR_CORRECT_ST: begin
                /*
                - Pop redundant pixel in the pixel buffer (DVP pixel FIFO)
                - Sending fake pixel to the DMA to complete the current DMA transfer 
                */
                int_pxl_info_rdy = 1'b1;    // Always assert to skip redundant pixels
                int_hpxl_vld     = 1'b1;    // Always assert to send fake pixels to DMA
                if(fwd_hpxl_hsk) begin  // Counter number of fordward pixels
                    pxl_ack_d = ~pxl_ack_q;
                    if(pxl_ack_q) begin // Update counters 
                        w_cnt_d = w_cnt_wrap ? {IMG_DIM_W{1'b0}} : w_cnt_q + 1'b1;
                        h_cnt_d = w_cnt_wrap ? (h_cnt_wrap ? {IMG_DIM_W{1'b0}} : h_cnt_q + 1'b1) : h_cnt_q;
                    end
                    drc_st_d = (pxl_ack_q & w_cnt_wrap & h_cnt_wrap) ? PXL_ALIGN_ST : drc_st_q;    // Transit to PIXEL_ALIGN state when sending all fake pixels to DMA 
                end
            end
            default: begin
                
            end
        endcase
    end

    // Flip-flop
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            drc_st_q    <= SLEEP_ST;
            w_cnt_q     <= {IMG_DIM_W{1'b0}};
            h_cnt_q     <= {IMG_DIM_W{1'b0}};
            pxl_cnt_q   <= {(IMG_DIM_W*2){1'b0}};
            pxl_ack_q   <= 1'b0;
        end 
        else begin
            drc_st_q    <= drc_st_d;
            w_cnt_q     <= w_cnt_d;
            pxl_cnt_q   <= pxl_cnt_d;
            h_cnt_q     <= h_cnt_d;
            pxl_ack_q   <= pxl_ack_d;
        end
    end
endmodule
