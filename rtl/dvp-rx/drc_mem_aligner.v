module drc_mem_aligner #(
    parameter I_PXL_W       = 16,   // Input pixel width
    parameter AXIS_DATA_W   = 256,
    parameter AXIS_TID_W    = 2,
    parameter AXIS_BYTE_AMT = AXIS_DATA_W/8  
) (
    input                       aclk,
    input                       aresetn,
    // Pixel (backward)
    input   [I_PXL_W-1:0]       i_pxl_dat,
    input                       i_pxl_last,
    input                       i_pxl_vld,
    output                      i_pxl_rdy,
    // AXI Stream Master interface (forward)
    output [AXIS_TID_W-1:0]     tid,    // Not-use
    output                      tdest,  // Not-use
    output [AXIS_DATA_W-1:0]    tdata,
    output                      tvalid,
    output [AXIS_BYTE_AMT-1:0]  tkeep,  // All bytes is valid
    output [AXIS_BYTE_AMT-1:0]  tstrb,  // All bytes is valid
    output                      tlast,  // Assert when last pixel of the frame is sent
    input                       tready
);
    // Internal signal
    wire    i_pxl_hsk;
    wire    axis_hsk;
    reg     last_pxl_flg;

    // Module instantiation
    sync_fifo #(
        .FIFO_TYPE      (3),        // Upsizer FIFO
        .DATA_WIDTH     (AXIS_DATA_W),
        .IN_DATA_WIDTH  (I_PXL_W)
    ) aligner (
        .clk            (aclk),
        .data_i         (i_pxl_dat),
        .wr_valid_i     (i_pxl_vld),
        .wr_ready_o     (i_pxl_rdy),
        .data_o         (tdata),
        .rd_ready_o     (tvalid),
        .rd_valid_i     (tready),
        .empty_o        (),
        .full_o         (),
        .almost_empty_o (),
        .almost_full_o  (),
        .counter        (),
        .rst_n          (aresetn)
    );
    // Connection
    assign tid      = 1'b0;
    assign tdest    = 1'b0;
    assign tkeep    = {AXIS_BYTE_AMT{1'b1}};
    assign tstrb    = {AXIS_BYTE_AMT{1'b1}};
    assign tlast    = last_pxl_flg;
    assign i_pxl_hsk= i_pxl_vld & i_pxl_rdy;
    assign axis_hsk = tvalid & tready;
    always @(posedge aclk or negedge aresetn) begin
        if(~aresetn) begin
            last_pxl_flg <= 1'b0;
        end
        else begin
            if(last_pxl_flg) begin  // Last pixel is in buffer now
                last_pxl_flg <= ~axis_hsk;  // Deassert when the pixels group, which contains last pixel, is sent via AXIS 
            end
            else if(i_pxl_hsk) begin 
                last_pxl_flg <= i_pxl_last; // Receive the last pixel
            end
        end
    end
endmodule