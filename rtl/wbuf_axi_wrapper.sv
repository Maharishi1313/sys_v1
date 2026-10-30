`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module wbuf_axi_wrapper #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter ID_W       = 6
)(
    input  logic clk,
    input  logic rst_n,
    
    // 1 = DMA controls SRAM (Loading weights)
    // 0 = MME controls SRAM (Running inference)
    input  logic sys_axi_ctrl, 

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

    // Accelerator MME Ports
    input  logic [$clog2(WBUF_SIZE)-1:0] mme_raddr,
    input  logic                         mme_ren,
    output logic [DATA_WIDTH-1:0]        mme_rdata,
    output logic                         mme_rvalid
);

    logic [$clog2(WBUF_SIZE)-1:0] axi_addr;
    logic [DATA_WIDTH-1:0]        axi_wdata, sram_rdata;
    logic                         axi_wen, axi_ren;

    axi4_sram_slave #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_W(ID_W),
        .SRAM_DEPTH(WBUF_SIZE)
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

    logic [$clog2(WBUF_SIZE)-1:0] final_addr;
    logic [DATA_WIDTH-1:0]        final_wdata;
    logic                         final_wen, final_ren;

    // Single-Port Multiplexing
    assign final_addr  = sys_axi_ctrl ? axi_addr  : mme_raddr;
    assign final_wdata = sys_axi_ctrl ? axi_wdata : 32'd0;
    assign final_wen   = sys_axi_ctrl ? axi_wen   : 1'b0;
    assign final_ren   = sys_axi_ctrl ? axi_ren   : mme_ren;

    buffer #(
        .WIDTH(DATA_WIDTH),
        .SIZE(WBUF_SIZE)
    ) weight_sram (
        .clk(clk),
        .rst_n(rst_n),
        .r_addr(final_addr),
        .ren(final_ren),
        .dout(sram_rdata),
        .r_valid_out(mme_rvalid), 
        .w_addr(final_addr),
        .wen(final_wen),
        .din(final_wdata)
    );

    assign mme_rdata = sram_rdata;

endmodule
