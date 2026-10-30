`timescale 1ns / 1ps

// =============================================================================
//  cam_vga_test_top : OV7670 bring-up on the Nexys A7-100T, nothing else
//
//  100 MHz board clock -> 25 MHz XCLK for the camera, SCCB register set-up (QVGA RGB565),
//  capture into a 320x240 frame buffer, 640x480 VGA output (2x zoom) with the 224x224
//  crop box.  Use it to check focus, colours and orientation before running the SoC.
//
//  LEDs: 0 SCCB done   1 toggles every camera frame   2 PCLK seen   3 HREF seen
//        15..8 frames counted (binary)
//  BTNC (centre button): rewrite the camera registers.   CPU_RESETN: reset everything.
//  SW0: hide the crop box.
// =============================================================================
module cam_vga_test_top (
    input  logic        clk100,
    input  logic        cpu_resetn,
    input  logic        btnc,
    input  logic        sw0,

    output logic        cam_xclk,
    output logic        cam_reset_n,
    output logic        cam_pwdn,
    output logic        cam_sioc,
    inout  wire         cam_siod,
    input  logic        cam_pclk,
    input  logic        cam_vsync,
    input  logic        cam_href,
    input  logic [7:0]  cam_d,

    output logic [3:0]  vga_r, vga_g, vga_b,
    output logic        vga_hs, vga_vs,
    output logic [15:0] led
);
    // ---------------- reset (2 flops) and 25 MHz camera clock
    logic [1:0] rst_q;
    always_ff @(posedge clk100 or negedge cpu_resetn)
        if (!cpu_resetn) rst_q <= '0; else rst_q <= {rst_q[0], 1'b1};
    wire rst_n = rst_q[1];

    logic [1:0] xdiv;
    always_ff @(posedge clk100) xdiv <= xdiv + 2'd1;
    assign cam_xclk    = xdiv[1];               // 100 / 4 = 25 MHz
    assign cam_pwdn    = 1'b0;
    assign cam_reset_n = rst_n;

    // ---------------- SCCB set-up: after reset and on BTNC (wait 1 ms after reset)
    logic [2:0]  btn_q;
    logic [19:0] por;
    logic        sccb_start, sccb_done;
    always_ff @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) begin btn_q <= '0; por <= '0; sccb_start <= 1'b0; end
        else begin
            btn_q      <= {btn_q[1:0], btnc};
            sccb_start <= (por == 20'd100_000) || (btn_q[2:1] == 2'b01);
            if (por != 20'hFFFFF) por <= por + 20'd1;
        end
    end

    ov7670_sccb_init sccb (
        .clk(clk100), .rst_n(rst_n), .start(sccb_start),
        .sioc(cam_sioc), .siod(cam_siod), .done(sccb_done)
    );

    // ---------------- capture -> frame buffer -> VGA
    logic [16:0] fb_waddr, fb_raddr;
    logic [11:0] fb_wdata, fb_rdata;
    logic        fb_we, frame_tick;

    ov7670_capture cap (
        .clk(clk100), .rst_n(rst_n),
        .cam_pclk(cam_pclk), .cam_vsync(cam_vsync), .cam_href(cam_href), .cam_d(cam_d),
        .fb_waddr(fb_waddr), .fb_wdata(fb_wdata), .fb_we(fb_we), .frame_tick(frame_tick)
    );

    frame_buffer fb (
        .clk(clk100), .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata),
        .raddr(fb_raddr), .rdata(fb_rdata)
    );

    vga_display vga (
        .clk(clk100), .rst_n(rst_n), .fb_raddr(fb_raddr), .fb_rdata(fb_rdata),
        .class_id(7'd0), .class_valid(1'b0), .show_overlay(!sw0),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs)
    );

    // ---------------- status LEDs
    logic [7:0] frames;
    logic       frame_led, pclk_seen, href_seen;
    logic [1:0] pclk_q;
    always_ff @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) begin frames <= '0; frame_led <= 1'b0; pclk_seen <= 1'b0; href_seen <= 1'b0; pclk_q <= '0; end
        else begin
            pclk_q <= {pclk_q[0], cam_pclk};
            if (pclk_q == 2'b01) pclk_seen <= 1'b1;
            if (cam_href)        href_seen <= 1'b1;
            if (frame_tick) begin frames <= frames + 8'd1; frame_led <= !frame_led; end
        end
    end
    assign led = {frames, 4'd0, href_seen, pclk_seen, frame_led, sccb_done};
endmodule
