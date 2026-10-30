`timescale 1ns / 1ps

// =============================================================================
//  fpga_top : Nexys A7-100T prototype - camera -> SqueezeNet SoC -> class on LEDs + VGA
//
//    accelerator_top  (the SoC)                         clk_sys   (50 MHz with the wizard)
//    spi_boot_master  (plays boot_rom.mem over SPI)     clk_sys
//    ov7670_sccb_init + 25 MHz XCLK                     clk_vid   (100 MHz)
//    ov7670_capture -> frame_buffer -> vga_display     clk_vid   (live picture on VGA)
//
//  The camera pins go both to the SoC (DVP input) and to the capture block, so the
//  monitor shows exactly what the network sees, with the 224x224 crop box and the class
//  number (binary squares, green when valid) drawn on top.
//
//  Clocks: define USE_CLK_WIZ and add a Clocking Wizard IP named clk_wiz_0 with
//  clk_in1 = 100 MHz, clk_out1 = 50 MHz (SoC), clk_out2 = 100 MHz (video), reset active
//  high, locked output.  Without the define both clocks are the board clock (simulation,
//  or if the SoC meets timing at 100 MHz).
//
//  Order after reset: SCCB configures the camera (~130 ms), then the boot master programs
//  the SoC (~25 ms at 50 MHz) and starts it; afterwards it reads every result and
//  restarts (one new camera frame per inference).
//
//  LEDs: 5:0 class id   6 class valid   7 SoC busy   8 camera configured
//        9 SoC programmed   10 toggles per camera frame   15:11 inferences done (low bits)
//  BTNC: rewrite the camera registers   SW0: hide the overlay   CPU_RESETN: reset
// =============================================================================
module fpga_top #(
    parameter string BOOT_HEX   = "boot_rom.mem",
    parameter bit    CONTINUOUS = 1'b1,
    parameter int    SCCB_HZ    = 100_000,       // simulation may speed these up
    parameter int    MS_DIV     = 100_000
)(
    input  logic        clk_board,              // 100 MHz
    input  logic        cpu_resetn,             // active low
    input  logic        btnc,
    input  logic        sw0,

    // OV7670 (two Pmods)
    output logic        cam_xclk,
    output logic        cam_reset_n,
    output logic        cam_pwdn,
    output logic        cam_sioc,
    inout  wire         cam_siod,
    input  logic        cam_pclk,
    input  logic        cam_vsync,
    input  logic        cam_href,
    input  logic [7:0]  cam_d,

    // weight flash (Pmod), weights from address 0
    output logic        flash_sck,
    output logic        flash_cs_n,
    inout  wire  [3:0]  flash_io,

    output logic [3:0]  vga_r, vga_g, vga_b,
    output logic        vga_hs, vga_vs,
    output logic [15:0] led
);
    // ------------------------------------------------------------ clocks
    logic clk_sys, clk_vid, clk_locked;
`ifdef USE_CLK_WIZ
    clk_wiz_0 u_clk (.clk_in1(clk_board), .clk_out1(clk_sys), .clk_out2(clk_vid),
                     .reset(!cpu_resetn), .locked(clk_locked));
