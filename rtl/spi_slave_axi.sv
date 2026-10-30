`timescale 1ns / 1ps

// =============================================================================
//  spi_slave_axi : MCU SPI slave -> AXI4 master (single-beat accesses)
//
//  SPI mode 0 (CPOL=0, CPHA=0), MSB first.  SCK/CS/MOSI are oversampled in the
//  clk domain (2-FF synchronisers), so SCK must be <= clk/8.
//
//  Frames (CS low for the whole frame):
//    WRITE  0x02 | addr[31:0] | data[31:0] { | data[31:0] ... }   addr += 4 per word
//    READ   0x03 | addr[31:0] | 8 dummy clocks | data[31:0] (MISO)
//  The AXI read is issued when the address is complete; it has the 8 dummy
//  clocks (>= 64 clk at the maximum SCK) to return.  rd_late counts reads whose
//  data was not back in time (data then reads as 0xDEAD_BEEF).
//
//  Any address of the SoC map is reachable: system CSRs / layer descriptors
//  (0xA000_0000), the activation SRAM banks (0x6000_0000), weight SRAM, ...
// =============================================================================
module spi_slave_axi #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter ID_W   = 4
)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic              spi_sck,
    input  logic              spi_cs_n,
    input  logic              spi_mosi,
    output logic              spi_miso,
    output logic              spi_miso_oe,      // drive MISO only while selected

    output logic [ID_W-1:0]   m_awid,
    output logic [ADDR_W-1:0] m_awaddr,
    output logic [7:0]        m_awlen,
    output logic [2:0]        m_awsize,
    output logic [1:0]        m_awburst,
    output logic              m_awvalid,
    input  logic              m_awready,
    output logic [DATA_W-1:0] m_wdata,
    output logic [DATA_W/8-1:0] m_wstrb,
    output logic              m_wlast,
    output logic              m_wvalid,
    input  logic              m_wready,
    input  logic [ID_W-1:0]   m_bid,
    input  logic [1:0]        m_bresp,
    input  logic              m_bvalid,
    output logic              m_bready,
    output logic [ID_W-1:0]   m_arid,
    output logic [ADDR_W-1:0] m_araddr,
    output logic [7:0]        m_arlen,
    output logic [2:0]        m_arsize,
    output logic [1:0]        m_arburst,
    output logic              m_arvalid,
    input  logic              m_arready,
    input  logic [ID_W-1:0]   m_rid,
    input  logic [DATA_W-1:0] m_rdata,
    input  logic [1:0]        m_rresp,
    input  logic              m_rlast,
    input  logic              m_rvalid,
    output logic              m_rready,

    output logic [15:0]       rd_late           // diagnostics
);
    localparam logic [7:0] CMD_WRITE = 8'h02;
    localparam logic [7:0] CMD_READ  = 8'h03;

    assign m_awid = '0;  assign m_awlen = 8'd0; assign m_awsize = 3'd2; assign m_awburst = 2'b01;
    assign m_wstrb = '1; assign m_wlast = 1'b1;
    assign m_arid = '0;  assign m_arlen = 8'd0; assign m_arsize = 3'd2; assign m_arburst = 2'b01;

    // ---------------------------------------------------------------- sync
    logic [2:0] sck_q, cs_q;
    logic [1:0] mosi_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sck_q <= '0; cs_q <= '1; mosi_q <= '0; end
        else begin
            sck_q  <= {sck_q[1:0], spi_sck};
            cs_q   <= {cs_q[1:0], spi_cs_n};
            mosi_q <= {mosi_q[0], spi_mosi};
        end
    end
    wire sel      = ~cs_q[1];
    wire sck_rise = sel && (sck_q[2:1] == 2'b01);
    wire sck_fall = sel && (sck_q[2:1] == 2'b10);
    wire mosi_b   = mosi_q[1];

    // ---------------------------------------------------------------- frame decode
    typedef enum logic [2:0] {S_CMD, S_ADDR, S_WDATA, S_DUMMY, S_RDATA, S_IGNORE} sp_state_t;
    sp_state_t sp;
    logic [5:0]        bit_cnt;
    logic [31:0]       shreg, out_sh;
    logic [7:0]        cmd;
    logic [ADDR_W-1:0] addr;

    // requests to the AXI side
    logic              wr_go, rd_go;
    logic [ADDR_W-1:0] req_addr;
    logic [DATA_W-1:0] req_data;
    logic              rd_done;
    logic [DATA_W-1:0] rd_buf;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp <= S_CMD; bit_cnt <= '0; shreg <= '0; out_sh <= '0; cmd <= '0; addr <= '0;
            wr_go <= 1'b0; rd_go <= 1'b0; req_addr <= '0; req_data <= '0;
            spi_miso <= 1'b0; rd_late <= '0;
        end else begin
            wr_go <= 1'b0;
            rd_go <= 1'b0;
            if (!sel) begin
                sp <= S_CMD; bit_cnt <= '0;
            end else if (sck_rise) begin
                shreg   <= {shreg[30:0], mosi_b};
                bit_cnt <= bit_cnt + 6'd1;
                case (sp)
                S_CMD: if (bit_cnt == 6'd7) begin
                    cmd     <= {shreg[6:0], mosi_b};
                    bit_cnt <= '0;
                    sp      <= ({shreg[6:0], mosi_b} == CMD_WRITE ||
                                {shreg[6:0], mosi_b} == CMD_READ) ? S_ADDR : S_IGNORE;
                end
                S_ADDR: if (bit_cnt == 6'd31) begin
                    addr    <= {shreg[30:0], mosi_b};
                    bit_cnt <= '0;
                    if (cmd == CMD_READ) begin
                        req_addr <= {shreg[30:0], mosi_b};
                        rd_go    <= 1'b1;
                        sp       <= S_DUMMY;
                    end else sp <= S_WDATA;
                end
                S_WDATA: if (bit_cnt == 6'd31) begin
                    req_addr <= addr;
                    req_data <= {shreg[30:0], mosi_b};
                    wr_go    <= 1'b1;
                    addr     <= addr + 4;
                    bit_cnt  <= '0;
                end
                S_DUMMY: if (bit_cnt == 6'd7) begin
                    bit_cnt <= '0;
                    sp      <= S_RDATA;
                end
                S_RDATA: if (bit_cnt == 6'd31) sp <= S_IGNORE;
                default: ;
                endcase
            end else if (sck_fall) begin
                // mode 0: the slave updates MISO on the falling edge
                if (sp == S_RDATA && bit_cnt == 6'd0) begin
                    // first falling edge after the dummy byte: load the word
                    if (!rd_done) rd_late <= rd_late + 16'd1;
                    spi_miso <= rd_done ? rd_buf[31] : 1'b1;
                    out_sh   <= rd_done ? {rd_buf[30:0], 1'b0} : {32'hDEAD_BEEF << 1};
                end else if (sp == S_RDATA) begin
                    spi_miso <= out_sh[31];
                    out_sh   <= {out_sh[30:0], 1'b0};
                end
            end
        end
    end
    assign spi_miso_oe = sel;

    // ---------------------------------------------------------------- AXI side
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_bready <= 1'b0;
            m_arvalid <= 1'b0; m_rready <= 1'b0;
            m_awaddr <= '0; m_wdata <= '0; m_araddr <= '0;
            rd_done <= 1'b0; rd_buf <= '0;
        end else begin
            // write: AW and W handshake independently, then B
            if (wr_go) begin
                m_awaddr <= req_addr; m_wdata <= req_data;
                m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_bready <= 1'b1;
            end else begin
                if (m_awvalid && m_awready) m_awvalid <= 1'b0;
                if (m_wvalid  && m_wready)  m_wvalid  <= 1'b0;
                if (m_bvalid  && m_bready && !m_awvalid && !m_wvalid) m_bready <= 1'b0;
            end
            // read
            if (rd_go) begin
                m_araddr <= req_addr; m_arvalid <= 1'b1; m_rready <= 1'b1; rd_done <= 1'b0;
            end else begin
                if (m_arvalid && m_arready) m_arvalid <= 1'b0;
                if (m_rvalid && m_rready) begin
                    m_rready <= 1'b0; rd_buf <= m_rdata; rd_done <= 1'b1;
                end
            end
        end
    end
endmodule
