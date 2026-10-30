`timescale 1ns / 1ps

// =============================================================================
//  out_writer : output-feature-map address generator + border filler
//
//  Takes the packed result words (4 pixels of one channel) from requant_and_pack
//  or maxpool_inline, in raster order per channel, and places them in a frame:
//
//    word(c, row, xw) = out_base + (oc_off + oc_base + c) * ch_stride
//                     + (row + pad) * row_stride + pad + xw          xw < words_per_row
//
//  * pad = 1 leaves a one-word left border and a one-row top border, so a
//    3x3 / pad-1 consumer reads pixel (y, x) at element (y+1)*4*row_stride + 4 + x and
//    its left pad at element ... + 3 (the last byte of the border word).
//  * oc_off places this layer's channels after another layer's (Fire concat).
//  * pixels x >= valid_w (tile padding when the width is not a multiple of 4) are
//    written as z_out, which reads as "minus infinity" / zero for ReLU outputs.
//
//  Border fill (fill_start): writes {4{z_out}} into the border of fill_channels
//  frames: rows 0 and rows+1 completely, and in rows 1..rows the words left of
//  and right of the data words (word 0 and words >= 1 + words_per_row).
// =============================================================================
module out_writer (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,          // per pass: resets the channel counters
    input  logic [31:0] oc_base,        // first output channel of this pass

    input  logic [23:0] out_base,       // words
    input  logic [23:0] ch_stride,      // words between channel frames
    input  logic [15:0] row_stride,     // words between rows
    input  logic [15:0] words_per_row,  // data words per row
    input  logic        out_pad,
    input  logic [15:0] oc_off,
    input  logic [15:0] valid_w,        // 0 = no masking
    input  logic [15:0] out_rows,       // data rows (border fill)
    input  logic signed [7:0] z_out,

    input  logic [31:0] in_wdata,
    input  logic        in_wen,
    input  logic [1:0]  in_ch,

    input  logic        fill_start,
    input  logic [15:0] fill_channels,
    output logic        fill_busy,
    output logic        fill_done,      // 1-cycle pulse

    output logic [31:0] waddr,
    output logic [31:0] wdata,
    output logic        wen
);
    // ------------------------------------------------------------ result placement
    logic [15:0] tx      [0:3];
    logic [31:0] row_adr [0:3];

    wire  [31:0] base0 = 32'(out_base) + (32'(oc_off) + oc_base) * 32'(ch_stride)
                       + (out_pad ? 32'(row_stride) + 32'd1 : 32'd0);

    logic [31:0] m_data;
    always_comb begin
        for (int p = 0; p < 4; p++) begin
            logic [16:0] px;
            px = {tx[in_ch], 2'b00} + 17'(p);
            m_data[8*p +: 8] = (valid_w != 16'd0 && px >= 17'(valid_w)) ? z_out : in_wdata[8*p +: 8];
        end
    end

    // ------------------------------------------------------------ border fill
    logic [15:0] f_ch, f_row, f_w;
    wire         f_border_row = (f_row == 16'd0) || (f_row == out_rows + 16'd1);
    wire         f_last_w     = (f_w == row_stride - 16'd1);
    wire  [31:0] f_addr = 32'(out_base) + 32'(f_ch) * 32'(ch_stride)
                        + 32'(f_row) * 32'(row_stride) + 32'(f_w);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wen <= 1'b0; waddr <= '0; wdata <= '0;
            fill_busy <= 1'b0; fill_done <= 1'b0;
            f_ch <= '0; f_row <= '0; f_w <= '0;
            for (int c = 0; c < 4; c++) begin tx[c] <= '0; row_adr[c] <= '0; end
        end else begin
            wen       <= 1'b0;
            fill_done <= 1'b0;

            if (start) begin
                for (int c = 0; c < 4; c++) begin
                    tx[c]      <= '0;
                    row_adr[c] <= base0 + 32'(c) * 32'(ch_stride);
                end
            end else if (in_wen) begin
                wen   <= 1'b1;
                waddr <= row_adr[in_ch] + 32'(tx[in_ch]);
                wdata <= m_data;
                if (tx[in_ch] == words_per_row - 16'd1) begin
                    tx[in_ch]      <= '0;
                    row_adr[in_ch] <= row_adr[in_ch] + 32'(row_stride);
                end else
                    tx[in_ch] <= tx[in_ch] + 16'd1;
            end

            if (fill_start && fill_channels != 16'd0) begin
                fill_busy <= 1'b1;
                f_ch <= '0; f_row <= '0; f_w <= '0;
            end else if (fill_busy) begin
                wen   <= 1'b1;
                waddr <= f_addr;
                wdata <= {4{z_out}};
                // next border word: whole border rows, else only the left word and
                // the words right of the data (if the row has any)
                if (f_last_w || (!f_border_row && f_w == 16'd0 &&
                                 16'd1 + words_per_row >= row_stride)) begin
                    f_w <= '0;
                    if (f_row == out_rows + 16'd1) begin
                        f_row <= '0;
                        if (f_ch == fill_channels - 16'd1) begin
                            fill_busy <= 1'b0;
                            fill_done <= 1'b1;
                        end else f_ch <= f_ch + 16'd1;
                    end else f_row <= f_row + 16'd1;
                end else if (!f_border_row && f_w == 16'd0)
                    f_w <= 16'd1 + words_per_row;
                else
                    f_w <= f_w + 16'd1;
            end
        end
    end
endmodule
