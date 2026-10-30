`timescale 1ns / 1ps

// =============================================================================
//  sys_csr : system control / status registers  (AXI slave S5, base 0xA000_0000)
//
//  Offset       Name         Access  Fields
//  0x0000       CTRL         W       [7:0] number of layers -> starts one inference
//                                     (forwarded to sys_controller START)
//                            R       [7:0] layers of the last start
//  0x0004       STATUS       R       [0] busy  [1] done (sticky)  [2] result valid
//                                    [8] DVP-RX trap  [9] DVP-DMA trap  [10] sys-DMA trap
//                                    [23:16] current layer   [31:24] current pass
//  0x0008       IRQ          R/W1C   [0] done   (host_irq = done & IRQ_EN[0])
//  0x000C       IRQ_EN       RW      [0] done-irq enable (reset 1)
//  0x0010       RESULT       R       [15:0] class id  [31] valid
//  0x0014       SCORE        R       winning class score (sum of its int8 outputs)
//  0x0018       HEAD_CFG     RW      [15:0] classes (0 = no classifier head)
//                                    [31:16] 32-bit words per class map
//  0x001C       HEAD_BASE    RW      byte offset of class 0 inside the output bank
//  0x0020       PIN_CFG      RW      [0] drive result_o / result_valid_o pins (reset 1)
//  0x0024       ID           R       0x5A_CE_0001
//  Camera front end (cam_frontend) - static while an inference runs:
//  0x0040       CAM_FRAME    RW      {height[31:16], width[15:0]} of the sensor frame (320x240)
//  0x0044       CAM_CROP_XY  RW      {y0, x0} of the crop window            (reset 8, 48)
//  0x0048       CAM_CROP_WH  RW      {h, w} of the crop window, w % 4 == 0   (reset 224, 224)
//  0x004C       CAM_MODE     RW      [0] 1 = raw bytes, 0 = RGB565 -> R/G/B row planes
//  0x0050       CAM_BUF      RW      AXI byte address of stripe slot 0
//  0x0054       CAM_SLOT     RW      bytes between stripe slots
//  0x0058       CAM_STRIPE   RW      {slots[31:24], halo rows[23:16], rows per stripe[15:0]}
//  0x005C       CAM_ROWSTR   RW      [15:0] bytes between rows in a slot
//  0x0060       CAM_STATUS   R       [15:0] rows written  [30] frame done  [31] overrun
//  STATUS[11] = camera overrun (sticky until the next START)
//  0x1_0000 +   DESCRIPTORS  W       layer*64 + word*4  (forwarded to sys_controller)
// =============================================================================
module sys_csr #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 6
)(
    input  logic              clk,
    input  logic              rst_n,

    // AXI4 slave (single-beat accesses)
    input  logic [ID_W-1:0]   s_awid,
    input  logic [ADDR_W-1:0] s_awaddr,
    input  logic              s_awvalid,
    output logic              s_awready,
    input  logic [DATA_W-1:0] s_wdata,
    input  logic              s_wvalid,
    output logic              s_wready,
    output logic [ID_W-1:0]   s_bid,
    output logic [1:0]        s_bresp,
    output logic              s_bvalid,
    input  logic              s_bready,
    input  logic [ID_W-1:0]   s_arid,
    input  logic [ADDR_W-1:0] s_araddr,
    input  logic              s_arvalid,
    output logic              s_arready,
    output logic [ID_W-1:0]   s_rid,
    output logic [DATA_W-1:0] s_rdata,
    output logic [1:0]        s_rresp,
    output logic              s_rlast,
    output logic              s_rvalid,
    input  logic              s_rready,

    // to sys_controller (descriptor SRAM / start register)
    output logic              cfg_we,
    output logic [ADDR_W-1:0] cfg_addr,
    output logic [31:0]       cfg_wdata,
    output logic [15:0]       head_classes,
    output logic [15:0]       head_words,
    output logic [31:0]       head_base,

    // status from the system
    input  logic              busy,
    input  logic              infer_done,      // 1-cycle pulse
    input  logic              result_valid,
    input  logic [15:0]       result_class,
    input  logic [31:0]       result_score,
    input  logic [7:0]        cur_layer,
    input  logic [7:0]        cur_pass,
    input  logic [2:0]        traps,           // {sys-DMA, DVP-DMA, DVP-RX}

    // camera front end
    output logic [15:0]       cam_frame_w, cam_frame_h,
    output logic [15:0]       cam_x0, cam_y0, cam_w, cam_h,
    output logic              cam_raw,
    output logic [31:0]       cam_buf, cam_slot,
    output logic [15:0]       cam_adv, cam_rowstr,
    output logic [7:0]        cam_halo, cam_slots,
    input  logic [15:0]       cam_rows_done,
    input  logic              cam_frame_done,
    input  logic              cam_overrun,

    output logic              host_irq,
    output logic              pins_en
);
    logic [7:0]  ctrl_layers;
    logic        done, irq_en;
    logic [2:0]  trap_sticky;

    // ------------------------------------------------------------ write path
    logic              aw_have, w_have;
    logic [ADDR_W-1:0] aw_addr;
    logic [DATA_W-1:0] w_data;

    assign s_awready = !aw_have && !s_bvalid;
    assign s_wready  = !w_have  && !s_bvalid;
    assign s_bresp   = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_have <= 1'b0; w_have <= 1'b0; aw_addr <= '0; w_data <= '0;
            s_bvalid <= 1'b0; s_bid <= '0;
            cfg_we <= 1'b0; cfg_addr <= '0; cfg_wdata <= '0;
            ctrl_layers <= '0; done <= 1'b0; irq_en <= 1'b1; pins_en <= 1'b1;
            head_classes <= '0; head_words <= '0; head_base <= '0; trap_sticky <= '0;
            cam_frame_w <= 16'd320; cam_frame_h <= 16'd240;
            cam_x0 <= 16'd48; cam_y0 <= 16'd8; cam_w <= 16'd224; cam_h <= 16'd224;
            cam_raw <= 1'b0; cam_buf <= 32'h6000_0000; cam_slot <= '0;
            cam_adv <= 16'd224; cam_rowstr <= 16'd672; cam_halo <= '0; cam_slots <= 8'd1;
        end else begin
            cfg_we <= 1'b0;
            if (s_awvalid && s_awready) begin aw_have <= 1'b1; aw_addr <= s_awaddr; s_bid <= s_awid; end
            if (s_wvalid  && s_wready)  begin w_have  <= 1'b1; w_data  <= s_wdata; end
            if (s_bvalid && s_bready) s_bvalid <= 1'b0;

            if (infer_done) done <= 1'b1;
            trap_sticky <= trap_sticky | traps;

            if (aw_have && w_have) begin
                aw_have  <= 1'b0;
                w_have   <= 1'b0;
                s_bvalid <= 1'b1;
                if (aw_addr[16]) begin                          // descriptor window
                    cfg_we <= 1'b1; cfg_addr <= aw_addr; cfg_wdata <= w_data;
                end else begin
                    case (aw_addr[7:0])
                    8'h00: begin
                        ctrl_layers <= w_data[7:0];
                        cfg_we <= 1'b1; cfg_addr <= aw_addr; cfg_wdata <= w_data;
                        done   <= 1'b0;
                    end
                    8'h08: if (w_data[0]) done <= 1'b0;
                    8'h0C: irq_en <= w_data[0];
                    8'h18: begin head_classes <= w_data[15:0]; head_words <= w_data[31:16]; end
                    8'h1C: head_base <= w_data;
                    8'h20: pins_en <= w_data[0];
                    8'h40: begin cam_frame_w <= w_data[15:0]; cam_frame_h <= w_data[31:16]; end
                    8'h44: begin cam_x0 <= w_data[15:0]; cam_y0 <= w_data[31:16]; end
                    8'h48: begin cam_w  <= w_data[15:0]; cam_h  <= w_data[31:16]; end
                    8'h4C: cam_raw <= w_data[0];
                    8'h50: cam_buf <= w_data;
                    8'h54: cam_slot <= w_data;
                    8'h58: begin cam_adv <= w_data[15:0]; cam_halo <= w_data[23:16]; cam_slots <= w_data[31:24]; end
                    8'h5C: cam_rowstr <= w_data[15:0];
                    default: ;
                    endcase
                end
            end
        end
    end

    assign host_irq = done & irq_en;

    // ------------------------------------------------------------ read path
    assign s_rresp = 2'b00;
    assign s_rlast = 1'b1;
    assign s_arready = !s_rvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 1'b0; s_rdata <= '0; s_rid <= '0;
        end else begin
            if (s_rvalid && s_rready) s_rvalid <= 1'b0;
            if (s_arvalid && s_arready) begin
                s_rvalid <= 1'b1;
                s_rid    <= s_arid;
                case (s_araddr[7:0])
                8'h00: s_rdata <= {24'd0, ctrl_layers};
                8'h04: s_rdata <= {cur_pass, cur_layer, 4'd0, cam_overrun, trap_sticky, 5'd0, result_valid, done, busy};
                8'h08: s_rdata <= {31'd0, done};
                8'h0C: s_rdata <= {31'd0, irq_en};
                8'h10: s_rdata <= {result_valid, 15'd0, result_class};
                8'h14: s_rdata <= result_score;
                8'h18: s_rdata <= {head_words, head_classes};
                8'h1C: s_rdata <= head_base;
                8'h20: s_rdata <= {31'd0, pins_en};
                8'h24: s_rdata <= 32'h5ACE_0001;
                8'h40: s_rdata <= {cam_frame_h, cam_frame_w};
                8'h44: s_rdata <= {cam_y0, cam_x0};
                8'h48: s_rdata <= {cam_h, cam_w};
                8'h4C: s_rdata <= {31'd0, cam_raw};
                8'h50: s_rdata <= cam_buf;
                8'h54: s_rdata <= cam_slot;
                8'h58: s_rdata <= {cam_slots, cam_halo, cam_adv};
                8'h5C: s_rdata <= {16'd0, cam_rowstr};
                8'h60: s_rdata <= {cam_overrun, cam_frame_done, 14'd0, cam_rows_done};
                default: s_rdata <= '0;
                endcase
            end
        end
    end
endmodule
