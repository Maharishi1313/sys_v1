`timescale 1ns / 1ps

// =============================================================================
//  fpga_top : board-level wrapper for the FPGA prototype
//
//    accelerator_top (the SoC)  +  spi_boot_master (plays boot_rom.mem over the SoC's SPI
//    port: camera + head CSRs, all job descriptors, START; then reads every result)
//
//  Board connections:
//    clk_board     board oscillator.  Replace the 'assign clk_sys' below with your clocking
//                  wizard / PLL output (start at 50 MHz; raise once timing is met).
//    rst_btn       active-high push button
//    cam_*         OV7670 DVP pins (the sensor must be set to QVGA RGB565 over SCCB by
//                  a separate block or MCU - not part of this SoC)
//    flash_*       QSPI flash holding flash_image.bin at the --flash-base used by the
//                  compiler.  If it is the configuration flash, its clock may have to go
//                  through the vendor primitive (Xilinx STARTUPE2 / Intel ASMI).
//    led[5:0]      class number of the last inference (33 classes -> 6 bits)
//    led[6]        result valid,  led[7] busy
//    result_o      the SoC's 7 result pins (for a header / logic analyser)
// =============================================================================
module fpga_top #(
    parameter string BOOT_HEX   = "boot_rom.mem",
    parameter bit    CONTINUOUS = 1'b1
)(
    input  logic       clk_board,
    input  logic       rst_btn,

    input  logic       cam_pclk,
    input  logic       cam_vsync,
    input  logic       cam_href,
    input  logic [7:0] cam_d,
    output logic       cam_xclk,
    output logic       cam_pwdn,

    output logic       flash_sck,
    output logic       flash_cs_n,
    inout  wire  [3:0] flash_io,

    output logic [7:0] led,
    output logic [6:0] result_o,
    output logic       host_irq
);
    logic clk_sys;
    assign clk_sys = clk_board;                  // <- clocking wizard output on hardware

    // power-on / button reset (the SoC has its own synchroniser)
    logic [3:0] rst_q;
    always_ff @(posedge clk_sys or posedge rst_btn)
        if (rst_btn) rst_q <= '0;
        else         rst_q <= {rst_q[2:0], 1'b1};
    wire rst_n = rst_q[3];

    logic spi_sck, spi_cs_n, spi_mosi, spi_miso;
    logic result_valid, busy;
    logic [15:0] boot_class, frames;
    logic booted, boot_valid;

    accelerator_top soc (
        .clk(clk_sys), .rst_n(rst_n),
        .dvp_pclk_i(cam_pclk), .dvp_vsync_i(cam_vsync), .dvp_hsync_i(1'b0),
        .dvp_href_i(cam_href), .dvp_d_i(cam_d), .dvp_xclk_o(cam_xclk), .dvp_pwdn_o(cam_pwdn),
        .qspi_sck(flash_sck), .qspi_cs_n(flash_cs_n), .qspi_io(flash_io),
        .mcu_spi_sck(spi_sck), .mcu_spi_cs_n(spi_cs_n), .mcu_spi_mosi(spi_mosi), .mcu_spi_miso(spi_miso),
        .host_irq(host_irq),
        .result_o(result_o), .result_valid_o(result_valid), .busy_o(busy)
    );

    spi_boot_master #(.BOOT_HEX(BOOT_HEX), .CONTINUOUS(CONTINUOUS)) boot (
        .clk(clk_sys), .rst_n(rst_n),
        .spi_sck(spi_sck), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .host_irq(host_irq),
        .result_class(boot_class), .result_valid(boot_valid), .frames_done(frames), .booted(booted)
    );

    assign led = {busy, result_valid, result_o[5:0]};
endmodule
