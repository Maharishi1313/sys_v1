`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module ifmap_axi_wrapper #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter ID_W       = 6,
    parameter IFMAP_DEPTH = 20480  // depth of one sram bank in ping pong activation buffer
)(
    input  logic clk,
    input  logic rst_n,
    
    // 1 = AXI (Camera DVP / DMA Reshaper) controls SRAM
    // 0 = Accelerator (MME / MaxPool) controls SRAM
    input  logic sys_axi_ctrl, 
    input  logic bank_sel,

    // AXI4 Slave Ports
    input  logic [ID_W-1:0]       s_axi_awid,
    output logic [ID_W-1:0]       s_axi_bid,
    input  logic [ID_W-1:0]       s_axi_arid,
    output logic [ID_W-1:0]       s_axi_rid,
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [7:0]            s_axi_awlen,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    input  logic                  s_axi_wlast,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [7:0]            s_axi_arlen,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rlast,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    // Accelerator MME/MaxPool Ports
    input  logic [$clog2(IFMAP_DEPTH)-1:0] acc_raddr,
    input  logic                     acc_ren,
    output logic [DATA_WIDTH-1:0]    acc_rdata,
    output logic                     acc_rvalid,
    input  logic [$clog2(20480)-1:0] acc_waddr,
    input  logic                     acc_wen,
    input  logic [DATA_WIDTH-1:0]    acc_wdata
);

    // The AXI window spans both banks (memory map: bank A at +0x0_0000,
    // bank B at +0x1_4000), so the slave decodes 2*IFMAP_DEPTH words.
    logic [$clog2(2*IFMAP_DEPTH)-1:0] axi_addr;
    logic [$clog2(IFMAP_DEPTH)-1:0]   axi_bank_addr;
    logic                     axi_bank;            // 0 = bank A, 1 = bank B
    logic [DATA_WIDTH-1:0]    axi_wdata, sram_rdata;
    logic                     axi_wen, axi_ren;

    assign axi_bank      = (axi_addr >= IFMAP_DEPTH);
    assign axi_bank_addr = $clog2(IFMAP_DEPTH)'(axi_bank ? axi_addr - IFMAP_DEPTH : axi_addr);

    axi4_sram_slave #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_W(ID_W),
        .SRAM_DEPTH(2*IFMAP_DEPTH)
    ) axi_slave (
        .clk(clk), .rst_n(rst_n),
        .awid(s_axi_awid), .bid(s_axi_bid), .arid(s_axi_arid), .rid(s_axi_rid),
        .awaddr(s_axi_awaddr), .awlen(s_axi_awlen), .awvalid(s_axi_awvalid), .awready(s_axi_awready),
        .wdata(s_axi_wdata), .wlast(s_axi_wlast), .wvalid(s_axi_wvalid), .wready(s_axi_wready),
        .bresp(s_axi_bresp), .bvalid(s_axi_bvalid), .bready(s_axi_bready),
        .araddr(s_axi_araddr), .arlen(s_axi_arlen), .arvalid(s_axi_arvalid), .arready(s_axi_arready),
        .rdata(s_axi_rdata), .rresp(s_axi_rresp), .rlast(s_axi_rlast), .rvalid(s_axi_rvalid), .rready(s_axi_rready),
        .sram_addr(axi_addr), .sram_wdata(axi_wdata), .sram_wen(axi_wen), .sram_ren(axi_ren), .sram_rdata(sram_rdata)
    );

    logic [$clog2(IFMAP_DEPTH)-1:0] final_raddr, final_waddr;
    logic [DATA_WIDTH-1:0]    final_wdata;
    logic                     final_wen, final_ren;

    // Dual-Port Multiplexing
    assign final_raddr = sys_axi_ctrl ? axi_bank_addr : acc_raddr;
    assign final_ren   = sys_axi_ctrl ? axi_ren       : acc_ren;
    assign final_waddr = sys_axi_ctrl ? axi_bank_addr : acc_waddr;
    assign final_wen   = sys_axi_ctrl ? axi_wen       : acc_wen;
    assign final_wdata = sys_axi_ctrl ? axi_wdata     : acc_wdata;

    // ping_pong_buffer reads the bank_sel bank and writes the other one.
    // AXI side: point it at the bank the address selects.
    logic pp_bank_sel;
    assign pp_bank_sel = !sys_axi_ctrl ? bank_sel :
                         axi_wen       ? ~axi_bank : axi_bank;

    ping_pong_buffer #(
        .WIDTH(DATA_WIDTH),
        .SIZE(IFMAP_DEPTH)
    ) pp_sram (
        .clk(clk),
        .rst_n(rst_n),
        .bank_sel(pp_bank_sel),
        .raddr(final_raddr),
        .ren(final_ren),
        .rdata(sram_rdata),
        .rvalid(acc_rvalid),
        .waddr(final_waddr),
        .wen(final_wen),
        .wdata(final_wdata)
    );

    assign acc_rdata = sram_rdata;

endmodule
