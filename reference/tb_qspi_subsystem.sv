`timescale 1ns/1ps
// =========================================================================
// Master Testbench
// =========================================================================
module tb_qspi_subsystem;
  import axi_qspi_pkg::*;

  // Parameters
  localparam C_S_AXI_DATA_WIDTH = 32;
  localparam C_S_AXI_ADDR_WIDTH = 8;
  localparam C_M_AXI_DATA_WIDTH = 32;
  localparam C_M_AXI_ADDR_WIDTH = 32;

  // Clocks and Reset
  logic clk;
  logic rst_n;

  // AXI4 Peripheral (Config) Interface
  logic [C_S_AXI_ADDR_WIDTH-1:0] s_awaddr;
  logic [7:0]                    s_awlen;
  logic [2:0]                    s_awsize;
  logic [1:0]                    s_awburst;
  logic                          s_awvalid;
  logic                          s_awready;
  logic [C_S_AXI_DATA_WIDTH-1:0] s_wdata;
  logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_wstrb;
  logic                          s_wlast;
  logic                          s_wvalid;
  logic                          s_wready;
  logic [1:0]                    s_bresp;
  logic                          s_bvalid;
  logic                          s_bready;
  logic [C_S_AXI_ADDR_WIDTH-1:0] s_araddr;
  logic [7:0]                    s_arlen;
  logic [2:0]                    s_arsize;
  logic [1:0]                    s_arburst;
  logic                          s_arvalid;
  logic                          s_arready;
  logic [C_S_AXI_DATA_WIDTH-1:0] s_rdata;
  logic [1:0]                    s_rresp;
  logic                          s_rlast;
  logic                          s_rvalid;
  logic                          s_rready;

  // RV SRAM Fetch Interface
  logic                          sram_req;
  logic [C_M_AXI_ADDR_WIDTH-1:0] sram_addr;
  logic                          sram_gnt;
  logic                          sram_rvalid;
  logic [C_M_AXI_DATA_WIDTH-1:0] sram_rdata;

  // AXI4 Memory Interface (Output of Bridge)
  logic [C_M_AXI_ADDR_WIDTH-1:0] m_araddr;
  logic [7:0]                    m_arlen;
  logic [2:0]                    m_arsize;
  logic [1:0]                    m_arburst;
  logic                          m_arvalid;
  logic                          m_arready;
  logic [C_M_AXI_DATA_WIDTH-1:0] m_rdata;
  logic [1:0]                    m_rresp;
  logic                          m_rlast;
  logic                          m_rvalid;
  logic                          m_rready;

  // QSPI Physical Interface
  logic       qspi_sclk;
  logic       qspi_cs_n;
  logic [3:0] qspi_io_i;
  logic [3:0] qspi_io_o;
  logic [3:0] qspi_io_oe;
  logic       qspi_irq;

  // Flash IO Mapping & Pullups
  wire flash_dio;
  wire flash_do;
  wire flash_wpn;
  wire flash_holdn;

  // pullup(flash_wpn);
  // pullup(flash_holdn);

  assign flash_dio   = qspi_io_oe[0] ? qspi_io_o[0] : 1'bz;
  assign flash_do    = qspi_io_oe[1] ? qspi_io_o[1] : 1'bz;
  assign flash_wpn   = qspi_io_oe[2] ? qspi_io_o[2] : 1'bz;
  assign flash_holdn = qspi_io_oe[3] ? qspi_io_o[3] : 1'bz;

  assign qspi_io_i[0] = flash_dio;
  assign qspi_io_i[1] = flash_do;
  assign qspi_io_i[2] = flash_wpn;
  assign qspi_io_i[3] = flash_holdn;

  // Clock Generation
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // -----------------------------------------------------------
  // DUT Instantiations
  // -----------------------------------------------------------
  axi_qspi_wrapper #(
    .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH),
    .C_M_AXI_DATA_WIDTH(C_M_AXI_DATA_WIDTH),
    .C_M_AXI_ADDR_WIDTH(C_M_AXI_ADDR_WIDTH)
  ) u_qspi_controller (
    .i_qspi_aclk      (clk),
    .i_qspi_aresetn   (rst_n),
    .i_qspi_s_awaddr  (s_awaddr),
    .i_qspi_s_awlen   (s_awlen),
    .i_qspi_s_awsize  (s_awsize),
    .i_qspi_s_awburst (s_awburst),
    .i_qspi_s_awvalid (s_awvalid),
    .o_qspi_s_awready (s_awready),
    .i_qspi_s_wdata   (s_wdata),
    .i_qspi_s_wstrb   (s_wstrb),
    .i_qspi_s_wlast   (s_wlast),
    .i_qspi_s_wvalid  (s_wvalid),
    .o_qspi_s_wready  (s_wready),
    .o_qspi_s_bresp   (s_bresp),
    .o_qspi_s_bvalid  (s_bvalid),
    .i_qspi_s_bready  (s_bready),
    .i_qspi_s_araddr  (s_araddr),
    .i_qspi_s_arlen   (s_arlen),
    .i_qspi_s_arsize  (s_arsize),
    .i_qspi_s_arburst (s_arburst),
    .i_qspi_s_arvalid (s_arvalid),
    .o_qspi_s_arready (s_arready),
    .o_qspi_s_rdata   (s_rdata),
    .o_qspi_s_rresp   (s_rresp),
    .o_qspi_s_rlast   (s_rlast),
    .o_qspi_s_rvalid  (s_rvalid),
    .i_qspi_s_rready  (s_rready),
    .i_qspi_m_araddr  (m_araddr),
    .i_qspi_m_arlen   (m_arlen),
    .i_qspi_m_arsize  (m_arsize),
    .i_qspi_m_arburst (m_arburst),
    .i_qspi_m_arvalid (m_arvalid),
    .o_qspi_m_arready (m_arready),
    .o_qspi_m_rdata   (m_rdata),
    .o_qspi_m_rresp   (m_rresp),
    .o_qspi_m_rlast   (m_rlast),
    .o_qspi_m_rvalid  (m_rvalid),
    .i_qspi_m_rready  (m_rready),
    .o_qspi_sclk      (qspi_sclk),
    .o_qspi_cs_n      (qspi_cs_n),
    .i_qspi_io_i      (qspi_io_i),
    .o_qspi_io_o      (qspi_io_o),
    .o_qspi_io_oe     (qspi_io_oe),
    .o_qspi_irq       (qspi_irq)
  );

  sram_to_axi4_bridge #(
    .C_M_AXI_ADDR_WIDTH(C_M_AXI_ADDR_WIDTH),
    .C_M_AXI_DATA_WIDTH(C_M_AXI_DATA_WIDTH)
  ) u_bridge (
    .clk          (clk),
    .rst_n        (rst_n),
    .sram_req     (sram_req),
    .sram_addr    (sram_addr),
    .sram_gnt     (sram_gnt),
    .sram_rvalid  (sram_rvalid),
    .sram_rdata   (sram_rdata),
    .m_araddr     (m_araddr),
    .m_arlen      (m_arlen),
    .m_arsize     (m_arsize),
    .m_arburst    (m_arburst),
    .m_arvalid    (m_arvalid),
    .m_arready    (m_arready),
    .m_rdata      (m_rdata),
    .m_rresp      (m_rresp),
    .m_rlast      (m_rlast),
    .m_rvalid     (m_rvalid),
    .m_rready     (m_rready)
  );

  W25Q16JV u_flash (
    .CSn   (qspi_cs_n),
    .CLK   (qspi_sclk),
    .DIO   (flash_dio),
    .DO    (flash_do),
    .WPn   (flash_wpn),
    .HOLDn (flash_holdn)
  );

  // -----------------------------------------------------------
  // AXI BFM Tasks (Strictly Synchronous, Blocking Assignments)
  // -----------------------------------------------------------
  task automatic axi_write(input [7:0] addr, input [31:0] data);
    begin
      $display("[%0t] [AXI_WRITE] Initiating AW/W for ADDR: 0x%02h, DATA: 0x%08h", $time, addr, data);
      
      // 1. Address Write Phase
      @(posedge clk); #1;
      s_awvalid = 1'b1; 
      s_awaddr  = addr;
      s_awlen   = 8'd0;
      s_awsize  = 3'd2;
      s_awburst = 2'b01;
      
      do begin
        @(posedge clk);
      end while (!s_awready);
      #1; s_awvalid = 1'b0;

      // 2. Data Write Phase
      s_wvalid = 1'b1; 
      s_wdata  = data; 
      s_wstrb  = 4'hF; 
      s_wlast  = 1'b1;

      do begin
        @(posedge clk);
      end while (!s_wready);
      #1; s_wvalid = 1'b0; 
      s_wlast  = 1'b0;

      // 3. Response Phase
      do begin
        @(posedge clk);
      end while (!s_bvalid);
      $display("[%0t] [AXI_WRITE] Handshake complete for ADDR: 0x%02h", $time, addr);
    end
  endtask

  task automatic axi_read(input [7:0] addr, output [31:0] data);
    begin
      $display("[%0t] [AXI_READ]  Initiating AR for ADDR: 0x%02h", $time, addr);
      
      // 1. Address Read Phase
      @(posedge clk); #1;
      s_arvalid = 1'b1;
      s_araddr  = addr;
      s_arlen   = 8'd0;
      s_arsize  = 3'd2;
      s_arburst = 2'b01;

      do begin
        @(posedge clk);
      end while (!s_arready);
      #1; s_arvalid = 1'b0;

      // 2. Data Read Phase
      do begin
        @(posedge clk);
      end while (!s_rvalid);
      data = s_rdata;
      $display("[%0t] [AXI_READ]  Handshake complete. Received DATA: 0x%08h", $time, data);
    end
  endtask

  // -----------------------------------------------------------
  // Main Test Sequence
  // -----------------------------------------------------------
  initial begin
    int fd;
    logic [31:0] rdata;
    logic [7:0]  byte0, byte1, byte2, byte3;
    logic [31:0] shadow_word;
    
    // Generate dummy files ONLY to prevent fatal IO missing errors
    // fd = $fopen("SECSI.TXT", "w"); if(fd) $fclose(fd);
    // fd = $fopen("SFDP.TXT", "w");  if(fd) $fclose(fd);
    // fd = $fopen("SREG.TXT", "w");  if(fd) begin $fdisplay(fd, "00 00 00"); $fclose(fd); end
    
    // Static Initializations
    s_awvalid = 0; s_wvalid = 0; s_bready = 1; 
    s_arvalid = 0; s_rready = 1; sram_req = 0; 
    s_awaddr  = 0; s_awlen  = 0; s_awsize = 0; s_awburst = 0;
    s_wdata   = 0; s_wstrb  = 0; s_wlast  = 0;
    s_araddr  = 0; s_arlen  = 0; s_arsize = 0; s_arburst = 0;
    sram_addr = 0;
    
    rst_n = 0;
    #100;
    rst_n = 1;
    #100;

    // -----------------------------------------------------------
    // 1. RAM Shadowing Test
    // -----------------------------------------------------------
    $display("\n[%0t] === STARTING RAM SHADOWING TEST ===", $time);
    
    axi_write(AXI_QSPI_ADDR_DUMMY, 32'h0000_0008);
    axi_write(AXI_QSPI_ADDR_FLASH_ADDR, 32'h0000_0000); 
    axi_write(AXI_QSPI_ADDR_LEN, 32'h0000_0004); 
    axi_write(AXI_QSPI_ADDR_CMD, 32'h0000_006B);
    axi_write(AXI_QSPI_ADDR_CLKDIV, 32'h0000_0000);

    
    $display("[%0t] [TEST] Firing Config Interface Read Command...", $time);
    axi_write(AXI_QSPI_ADDR_CTRL, 32'h0000_0001); 

    do begin
      #500;
      axi_read(AXI_QSPI_ADDR_STATUS, rdata);
    end while (rdata[0] == 1'b1);
    
    axi_read(AXI_QSPI_ADDR_RXDATA, rdata); byte0 = rdata[7:0]; 
    axi_read(AXI_QSPI_ADDR_RXDATA, rdata); byte1 = rdata[7:0]; 
    axi_read(AXI_QSPI_ADDR_RXDATA, rdata); byte2 = rdata[7:0]; 
    axi_read(AXI_QSPI_ADDR_RXDATA, rdata); byte3 = rdata[7:0]; 
    
    shadow_word = {byte3, byte2, byte1, byte0};
    
    $display("[%0t] [RAM Shadow Result] Reconstructed Little-Endian 32-bit output: 0x%08h", $time, shadow_word);
    $display("[%0t] [Expected From MEM.TXT]                                      0x00000013", $time);

    #500;

    // -----------------------------------------------------------
    // 2. XIP Instruction Fetch Test
    // -----------------------------------------------------------
    $display("\n[%0t] === STARTING XIP INSTRUCTION FETCH TEST ===", $time);
    
    // Write Configuration
    axi_write(AXI_QSPI_ADDR_MODE, 32'h0000_0002); // Set Controller to QSPI_MODE_QUAD
    // axi_write(AXI_QSPI_ADDR_DUMMY, 32'h0000_0004); // 0xEB needs 6 total dummy cycles (2 mode + 4 pure dummy)
    // axi_write(AXI_QSPI_ADDR_XIP_MODE, 32'h0000_01FF);
    axi_write(AXI_QSPI_ADDR_DUMMY, 32'h0000_0006);
    axi_write(AXI_QSPI_ADDR_XIP_BASE, 32'h2000_0000);
    axi_write(AXI_QSPI_ADDR_XIP_MASK, 32'hFF00_0000); 
    axi_write(AXI_QSPI_ADDR_XIP_CMD,  32'h0000_006B); 
    axi_write(AXI_QSPI_ADDR_XIP_CTRL, 32'h0000_0001); 
    
    $display("[%0t] [DEBUG] Validating Hardware XIP Registers via Readback...", $time);
    axi_read(AXI_QSPI_ADDR_XIP_BASE, rdata); $display("        -> XIP_BASE READBACK: 0x%08h", rdata);
    axi_read(AXI_QSPI_ADDR_XIP_MASK, rdata); $display("        -> XIP_MASK READBACK: 0x%08h", rdata);
    axi_read(AXI_QSPI_ADDR_XIP_CTRL, rdata); $display("        -> XIP_CTRL READBACK: 0x%08h", rdata);

    $display("\n[%0t] [TEST] Issuing RV SRAM Instruction Request at 0x2000_0004...", $time);
    @(posedge clk); #1;
    sram_req  = 1'b1;
    sram_addr = 32'h2000_0004; 
    
    do begin
      @(posedge clk);
    end while (!sram_gnt);
    #1; sram_req = 1'b0;
    
    $display("[%0t] [TEST] SRAM Request Granted by Bridge.", $time);
    
    do begin
      @(posedge clk);
    end while (!sram_rvalid);
    
    if (m_rresp != 2'b00) begin
       $display("[%0t] [ERROR] XIP Read returned AXI ERROR Response: %0b", $time, m_rresp);
       $display("        -> This usually indicates w_xip_hit failed mask condition check.");
    end else begin
       $display("\n[%0t] [XIP Result] Instruction fetched via Memory AXI: 0x%08h", $time, sram_rdata);
       $display("[%0t] [Expected]                                     0x00000513\n", $time);
    end

    #1000;
    $display("[%0t] === TESTS COMPLETED ===", $time);
    $finish;
  end

  // Saftey Timeout
  initial begin
    #100_000_000;
    $display("[%0t] [TIMEOUT] Simulation Deadlocked.", $time);
    $finish;
  end

endmodule
