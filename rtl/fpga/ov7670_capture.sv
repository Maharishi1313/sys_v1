`timescale 1ns / 1ps

// =============================================================================
//  ov7670_capture : OV7670 DVP pins -> 320x240 RGB444 frame buffer writes
//
//  All camera pins are over-sampled by clk (100 MHz) through 2-flop synchronisers, so
//  PCLK is never used as a clock (no clock-capable pin needed on a Pmod).  A byte is
//  taken on every PCLK rising edge while HREF is high; two bytes form one RGB565 pixel
//  (first byte = high byte).  VSYNC high restarts the frame.
// =============================================================================
module ov7670_capture #(
    parameter int W = 320,
    parameter int H = 240
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cam_pclk,
    input  logic        cam_vsync,
    input  logic        cam_href,
    input  logic [7:0]  cam_d,

    output logic [16:0] fb_waddr,               // y * W + x
    output logic [11:0] fb_wdata,               // {R4, G4, B4}
    output logic        fb_we,
    output logic        frame_tick              // 1 cycle at the start of every frame
);
    logic [2:0] pclk_q, href_q, vs_q;
    logic [7:0] d_q1, d_q2;
    always_ff @(posedge clk) begin
        pclk_q <= {pclk_q[1:0], cam_pclk};
        href_q <= {href_q[1:0], cam_href};
        vs_q   <= {vs_q[1:0],   cam_vsync};
        d_q1   <= cam_d;
        d_q2   <= d_q1;
    end
    wire pclk_rise = pclk_q[2:1] == 2'b01;
    wire href      = href_q[1];
    wire href_fall = href_q[2:1] == 2'b10;
    wire vs_rise   = vs_q[2:1] == 2'b01;

    logic [8:0] x;
    logic [7:0] y;
    logic       second;
    logic [7:0] hi;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= '0; y <= '0; second <= 1'b0; hi <= '0;
            fb_we <= 1'b0; fb_waddr <= '0; fb_wdata <= '0; frame_tick <= 1'b0;
        end else begin
            fb_we      <= 1'b0;
            frame_tick <= 1'b0;
            if (vs_rise) begin
                x <= '0; y <= '0; second <= 1'b0; frame_tick <= 1'b1;
            end else if (href_fall) begin
                if (x != 0) y <= y + 8'd1;
                x <= '0; second <= 1'b0;
            end else if (href && pclk_rise) begin
                second <= !second;
                if (!second) hi <= d_q2;
                else begin
                    // RGB565 {hi, lo} = R5 G6 B5 -> R4 G4 B4
                    if (x < W && y < H) begin
                        fb_we    <= 1'b1;
                        fb_waddr <= 17'(y) * 17'(W) + 17'(x);
                        fb_wdata <= {hi[7:4], hi[2:0], d_q2[7], d_q2[4:1]};
                    end
                    x <= x + 9'd1;
                end
            end
        end
    end
endmodule
