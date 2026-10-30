`timescale 1ns/1ps

// =========================================================================
// Sychronous SRAM to AXI4 Bridge
// =========================================================================
module sram_to_axi4_bridge #(
  parameter int C_M_AXI_ADDR_WIDTH = 32,
  parameter int C_M_AXI_DATA_WIDTH = 32
)(
  input  logic clk,
  input  logic rst_n,

  // RISC-V Native SRAM Fetch Interface
  input  logic                          sram_req,
  input  logic [C_M_AXI_ADDR_WIDTH-1:0] sram_addr,
  output logic                          sram_gnt,
  output logic                          sram_rvalid,
  output logic [C_M_AXI_DATA_WIDTH-1:0] sram_rdata,

  // AXI4 Master Interface
  output logic [C_M_AXI_ADDR_WIDTH-1:0] m_araddr,
  output logic [7:0]                    m_arlen,
  output logic [2:0]                    m_arsize,
  output logic [1:0]                    m_arburst,
  output logic                          m_arvalid,
  input  logic                          m_arready,

  input  logic [C_M_AXI_DATA_WIDTH-1:0] m_rdata,
  input  logic [1:0]                    m_rresp,
  input  logic                          m_rlast,
  input  logic                          m_rvalid,
  output logic                          m_rready
);

  typedef enum logic [1:0] {IDLE, AR_BUSY, R_BUSY} state_t;
  state_t state, next_state;

  logic [C_M_AXI_ADDR_WIDTH-1:0] latched_addr;

  assign m_arlen   = 8'd0;    
  assign m_arsize  = 3'd2;    
  assign m_arburst = 2'b01;   

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= IDLE;
      latched_addr <= '0;
    end else begin
      state <= next_state;
      if (sram_req && state == IDLE) begin
        latched_addr <= sram_addr; // Latch for subsequent cycles
      end
    end
  end

  always_comb begin
    next_state = state;
    m_arvalid  = 1'b0;
    m_rready   = 1'b0;
    sram_gnt   = 1'b0;

    // CRITICAL FIX: Combinatorial routing ensures Address is valid exactly alongside m_arvalid
    m_araddr = (state == IDLE) ? sram_addr : latched_addr;

    case (state)
      IDLE: begin
        if (sram_req) begin
          m_arvalid = 1'b1;
          if (m_arready) begin
            sram_gnt = 1'b1;
            next_state = R_BUSY;
          end else begin
            next_state = AR_BUSY;
          end
        end
      end

      AR_BUSY: begin
        m_arvalid = 1'b1;
        if (m_arready) begin
          sram_gnt = 1'b1;
          next_state = R_BUSY;
        end
      end

      R_BUSY: begin
        m_rready = 1'b1;
        if (m_rvalid) begin
          next_state = IDLE;
        end
      end
      
      default: next_state = IDLE;
    endcase
  end

  assign sram_rvalid = (state == R_BUSY) && m_rvalid;
  assign sram_rdata  = m_rdata;

endmodule
