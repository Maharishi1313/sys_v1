`timescale 1ns / 1ps

// =============================================================================
//  vga_display : 640x480 @ 60 Hz from a 320x240 frame buffer (each pixel shown 2x2)
//
//  Runs on the 100 MHz clock with a pixel enable every 4th cycle (25 MHz pixel rate, which
//  every VGA monitor accepts for 640x480).  Overlays:
//    * a yellow box around the 224x224 crop the network sees (x 48..271, y 8..231)
//    * a row of 7 squares at the bottom: the class number in binary (MSB left), green
//      squares when result_valid, plus result_valid itself as the 8th square
//  Output: 4-bit R/G/B (Nexys A7 VGA port), active-low HS / VS.
// =============================================================================
module vga_display #(
    parameter int CROP_X0 = 48, CROP_Y0 = 8, CROP = 224
)(
    input  logic        clk,                    // 100 MHz
    input  logic        rst_n,
    output logic [16:0] fb_raddr,
    input  logic [11:0] fb_rdata,               // 1 clock after fb_raddr
    input  logic [6:0]  class_id,
    input  logic        class_valid,
    input  logic        show_overlay,
    output logic [3:0]  vga_r, vga_g, vga_b,
    output logic        vga_hs, vga_vs
);
    // 640x480@60: h 640 + 16 + 96 + 48 = 800, v 480 + 10 + 2 + 33 = 525
    logic [1:0] div;
    logic [9:0] hc, vc;
    wire        pix = (div == 2'd3);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin div <= '0; hc <= '0; vc <= '0; end
        else begin
            div <= div + 2'd1;
            if (pix) begin
                if (hc == 10'd799) begin
                    hc <= '0;
                    vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1;
                end else hc <= hc + 10'd1;
            end
        end
    end

    wire       active = (hc < 10'd640) && (vc < 10'd480);
    wire [8:0] fx = hc[9:1];                    // frame-buffer pixel (2x scaling)
    wire [7:0] fy = vc[8:1];
    assign fb_raddr = 17'(fy) * 17'd320 + 17'(fx);   // data is back long before the next pix

    // crop box (frame coordinates), 1 frame-pixel thick
    wire in_box_x = (fx >= CROP_X0 - 1) && (fx <= CROP_X0 + CROP);
    wire in_box_y = (fy >= CROP_Y0 - 1) && (fy <= CROP_Y0 + CROP);
    wire box = show_overlay && in_box_x && in_box_y &&
               ((fx == CROP_X0 - 1) || (fx == CROP_X0 + CROP) || (fy == CROP_Y0 - 1) || (fy == CROP_Y0 + CROP));

    // result squares: 8 squares of 24x24 screen pixels at the bottom-left
    wire        in_bar = show_overlay && (vc >= 10'd448) && (vc < 10'd472) && (hc >= 10'd16) && (hc < 10'd16 + 8 * 32);
    wire [2:0]  sq     = 3'((hc - 10'd16) >> 5);
    wire        in_sq  = ((hc - 10'd16) & 10'd31) < 10'd24;
    wire        bit_on = (sq == 3'd7) ? class_valid : class_id[3'd6 - sq];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_r <= '0; vga_g <= '0; vga_b <= '0; vga_hs <= 1'b1; vga_vs <= 1'b1;
        end else if (pix) begin
            vga_hs <= !((hc >= 10'd656) && (hc < 10'd752));
            vga_vs <= !((vc >= 10'd490) && (vc < 10'd492));
            if (!active)                 {vga_r, vga_g, vga_b} <= 12'h000;
            else if (in_bar && in_sq)    {vga_r, vga_g, vga_b} <= bit_on ? (class_valid ? 12'h0F0 : 12'hFFF) : 12'h333;
            else if (box)                {vga_r, vga_g, vga_b} <= 12'hFF0;
            else                         {vga_r, vga_g, vga_b} <= fb_rdata;
        end
    end
endmodule
