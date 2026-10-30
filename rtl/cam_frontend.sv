`timescale 1ns / 1ps

// =============================================================================
//  cam_frontend : DVP pixel stream -> cropped, converted rows in activation memory
//
//  Input : AXI-Stream from dvp_rx_core, 2 pixels per 32-bit beat (pixel 0 = [15:0]),
//          pixel = {first DVP byte, second DVP byte} = RGB565 for the OV7670.
//  Output: AXI4 write master (INCR bursts <= 16 beats, never across a 64-byte line).
//
//  Only pixels inside the crop window (x0, y0, w, h) are kept.  Every kept row is
//  assembled in a line buffer and written as
//     mode 0 (RGB):  R[w] G[w] B[w]  - RGB565 -> RGB888 by bit replication, 3w bytes
//     mode 1 (RAW):  the DVP bytes in arrival order, 2w bytes
//  each byte XORed with 0x80 (uint8 -> int8, the accelerator's activation format).
//  In RGB mode a row is "row-planar": the conv1 feeder reads it with
//  chstep = w and ystep = row_stride, so no reordering of the frame is ever needed.
//
//  Rows go to stripe slots (row-streaming / Option A):
//     stripe s = rows [s*adv, s*adv + adv + halo)    slot = s mod nslots
//     row r of stripe s -> buf_base + slot*slot_stride + (r - s*adv)*row_stride
//  A row inside the halo of the previous stripe is written to both slots, so every
//  stripe is contiguous for the engine.  rows_done counts rows whose writes are all
//  acknowledged; the controller waits on it.  'consume' (one pulse per finished
//  stripe) frees a slot; a row that would land in a slot still in use is dropped and
//  raises 'overrun' (the camera is faster than the engine - lower the frame rate).
//  One frame per 'arm'.
// =============================================================================
module cam_frontend #(
    parameter ADDR_W = 32,
    parameter ID_W   = 4,
    parameter MAX_W  = 320              // widest row accepted (pixels)
)(
    input  logic              clk,
    input  logic              rst_n,

    // pixel stream
    input  logic [31:0]       s_tdata,
    input  logic              s_tvalid,
    output logic              s_tready,

    // configuration (static while armed)
    input  logic              arm,          // 1-cycle: reset, accept the next frame
    input  logic              mode_raw,
    input  logic [15:0]       frame_w,      // sensor row length in pixels
    input  logic [15:0]       crop_x0, crop_y0, crop_w, crop_h,
    input  logic [31:0]       buf_base,     // AXI byte address of slot 0
    input  logic [31:0]       slot_stride,  // bytes
    input  logic [15:0]       row_stride,   // bytes
    input  logic [15:0]       adv,          // rows per stripe advance
    input  logic [7:0]        halo,         // extra rows shared with the next stripe
    input  logic [7:0]        nslots,
    input  logic              consume,      // 1-cycle: the oldest unfinished stripe is done

    output logic [15:0]       rows_done,
    output logic              frame_done,
    output logic              overrun,

    // AXI4 write master
    output logic [ID_W-1:0]   m_awid,
    output logic [ADDR_W-1:0] m_awaddr,
    output logic [7:0]        m_awlen,
    output logic [2:0]        m_awsize,
    output logic [1:0]        m_awburst,
    output logic              m_awvalid,
    input  logic              m_awready,
    output logic [31:0]       m_wdata,
    output logic [3:0]        m_wstrb,
    output logic              m_wlast,
    output logic              m_wvalid,
    input  logic              m_wready,
    input  logic [1:0]        m_bresp,
    input  logic              m_bvalid,
    output logic              m_bready
);
    localparam LBW  = MAX_W / 2;                      // words per plane (RAW rows use plane 0 only)
    localparam LI_W = $clog2(LBW);

    assign m_awid = '0; assign m_awsize = 3'd2; assign m_awburst = 2'b01; assign m_wstrb = 4'hF;

    // ------------------------------------------------------------ pixel side
    logic        armed;
    logic        half;                                // 0: pixel 0 of the beat, 1: pixel 1
    logic [15:0] x, y;
    wire  [15:0] pix  = half ? s_tdata[31:16] : s_tdata[15:0];
    wire         take = armed && s_tvalid;            // a pixel is consumed this cycle
    wire         in_x = (x >= crop_x0) && (x < crop_x0 + crop_w);
    wire         in_y = (y >= crop_y0) && (y < crop_y0 + crop_h);
    wire  [15:0] cx   = x - crop_x0;
    assign s_tready = !armed || half;                 // 2 cycles per beat while armed

    // line buffers: fill one while the writer drains the other.  Three byte-enable word
    // planes (R, G, B) -> one byte write per plane per pixel, block-RAM friendly.
    logic [31:0] lb [0:1][0:2][0:LBW-1];
    logic        fill_sel;                            // buffer being filled
    logic [1:0]  lb_full;                             // row complete, waiting for the writer
    logic [15:0] lb_row  [0:1];                       // cropped row index held in the buffer

    wire [7:0] r8 = {pix[15:11], pix[15:13]};
    wire [7:0] g8 = {pix[10:5],  pix[10:9]};
    wire [7:0] b8 = {pix[4:0],   pix[4:2]};

    // ------------------------------------------------------------ writer side
    typedef enum logic [2:0] {WR_IDLE, WR_AW, WR_W, WR_B, WR_NEXT} wr_st_t;
    wr_st_t      wr_st;
    logic        wr_sel;                               // buffer being written out
    logic        wr_second;                            // writing the halo copy
    logic [31:0] wr_addr;                              // next burst address
    logic [15:0] wr_word, row_words;                   // word index in the row / row length
    logic [4:0]  beat, blen;
    logic [1:0]  rd_pl;                                // plane / word of the next beat
    logic [15:0] rd_off, plane_words;
    logic [15:0] s_cur, l_cur;                         // stripe / local row of the next row
    logic [7:0]  slot_cur;
    logic [15:0] consumed;
    logic        row_drop;

    wire  [7:0]  slot_prev = (slot_cur == 8'd0) ? nslots - 8'd1 : slot_cur - 8'd1;
    wire         has_halo_copy = (s_cur != 16'd0) && (16'(l_cur) < 16'(halo));
    wire  [15:0] row_bytes = mode_raw ? (crop_w << 1) : (crop_w * 16'd3);
    wire  [31:0] addr_first  = buf_base + 32'(slot_cur)  * slot_stride + 32'(l_cur)        * 32'(row_stride);
    wire  [31:0] addr_second = buf_base + 32'(slot_prev) * slot_stride + 32'(l_cur + adv)  * 32'(row_stride);
    // burst length: up to 16 words, never across a 64-byte line
    wire  [4:0]  to_line = 5'd16 - 5'(wr_addr[5:2]);
    wire  [15:0] left    = row_words - wr_word;
    wire  [4:0]  nlen    = (left < 16'(to_line)) ? 5'(left) : to_line;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 1'b0; half <= 1'b0; x <= '0; y <= '0;
            fill_sel <= 1'b0; lb_full <= '0; lb_row[0] <= '0; lb_row[1] <= '0;
            frame_done <= 1'b0; overrun <= 1'b0; rows_done <= '0;
            wr_st <= WR_IDLE; wr_sel <= 1'b0; wr_second <= 1'b0; wr_addr <= '0; wr_word <= '0;
            row_words <= '0; beat <= '0; blen <= '0; s_cur <= '0; l_cur <= '0; slot_cur <= '0;
            rd_pl <= '0; rd_off <= '0; plane_words <= '0;
            consumed <= '0; row_drop <= 1'b0;
            m_awvalid <= 1'b0; m_awaddr <= '0; m_awlen <= '0;
            m_wvalid <= 1'b0; m_wlast <= 1'b0; m_wdata <= '0; m_bready <= 1'b0;
        end else begin
            if (consume) consumed <= consumed + 16'd1;

            // ---------------- pixel side ----------------
            if (arm) begin
                armed <= 1'b1; half <= 1'b0; x <= '0; y <= '0;
                fill_sel <= 1'b0; lb_full <= '0;
                frame_done <= 1'b0; overrun <= 1'b0; rows_done <= '0;
                s_cur <= '0; l_cur <= '0; slot_cur <= '0; consumed <= '0;
            end else if (take) begin
                half <= ~half;
                if (in_x && in_y) begin
                    if (mode_raw) begin                      // bytes 2cx, 2cx+1 of plane 0
                        lb[fill_sel][0][LI_W'(cx >> 1)][16*cx[0] +: 16] <= {pix[7:0], pix[15:8]} ^ 16'h8080;
                    end else begin
                        lb[fill_sel][0][LI_W'(cx >> 2)][8*cx[1:0] +: 8] <= r8 ^ 8'h80;
                        lb[fill_sel][1][LI_W'(cx >> 2)][8*cx[1:0] +: 8] <= g8 ^ 8'h80;
                        lb[fill_sel][2][LI_W'(cx >> 2)][8*cx[1:0] +: 8] <= b8 ^ 8'h80;
                    end
                    if (cx == crop_w - 16'd1) begin          // cropped row complete
                        if (lb_full[fill_sel]) overrun <= 1'b1;   // writer still busy: row lost
                        else begin
                            lb_full[fill_sel] <= 1'b1;
                            lb_row[fill_sel]  <= y - crop_y0;
                            fill_sel          <= ~fill_sel;
                        end
                    end
                end
                if (x == frame_w - 16'd1) begin
                    x <= '0;
                    y <= y + 16'd1;
                    if (y == crop_y0 + crop_h - 16'd1) armed <= 1'b0;   // rest of the frame: dropped
                end else x <= x + 16'd1;
            end

            // ---------------- writer side ----------------
            case (wr_st)
            WR_IDLE: if (lb_full[wr_sel]) begin
                row_words <= row_bytes >> 2;
                plane_words <= mode_raw ? (crop_w >> 1) : (crop_w >> 2);
                rd_pl     <= '0;
                rd_off    <= '0;
                wr_word   <= '0;
                wr_second <= 1'b0;
                wr_addr   <= addr_first;
                // the slot of stripe s_cur must have been released by the engine
                row_drop  <= (s_cur >= consumed + 16'(nslots));
                if (s_cur >= consumed + 16'(nslots)) overrun <= 1'b1;
                wr_st     <= (s_cur >= consumed + 16'(nslots)) ? WR_NEXT : WR_AW;
            end
            WR_AW: begin
                m_awaddr  <= wr_addr;
                m_awlen   <= 8'(nlen - 5'd1);
                blen      <= nlen;
                beat      <= '0;
                m_awvalid <= 1'b1;
                m_wvalid  <= 1'b0;
                m_bready  <= 1'b0;
                if (m_awvalid && m_awready) begin
                    m_awvalid <= 1'b0;
                    wr_st     <= WR_W;
                end
            end
            WR_W: begin
                if (!m_wvalid || m_wready) begin
                    if (m_wvalid && m_wready && m_wlast) begin
                        m_wvalid <= 1'b0;
                        m_bready <= 1'b1;
                        wr_st    <= WR_B;
                    end else begin
                        m_wdata  <= lb[wr_sel][rd_pl][LI_W'(rd_off)];
                        m_wlast  <= (beat == blen - 5'd1);
                        m_wvalid <= 1'b1;
                        beat     <= beat + 5'd1;
                        if (rd_off == plane_words - 16'd1) begin
                            rd_off <= '0;
                            rd_pl  <= rd_pl + 2'd1;
                        end else rd_off <= rd_off + 16'd1;
                    end
                end
            end
            WR_B: if (m_bvalid) begin
                m_bready <= 1'b0;
                if (wr_word + 16'(blen) < row_words) begin
                    wr_word <= wr_word + 16'(blen);
                    wr_addr <= wr_addr + {blen, 2'b00};
                    wr_st   <= WR_AW;
                end else if (!wr_second && has_halo_copy) begin
                    wr_second <= 1'b1;
                    wr_word   <= '0;
                    rd_pl     <= '0;
                    rd_off    <= '0;
                    wr_addr   <= addr_second;
                    wr_st     <= WR_AW;
                end else wr_st <= WR_NEXT;
            end
            WR_NEXT: begin                                  // row finished (or dropped)
                lb_full[wr_sel] <= 1'b0;
                wr_sel          <= ~wr_sel;
                if (!row_drop) rows_done <= rows_done + 16'd1;
                if (l_cur == adv - 16'd1) begin
                    l_cur    <= '0;
                    s_cur    <= s_cur + 16'd1;
                    slot_cur <= (slot_cur == nslots - 8'd1) ? 8'd0 : slot_cur + 8'd1;
                end else l_cur <= l_cur + 16'd1;
                if (lb_row[wr_sel] == crop_h - 16'd1) frame_done <= 1'b1;
                wr_st <= WR_IDLE;
            end
            default: wr_st <= WR_IDLE;
            endcase
        end
    end
endmodule
