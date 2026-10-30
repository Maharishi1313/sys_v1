`timescale 1ns / 1ps

module axi4_sram_slave #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter SRAM_DEPTH = 20480,
    parameter ID_W       = 6       // interconnect routes B/R back by the echoed ID
)(
    input  logic clk,
    input  logic rst_n,

    // AXI4 Write Channels
    input  logic [ID_W-1:0]       awid,
    output logic [ID_W-1:0]       bid,
    input  logic [ADDR_WIDTH-1:0] awaddr,
    input  logic [7:0]            awlen,
    input  logic                  awvalid,
    output logic                  awready,
    input  logic [DATA_WIDTH-1:0] wdata,
    input  logic                  wlast,
    input  logic                  wvalid,
    output logic                  wready,
    output logic [1:0]            bresp,
    output logic                  bvalid,
    input  logic                  bready,

    // AXI4 Read Channels
    input  logic [ID_W-1:0]       arid,
    output logic [ID_W-1:0]       rid,
    input  logic [ADDR_WIDTH-1:0] araddr,
    input  logic [7:0]            arlen,
    input  logic                  arvalid,
    output logic                  arready,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic [1:0]            rresp,
    output logic                  rlast,
    output logic                  rvalid,
    input  logic                  rready,

    // Native SRAM Ports
    output logic [$clog2(SRAM_DEPTH)-1:0] sram_addr,
    output logic [DATA_WIDTH-1:0]         sram_wdata,
    output logic                          sram_wen,
    output logic                          sram_ren,
    input  logic [DATA_WIDTH-1:0]         sram_rdata
);

    typedef enum logic [1:0] {W_IDLE, W_BURST, W_RESP} w_state_t;
    typedef enum logic [1:0] {R_IDLE, R_BURST, R_WAIT_LAST} r_state_t;
    
    w_state_t w_state;
    r_state_t r_state;

    logic [ADDR_WIDTH-1:0] w_addr_reg, r_addr_reg;
    logic [7:0] rlen_cnt;
    logic rvalid_reg, rlast_reg;

    // ---------------------------------------------------------
    // WRITE FSM
    // ---------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_state <= W_IDLE;
            awready <= 1'b1;
            wready  <= 1'b0;
            bvalid  <= 1'b0;
        end else begin
            case (w_state)
                W_IDLE: begin
                    if (awvalid && awready) begin
                        awready    <= 1'b0;
                        w_addr_reg <= awaddr;
                        bid        <= awid;
                        wready     <= 1'b1;
                        w_state    <= W_BURST;
                    end
                end
                W_BURST: begin
                    if (wvalid && wready) begin
                        w_addr_reg <= w_addr_reg + (DATA_WIDTH/8);
                        if (wlast) begin
                            wready  <= 1'b0;
                            bvalid  <= 1'b1;
                            w_state <= W_RESP;
                        end
                    end
                end
                W_RESP: begin
                    if (bvalid && bready) begin
                        bvalid  <= 1'b0;
                        awready <= 1'b1;
                        w_state <= W_IDLE;
                    end
                end
            endcase
        end
    end

    assign sram_wen   = (w_state == W_BURST) && wvalid && wready;
    assign sram_wdata = wdata;

    // ---------------------------------------------------------
    // READ FSM (Handles 1-cycle latency)
    // ---------------------------------------------------------
    assign sram_ren = (r_state == R_BURST) && (!rvalid_reg || rready);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rvalid_reg <= 1'b0;
            rlast_reg  <= 1'b0;
            r_state    <= R_IDLE;
            arready    <= 1'b1;
        end else begin
            case (r_state)
                R_IDLE: begin
                    if (arvalid && arready) begin
                        arready    <= 1'b0;
                        r_addr_reg <= araddr;
                        rid        <= arid;
                        rlen_cnt   <= arlen;
                        r_state    <= R_BURST;
                    end
                end
                R_BURST: begin
                    if (rvalid_reg && rready) rvalid_reg <= 1'b0;

                    if (sram_ren) begin
                        rvalid_reg <= 1'b1;
                        rlast_reg  <= (rlen_cnt == 0);
                        r_addr_reg <= r_addr_reg + (DATA_WIDTH/8);
                        rlen_cnt   <= rlen_cnt - 1;
                        if (rlen_cnt == 0) r_state <= R_WAIT_LAST;
                    end
                end
                R_WAIT_LAST: begin
                    if (rvalid_reg && rready) begin
                        rvalid_reg <= 1'b0;
                        arready    <= 1'b1;
                        r_state    <= R_IDLE;
                    end
                end
            endcase
        end
    end

    assign rvalid = rvalid_reg;
    assign rlast  = rlast_reg;
    assign rdata  = sram_rdata;
    assign rresp  = 2'b00; // OKAY
    assign bresp  = 2'b00; // OKAY

    // Shift byte-address to word-address
    assign sram_addr = sram_wen ? w_addr_reg[$clog2(SRAM_DEPTH)+1 : 2] : r_addr_reg[$clog2(SRAM_DEPTH)+1 : 2];

endmodule