`else
    assign clk_sys = clk_board;
    assign clk_vid = clk_board;
    assign clk_locked = 1'b1;
`endif

    // ------------------------------------------------------------ resets
    logic [1:0] vid_rq, sys_rq;
    always_ff @(posedge clk_vid or negedge cpu_resetn)
        if (!cpu_resetn) vid_rq <= '0; else vid_rq <= {vid_rq[0], clk_locked};
    always_ff @(posedge clk_sys or negedge cpu_resetn)
        if (!cpu_resetn) sys_rq <= '0; else sys_rq <= {sys_rq[0], clk_locked};
    wire vid_rst_n = vid_rq[1];
    wire sys_rst_n = sys_rq[1];

    // ------------------------------------------------------------ camera control (video domain)
    logic [1:0]  xdiv;
    always_ff @(posedge clk_vid) xdiv <= xdiv + 2'd1;
    assign cam_xclk    = xdiv[1];               // 25 MHz
    assign cam_pwdn    = 1'b0;
    assign cam_reset_n = vid_rst_n;

    logic [2:0]  btn_q;
    logic [19:0] por;
    logic        sccb_start, sccb_done;
    always_ff @(posedge clk_vid or negedge vid_rst_n) begin
        if (!vid_rst_n) begin btn_q <= '0; por <= '0; sccb_start <= 1'b0; end
        else begin
            btn_q      <= {btn_q[1:0], btnc};
            sccb_start <= (por == 20'd100_000) || (btn_q[2:1] == 2'b01);
            if (por != 20'hFFFFF) por <= por + 20'd1;
        end
    end

    ov7670_sccb_init #(.SCCB_HZ(SCCB_HZ), .MS_DIV(MS_DIV)) sccb (
        .clk(clk_vid), .rst_n(vid_rst_n), .start(sccb_start),
        .sioc(cam_sioc), .siod(cam_siod), .done(sccb_done)
    );

    // ------------------------------------------------------------ SoC + boot master (system domain)
    logic        spi_sck, spi_cs_n, spi_mosi, spi_miso, host_irq, result_valid, busy, booted, boot_valid;
    logic [6:0]  result_o;
    logic [15:0] boot_class, frames;
    logic [1:0]  cam_ok_q;                     // camera configured, synchronised to clk_sys
    always_ff @(posedge clk_sys or negedge sys_rst_n)
        if (!sys_rst_n) cam_ok_q <= '0; else cam_ok_q <= {cam_ok_q[0], sccb_done};

    accelerator_top soc (
        .clk(clk_sys), .rst_n(sys_rst_n),
        .dvp_pclk_i(cam_pclk), .dvp_vsync_i(cam_vsync), .dvp_hsync_i(1'b0),
        .dvp_href_i(cam_href), .dvp_d_i(cam_d), .dvp_xclk_o(), .dvp_pwdn_o(),
        .qspi_sck(flash_sck), .qspi_cs_n(flash_cs_n), .qspi_io(flash_io),
        .mcu_spi_sck(spi_sck), .mcu_spi_cs_n(spi_cs_n), .mcu_spi_mosi(spi_mosi), .mcu_spi_miso(spi_miso),
        .host_irq(host_irq),
        .result_o(result_o), .result_valid_o(result_valid), .busy_o(busy)
    );

    // the boot master waits in reset until the camera has been configured
    spi_boot_master #(.BOOT_HEX(BOOT_HEX), .CONTINUOUS(CONTINUOUS)) boot (
        .clk(clk_sys), .rst_n(sys_rst_n && cam_ok_q[1]),
        .spi_sck(spi_sck), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .host_irq(host_irq),
        .result_class(boot_class), .result_valid(boot_valid), .frames_done(frames), .booted(booted)
    );

    // ------------------------------------------------------------ live picture (video domain)
    logic [16:0] fb_waddr, fb_raddr;
    logic [11:0] fb_wdata, fb_rdata;
    logic        fb_we, frame_tick, frame_led;
    logic [7:0]  res_q1, res_q2;                // class / valid into the video domain

    ov7670_capture cap (
        .clk(clk_vid), .rst_n(vid_rst_n),
        .cam_pclk(cam_pclk), .cam_vsync(cam_vsync), .cam_href(cam_href), .cam_d(cam_d),
        .fb_waddr(fb_waddr), .fb_wdata(fb_wdata), .fb_we(fb_we), .frame_tick(frame_tick)
    );

    frame_buffer fb (
        .clk(clk_vid), .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata),
        .raddr(fb_raddr), .rdata(fb_rdata)
    );

    always_ff @(posedge clk_vid) begin
        res_q1 <= {result_valid, result_o};
        res_q2 <= res_q1;
    end

    vga_display vga (
        .clk(clk_vid), .rst_n(vid_rst_n), .fb_raddr(fb_raddr), .fb_rdata(fb_rdata),
        .class_id(res_q2[6:0]), .class_valid(res_q2[7]), .show_overlay(!sw0),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs)
    );

    always_ff @(posedge clk_vid or negedge vid_rst_n)
        if (!vid_rst_n) frame_led <= 1'b0; else if (frame_tick) frame_led <= !frame_led;

    assign led = {frames[4:0], frame_led, booted, sccb_done, busy, result_valid, result_o[5:0]};
endmodule
