`timescale 1ns / 1ps

module pixel_converter #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32
)(
    // AXI4 Slave Interface (Connects to DVP-RX DMA Master Out)
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [7:0]            s_axi_awlen,
    input  logic [2:0]            s_axi_awsize,
    input  logic [1:0]            s_axi_awburst,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [(DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  logic                  s_axi_wlast,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,

    // AXI4 Master Interface (Connects to Interconnect)
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    
    output logic [DATA_WIDTH-1:0] m_axi_wdata,
    output logic [(DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    
    input  logic [1:0]            m_axi_bresp,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,

    input  logic                  en
);

    // Pass AW channel transparently
    assign m_axi_awaddr   = s_axi_awaddr;
    assign m_axi_awlen    = s_axi_awlen;
    assign m_axi_awsize   = s_axi_awsize;
    assign m_axi_awburst  = s_axi_awburst;
    assign m_axi_awvalid  = s_axi_awvalid;
    assign s_axi_awready  = m_axi_awready;

    // Intercept W channel: XOR 0x80 on every byte
    genvar i;
    generate
        for (i = 0; i < DATA_WIDTH/8; i++) begin : gen_xor
            assign m_axi_wdata[(i*8)+7 : i*8] = en ? s_axi_wdata[(i*8)+7 : i*8] ^ 8'h80 : s_axi_wdata[(i*8)+7 : i*8];
        end
    endgenerate

    assign m_axi_wstrb    = s_axi_wstrb;
    assign m_axi_wlast    = s_axi_wlast;
    assign m_axi_wvalid   = s_axi_wvalid;
    assign s_axi_wready   = m_axi_wready;

    // Pass B channel transparently
    assign s_axi_bresp    = m_axi_bresp;
    assign s_axi_bvalid   = m_axi_bvalid;
    assign m_axi_bready   = s_axi_bready;

endmodule
