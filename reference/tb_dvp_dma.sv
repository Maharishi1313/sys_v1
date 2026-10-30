// `timescale 1ns / 1ps

// module tb_dvp_dma;

//     // =========================================================================
//     // Parameters & Runtime Mode Toggles
//     // =========================================================================
//     localparam ADDR_W        = 32;
//     localparam DATA_W        = 32;
//     localparam ID_W          = 4;
//     localparam DRC_BASE_ADDR = 32'h6001_0000;
//     localparam DMA_BASE_ADDR = 32'h6000_0010;
    
//     // --- NEW: RUNTIME FEATURE TOGGLES ---
//     localparam logic EN_GRAYSCALE = 1'b1; // 1: 8-bit Grayscale (0x00GG), 0: RGB565
//     localparam logic EN_DOWNSCALE = 1'b1; // 1: 2x2 Pooling, 0: Full Res
    
//     // Test image geometry (Input)
//     localparam IMG_W         = 56; 
//     localparam IMG_H         = 56;
//     localparam TOTAL_PIXELS  = IMG_W * IMG_H;
    
//     // Calculated Output Geometry
//     localparam OUT_W         = EN_DOWNSCALE ? (IMG_W / 2) : IMG_W;
//     localparam OUT_H         = EN_DOWNSCALE ? (IMG_H / 2) : IMG_H;
//     localparam OUT_PIXELS    = OUT_W * OUT_H;
    
//     // The resizer guarantees output is ALWAYS 16 bits wide (2 bytes) per pixel
//     localparam OUT_BYTES     = OUT_PIXELS * 2; 
//     localparam OUT_WORDS     = OUT_BYTES / 4;  // 32-bit DMA transfers
    
//     localparam DTCM_BASE     = 32'h0000_0000;

//     // =========================================================================
//     // Signals
//     // =========================================================================
//     logic clk, rst_n;
//     logic dvp_pclk_i;
    
//     logic [7:0] dvp_d_i;
//     logic       dvp_href_i, dvp_vsync_i, dvp_hsync_i;
//     wire        dvp_xclk_o, dvp_pwdn_o;

//     // AXI Slave 1 (DRC Config)
//     logic [ID_W-1:0]   s_drc_awid, s_drc_arid, s_drc_bid, s_drc_rid;
//     logic [ADDR_W-1:0] s_drc_awaddr, s_drc_araddr;
//     logic [7:0]        s_drc_awlen, s_drc_arlen;
//     logic [2:0]        s_drc_awsize, s_drc_arsize;
//     logic [1:0]        s_drc_awburst, s_drc_arburst, s_drc_bresp, s_drc_rresp;
//     logic [DATA_W-1:0] s_drc_wdata, s_drc_rdata;
//     logic [3:0]        s_drc_wstrb;
//     logic s_drc_awvalid, s_drc_awready, s_drc_wlast, s_drc_wvalid, s_drc_wready;
//     logic s_drc_bvalid, s_drc_bready, s_drc_arvalid, s_drc_arready;
//     logic s_drc_rlast, s_drc_rvalid, s_drc_rready;

//     // AXI Slave 2 (DMA Config)
//     logic [ID_W-1:0]   s_dma_awid, s_dma_arid, s_dma_bid, s_dma_rid;
//     logic [ADDR_W-1:0] s_dma_awaddr, s_dma_araddr;
//     logic [7:0]        s_dma_awlen, s_dma_arlen;
//     logic [2:0]        s_dma_awsize, s_dma_arsize;
//     logic [1:0]        s_dma_awburst, s_dma_arburst, s_dma_bresp, s_dma_rresp;
//     logic [DATA_W-1:0] s_dma_wdata, s_dma_rdata;
//     logic [3:0]        s_dma_wstrb;
//     logic s_dma_awvalid, s_dma_awready, s_dma_wlast, s_dma_wvalid, s_dma_wready;
//     logic s_dma_bvalid, s_dma_bready, s_dma_arvalid, s_dma_arready;
//     logic s_dma_rlast, s_dma_rvalid, s_dma_rready;

//     // AXI Master (DMA to DTCM)
//     wire [ID_W-1:0]   m_dma_awid, m_dma_bid;
//     wire [ADDR_W-1:0] m_dma_awaddr;
//     wire [7:0]        m_dma_awlen;
//     wire [1:0]        m_dma_awburst, m_dma_bresp;
//     wire              m_dma_awvalid, m_dma_awready;
//     wire [DATA_W-1:0] m_dma_wdata;
//     wire              m_dma_wlast, m_dma_wvalid, m_dma_wready;
//     wire              m_dma_bvalid, m_dma_bready;

//     wire drc_irq, drc_trap, dma_irq, dma_trap;

//     reg [15:0] source_image [0:TOTAL_PIXELS-1];
//     reg [31:0] dtcm_mem     [0:4095]; 

//     initial clk = 0;
//     always #5 clk = ~clk; 

//     initial dvp_pclk_i = 1;
//     // async delay generation
    
//     always #25 dvp_pclk_i = ~dvp_pclk_i;   // 25 mhz pclk

//     initial begin
//         rst_n = 0;
//         #55 rst_n = 1;
//     end

//     // =========================================================================
//     // DUT Instantiation
//     // =========================================================================
//     dvp_dma_wrapper #(
//         .ADDR_W       (ADDR_W),
//         .DATA_W       (DATA_W),
//         .ID_W         (ID_W),
//         .DRC_BASE_ADDR(DRC_BASE_ADDR),
//         .DMA_BASE_ADDR(DMA_BASE_ADDR),
//         .FRM_COL_NUM  (IMG_W),
//         .FRM_ROW_NUM  (IMG_H)
//     ) dut (
//         .clk              (clk),
//         .rst_n            (rst_n),
//         .dvp_d_i          (dvp_d_i),
//         .dvp_href_i       (dvp_href_i),
//         .dvp_vsync_i      (dvp_vsync_i),
//         .dvp_hsync_i      (dvp_hsync_i),
//         .dvp_pclk_i       (dvp_pclk_i),
//         .dvp_xclk_o       (dvp_xclk_o),
//         .dvp_pwdn_o       (dvp_pwdn_o),
        
//         // DRC Config
//         .s_axi_drc_awid   (s_drc_awid),     .s_axi_drc_awaddr (s_drc_awaddr),
//         .s_axi_drc_awlen  (s_drc_awlen),    .s_axi_drc_awsize (s_drc_awsize),
//         .s_axi_drc_awburst(s_drc_awburst),  .s_axi_drc_awvalid(s_drc_awvalid),
//         .s_axi_drc_awready(s_drc_awready),  .s_axi_drc_wdata  (s_drc_wdata),
//         .s_axi_drc_wstrb  (s_drc_wstrb),    .s_axi_drc_wlast  (s_drc_wlast),
//         .s_axi_drc_wvalid (s_drc_wvalid),   .s_axi_drc_wready (s_drc_wready),
//         .s_axi_drc_bid    (s_drc_bid),      .s_axi_drc_bresp  (s_drc_bresp),
//         .s_axi_drc_bvalid (s_drc_bvalid),   .s_axi_drc_bready (s_drc_bready),
//         .s_axi_drc_arid   (s_drc_arid),     .s_axi_drc_araddr (s_drc_araddr),
//         .s_axi_drc_arlen  (s_drc_arlen),    .s_axi_drc_arsize (s_drc_arsize),
//         .s_axi_drc_arburst(s_drc_arburst),  .s_axi_drc_arvalid(s_drc_arvalid),
//         .s_axi_drc_arready(s_drc_arready),  .s_axi_drc_rid    (s_drc_rid),
//         .s_axi_drc_rdata  (s_drc_rdata),    .s_axi_drc_rresp  (s_drc_rresp),
//         .s_axi_drc_rlast  (s_drc_rlast),    .s_axi_drc_rvalid (s_drc_rvalid),
//         .s_axi_drc_rready (s_drc_rready),

//         // DMA Config
//         .s_axi_dma_awid   (s_dma_awid),     .s_axi_dma_awaddr (s_dma_awaddr),
//         .s_axi_dma_awlen  (s_dma_awlen),    .s_axi_dma_awsize (s_dma_awsize),
//         .s_axi_dma_awburst(s_dma_awburst),  .s_axi_dma_awvalid(s_dma_awvalid),
//         .s_axi_dma_awready(s_dma_awready),  .s_axi_dma_wdata  (s_dma_wdata),
//         .s_axi_dma_wstrb  (s_dma_wstrb),    .s_axi_dma_wlast  (s_dma_wlast),
//         .s_axi_dma_wvalid (s_dma_wvalid),   .s_axi_dma_wready (s_dma_wready),
//         .s_axi_dma_bid    (s_dma_bid),      .s_axi_dma_bresp  (s_dma_bresp),
//         .s_axi_dma_bvalid (s_dma_bvalid),   .s_axi_dma_bready (s_dma_bready),
//         .s_axi_dma_arid   (s_dma_arid),     .s_axi_dma_araddr (s_dma_araddr),
//         .s_axi_dma_arlen  (s_dma_arlen),    .s_axi_dma_arsize (s_dma_arsize),
//         .s_axi_dma_arburst(s_dma_arburst),  .s_axi_dma_arvalid(s_dma_arvalid),
//         .s_axi_dma_arready(s_dma_arready),  .s_axi_dma_rid    (s_dma_rid),
//         .s_axi_dma_rdata  (s_dma_rdata),    .s_axi_dma_rresp  (s_dma_rresp),
//         .s_axi_dma_rlast  (s_dma_rlast),    .s_axi_dma_rvalid (s_dma_rvalid),
//         .s_axi_dma_rready (s_dma_rready),

//         // AXI Master out to DTCM
//         .m_axi_dma_awid   (m_dma_awid),     .m_axi_dma_awaddr (m_dma_awaddr),
//         .m_axi_dma_awlen  (m_dma_awlen),    .m_axi_dma_awburst(m_dma_awburst),
//         .m_axi_dma_awvalid(m_dma_awvalid),  .m_axi_dma_awready(m_dma_awready),
//         .m_axi_dma_wdata  (m_dma_wdata),    .m_axi_dma_wlast  (m_dma_wlast),
//         .m_axi_dma_wvalid (m_dma_wvalid),   .m_axi_dma_wready (m_dma_wready),
//         .m_axi_dma_bid    (m_dma_bid),      .m_axi_dma_bresp  (m_dma_bresp),
//         .m_axi_dma_bvalid (m_dma_bvalid),   .m_axi_dma_bready (m_dma_bready),

//         .drc_irq          (drc_irq),
//         .drc_trap         (drc_trap),
//         .dma_irq          (dma_irq),
//         .dma_trap         (dma_trap)
//     );

//     // =========================================================================
//     // AXI Slave Write Tasks
//     // =========================================================================
//     task automatic write_drc(input [31:0] addr, input [31:0] data);
//         @(posedge clk); #1;
//         s_drc_awvalid = 1; s_drc_awaddr = addr;
//         s_drc_awid = 0; s_drc_awburst = 2'b01; s_drc_awlen = 0;
//         @(posedge clk); while (!s_drc_awready) @(posedge clk);
//         #1; s_drc_awvalid = 0;
        
//         @(posedge clk); #1;
//         s_drc_wvalid = 1; s_drc_wdata = data; s_drc_wlast = 1; s_drc_wstrb = 4'hF;
//         @(posedge clk); while (!s_drc_wready) @(posedge clk);
//         #1; s_drc_wvalid = 0; s_drc_wlast = 0;
        
//         while (!s_drc_bvalid) @(posedge clk);
//         $display("[CFG] DRC 0x%08h <= 0x%08h", addr, data);
//     endtask

//     task automatic write_dma(input [31:0] addr, input [31:0] data);
//         @(posedge clk); #1;
//         s_dma_awvalid = 1; s_dma_awaddr = addr;
//         s_dma_awid = 0; s_dma_awburst = 2'b01; s_dma_awlen = 0;
//         @(posedge clk); while (!s_dma_awready) @(posedge clk);
//         #1; s_dma_awvalid = 0;
        
//         @(posedge clk); #1;
//         s_dma_wvalid = 1; s_dma_wdata = data; s_dma_wlast = 1; s_dma_wstrb = 4'hF;
//         @(posedge clk); while (!s_dma_wready) @(posedge clk);
//         #1; s_dma_wvalid = 0; s_dma_wlast = 0;
        
//         while (!s_dma_bvalid) @(posedge clk);
//         $display("[CFG] DMA 0x%08h <= 0x%08h", addr, data);
//     endtask

//     // =========================================================================
//     // FSM: DTCM Memory Slave (Receives pixels from DMA)
//     // =========================================================================
//     reg [1:0] dtcm_state = 0;
//     reg [ID_W-1:0] cap_awid;
//     reg [31:0] cap_awaddr;
//     reg [7:0]  cap_awlen;
//     reg [7:0]  w_beat = 0;

//     assign m_dma_awready = (dtcm_state == 0);
//     assign m_dma_wready  = (dtcm_state == 1);
//     assign m_dma_bvalid  = (dtcm_state == 2);
//     assign m_dma_bid     = cap_awid;
//     assign m_dma_bresp   = 2'b00;

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             dtcm_state <= 0;
//         end else begin
//             case (dtcm_state)
//                 0: begin
//                     if (m_dma_awvalid) begin
//                         cap_awid   <= m_dma_awid;
//                         cap_awaddr <= m_dma_awaddr;
//                         cap_awlen  <= m_dma_awlen;
//                         w_beat     <= 0;
//                         dtcm_state <= 1;
//                     end
//                 end
//                 1: begin
//                     if (m_dma_wvalid) begin
//                         // Safely calculate the index
//                         integer mem_idx;
//                         mem_idx = (cap_awaddr - DTCM_BASE)/4 + w_beat;
                        
//                         // Prevent Out-of-Bounds C++ Segfaults
//                         if (mem_idx >= 0 && mem_idx < 4096) begin
//                             dtcm_mem[mem_idx] <= m_dma_wdata;
//                         end else begin
//                             $display("[ERR] OOB Memory Write! Addr: 0x%08h", cap_awaddr);
//                         end
                        
//                         if (m_dma_wlast) dtcm_state <= 2;
//                         else w_beat <= w_beat + 1;
//                     end
//                 end
//                 2: begin
//                     if (m_dma_bready) dtcm_state <= 0;
//                 end
//             endcase
//         end
//     end

//     // =========================================================================
//     // MAIN TEST SEQUENCE
//     // =========================================================================
//     initial begin
//         s_drc_awvalid = 0; s_drc_wvalid = 0; s_drc_bready = 1;
//         s_drc_arvalid = 0; s_drc_rready = 1;
//         s_dma_awvalid = 0; s_dma_wvalid = 0; s_dma_bready = 1;
//         s_dma_arvalid = 0; s_dma_rready = 1;
        
//         dvp_vsync_i = 0; dvp_href_i = 0; dvp_hsync_i = 0; dvp_d_i = 0;
        
//         $readmemh("./python/input_image.hex", source_image);
//         $display("[INIT] Read image hex file.");

//         @(posedge rst_n);
//         repeat(10) @(posedge clk);
        
//         // ---------------------------------------------------------------------
//         // 1. Configure DMA Channel 0
//         // ---------------------------------------------------------------------
//         write_dma(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); // Global EN
//         write_dma(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); // Ch0 EN
//         write_dma(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); // 1D Mode
//         write_dma(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); // IRQ on Done
//         write_dma(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); // Dst burst INCR
//         write_dma(DMA_BASE_ADDR + 32'h0008, 32'd15);        // 16 beats per burst
//         write_dma(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     // DEST ADDR
        
//         // --- NEW: Dynamic length based on runtime mode ---
//         write_dma(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   // X_LEN
        
//         write_dma(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); // Submit descriptor
//         $display("[CFG] DMA programmed to fetch %0d words", OUT_WORDS);

//         // ---------------------------------------------------------------------
//         // 2. Configure DVP RX Controller
//         // // ---------------------------------------------------------------------
//         // write_drc(DRC_BASE_ADDR + 32'h10, 32'h0000_0003); // Enable IRQs
//         // write_drc(DRC_BASE_ADDR + 32'h14, IMG_W);         // INPUT Width
//         // write_drc(DRC_BASE_ADDR + 32'h18, IMG_H);         // INPUT Height
        
//         // // --- NEW: Write to DRC_PROC_CTRL [1]=Downscale, [0]=Grayscale ---
//         // write_drc(DRC_BASE_ADDR + 32'h28, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
        
//         // write_drc(DRC_BASE_ADDR + 32'h00, 32'h0000_0001); // Enable Camera Core
//         // write_drc(DRC_BASE_ADDR + 32'h04, 32'h0000_0001); // Start Capture
//         // $display("[CFG] DVP RX started.");

        

//         // ---------------------------------------------------------------------
//         // 1. Configure DMA Channel 0
//         // ---------------------------------------------------------------------
//         // write_dma(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); // Global EN
//         // write_dma(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); // Ch0 EN
//         // write_dma(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); // 1D Mode
//         // write_dma(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); // IRQ on Done
//         // write_dma(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); // Dst burst INCR
//         // write_dma(DMA_BASE_ADDR + 32'h0008, 32'd15);        // 16 beats per burst
//         // write_dma(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     // DEST ADDR
        
//         // // --- NEW: Dynamic length based on runtime mode ---
//         // write_dma(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   // X_LEN
        
//         // write_dma(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); // Submit descriptor
//         // $display("[CFG] DMA programmed to fetch %0d words", OUT_WORDS);

//         // ---------------------------------------------------------------------
//         // 2. Configure DVP RX Controller 
//         // ---------------------------------------------------------------------
//         write_drc(DRC_BASE_ADDR + 32'h00, 32'h01);
//         write_drc(DRC_BASE_ADDR + 32'h01, 32'h01);
//         write_drc(DRC_BASE_ADDR + 32'h02, 32'h02);

//         write_drc(DRC_BASE_ADDR + 32'h03, 32'h0000_0003); // [0x0C] Enable IRQs
//         write_drc(DRC_BASE_ADDR + 32'h04, IMG_W);
//         write_drc(DRC_BASE_ADDR + 32'h05, IMG_H);         // [0x14] INPUT Height
        
//         // Write to your custom DRC_PROC_CTRL [1]=Downscale, [0]=Grayscale
//         write_drc(DRC_BASE_ADDR + 32'h06, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
        
//         write_drc(DRC_BASE_ADDR + 32'h10, 32'h0000_0001); // [0x00] Enable Camera Core
        
//         // Write IMG_W to 0x10. This sets rw_reg[4] (width) AND triggers cam_rx_start
//         // write_drc(DRC_BASE_ADDR + 32'h10, IMG_W);         
//         $display("[CFG] DVP RX started.");

//         // ---------------------------------------------------------------------
//         // 3. Stream FULL Virtual Image via DVP interface
//         // ---------------------------------------------------------------------
//         $display("[STREAM] Sending VSYNC...");
//         dvp_vsync_i = 1; repeat(20) @(posedge dvp_pclk_i); dvp_vsync_i = 0;
//         repeat(50) @(posedge dvp_pclk_i); 
        
//         $display("[STREAM] Streaming %0d rows...", IMG_H);
//         for (int r = 0; r < IMG_H; r++) begin
//             dvp_href_i = 1;
//             for (int c = 0; c < IMG_W; c++) begin
//                 dvp_d_i = source_image[r*IMG_W + c][15:8]; // High Byte
//                 @(posedge dvp_pclk_i);
//                 dvp_d_i = source_image[r*IMG_W + c][7:0];  // Low Byte
//                 @(posedge dvp_pclk_i);
//             end
//             dvp_href_i = 0;
//             repeat(30) @(posedge dvp_pclk_i); 
//         end
        
//         repeat(50) @(posedge dvp_pclk_i);
//         dvp_vsync_i = 1; repeat(20) @(posedge dvp_pclk_i); dvp_vsync_i = 0;
//         $display("[STREAM] Frame transfer complete.");

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         // $display("[WAIT] Waiting for DMA & DRC Interrupts...");
//         // fork
//         //     begin
//         //         wait (dma_irq == 1);
//         //         $display("[IRQ] DMA Transfer Complete!");
//         //     end
//         //     begin
//         //         wait (drc_irq == 1);
//         //         $display("[IRQ] DRC Capture Complete!");
//         //     end
//         // join
        

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         // $display("[WAIT] Waiting for DMA & DRC Interrupts...");
        
//         // // Single-threaded polling to prevent Verilator Segfaults
//         // while (!dma_irq || !drc_irq) begin
//         //     @(posedge clk);
//         //     if (dma_irq) $display("[IRQ] DMA Transfer Complete!");
//         //     if (drc_irq) $display("[IRQ] DRC Capture Complete!");
//         // end
//         // $display("[PASS] Both hardware blocks completed successfully.");

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         $display("[WAIT] Waiting for DMA & DRC Interrupts...");
//         begin
//             logic dma_done = 0;
//             logic drc_done = 0;
            
//             // Polling loop ensures no log-spam and no segfaults
//             while (!dma_done || !drc_done) begin
//                 @(posedge clk);
//                 if (dma_irq && !dma_done) begin
//                     $display("[IRQ] DMA Transfer Complete!");
//                     dma_done = 1;
//                 end
//                 if (drc_irq && !drc_done) begin
//                     $display("[IRQ] DRC Capture Complete!");
//                     drc_done = 1;
//                 end
//             end
//         end
//         $display("[PASS] Both hardware blocks completed successfully.");
        
//         // Dump the memory map to a file for Python reconstruction
//         begin
//             int fd;
//             fd = $fopen("./python/output_dtcm.hex", "w");
//             for (int i = 0; i < OUT_WORDS; i++) begin
//                 $fdisplay(fd, "%08x", dtcm_mem[i]);
//             end
//             $fclose(fd);
//             $display("[PASS] Memory dumped to output_dtcm.hex");
//         end

//         #1000;
//         $finish;
//     end

//     initial begin
//         #10_000;
//         $display("[TIMEOUT] Simulation stalled.");
//         $finish;
//     end

// endmodule


// `timescale 1ns / 1ps

// module tb_dvp_dma;

//     // =========================================================================
//     // Parameters & Runtime Mode Toggles
//     // =========================================================================
//     localparam ADDR_W        = 32;
//     localparam DATA_W        = 32;
//     localparam ID_W          = 4;
//     localparam DRC_BASE_ADDR = 32'h6001_0000;
//     localparam DMA_BASE_ADDR = 32'h6000_0010;
    
//     // --- RUNTIME FEATURE TOGGLES ---
//     localparam logic EN_GRAYSCALE = 1'b1; 
//     localparam logic EN_DOWNSCALE = 1'b1; 
    
//     // Test image geometry (Input)
//     localparam IMG_W         = 56; 
//     localparam IMG_H         = 56;
//     localparam TOTAL_PIXELS  = IMG_W * IMG_H;
    
//     // Calculated Output Geometry
//     localparam OUT_W         = EN_DOWNSCALE ? (IMG_W / 2) : IMG_W;
//     localparam OUT_H         = EN_DOWNSCALE ? (IMG_H / 2) : IMG_H;
//     localparam OUT_PIXELS    = OUT_W * OUT_H;
    
//     localparam OUT_BYTES     = OUT_PIXELS * 2; 
//     localparam OUT_WORDS     = OUT_BYTES / 4;  // 32-bit DMA transfers
    
//     localparam DTCM_BASE     = 32'h0000_0000;

//     // =========================================================================
//     // Signals
//     // =========================================================================
//     logic clk, rst_n;
//     logic dvp_pclk_i;
    
//     logic [7:0] dvp_d_i;
//     logic       dvp_href_i, dvp_vsync_i, dvp_hsync_i;
//     wire        dvp_xclk_o, dvp_pwdn_o;

//     // AXI Slave 1 (DRC Config)
//     logic [ID_W-1:0]   s_drc_awid, s_drc_arid, s_drc_bid, s_drc_rid;
//     logic [ADDR_W-1:0] s_drc_awaddr, s_drc_araddr;
//     logic [7:0]        s_drc_awlen, s_drc_arlen;
//     logic [2:0]        s_drc_awsize, s_drc_arsize;
//     logic [1:0]        s_drc_awburst, s_drc_arburst, s_drc_bresp, s_drc_rresp;
//     logic [DATA_W-1:0] s_drc_wdata, s_drc_rdata;
//     logic [3:0]        s_drc_wstrb;
//     logic s_drc_awvalid, s_drc_awready, s_drc_wlast, s_drc_wvalid, s_drc_wready;
//     logic s_drc_bvalid, s_drc_bready, s_drc_arvalid, s_drc_arready;
//     logic s_drc_rlast, s_drc_rvalid, s_drc_rready;

//     // AXI Slave 2 (DMA Config)
//     logic [ID_W-1:0]   s_dma_awid, s_dma_arid, s_dma_bid, s_dma_rid;
//     logic [ADDR_W-1:0] s_dma_awaddr, s_dma_araddr;
//     logic [7:0]        s_dma_awlen, s_dma_arlen;
//     logic [2:0]        s_dma_awsize, s_dma_arsize;
//     logic [1:0]        s_dma_awburst, s_dma_arburst, s_dma_bresp, s_dma_rresp;
//     logic [DATA_W-1:0] s_dma_wdata, s_dma_rdata;
//     logic [3:0]        s_dma_wstrb;
//     logic s_dma_awvalid, s_dma_awready, s_dma_wlast, s_dma_wvalid, s_dma_wready;
//     logic s_dma_bvalid, s_dma_bready, s_dma_arvalid, s_dma_arready;
//     logic s_dma_rlast, s_dma_rvalid, s_dma_rready;

//     // AXI Master (DMA to DTCM)
//     wire [ID_W-1:0]   m_dma_awid, m_dma_bid;
//     wire [ADDR_W-1:0] m_dma_awaddr;
//     wire [7:0]        m_dma_awlen;
//     wire [1:0]        m_dma_awburst, m_dma_bresp;
//     wire              m_dma_awvalid, m_dma_awready;
//     wire [DATA_W-1:0] m_dma_wdata;
//     wire              m_dma_wlast, m_dma_wvalid, m_dma_wready;
//     wire              m_dma_bvalid, m_dma_bready;

//     wire drc_irq, drc_trap, dma_irq, dma_trap;

//     reg [15:0] source_image [0:TOTAL_PIXELS-1];
//     reg [31:0] dtcm_mem     [0:4095]; 

//     // Initialize arrays to prevent Verilator C++ Segfaults during VCD dumping
//     initial begin
//         for (int i = 0; i < 4096; i++) dtcm_mem[i] = 32'h0;
//         for (int i = 0; i < TOTAL_PIXELS; i++) source_image[i] = 16'h0;
//     end

//     // =========================================================================
//     // Clocks
//     // =========================================================================
//     initial clk = 0;
//     always #5 clk = ~clk; 

//     // Phase shift PCLK slightly to prevent internal CDC Race Conditions
//     initial begin
//         dvp_pclk_i = 0;
//         #3; 
//         forever #40 dvp_pclk_i = ~dvp_pclk_i; 
//     end

//     initial begin
//         rst_n = 0;
//         #55 rst_n = 1;
//     end

//     // =========================================================================
//     // DUT Instantiation
//     // =========================================================================
//     dvp_dma_wrapper #(
//         .ADDR_W       (ADDR_W),
//         .DATA_W       (DATA_W),
//         .ID_W         (ID_W),
//         .DRC_BASE_ADDR(DRC_BASE_ADDR),
//         .DMA_BASE_ADDR(DMA_BASE_ADDR),
//         .FRM_COL_NUM  (IMG_W),
//         .FRM_ROW_NUM  (IMG_H)
//     ) dut (
//         .clk              (clk),
//         .rst_n            (rst_n),
//         .dvp_d_i          (dvp_d_i),
//         .dvp_href_i       (dvp_href_i),
//         .dvp_vsync_i      (dvp_vsync_i),
//         .dvp_hsync_i      (dvp_hsync_i),
//         .dvp_pclk_i       (dvp_pclk_i),
//         .dvp_xclk_o       (dvp_xclk_o),
//         .dvp_pwdn_o       (dvp_pwdn_o),
        
//         .s_axi_drc_awid   (s_drc_awid),     .s_axi_drc_awaddr (s_drc_awaddr),
//         .s_axi_drc_awlen  (s_drc_awlen),    .s_axi_drc_awsize (s_drc_awsize),
//         .s_axi_drc_awburst(s_drc_awburst),  .s_axi_drc_awvalid(s_drc_awvalid),
//         .s_axi_drc_awready(s_drc_awready),  .s_axi_drc_wdata  (s_drc_wdata),
//         .s_axi_drc_wstrb  (s_drc_wstrb),    .s_axi_drc_wlast  (s_drc_wlast),
//         .s_axi_drc_wvalid (s_drc_wvalid),   .s_axi_drc_wready (s_drc_wready),
//         .s_axi_drc_bid    (s_drc_bid),      .s_axi_drc_bresp  (s_drc_bresp),
//         .s_axi_drc_bvalid (s_drc_bvalid),   .s_axi_drc_bready (s_drc_bready),
//         .s_axi_drc_arid   (s_drc_arid),     .s_axi_drc_araddr (s_drc_araddr),
//         .s_axi_drc_arlen  (s_drc_arlen),    .s_axi_drc_arsize (s_drc_arsize),
//         .s_axi_drc_arburst(s_drc_arburst),  .s_axi_drc_arvalid(s_drc_arvalid),
//         .s_axi_drc_arready(s_drc_arready),  .s_axi_drc_rid    (s_drc_rid),
//         .s_axi_drc_rdata  (s_drc_rdata),    .s_axi_drc_rresp  (s_drc_rresp),
//         .s_axi_drc_rlast  (s_drc_rlast),    .s_axi_drc_rvalid (s_drc_rvalid),
//         .s_axi_drc_rready (s_drc_rready),

//         .s_axi_dma_awid   (s_dma_awid),     .s_axi_dma_awaddr (s_dma_awaddr),
//         .s_axi_dma_awlen  (s_dma_awlen),    .s_axi_dma_awsize (s_dma_awsize),
//         .s_axi_dma_awburst(s_dma_awburst),  .s_axi_dma_awvalid(s_dma_awvalid),
//         .s_axi_dma_awready(s_dma_awready),  .s_axi_dma_wdata  (s_dma_wdata),
//         .s_axi_dma_wstrb  (s_dma_wstrb),    .s_axi_dma_wlast  (s_dma_wlast),
//         .s_axi_dma_wvalid (s_dma_wvalid),   .s_axi_dma_wready (s_dma_wready),
//         .s_axi_dma_bid    (s_dma_bid),      .s_axi_dma_bresp  (s_dma_bresp),
//         .s_axi_dma_bvalid (s_dma_bvalid),   .s_axi_dma_bready (s_dma_bready),
//         .s_axi_dma_arid   (s_dma_arid),     .s_axi_dma_araddr (s_dma_araddr),
//         .s_axi_dma_arlen  (s_dma_arlen),    .s_axi_dma_arsize (s_dma_arsize),
//         .s_axi_dma_arburst(s_dma_arburst),  .s_axi_dma_arvalid(s_dma_arvalid),
//         .s_axi_dma_arready(s_dma_arready),  .s_axi_dma_rid    (s_dma_rid),
//         .s_axi_dma_rdata  (s_dma_rdata),    .s_axi_dma_rresp  (s_dma_rresp),
//         .s_axi_dma_rlast  (s_dma_rlast),    .s_axi_dma_rvalid (s_dma_rvalid),
//         .s_axi_dma_rready (s_dma_rready),

//         .m_axi_dma_awid   (m_dma_awid),     .m_axi_dma_awaddr (m_dma_awaddr),
//         .m_axi_dma_awlen  (m_dma_awlen),    .m_axi_dma_awburst(m_dma_awburst),
//         .m_axi_dma_awvalid(m_dma_awvalid),  .m_axi_dma_awready(m_dma_awready),
//         .m_axi_dma_wdata  (m_dma_wdata),    .m_axi_dma_wlast  (m_dma_wlast),
//         .m_axi_dma_wvalid (m_dma_wvalid),   .m_axi_dma_wready (m_dma_wready),
//         .m_axi_dma_bid    (m_dma_bid),      .m_axi_dma_bresp  (m_dma_bresp),
//         .m_axi_dma_bvalid (m_dma_bvalid),   .m_axi_dma_bready (m_dma_bready),

//         .drc_irq          (drc_irq),
//         .drc_trap         (drc_trap),
//         .dma_irq          (dma_irq),
//         .dma_trap         (dma_trap)
//     );

//     // =========================================================================
//     // AXI Slave Write Tasks (Parallel Handshake to prevent deadlock)
//     // =========================================================================
//     task automatic write_drc(input [31:0] addr, input [31:0] data);
//         logic aw_done = 0; logic w_done  = 0;
//         @(posedge clk); #1;
//         s_drc_awvalid = 1; s_drc_awaddr = addr; s_drc_awid = 0; s_drc_awburst = 2'b01; s_drc_awlen = 0;
//         s_drc_wvalid = 1; s_drc_wdata = data; s_drc_wlast = 1; s_drc_wstrb = 4'hF;
//         while (!aw_done || !w_done) begin
//             @(posedge clk);
//             if (s_drc_awready && !aw_done) begin #1; s_drc_awvalid = 0; aw_done = 1; end
//             if (s_drc_wready && !w_done) begin #1; s_drc_wvalid = 0; s_drc_wlast = 0; w_done = 1; end
//         end
//         while (!s_drc_bvalid) @(posedge clk);
//         $display("[CFG] DRC 0x%08h <= 0x%08h", addr, data);
//     endtask

//     task automatic write_dma(input [31:0] addr, input [31:0] data);
//         logic aw_done = 0; logic w_done  = 0;
//         @(posedge clk); #1;
//         s_dma_awvalid = 1; s_dma_awaddr = addr; s_dma_awid = 0; s_dma_awburst = 2'b01; s_dma_awlen = 0;
//         s_dma_wvalid = 1; s_dma_wdata = data; s_dma_wlast = 1; s_dma_wstrb = 4'hF;
//         while (!aw_done || !w_done) begin
//             @(posedge clk);
//             if (s_dma_awready && !aw_done) begin #1; s_dma_awvalid = 0; aw_done = 1; end
//             if (s_dma_wready && !w_done) begin #1; s_dma_wvalid = 0; s_dma_wlast = 0; w_done = 1; end
//         end
//         while (!s_dma_bvalid) @(posedge clk);
//         $display("[CFG] DMA 0x%08h <= 0x%08h", addr, data);
//     endtask

//     // =========================================================================
//     // FSM: DTCM Memory Slave (Receives pixels from DMA)
//     // =========================================================================
//     reg [1:0] dtcm_state = 0;
//     reg [ID_W-1:0] cap_awid;
//     reg [31:0] cap_awaddr;
//     reg [7:0]  cap_awlen;
//     reg [7:0]  w_beat = 0;

//     assign m_dma_awready = (dtcm_state == 0);
//     assign m_dma_wready  = (dtcm_state == 1);
//     assign m_dma_bvalid  = (dtcm_state == 2);
//     assign m_dma_bid     = cap_awid;
//     assign m_dma_bresp   = 2'b00;

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             dtcm_state <= 0;
//         end else begin
//             case (dtcm_state)
//                 0: begin
//                     if (m_dma_awvalid) begin
//                         cap_awid   <= m_dma_awid;
//                         cap_awaddr <= m_dma_awaddr;
//                         cap_awlen  <= m_dma_awlen;
//                         w_beat     <= 0;
//                         dtcm_state <= 1;
//                     end
//                 end
//                 1: begin
//                     if (m_dma_wvalid) begin
//                         integer mem_idx;
//                         mem_idx = (cap_awaddr - DTCM_BASE)/4 + w_beat;
                        
//                         if (mem_idx >= 0 && mem_idx < 4096) begin
//                             dtcm_mem[mem_idx] <= m_dma_wdata;
//                         end
//                         if (m_dma_wlast) dtcm_state <= 2;
//                         else w_beat <= w_beat + 1;
//                     end
//                 end
//                 2: begin
//                     if (m_dma_bready) dtcm_state <= 0;
//                 end
//             endcase
//         end
//     end

//     // =========================================================================
//     // MAIN TEST SEQUENCE
//     // =========================================================================
//     initial begin
//         s_drc_awvalid = 0; s_drc_wvalid = 0; s_drc_bready = 1;
//         s_drc_arvalid = 0; s_drc_rready = 1;
//         s_dma_awvalid = 0; s_dma_wvalid = 0; s_dma_bready = 1;
//         s_dma_arvalid = 0; s_dma_rready = 1;
        
//         dvp_vsync_i = 0; dvp_href_i = 0; dvp_hsync_i = 0; dvp_d_i = 0;
        
//         $readmemh("./python/input_image.hex", source_image);
//         $display("[INIT] Read image hex file.");

//         @(posedge rst_n);
//         repeat(10) @(posedge clk);
        
//         // ---------------------------------------------------------------------
//         // 1. Configure DMA Channel 0
//         // ---------------------------------------------------------------------
//         write_dma(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); 
//         write_dma(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0008, 32'd15);        
//         write_dma(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     
//         write_dma(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   
//         write_dma(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); 
//         $display("[CFG] DMA programmed to fetch %0d words", OUT_WORDS);

//         // ---------------------------------------------------------------------
//         // 2. Configure DVP RX Controller (Using your exact mapped offsets)
//         // ---------------------------------------------------------------------
//         write_drc(DRC_BASE_ADDR + 32'h00, 32'h01);
//         write_drc(DRC_BASE_ADDR + 32'h01, 32'h00);
//         write_drc(DRC_BASE_ADDR + 32'h02, 32'h02);
//         write_drc(DRC_BASE_ADDR + 32'h03, 32'h0000_0003); 
//         write_drc(DRC_BASE_ADDR + 32'h04, IMG_W);
//         write_drc(DRC_BASE_ADDR + 32'h05, IMG_H);         
//         write_drc(DRC_BASE_ADDR + 32'h06, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
//         write_drc(DRC_BASE_ADDR + 32'h10, 32'h0000_0001); 
//         $display("[CFG] DVP RX started.");

//         // ---------------------------------------------------------------------
//         // CRITICAL FIX: Give the hardware time to fully enter PXL_ALIGN_ST 
//         // before firing the VSYNC pulse!
//         // ---------------------------------------------------------------------
//         #5000;

//         // ---------------------------------------------------------------------
//         // 3. Stream Virtual Image
//         // ---------------------------------------------------------------------
//         $display("[STREAM] Sending VSYNC...");
//         @(posedge dvp_pclk_i);
//         dvp_vsync_i = 1; 
//         repeat(20) @(posedge dvp_pclk_i); 
//         dvp_vsync_i = 0;
        
//         repeat(50) @(posedge dvp_pclk_i); 
        
//         $display("[STREAM] Streaming %0d rows...", IMG_H);
//         for (int r = 0; r < IMG_H; r++) begin
//             @(posedge dvp_pclk_i);
//             dvp_href_i = 1;
//             for (int c = 0; c < IMG_W; c++) begin
//                 dvp_d_i = source_image[r*IMG_W + c][15:8];
//                 @(posedge dvp_pclk_i);
//                 dvp_d_i = source_image[r*IMG_W + c][7:0];  
//                 @(posedge dvp_pclk_i);
//             end
//             dvp_href_i = 0;
//             repeat(30) @(posedge dvp_pclk_i); 
//         end
        
//         repeat(50) @(posedge dvp_pclk_i);
//         dvp_vsync_i = 1; 
//         repeat(20) @(posedge dvp_pclk_i); 
//         dvp_vsync_i = 0;
//         $display("[STREAM] Frame transfer complete.");

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         begin
//             logic dma_done = 0;
//             logic drc_done = 0;
            
//             while (!dma_done || !drc_done) begin
//                 @(posedge clk);
//                 if (dma_irq && !dma_done) begin
//                     $display("[IRQ] DMA Transfer Complete!");
//                     dma_done = 1;
//                 end
//                 if (drc_irq && !drc_done) begin
//                     $display("[IRQ] DRC Capture Complete!");
//                     drc_done = 1;
//                 end
//             end
//         end
//         $display("[PASS] Both hardware blocks completed successfully.");
        
//         begin
//             int fd;
//             fd = $fopen("./python/output_dtcm.hex", "w");
//             for (int i = 0; i < OUT_WORDS; i++) begin
//                 $fdisplay(fd, "%08x", dtcm_mem[i]);
//             end
//             $fclose(fd);
//             $display("[PASS] Memory dumped to output_dtcm.hex");
//         end

//         #1000;
//         $finish;
//     end

//     // Safety timeout (10 ms)
//     initial begin
//         #10_000_000;
//         $display("[TIMEOUT] Simulation stalled.");
//         $finish;
//     end

// endmodule

`timescale 1ns / 1ps
// =============================================================================
// tb_dvp_dma.sv  –  DVP RX + AXI-DMA subsystem testbench
//
// DUT : dvp_dma_wrapper (dvp_rx_core + axi_dma internally connected)
//
// What this bench does
// --------------------
//  1. Generates an independent free-running DVP PCLK from the start (not
//     gated on xclk), fed back through the xclk loopback with a 1-ns delay
//     to mimic camera output propagation.
//  2. Configures DMA channel registers (but does NOT submit descriptor yet).
//  3. Configures DVP RX Controller registers and triggers cam_rx_start.
//  4. Waits for XCLK to stabilise (cam_rx_en must be set first).
//  5. Submits the DMA descriptor so the DMA is armed just before pixels flow.
//  6. Streams a complete synthetic RGB-565 frame over the DVP interface.
//  7. Polls for drc_irq and dma_irq, then dumps DTCM memory to a file.
//
// Key bugs fixed versus the original tb_dvp_dma.sv
// -------------------------------------------------
//  A. pclk was derived from xclk via combinational assign – xclk is static
//     (0) until cam_rx_en=1, so any @(posedge dvp_pclk_i) before that hung
//     the simulation.  Fix: independent free-running pclk; xclk loopback
//     with #1 delay drives pclk_i exactly like the reference TB.
//
//  B. DMA descriptor was submitted BEFORE the DVP RX was enabled.  If no
//     AXIS data arrives the DMA descriptor queue can stall.
//     Fix: configure DMA regs first, enable DVP RX second, submit descriptor
//     last (right before streaming).
//
//  C. DTCM AXI slave FSM could not handle back-to-back AXI write bursts.
//     awready was only high in state-0, but the DMA may issue consecutive AW
//     beats; the old FSM serialised them one-at-a-time with no overlap.
//     Fix: rewritten with a proper AW-FIFO + W-FSM + B-channel path so the
//     slave can queue an incoming AW while it is still processing W-data.
//
//  D. write_drc / write_dma tasks used parallel handshake with local logic
//     variable initialisations that confuse some simulators and can create
//     race conditions if AW and W fire on the same edge.
//     Fix: clean sequential AW→W→B handshake, wait-on-ready style.
//
//  E. Simulation timeout was 10 ms which is marginal when bclk=100 MHz,
//     pclk=25 MHz and the full configuration + streaming sequence has to
//     complete.  Increased to 50 ms.
//
//  F. DVP data byte driving: data must be stable BEFORE the rising edge of
//     pclk that samples it.  Added #1 hold after posedge to match real
//     camera setup/hold (same pattern as reference TB's DVP_PCLK_DLY).
// =============================================================================

`timescale 1ns / 1ps
// =============================================================================
// tb_dvp_dma.sv  –  DVP RX + AXI-DMA subsystem testbench  (v3 – bug-fixed)
//
// Root-cause of the v2 hang (found from FST/hier analysis)
// --------------------------------------------------------
// dvp_pclk_i had TWO simultaneous drivers in the same reg:
//
//   Driver A (free-running):
//       always #DVP_CLK_HALF dvp_pclk_i = dvp_pclk_i ^ 1'b1;
//
//   Driver B (xclk mirror):
//       always @(dvp_xclk_o) begin #1; dvp_pclk_i <= dvp_xclk_o; end
//
// Once cam_rx_en=1 is written and dvp_xclk_o starts toggling, both drivers
// fire on dvp_pclk_i at incommensurable intervals (20 ns free-run vs 30 ns
// xclk-half-period at 16.7 MHz). Icarus evaluates the last delta-cycle
// winner, turning dvp_pclk_i into a chaotic, non-monotonic signal. The
// streaming task's @(posedge dvp_pclk_i) never fires on a clean edge and
// the simulation hangs.
//
// Fix: delete the free-running driver completely.
//       Use ONLY the xclk mirror (one driver, clean edges).
//       Sequence the streaming task AFTER cam_rx_en is confirmed written,
//       then explicitly wait for xclk to start toggling before any
//       @(posedge dvp_pclk_i) calls.
//
// Other changes vs v2
// -------------------
//  • DVP PCLK: single driver — xclk mirror with #1 propagation delay.
//  • Streaming task: simplified to negedge-drive / posedge-sample, matching
//    a real OV-series camera (data stable well before rising edge).
//  • wait_for_xclk() helper: spins on @(posedge clk) until xclk_o toggles,
//    guaranteeing pclk is running before the DVP task touches it.
//  • Explicit `wait(dvp_pwdn_o == 0)` guard removed (cam_pwdn defaults 0).
//  • Timeout bumped to 100 ms for safety; debug print on exit.
// =============================================================================

// `timescale 1ns / 1ps

// module tb_dvp_dma;

//     // =========================================================================
//     // Parameters & Runtime Mode Toggles
//     // =========================================================================
//     localparam ADDR_W        = 32;
//     localparam DATA_W        = 32;
//     localparam ID_W          = 4;
//     localparam DRC_BASE_ADDR = 32'h6001_0000;
//     localparam DMA_BASE_ADDR = 32'h6000_0010;
    
//     // --- NEW: RUNTIME FEATURE TOGGLES ---
//     localparam logic EN_GRAYSCALE = 1'b1; // 1: 8-bit Grayscale (0x00GG), 0: RGB565
//     localparam logic EN_DOWNSCALE = 1'b1; // 1: 2x2 Pooling, 0: Full Res
    
//     // Test image geometry (Input)
//     localparam IMG_W         = 56; 
//     localparam IMG_H         = 56;
//     localparam TOTAL_PIXELS  = IMG_W * IMG_H;
    
//     // Calculated Output Geometry
//     localparam OUT_W         = EN_DOWNSCALE ? (IMG_W / 2) : IMG_W;
//     localparam OUT_H         = EN_DOWNSCALE ? (IMG_H / 2) : IMG_H;
//     localparam OUT_PIXELS    = OUT_W * OUT_H;
    
//     // The resizer guarantees output is ALWAYS 16 bits wide (2 bytes) per pixel
//     localparam OUT_BYTES     = OUT_PIXELS * 2; 
//     localparam OUT_WORDS     = OUT_BYTES / 4;  // 32-bit DMA transfers
    
//     localparam DTCM_BASE     = 32'h0000_0000;

//     // =========================================================================
//     // Signals
//     // =========================================================================
//     logic clk, rst_n;
//     logic dvp_pclk_i;
    
//     logic [7:0] dvp_d_i;
//     logic       dvp_href_i, dvp_vsync_i, dvp_hsync_i;
//     wire        dvp_xclk_o, dvp_pwdn_o;

//     // AXI Slave 1 (DRC Config)
//     logic [ID_W-1:0]   s_drc_awid, s_drc_arid, s_drc_bid, s_drc_rid;
//     logic [ADDR_W-1:0] s_drc_awaddr, s_drc_araddr;
//     logic [7:0]        s_drc_awlen, s_drc_arlen;
//     logic [2:0]        s_drc_awsize, s_drc_arsize;
//     logic [1:0]        s_drc_awburst, s_drc_arburst, s_drc_bresp, s_drc_rresp;
//     logic [DATA_W-1:0] s_drc_wdata, s_drc_rdata;
//     logic [3:0]        s_drc_wstrb;
//     logic s_drc_awvalid, s_drc_awready, s_drc_wlast, s_drc_wvalid, s_drc_wready;
//     logic s_drc_bvalid, s_drc_bready, s_drc_arvalid, s_drc_arready;
//     logic s_drc_rlast, s_drc_rvalid, s_drc_rready;

//     // AXI Slave 2 (DMA Config)
//     logic [ID_W-1:0]   s_dma_awid, s_dma_arid, s_dma_bid, s_dma_rid;
//     logic [ADDR_W-1:0] s_dma_awaddr, s_dma_araddr;
//     logic [7:0]        s_dma_awlen, s_dma_arlen;
//     logic [2:0]        s_dma_awsize, s_dma_arsize;
//     logic [1:0]        s_dma_awburst, s_dma_arburst, s_dma_bresp, s_dma_rresp;
//     logic [DATA_W-1:0] s_dma_wdata, s_dma_rdata;
//     logic [3:0]        s_dma_wstrb;
//     logic s_dma_awvalid, s_dma_awready, s_dma_wlast, s_dma_wvalid, s_dma_wready;
//     logic s_dma_bvalid, s_dma_bready, s_dma_arvalid, s_dma_arready;
//     logic s_dma_rlast, s_dma_rvalid, s_dma_rready;

//     // AXI Master (DMA to DTCM)
//     wire [ID_W-1:0]   m_dma_awid, m_dma_bid;
//     wire [ADDR_W-1:0] m_dma_awaddr;
//     wire [7:0]        m_dma_awlen;
//     wire [1:0]        m_dma_awburst, m_dma_bresp;
//     wire              m_dma_awvalid, m_dma_awready;
//     wire [DATA_W-1:0] m_dma_wdata;
//     wire              m_dma_wlast, m_dma_wvalid, m_dma_wready;
//     wire              m_dma_bvalid, m_dma_bready;

//     wire drc_irq, drc_trap, dma_irq, dma_trap;

//     reg [15:0] source_image [0:TOTAL_PIXELS-1];
//     reg [31:0] dtcm_mem     [0:4095]; 

//     initial clk = 0;
//     always #5 clk = ~clk; 

//     initial dvp_pclk_i = 1;
//     // async delay generation
    
//     always #25 dvp_pclk_i = ~dvp_pclk_i;   // 25 mhz pclk

//     initial begin
//         rst_n = 0;
//         #55 rst_n = 1;
//     end

//     // =========================================================================
//     // DUT Instantiation
//     // =========================================================================
//     dvp_dma_wrapper #(
//         .ADDR_W       (ADDR_W),
//         .DATA_W       (DATA_W),
//         .ID_W         (ID_W),
//         .DRC_BASE_ADDR(DRC_BASE_ADDR),
//         .DMA_BASE_ADDR(DMA_BASE_ADDR),
//         .FRM_COL_NUM  (IMG_W),
//         .FRM_ROW_NUM  (IMG_H)
//     ) dut (
//         .clk              (clk),
//         .rst_n            (rst_n),
//         .dvp_d_i          (dvp_d_i),
//         .dvp_href_i       (dvp_href_i),
//         .dvp_vsync_i      (dvp_vsync_i),
//         .dvp_hsync_i      (dvp_hsync_i),
//         .dvp_pclk_i       (dvp_pclk_i),
//         .dvp_xclk_o       (dvp_xclk_o),
//         .dvp_pwdn_o       (dvp_pwdn_o),
        
//         // DRC Config
//         .s_axi_drc_awid   (s_drc_awid),     .s_axi_drc_awaddr (s_drc_awaddr),
//         .s_axi_drc_awlen  (s_drc_awlen),    .s_axi_drc_awsize (s_drc_awsize),
//         .s_axi_drc_awburst(s_drc_awburst),  .s_axi_drc_awvalid(s_drc_awvalid),
//         .s_axi_drc_awready(s_drc_awready),  .s_axi_drc_wdata  (s_drc_wdata),
//         .s_axi_drc_wstrb  (s_drc_wstrb),    .s_axi_drc_wlast  (s_drc_wlast),
//         .s_axi_drc_wvalid (s_drc_wvalid),   .s_axi_drc_wready (s_drc_wready),
//         .s_axi_drc_bid    (s_drc_bid),      .s_axi_drc_bresp  (s_drc_bresp),
//         .s_axi_drc_bvalid (s_drc_bvalid),   .s_axi_drc_bready (s_drc_bready),
//         .s_axi_drc_arid   (s_drc_arid),     .s_axi_drc_araddr (s_drc_araddr),
//         .s_axi_drc_arlen  (s_drc_arlen),    .s_axi_drc_arsize (s_drc_arsize),
//         .s_axi_drc_arburst(s_drc_arburst),  .s_axi_drc_arvalid(s_drc_arvalid),
//         .s_axi_drc_arready(s_drc_arready),  .s_axi_drc_rid    (s_drc_rid),
//         .s_axi_drc_rdata  (s_drc_rdata),    .s_axi_drc_rresp  (s_drc_rresp),
//         .s_axi_drc_rlast  (s_drc_rlast),    .s_axi_drc_rvalid (s_drc_rvalid),
//         .s_axi_drc_rready (s_drc_rready),

//         // DMA Config
//         .s_axi_dma_awid   (s_dma_awid),     .s_axi_dma_awaddr (s_dma_awaddr),
//         .s_axi_dma_awlen  (s_dma_awlen),    .s_axi_dma_awsize (s_dma_awsize),
//         .s_axi_dma_awburst(s_dma_awburst),  .s_axi_dma_awvalid(s_dma_awvalid),
//         .s_axi_dma_awready(s_dma_awready),  .s_axi_dma_wdata  (s_dma_wdata),
//         .s_axi_dma_wstrb  (s_dma_wstrb),    .s_axi_dma_wlast  (s_dma_wlast),
//         .s_axi_dma_wvalid (s_dma_wvalid),   .s_axi_dma_wready (s_dma_wready),
//         .s_axi_dma_bid    (s_dma_bid),      .s_axi_dma_bresp  (s_dma_bresp),
//         .s_axi_dma_bvalid (s_dma_bvalid),   .s_axi_dma_bready (s_dma_bready),
//         .s_axi_dma_arid   (s_dma_arid),     .s_axi_dma_araddr (s_dma_araddr),
//         .s_axi_dma_arlen  (s_dma_arlen),    .s_axi_dma_arsize (s_dma_arsize),
//         .s_axi_dma_arburst(s_dma_arburst),  .s_axi_dma_arvalid(s_dma_arvalid),
//         .s_axi_dma_arready(s_dma_arready),  .s_axi_dma_rid    (s_dma_rid),
//         .s_axi_dma_rdata  (s_dma_rdata),    .s_axi_dma_rresp  (s_dma_rresp),
//         .s_axi_dma_rlast  (s_dma_rlast),    .s_axi_dma_rvalid (s_dma_rvalid),
//         .s_axi_dma_rready (s_dma_rready),

//         // AXI Master out to DTCM
//         .m_axi_dma_awid   (m_dma_awid),     .m_axi_dma_awaddr (m_dma_awaddr),
//         .m_axi_dma_awlen  (m_dma_awlen),    .m_axi_dma_awburst(m_dma_awburst),
//         .m_axi_dma_awvalid(m_dma_awvalid),  .m_axi_dma_awready(m_dma_awready),
//         .m_axi_dma_wdata  (m_dma_wdata),    .m_axi_dma_wlast  (m_dma_wlast),
//         .m_axi_dma_wvalid (m_dma_wvalid),   .m_axi_dma_wready (m_dma_wready),
//         .m_axi_dma_bid    (m_dma_bid),      .m_axi_dma_bresp  (m_dma_bresp),
//         .m_axi_dma_bvalid (m_dma_bvalid),   .m_axi_dma_bready (m_dma_bready),

//         .drc_irq          (drc_irq),
//         .drc_trap         (drc_trap),
//         .dma_irq          (dma_irq),
//         .dma_trap         (dma_trap)
//     );

//     // =========================================================================
//     // AXI Slave Write Tasks
//     // =========================================================================
//     task automatic write_drc(input [31:0] addr, input [31:0] data);
//         @(posedge clk); #1;
//         s_drc_awvalid = 1; s_drc_awaddr = addr;
//         s_drc_awid = 0; s_drc_awburst = 2'b01; s_drc_awlen = 0;
//         @(posedge clk); while (!s_drc_awready) @(posedge clk);
//         #1; s_drc_awvalid = 0;
        
//         @(posedge clk); #1;
//         s_drc_wvalid = 1; s_drc_wdata = data; s_drc_wlast = 1; s_drc_wstrb = 4'hF;
//         @(posedge clk); while (!s_drc_wready) @(posedge clk);
//         #1; s_drc_wvalid = 0; s_drc_wlast = 0;
        
//         while (!s_drc_bvalid) @(posedge clk);
//         $display("[CFG] DRC 0x%08h <= 0x%08h", addr, data);
//     endtask

//     task automatic write_dma(input [31:0] addr, input [31:0] data);
//         @(posedge clk); #1;
//         s_dma_awvalid = 1; s_dma_awaddr = addr;
//         s_dma_awid = 0; s_dma_awburst = 2'b01; s_dma_awlen = 0;
//         @(posedge clk); while (!s_dma_awready) @(posedge clk);
//         #1; s_dma_awvalid = 0;
        
//         @(posedge clk); #1;
//         s_dma_wvalid = 1; s_dma_wdata = data; s_dma_wlast = 1; s_dma_wstrb = 4'hF;
//         @(posedge clk); while (!s_dma_wready) @(posedge clk);
//         #1; s_dma_wvalid = 0; s_dma_wlast = 0;
        
//         while (!s_dma_bvalid) @(posedge clk);
//         $display("[CFG] DMA 0x%08h <= 0x%08h", addr, data);
//     endtask

//     // =========================================================================
//     // FSM: DTCM Memory Slave (Receives pixels from DMA)
//     // =========================================================================
//     reg [1:0] dtcm_state = 0;
//     reg [ID_W-1:0] cap_awid;
//     reg [31:0] cap_awaddr;
//     reg [7:0]  cap_awlen;
//     reg [7:0]  w_beat = 0;

//     assign m_dma_awready = (dtcm_state == 0);
//     assign m_dma_wready  = (dtcm_state == 1);
//     assign m_dma_bvalid  = (dtcm_state == 2);
//     assign m_dma_bid     = cap_awid;
//     assign m_dma_bresp   = 2'b00;

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             dtcm_state <= 0;
//         end else begin
//             case (dtcm_state)
//                 0: begin
//                     if (m_dma_awvalid) begin
//                         cap_awid   <= m_dma_awid;
//                         cap_awaddr <= m_dma_awaddr;
//                         cap_awlen  <= m_dma_awlen;
//                         w_beat     <= 0;
//                         dtcm_state <= 1;
//                     end
//                 end
//                 1: begin
//                     if (m_dma_wvalid) begin
//                         // Safely calculate the index
//                         integer mem_idx;
//                         mem_idx = (cap_awaddr - DTCM_BASE)/4 + w_beat;
                        
//                         // Prevent Out-of-Bounds C++ Segfaults
//                         if (mem_idx >= 0 && mem_idx < 4096) begin
//                             dtcm_mem[mem_idx] <= m_dma_wdata;
//                         end else begin
//                             $display("[ERR] OOB Memory Write! Addr: 0x%08h", cap_awaddr);
//                         end
                        
//                         if (m_dma_wlast) dtcm_state <= 2;
//                         else w_beat <= w_beat + 1;
//                     end
//                 end
//                 2: begin
//                     if (m_dma_bready) dtcm_state <= 0;
//                 end
//             endcase
//         end
//     end

//     // =========================================================================
//     // MAIN TEST SEQUENCE
//     // =========================================================================
//     initial begin
//         s_drc_awvalid = 0; s_drc_wvalid = 0; s_drc_bready = 1;
//         s_drc_arvalid = 0; s_drc_rready = 1;
//         s_dma_awvalid = 0; s_dma_wvalid = 0; s_dma_bready = 1;
//         s_dma_arvalid = 0; s_dma_rready = 1;
        
//         dvp_vsync_i = 0; dvp_href_i = 0; dvp_hsync_i = 0; dvp_d_i = 0;
        
//         $readmemh("./python/input_image.hex", source_image);
//         $display("[INIT] Read image hex file.");

//         @(posedge rst_n);
//         repeat(10) @(posedge clk);
        
//         // ---------------------------------------------------------------------
//         // 1. Configure DMA Channel 0
//         // ---------------------------------------------------------------------
//         write_dma(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); // Global EN
//         write_dma(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); // Ch0 EN
//         write_dma(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); // 1D Mode
//         write_dma(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); // IRQ on Done
//         write_dma(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); // Dst burst INCR
//         write_dma(DMA_BASE_ADDR + 32'h0008, 32'd15);        // 16 beats per burst
//         write_dma(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     // DEST ADDR
        
//         // --- NEW: Dynamic length based on runtime mode ---
//         write_dma(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   // X_LEN
        
//         write_dma(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); // Submit descriptor
//         $display("[CFG] DMA programmed to fetch %0d words", OUT_WORDS);

//         // ---------------------------------------------------------------------
//         // 2. Configure DVP RX Controller
//         // // ---------------------------------------------------------------------
//         // write_drc(DRC_BASE_ADDR + 32'h10, 32'h0000_0003); // Enable IRQs
//         // write_drc(DRC_BASE_ADDR + 32'h14, IMG_W);         // INPUT Width
//         // write_drc(DRC_BASE_ADDR + 32'h18, IMG_H);         // INPUT Height
        
//         // // --- NEW: Write to DRC_PROC_CTRL [1]=Downscale, [0]=Grayscale ---
//         // write_drc(DRC_BASE_ADDR + 32'h28, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
        
//         // write_drc(DRC_BASE_ADDR + 32'h00, 32'h0000_0001); // Enable Camera Core
//         // write_drc(DRC_BASE_ADDR + 32'h04, 32'h0000_0001); // Start Capture
//         // $display("[CFG] DVP RX started.");

        

//         // ---------------------------------------------------------------------
//         // 1. Configure DMA Channel 0
//         // ---------------------------------------------------------------------
//         // write_dma(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); // Global EN
//         // write_dma(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); // Ch0 EN
//         // write_dma(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); // 1D Mode
//         // write_dma(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); // IRQ on Done
//         // write_dma(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); // Dst burst INCR
//         // write_dma(DMA_BASE_ADDR + 32'h0008, 32'd15);        // 16 beats per burst
//         // write_dma(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     // DEST ADDR
        
//         // // --- NEW: Dynamic length based on runtime mode ---
//         // write_dma(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   // X_LEN
        
//         // write_dma(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); // Submit descriptor
//         // $display("[CFG] DMA programmed to fetch %0d words", OUT_WORDS);

//         // ---------------------------------------------------------------------
//         // 2. Configure DVP RX Controller 
//         // ---------------------------------------------------------------------
//         write_drc(DRC_BASE_ADDR + 32'h00, 32'h01);
//         write_drc(DRC_BASE_ADDR + 32'h01, 32'h01);
//         write_drc(DRC_BASE_ADDR + 32'h02, 32'h02);

//         write_drc(DRC_BASE_ADDR + 32'h03, 32'h0000_0003); // [0x0C] Enable IRQs
//         write_drc(DRC_BASE_ADDR + 32'h04, IMG_W);
//         write_drc(DRC_BASE_ADDR + 32'h05, IMG_H);         // [0x14] INPUT Height
        
//         // Write to your custom DRC_PROC_CTRL [1]=Downscale, [0]=Grayscale
//         write_drc(DRC_BASE_ADDR + 32'h06, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
        
//         write_drc(DRC_BASE_ADDR + 32'h10, 32'h0000_0001); // [0x00] Enable Camera Core
        
//         // Write IMG_W to 0x10. This sets rw_reg[4] (width) AND triggers cam_rx_start
//         // write_drc(DRC_BASE_ADDR + 32'h10, IMG_W);         
//         $display("[CFG] DVP RX started.");

//         // ---------------------------------------------------------------------
//         // 3. Stream FULL Virtual Image via DVP interface
//         // ---------------------------------------------------------------------
//         $display("[STREAM] Sending VSYNC...");
//         dvp_vsync_i = 1; repeat(20) @(posedge dvp_pclk_i); dvp_vsync_i = 0;
//         repeat(50) @(posedge dvp_pclk_i); 
        
//         $display("[STREAM] Streaming %0d rows...", IMG_H);
//         for (int r = 0; r < IMG_H; r++) begin
//             dvp_href_i = 1;
//             for (int c = 0; c < IMG_W; c++) begin
//                 dvp_d_i = source_image[r*IMG_W + c][15:8]; // High Byte
//                 @(posedge dvp_pclk_i);
//                 dvp_d_i = source_image[r*IMG_W + c][7:0];  // Low Byte
//                 @(posedge dvp_pclk_i);
//             end
//             dvp_href_i = 0;
//             repeat(30) @(posedge dvp_pclk_i); 
//         end
        
//         repeat(50) @(posedge dvp_pclk_i);
//         dvp_vsync_i = 1; repeat(20) @(posedge dvp_pclk_i); dvp_vsync_i = 0;
//         $display("[STREAM] Frame transfer complete.");

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         // $display("[WAIT] Waiting for DMA & DRC Interrupts...");
//         // fork
//         //     begin
//         //         wait (dma_irq == 1);
//         //         $display("[IRQ] DMA Transfer Complete!");
//         //     end
//         //     begin
//         //         wait (drc_irq == 1);
//         //         $display("[IRQ] DRC Capture Complete!");
//         //     end
//         // join
        

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         // $display("[WAIT] Waiting for DMA & DRC Interrupts...");
        
//         // // Single-threaded polling to prevent Verilator Segfaults
//         // while (!dma_irq || !drc_irq) begin
//         //     @(posedge clk);
//         //     if (dma_irq) $display("[IRQ] DMA Transfer Complete!");
//         //     if (drc_irq) $display("[IRQ] DRC Capture Complete!");
//         // end
//         // $display("[PASS] Both hardware blocks completed successfully.");

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         $display("[WAIT] Waiting for DMA & DRC Interrupts...");
//         begin
//             logic dma_done = 0;
//             logic drc_done = 0;
            
//             // Polling loop ensures no log-spam and no segfaults
//             while (!dma_done || !drc_done) begin
//                 @(posedge clk);
//                 if (dma_irq && !dma_done) begin
//                     $display("[IRQ] DMA Transfer Complete!");
//                     dma_done = 1;
//                 end
//                 if (drc_irq && !drc_done) begin
//                     $display("[IRQ] DRC Capture Complete!");
//                     drc_done = 1;
//                 end
//             end
//         end
//         $display("[PASS] Both hardware blocks completed successfully.");
        
//         // Dump the memory map to a file for Python reconstruction
//         begin
//             int fd;
//             fd = $fopen("./python/output_dtcm.hex", "w");
//             for (int i = 0; i < OUT_WORDS; i++) begin
//                 $fdisplay(fd, "%08x", dtcm_mem[i]);
//             end
//             $fclose(fd);
//             $display("[PASS] Memory dumped to output_dtcm.hex");
//         end

//         #1000;
//         $finish;
//     end

//     initial begin
//         #10_000;
//         $display("[TIMEOUT] Simulation stalled.");
//         $finish;
//     end

// endmodule


// `timescale 1ns / 1ps

// module tb_dvp_dma;

//     // =========================================================================
//     // Parameters & Runtime Mode Toggles
//     // =========================================================================
//     localparam ADDR_W        = 32;
//     localparam DATA_W        = 32;
//     localparam ID_W          = 4;
//     localparam DRC_BASE_ADDR = 32'h6001_0000;
//     localparam DMA_BASE_ADDR = 32'h6000_0010;
    
//     // --- RUNTIME FEATURE TOGGLES ---
//     localparam logic EN_GRAYSCALE = 1'b1; 
//     localparam logic EN_DOWNSCALE = 1'b1; 
    
//     // Test image geometry (Input)
//     localparam IMG_W         = 56; 
//     localparam IMG_H         = 56;
//     localparam TOTAL_PIXELS  = IMG_W * IMG_H;
    
//     // Calculated Output Geometry
//     localparam OUT_W         = EN_DOWNSCALE ? (IMG_W / 2) : IMG_W;
//     localparam OUT_H         = EN_DOWNSCALE ? (IMG_H / 2) : IMG_H;
//     localparam OUT_PIXELS    = OUT_W * OUT_H;
    
//     localparam OUT_BYTES     = OUT_PIXELS * 2; 
//     localparam OUT_WORDS     = OUT_BYTES / 4;  // 32-bit DMA transfers
    
//     localparam DTCM_BASE     = 32'h0000_0000;

//     // =========================================================================
//     // Signals
//     // =========================================================================
//     logic clk, rst_n;
//     logic dvp_pclk_i;
    
//     logic [7:0] dvp_d_i;
//     logic       dvp_href_i, dvp_vsync_i, dvp_hsync_i;
//     wire        dvp_xclk_o, dvp_pwdn_o;

//     // AXI Slave 1 (DRC Config)
//     logic [ID_W-1:0]   s_drc_awid, s_drc_arid, s_drc_bid, s_drc_rid;
//     logic [ADDR_W-1:0] s_drc_awaddr, s_drc_araddr;
//     logic [7:0]        s_drc_awlen, s_drc_arlen;
//     logic [2:0]        s_drc_awsize, s_drc_arsize;
//     logic [1:0]        s_drc_awburst, s_drc_arburst, s_drc_bresp, s_drc_rresp;
//     logic [DATA_W-1:0] s_drc_wdata, s_drc_rdata;
//     logic [3:0]        s_drc_wstrb;
//     logic s_drc_awvalid, s_drc_awready, s_drc_wlast, s_drc_wvalid, s_drc_wready;
//     logic s_drc_bvalid, s_drc_bready, s_drc_arvalid, s_drc_arready;
//     logic s_drc_rlast, s_drc_rvalid, s_drc_rready;

//     // AXI Slave 2 (DMA Config)
//     logic [ID_W-1:0]   s_dma_awid, s_dma_arid, s_dma_bid, s_dma_rid;
//     logic [ADDR_W-1:0] s_dma_awaddr, s_dma_araddr;
//     logic [7:0]        s_dma_awlen, s_dma_arlen;
//     logic [2:0]        s_dma_awsize, s_dma_arsize;
//     logic [1:0]        s_dma_awburst, s_dma_arburst, s_dma_bresp, s_dma_rresp;
//     logic [DATA_W-1:0] s_dma_wdata, s_dma_rdata;
//     logic [3:0]        s_dma_wstrb;
//     logic s_dma_awvalid, s_dma_awready, s_dma_wlast, s_dma_wvalid, s_dma_wready;
//     logic s_dma_bvalid, s_dma_bready, s_dma_arvalid, s_dma_arready;
//     logic s_dma_rlast, s_dma_rvalid, s_dma_rready;

//     // AXI Master (DMA to DTCM)
//     wire [ID_W-1:0]   m_dma_awid, m_dma_bid;
//     wire [ADDR_W-1:0] m_dma_awaddr;
//     wire [7:0]        m_dma_awlen;
//     wire [1:0]        m_dma_awburst, m_dma_bresp;
//     wire              m_dma_awvalid, m_dma_awready;
//     wire [DATA_W-1:0] m_dma_wdata;
//     wire              m_dma_wlast, m_dma_wvalid, m_dma_wready;
//     wire              m_dma_bvalid, m_dma_bready;

//     wire drc_irq, drc_trap, dma_irq, dma_trap;

//     reg [15:0] source_image [0:TOTAL_PIXELS-1];
//     reg [31:0] dtcm_mem     [0:4095]; 

//     // Initialize arrays to prevent Verilator C++ Segfaults during VCD dumping
//     initial begin
//         for (int i = 0; i < 4096; i++) dtcm_mem[i] = 32'h0;
//         for (int i = 0; i < TOTAL_PIXELS; i++) source_image[i] = 16'h0;
//     end

//     // =========================================================================
//     // Clocks
//     // =========================================================================
//     initial clk = 0;
//     always #5 clk = ~clk; 

//     // Phase shift PCLK slightly to prevent internal CDC Race Conditions
//     initial begin
//         dvp_pclk_i = 0;
//         #3; 
//         forever #40 dvp_pclk_i = ~dvp_pclk_i; 
//     end

//     initial begin
//         rst_n = 0;
//         #55 rst_n = 1;
//     end

//     // =========================================================================
//     // DUT Instantiation
//     // =========================================================================
//     dvp_dma_wrapper #(
//         .ADDR_W       (ADDR_W),
//         .DATA_W       (DATA_W),
//         .ID_W         (ID_W),
//         .DRC_BASE_ADDR(DRC_BASE_ADDR),
//         .DMA_BASE_ADDR(DMA_BASE_ADDR),
//         .FRM_COL_NUM  (IMG_W),
//         .FRM_ROW_NUM  (IMG_H)
//     ) dut (
//         .clk              (clk),
//         .rst_n            (rst_n),
//         .dvp_d_i          (dvp_d_i),
//         .dvp_href_i       (dvp_href_i),
//         .dvp_vsync_i      (dvp_vsync_i),
//         .dvp_hsync_i      (dvp_hsync_i),
//         .dvp_pclk_i       (dvp_pclk_i),
//         .dvp_xclk_o       (dvp_xclk_o),
//         .dvp_pwdn_o       (dvp_pwdn_o),
        
//         .s_axi_drc_awid   (s_drc_awid),     .s_axi_drc_awaddr (s_drc_awaddr),
//         .s_axi_drc_awlen  (s_drc_awlen),    .s_axi_drc_awsize (s_drc_awsize),
//         .s_axi_drc_awburst(s_drc_awburst),  .s_axi_drc_awvalid(s_drc_awvalid),
//         .s_axi_drc_awready(s_drc_awready),  .s_axi_drc_wdata  (s_drc_wdata),
//         .s_axi_drc_wstrb  (s_drc_wstrb),    .s_axi_drc_wlast  (s_drc_wlast),
//         .s_axi_drc_wvalid (s_drc_wvalid),   .s_axi_drc_wready (s_drc_wready),
//         .s_axi_drc_bid    (s_drc_bid),      .s_axi_drc_bresp  (s_drc_bresp),
//         .s_axi_drc_bvalid (s_drc_bvalid),   .s_axi_drc_bready (s_drc_bready),
//         .s_axi_drc_arid   (s_drc_arid),     .s_axi_drc_araddr (s_drc_araddr),
//         .s_axi_drc_arlen  (s_drc_arlen),    .s_axi_drc_arsize (s_drc_arsize),
//         .s_axi_drc_arburst(s_drc_arburst),  .s_axi_drc_arvalid(s_drc_arvalid),
//         .s_axi_drc_arready(s_drc_arready),  .s_axi_drc_rid    (s_drc_rid),
//         .s_axi_drc_rdata  (s_drc_rdata),    .s_axi_drc_rresp  (s_drc_rresp),
//         .s_axi_drc_rlast  (s_drc_rlast),    .s_axi_drc_rvalid (s_drc_rvalid),
//         .s_axi_drc_rready (s_drc_rready),

//         .s_axi_dma_awid   (s_dma_awid),     .s_axi_dma_awaddr (s_dma_awaddr),
//         .s_axi_dma_awlen  (s_dma_awlen),    .s_axi_dma_awsize (s_dma_awsize),
//         .s_axi_dma_awburst(s_dma_awburst),  .s_axi_dma_awvalid(s_dma_awvalid),
//         .s_axi_dma_awready(s_dma_awready),  .s_axi_dma_wdata  (s_dma_wdata),
//         .s_axi_dma_wstrb  (s_dma_wstrb),    .s_axi_dma_wlast  (s_dma_wlast),
//         .s_axi_dma_wvalid (s_dma_wvalid),   .s_axi_dma_wready (s_dma_wready),
//         .s_axi_dma_bid    (s_dma_bid),      .s_axi_dma_bresp  (s_dma_bresp),
//         .s_axi_dma_bvalid (s_dma_bvalid),   .s_axi_dma_bready (s_dma_bready),
//         .s_axi_dma_arid   (s_dma_arid),     .s_axi_dma_araddr (s_dma_araddr),
//         .s_axi_dma_arlen  (s_dma_arlen),    .s_axi_dma_arsize (s_dma_arsize),
//         .s_axi_dma_arburst(s_dma_arburst),  .s_axi_dma_arvalid(s_dma_arvalid),
//         .s_axi_dma_arready(s_dma_arready),  .s_axi_dma_rid    (s_dma_rid),
//         .s_axi_dma_rdata  (s_dma_rdata),    .s_axi_dma_rresp  (s_dma_rresp),
//         .s_axi_dma_rlast  (s_dma_rlast),    .s_axi_dma_rvalid (s_dma_rvalid),
//         .s_axi_dma_rready (s_dma_rready),

//         .m_axi_dma_awid   (m_dma_awid),     .m_axi_dma_awaddr (m_dma_awaddr),
//         .m_axi_dma_awlen  (m_dma_awlen),    .m_axi_dma_awburst(m_dma_awburst),
//         .m_axi_dma_awvalid(m_dma_awvalid),  .m_axi_dma_awready(m_dma_awready),
//         .m_axi_dma_wdata  (m_dma_wdata),    .m_axi_dma_wlast  (m_dma_wlast),
//         .m_axi_dma_wvalid (m_dma_wvalid),   .m_axi_dma_wready (m_dma_wready),
//         .m_axi_dma_bid    (m_dma_bid),      .m_axi_dma_bresp  (m_dma_bresp),
//         .m_axi_dma_bvalid (m_dma_bvalid),   .m_axi_dma_bready (m_dma_bready),

//         .drc_irq          (drc_irq),
//         .drc_trap         (drc_trap),
//         .dma_irq          (dma_irq),
//         .dma_trap         (dma_trap)
//     );

//     // =========================================================================
//     // AXI Slave Write Tasks (Parallel Handshake to prevent deadlock)
//     // =========================================================================
//     task automatic write_drc(input [31:0] addr, input [31:0] data);
//         logic aw_done = 0; logic w_done  = 0;
//         @(posedge clk); #1;
//         s_drc_awvalid = 1; s_drc_awaddr = addr; s_drc_awid = 0; s_drc_awburst = 2'b01; s_drc_awlen = 0;
//         s_drc_wvalid = 1; s_drc_wdata = data; s_drc_wlast = 1; s_drc_wstrb = 4'hF;
//         while (!aw_done || !w_done) begin
//             @(posedge clk);
//             if (s_drc_awready && !aw_done) begin #1; s_drc_awvalid = 0; aw_done = 1; end
//             if (s_drc_wready && !w_done) begin #1; s_drc_wvalid = 0; s_drc_wlast = 0; w_done = 1; end
//         end
//         while (!s_drc_bvalid) @(posedge clk);
//         $display("[CFG] DRC 0x%08h <= 0x%08h", addr, data);
//     endtask

//     task automatic write_dma(input [31:0] addr, input [31:0] data);
//         logic aw_done = 0; logic w_done  = 0;
//         @(posedge clk); #1;
//         s_dma_awvalid = 1; s_dma_awaddr = addr; s_dma_awid = 0; s_dma_awburst = 2'b01; s_dma_awlen = 0;
//         s_dma_wvalid = 1; s_dma_wdata = data; s_dma_wlast = 1; s_dma_wstrb = 4'hF;
//         while (!aw_done || !w_done) begin
//             @(posedge clk);
//             if (s_dma_awready && !aw_done) begin #1; s_dma_awvalid = 0; aw_done = 1; end
//             if (s_dma_wready && !w_done) begin #1; s_dma_wvalid = 0; s_dma_wlast = 0; w_done = 1; end
//         end
//         while (!s_dma_bvalid) @(posedge clk);
//         $display("[CFG] DMA 0x%08h <= 0x%08h", addr, data);
//     endtask

//     // =========================================================================
//     // FSM: DTCM Memory Slave (Receives pixels from DMA)
//     // =========================================================================
//     reg [1:0] dtcm_state = 0;
//     reg [ID_W-1:0] cap_awid;
//     reg [31:0] cap_awaddr;
//     reg [7:0]  cap_awlen;
//     reg [7:0]  w_beat = 0;

//     assign m_dma_awready = (dtcm_state == 0);
//     assign m_dma_wready  = (dtcm_state == 1);
//     assign m_dma_bvalid  = (dtcm_state == 2);
//     assign m_dma_bid     = cap_awid;
//     assign m_dma_bresp   = 2'b00;

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             dtcm_state <= 0;
//         end else begin
//             case (dtcm_state)
//                 0: begin
//                     if (m_dma_awvalid) begin
//                         cap_awid   <= m_dma_awid;
//                         cap_awaddr <= m_dma_awaddr;
//                         cap_awlen  <= m_dma_awlen;
//                         w_beat     <= 0;
//                         dtcm_state <= 1;
//                     end
//                 end
//                 1: begin
//                     if (m_dma_wvalid) begin
//                         integer mem_idx;
//                         mem_idx = (cap_awaddr - DTCM_BASE)/4 + w_beat;
                        
//                         if (mem_idx >= 0 && mem_idx < 4096) begin
//                             dtcm_mem[mem_idx] <= m_dma_wdata;
//                         end
//                         if (m_dma_wlast) dtcm_state <= 2;
//                         else w_beat <= w_beat + 1;
//                     end
//                 end
//                 2: begin
//                     if (m_dma_bready) dtcm_state <= 0;
//                 end
//             endcase
//         end
//     end

//     // =========================================================================
//     // MAIN TEST SEQUENCE
//     // =========================================================================
//     initial begin
//         s_drc_awvalid = 0; s_drc_wvalid = 0; s_drc_bready = 1;
//         s_drc_arvalid = 0; s_drc_rready = 1;
//         s_dma_awvalid = 0; s_dma_wvalid = 0; s_dma_bready = 1;
//         s_dma_arvalid = 0; s_dma_rready = 1;
        
//         dvp_vsync_i = 0; dvp_href_i = 0; dvp_hsync_i = 0; dvp_d_i = 0;
        
//         $readmemh("./python/input_image.hex", source_image);
//         $display("[INIT] Read image hex file.");

//         @(posedge rst_n);
//         repeat(10) @(posedge clk);
        
//         // ---------------------------------------------------------------------
//         // 1. Configure DMA Channel 0
//         // ---------------------------------------------------------------------
//         write_dma(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); 
//         write_dma(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0008, 32'd15);        
//         write_dma(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     
//         write_dma(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   
//         write_dma(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); 
//         $display("[CFG] DMA programmed to fetch %0d words", OUT_WORDS);

//         // ---------------------------------------------------------------------
//         // 2. Configure DVP RX Controller (Using your exact mapped offsets)
//         // ---------------------------------------------------------------------
//         write_drc(DRC_BASE_ADDR + 32'h00, 32'h01);
//         write_drc(DRC_BASE_ADDR + 32'h01, 32'h00);
//         write_drc(DRC_BASE_ADDR + 32'h02, 32'h02);
//         write_drc(DRC_BASE_ADDR + 32'h03, 32'h0000_0003); 
//         write_drc(DRC_BASE_ADDR + 32'h04, IMG_W);
//         write_drc(DRC_BASE_ADDR + 32'h05, IMG_H);         
//         write_drc(DRC_BASE_ADDR + 32'h06, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
//         write_drc(DRC_BASE_ADDR + 32'h10, 32'h0000_0001); 
//         $display("[CFG] DVP RX started.");

//         // ---------------------------------------------------------------------
//         // CRITICAL FIX: Give the hardware time to fully enter PXL_ALIGN_ST 
//         // before firing the VSYNC pulse!
//         // ---------------------------------------------------------------------
//         #5000;

//         // ---------------------------------------------------------------------
//         // 3. Stream Virtual Image
//         // ---------------------------------------------------------------------
//         $display("[STREAM] Sending VSYNC...");
//         @(posedge dvp_pclk_i);
//         dvp_vsync_i = 1; 
//         repeat(20) @(posedge dvp_pclk_i); 
//         dvp_vsync_i = 0;
        
//         repeat(50) @(posedge dvp_pclk_i); 
        
//         $display("[STREAM] Streaming %0d rows...", IMG_H);
//         for (int r = 0; r < IMG_H; r++) begin
//             @(posedge dvp_pclk_i);
//             dvp_href_i = 1;
//             for (int c = 0; c < IMG_W; c++) begin
//                 dvp_d_i = source_image[r*IMG_W + c][15:8];
//                 @(posedge dvp_pclk_i);
//                 dvp_d_i = source_image[r*IMG_W + c][7:0];  
//                 @(posedge dvp_pclk_i);
//             end
//             dvp_href_i = 0;
//             repeat(30) @(posedge dvp_pclk_i); 
//         end
        
//         repeat(50) @(posedge dvp_pclk_i);
//         dvp_vsync_i = 1; 
//         repeat(20) @(posedge dvp_pclk_i); 
//         dvp_vsync_i = 0;
//         $display("[STREAM] Frame transfer complete.");

//         // ---------------------------------------------------------------------
//         // 4. Wait for completion and verify
//         // ---------------------------------------------------------------------
//         begin
//             logic dma_done = 0;
//             logic drc_done = 0;
            
//             while (!dma_done || !drc_done) begin
//                 @(posedge clk);
//                 if (dma_irq && !dma_done) begin
//                     $display("[IRQ] DMA Transfer Complete!");
//                     dma_done = 1;
//                 end
//                 if (drc_irq && !drc_done) begin
//                     $display("[IRQ] DRC Capture Complete!");
//                     drc_done = 1;
//                 end
//             end
//         end
//         $display("[PASS] Both hardware blocks completed successfully.");
        
//         begin
//             int fd;
//             fd = $fopen("./python/output_dtcm.hex", "w");
//             for (int i = 0; i < OUT_WORDS; i++) begin
//                 $fdisplay(fd, "%08x", dtcm_mem[i]);
//             end
//             $fclose(fd);
//             $display("[PASS] Memory dumped to output_dtcm.hex");
//         end

//         #1000;
//         $finish;
//     end

//     // Safety timeout (10 ms)
//     initial begin
//         #10_000_000;
//         $display("[TIMEOUT] Simulation stalled.");
//         $finish;
//     end

// endmodule

`timescale 1ns / 1ps
// =============================================================================
// tb_dvp_dma.sv  –  DVP RX + AXI-DMA subsystem testbench
//
// DUT : dvp_dma_wrapper (dvp_rx_core + axi_dma internally connected)
//
// What this bench does
// --------------------
//  1. Generates an independent free-running DVP PCLK from the start (not
//     gated on xclk), fed back through the xclk loopback with a 1-ns delay
//     to mimic camera output propagation.
//  2. Configures DMA channel registers (but does NOT submit descriptor yet).
//  3. Configures DVP RX Controller registers and triggers cam_rx_start.
//  4. Waits for XCLK to stabilise (cam_rx_en must be set first).
//  5. Submits the DMA descriptor so the DMA is armed just before pixels flow.
//  6. Streams a complete synthetic RGB-565 frame over the DVP interface.
//  7. Polls for drc_irq and dma_irq, then dumps DTCM memory to a file.
//
// Key bugs fixed versus the original tb_dvp_dma.sv
// -------------------------------------------------
//  A. pclk was derived from xclk via combinational assign – xclk is static
//     (0) until cam_rx_en=1, so any @(posedge dvp_pclk_i) before that hung
//     the simulation.  Fix: independent free-running pclk; xclk loopback
//     with #1 delay drives pclk_i exactly like the reference TB.
//
//  B. DMA descriptor was submitted BEFORE the DVP RX was enabled.  If no
//     AXIS data arrives the DMA descriptor queue can stall.
//     Fix: configure DMA regs first, enable DVP RX second, submit descriptor
//     last (right before streaming).
//
//  C. DTCM AXI slave FSM could not handle back-to-back AXI write bursts.
//     awready was only high in state-0, but the DMA may issue consecutive AW
//     beats; the old FSM serialised them one-at-a-time with no overlap.
//     Fix: rewritten with a proper AW-FIFO + W-FSM + B-channel path so the
//     slave can queue an incoming AW while it is still processing W-data.
//
//  D. write_drc / write_dma tasks used parallel handshake with local logic
//     variable initialisations that confuse some simulators and can create
//     race conditions if AW and W fire on the same edge.
//     Fix: clean sequential AW→W→B handshake, wait-on-ready style.
//
//  E. Simulation timeout was 10 ms which is marginal when bclk=100 MHz,
//     pclk=25 MHz and the full configuration + streaming sequence has to
//     complete.  Increased to 50 ms.
//
//  F. DVP data byte driving: data must be stable BEFORE the rising edge of
//     pclk that samples it.  Added #1 hold after posedge to match real
//     camera setup/hold (same pattern as reference TB's DVP_PCLK_DLY).
// =============================================================================

`timescale 1ns / 1ps
// =============================================================================
// tb_dvp_dma.sv  –  DVP RX + AXI-DMA subsystem testbench  (v3 – bug-fixed)
//
// Root-cause of the v2 hang (found from FST/hier analysis)
// --------------------------------------------------------
// dvp_pclk_i had TWO simultaneous drivers in the same reg:
//
//   Driver A (free-running):
//       always #DVP_CLK_HALF dvp_pclk_i = dvp_pclk_i ^ 1'b1;
//
//   Driver B (xclk mirror):
//       always @(dvp_xclk_o) begin #1; dvp_pclk_i <= dvp_xclk_o; end
//
// Once cam_rx_en=1 is written and dvp_xclk_o starts toggling, both drivers
// fire on dvp_pclk_i at incommensurable intervals (20 ns free-run vs 30 ns
// xclk-half-period at 16.7 MHz). Icarus evaluates the last delta-cycle
// winner, turning dvp_pclk_i into a chaotic, non-monotonic signal. The
// streaming task's @(posedge dvp_pclk_i) never fires on a clean edge and
// the simulation hangs.
//
// Fix: delete the free-running driver completely.
//       Use ONLY the xclk mirror (one driver, clean edges).
//       Sequence the streaming task AFTER cam_rx_en is confirmed written,
//       then explicitly wait for xclk to start toggling before any
//       @(posedge dvp_pclk_i) calls.
//
// Other changes vs v2
// -------------------
//  • DVP PCLK: single driver — xclk mirror with #1 propagation delay.
//  • Streaming task: simplified to negedge-drive / posedge-sample, matching
//    a real OV-series camera (data stable well before rising edge).
//  • wait_for_xclk() helper: spins on @(posedge clk) until xclk_o toggles,
//    guaranteeing pclk is running before the DVP task touches it.
//  • Explicit `wait(dvp_pwdn_o == 0)` guard removed (cam_pwdn defaults 0).
//  • Timeout bumped to 100 ms for safety; debug print on exit.
// =============================================================================

// module tb_dvp_dma;

//     // =========================================================================
//     // Parameters
//     // =========================================================================
//     localparam ADDR_W        = 32;
//     localparam DATA_W        = 32;
//     localparam ID_W          = 4;

//     localparam DRC_BASE_ADDR = 32'h6001_0000;
//     localparam DMA_BASE_ADDR = 32'h6000_0010;

//     // DRC register offsets (CONF_OFFSET=1 → each CSR is 1 address unit apart)
//     localparam DRC_OFF_CAM_EN   = 32'h00;
//     localparam DRC_OFF_CAM_PWDN = 32'h01;
//     localparam DRC_OFF_RX_MODE  = 32'h02;
//     localparam DRC_OFF_IRQ_MSK  = 32'h03;
//     localparam DRC_OFF_IMG_W    = 32'h04;
//     localparam DRC_OFF_IMG_H    = 32'h05;
//     localparam DRC_OFF_PROC     = 32'h06;   // [1]=downscale  [0]=grayscale
//     localparam DRC_OFF_START    = 32'h10;   // RW1S – cam_rx_start

//     // DMA register offsets
//     localparam DMA_OFF_GLOB_EN  = 32'h00;
//     localparam DMA_OFF_CHN_EN   = 32'h01;
//     localparam DMA_OFF_CHN_FLG  = 32'h02;   // [1]=cyclic  [0]=2D
//     localparam DMA_OFF_IRQ_MSK  = 32'h03;
//     localparam DMA_OFF_DST_BST  = 32'h07;
//     localparam DMA_OFF_WPB      = 32'h08;   // words per burst
//     localparam DMA_OFF_SRC_ADDR = 32'h09;
//     localparam DMA_OFF_DST_ADDR = 32'h0A;
//     localparam DMA_OFF_XLEN     = 32'h0B;   // total transfers − 1
//     localparam DMA_OFF_SUBMIT   = 32'h1000;

//     // Runtime toggles
//     localparam bit EN_GRAYSCALE = 1'b0;
//     localparam bit EN_DOWNSCALE = 1'b0;

//     // Image geometry
//     localparam IMG_W        = 14;
//     localparam IMG_H        = 14;
//     localparam TOTAL_PIXELS = IMG_W * IMG_H;

//     localparam OUT_W        = EN_DOWNSCALE ? (IMG_W / 2) : IMG_W;
//     localparam OUT_H        = EN_DOWNSCALE ? (IMG_H / 2) : IMG_H;
//     localparam OUT_PIXELS   = OUT_W * OUT_H;
//     localparam OUT_BYTES    = OUT_PIXELS * 2;    // always 16-bit output pixel
//     localparam OUT_WORDS    = OUT_BYTES  / 4;    // 32-bit DMA words

//     localparam DTCM_BASE    = 32'h0000_0000;
//     localparam DTCM_DEPTH   = 4096;

//     // Clock: 100 MHz system, propagation delay for pclk mirror
//     localparam SYS_CLK_HALF  = 5;    // ns  → 10 ns period
//     localparam DVP_PCLK_DLY  = 1;    // ns  camera output propagation delay

//     // =========================================================================
//     // Clock & Reset
//     // =========================================================================
//     logic clk;
//     logic rst_n;

//     initial clk = 1'b0;
//     always #SYS_CLK_HALF clk = ~clk;

//     initial begin
//         rst_n = 1'b0;
//         repeat (12) @(posedge clk);
//         @(posedge clk); #1;
//         rst_n = 1'b1;
//     end

//     // =========================================================================
//     // DVP PCLK – SINGLE DRIVER: xclk mirror only
//     // =========================================================================
//     // dvp_pclk_i starts at 0 and stays 0 until cam_rx_en=1 makes xclk toggle.
//     // The streaming task must call wait_for_xclk() before any pclk-edge waits.
//     // Having only ONE always block writing dvp_pclk_i eliminates the
//     // multi-driver conflict that caused the v2 hang.
//     logic dvp_pclk_i;
//     wire  dvp_xclk_o;          // output from DUT xclk generator

//     initial dvp_pclk_i = 1'b0;

//     // Mirror xclk → pclk with propagation delay (one driver, no conflict)
//     always @(dvp_xclk_o) begin
//         #DVP_PCLK_DLY;
//         dvp_pclk_i <= dvp_xclk_o;
//     end

//     // Helper: block until xclk (and therefore pclk) starts toggling
//     task automatic wait_for_xclk();
//         // Poll posedge clk until we see xclk go high at least once
//         while (dvp_xclk_o === 1'b0) @(posedge clk);
//         // Then wait one full pclk cycle so pclk_i is fully synchronised
//         @(posedge dvp_pclk_i);
//         @(negedge dvp_pclk_i);
//         $display("[PCLK]  dvp_xclk_o is running – pclk mirror active.");
//     endtask

//     // =========================================================================
//     // DVP Data Signals
//     // =========================================================================
//     logic [7:0] dvp_d_i;
//     logic       dvp_href_i;
//     logic       dvp_vsync_i;
//     logic       dvp_hsync_i;
//     wire        dvp_pwdn_o;

//     // =========================================================================
//     // AXI4 Slave 1 – DRC configuration port
//     // =========================================================================
//     logic [ID_W-1:0]    s_drc_awid;
//     logic [ADDR_W-1:0]  s_drc_awaddr;
//     logic [7:0]         s_drc_awlen;
//     logic [2:0]         s_drc_awsize;
//     logic [1:0]         s_drc_awburst;
//     logic               s_drc_awvalid;
//     wire                s_drc_awready;
//     logic [DATA_W-1:0]  s_drc_wdata;
//     logic [3:0]         s_drc_wstrb;
//     logic               s_drc_wlast;
//     logic               s_drc_wvalid;
//     wire                s_drc_wready;
//     wire  [ID_W-1:0]    s_drc_bid;
//     wire  [1:0]         s_drc_bresp;
//     wire                s_drc_bvalid;
//     logic               s_drc_bready;
//     logic [ID_W-1:0]    s_drc_arid;
//     logic [ADDR_W-1:0]  s_drc_araddr;
//     logic [7:0]         s_drc_arlen;
//     logic [2:0]         s_drc_arsize;
//     logic [1:0]         s_drc_arburst;
//     logic               s_drc_arvalid;
//     wire                s_drc_arready;
//     wire  [ID_W-1:0]    s_drc_rid;
//     wire  [DATA_W-1:0]  s_drc_rdata;
//     wire  [1:0]         s_drc_rresp;
//     wire                s_drc_rlast;
//     wire                s_drc_rvalid;
//     logic               s_drc_rready;

//     // =========================================================================
//     // AXI4 Slave 2 – DMA configuration port
//     // =========================================================================
//     logic [ID_W-1:0]    s_dma_awid;
//     logic [ADDR_W-1:0]  s_dma_awaddr;
//     logic [7:0]         s_dma_awlen;
//     logic [2:0]         s_dma_awsize;
//     logic [1:0]         s_dma_awburst;
//     logic               s_dma_awvalid;
//     wire                s_dma_awready;
//     logic [DATA_W-1:0]  s_dma_wdata;
//     logic [3:0]         s_dma_wstrb;
//     logic               s_dma_wlast;
//     logic               s_dma_wvalid;
//     wire                s_dma_wready;
//     wire  [ID_W-1:0]    s_dma_bid;
//     wire  [1:0]         s_dma_bresp;
//     wire                s_dma_bvalid;
//     logic               s_dma_bready;
//     logic [ID_W-1:0]    s_dma_arid;
//     logic [ADDR_W-1:0]  s_dma_araddr;
//     logic [7:0]         s_dma_arlen;
//     logic [2:0]         s_dma_arsize;
//     logic [1:0]         s_dma_arburst;
//     logic               s_dma_arvalid;
//     wire                s_dma_arready;
//     wire  [ID_W-1:0]    s_dma_rid;
//     wire  [DATA_W-1:0]  s_dma_rdata;
//     wire  [1:0]         s_dma_rresp;
//     wire                s_dma_rlast;
//     wire                s_dma_rvalid;
//     logic               s_dma_rready;

//     // =========================================================================
//     // AXI4 Master – DMA write port (→ DTCM memory model)
//     // =========================================================================
//     wire  [ID_W-1:0]    m_dma_awid;
//     wire  [ADDR_W-1:0]  m_dma_awaddr;
//     wire  [7:0]         m_dma_awlen;
//     wire  [1:0]         m_dma_awburst;
//     wire                m_dma_awvalid;
//     logic               m_dma_awready;
//     wire  [DATA_W-1:0]  m_dma_wdata;
//     wire                m_dma_wlast;
//     wire                m_dma_wvalid;
//     logic               m_dma_wready;
//     logic [ID_W-1:0]    m_dma_bid;
//     logic [1:0]         m_dma_bresp;
//     logic               m_dma_bvalid;
//     wire                m_dma_bready;

//     wire drc_irq, drc_trap;
//     wire dma_irq, dma_trap;

//     // =========================================================================
//     // Test data
//     // =========================================================================
//     reg [15:0] source_image [0:TOTAL_PIXELS-1];
//     reg [31:0] dtcm_mem     [0:DTCM_DEPTH-1];

//     // =========================================================================
//     // DUT
//     // =========================================================================
//     dvp_dma_wrapper #(
//         .ADDR_W        (ADDR_W),
//         .DATA_W        (DATA_W),
//         .ID_W          (ID_W),
//         .DRC_BASE_ADDR (DRC_BASE_ADDR),
//         .DMA_BASE_ADDR (DMA_BASE_ADDR),
//         .FRM_COL_NUM   (IMG_W),
//         .FRM_ROW_NUM   (IMG_H)
//     ) dut (
//         .clk                (clk),
//         .rst_n              (rst_n),
//         .dvp_d_i            (dvp_d_i),
//         .dvp_href_i         (dvp_href_i),
//         .dvp_vsync_i        (dvp_vsync_i),
//         .dvp_hsync_i        (dvp_hsync_i),
//         .dvp_pclk_i         (dvp_pclk_i),
//         .dvp_xclk_o         (dvp_xclk_o),
//         .dvp_pwdn_o         (dvp_pwdn_o),
//         // DRC slave
//         .s_axi_drc_awid     (s_drc_awid),   .s_axi_drc_awaddr   (s_drc_awaddr),
//         .s_axi_drc_awlen    (s_drc_awlen),   .s_axi_drc_awsize   (s_drc_awsize),
//         .s_axi_drc_awburst  (s_drc_awburst), .s_axi_drc_awvalid  (s_drc_awvalid),
//         .s_axi_drc_awready  (s_drc_awready), .s_axi_drc_wdata    (s_drc_wdata),
//         .s_axi_drc_wstrb    (s_drc_wstrb),   .s_axi_drc_wlast    (s_drc_wlast),
//         .s_axi_drc_wvalid   (s_drc_wvalid),  .s_axi_drc_wready   (s_drc_wready),
//         .s_axi_drc_bid      (s_drc_bid),     .s_axi_drc_bresp    (s_drc_bresp),
//         .s_axi_drc_bvalid   (s_drc_bvalid),  .s_axi_drc_bready   (s_drc_bready),
//         .s_axi_drc_arid     (s_drc_arid),    .s_axi_drc_araddr   (s_drc_araddr),
//         .s_axi_drc_arlen    (s_drc_arlen),   .s_axi_drc_arsize   (s_drc_arsize),
//         .s_axi_drc_arburst  (s_drc_arburst), .s_axi_drc_arvalid  (s_drc_arvalid),
//         .s_axi_drc_arready  (s_drc_arready), .s_axi_drc_rid      (s_drc_rid),
//         .s_axi_drc_rdata    (s_drc_rdata),   .s_axi_drc_rresp    (s_drc_rresp),
//         .s_axi_drc_rlast    (s_drc_rlast),   .s_axi_drc_rvalid   (s_drc_rvalid),
//         .s_axi_drc_rready   (s_drc_rready),
//         // DMA slave
//         .s_axi_dma_awid     (s_dma_awid),    .s_axi_dma_awaddr   (s_dma_awaddr),
//         .s_axi_dma_awlen    (s_dma_awlen),   .s_axi_dma_awsize   (s_dma_awsize),
//         .s_axi_dma_awburst  (s_dma_awburst), .s_axi_dma_awvalid  (s_dma_awvalid),
//         .s_axi_dma_awready  (s_dma_awready), .s_axi_dma_wdata    (s_dma_wdata),
//         .s_axi_dma_wstrb    (s_dma_wstrb),   .s_axi_dma_wlast    (s_dma_wlast),
//         .s_axi_dma_wvalid   (s_dma_wvalid),  .s_axi_dma_wready   (s_dma_wready),
//         .s_axi_dma_bid      (s_dma_bid),     .s_axi_dma_bresp    (s_dma_bresp),
//         .s_axi_dma_bvalid   (s_dma_bvalid),  .s_axi_dma_bready   (s_dma_bready),
//         .s_axi_dma_arid     (s_dma_arid),    .s_axi_dma_araddr   (s_dma_araddr),
//         .s_axi_dma_arlen    (s_dma_arlen),   .s_axi_dma_arsize   (s_dma_arsize),
//         .s_axi_dma_arburst  (s_dma_arburst), .s_axi_dma_arvalid  (s_dma_arvalid),
//         .s_axi_dma_arready  (s_dma_arready), .s_axi_dma_rid      (s_dma_rid),
//         .s_axi_dma_rdata    (s_dma_rdata),   .s_axi_dma_rresp    (s_dma_rresp),
//         .s_axi_dma_rlast    (s_dma_rlast),   .s_axi_dma_rvalid   (s_dma_rvalid),
//         .s_axi_dma_rready   (s_dma_rready),
//         // DMA master → DTCM
//         .m_axi_dma_awid     (m_dma_awid),    .m_axi_dma_awaddr   (m_dma_awaddr),
//         .m_axi_dma_awlen    (m_dma_awlen),   .m_axi_dma_awburst  (m_dma_awburst),
//         .m_axi_dma_awvalid  (m_dma_awvalid), .m_axi_dma_awready  (m_dma_awready),
//         .m_axi_dma_wdata    (m_dma_wdata),   .m_axi_dma_wlast    (m_dma_wlast),
//         .m_axi_dma_wvalid   (m_dma_wvalid),  .m_axi_dma_wready   (m_dma_wready),
//         .m_axi_dma_bid      (m_dma_bid),     .m_axi_dma_bresp    (m_dma_bresp),
//         .m_axi_dma_bvalid   (m_dma_bvalid),  .m_axi_dma_bready   (m_dma_bready),
//         .drc_irq            (drc_irq),       .drc_trap           (drc_trap),
//         .dma_irq            (dma_irq),       .dma_trap           (dma_trap)
//     );

//     // =========================================================================
//     // AXI Write Tasks – sequential AW → W → B (no parallel-driver race)
//     // =========================================================================
//     task automatic axi_write_drc (input [ADDR_W-1:0] addr,
//                                   input [DATA_W-1:0] data);
//         @(posedge clk); #1;
//         s_drc_awvalid = 1'b1; s_drc_awaddr = addr;
//         s_drc_awid = '0; s_drc_awlen = '0; s_drc_awsize = 3'b010; s_drc_awburst = 2'b01;
//         @(posedge clk);
//         while (!s_drc_awready) @(posedge clk);
//         #1; s_drc_awvalid = 1'b0;

//         @(posedge clk); #1;
//         s_drc_wvalid = 1'b1; s_drc_wdata = data; s_drc_wstrb = 4'hF; s_drc_wlast = 1'b1;
//         @(posedge clk);
//         while (!s_drc_wready) @(posedge clk);
//         #1; s_drc_wvalid = 1'b0; s_drc_wlast = 1'b0;

//         @(posedge clk);
//         while (!s_drc_bvalid) @(posedge clk);
//         $display("[CFG-DRC] addr=0x%08h  data=0x%08h", addr, data);
//     endtask

//     task automatic axi_write_dma (input [ADDR_W-1:0] addr,
//                                   input [DATA_W-1:0] data);
//         @(posedge clk); #1;
//         s_dma_awvalid = 1'b1; s_dma_awaddr = addr;
//         s_dma_awid = '0; s_dma_awlen = '0; s_dma_awsize = 3'b010; s_dma_awburst = 2'b01;
//         @(posedge clk);
//         while (!s_dma_awready) @(posedge clk);
//         #1; s_dma_awvalid = 1'b0;

//         @(posedge clk); #1;
//         s_dma_wvalid = 1'b1; s_dma_wdata = data; s_dma_wstrb = 4'hF; s_dma_wlast = 1'b1;
//         @(posedge clk);
//         while (!s_dma_wready) @(posedge clk);
//         #1; s_dma_wvalid = 1'b0; s_dma_wlast = 1'b0;

//         @(posedge clk);
//         while (!s_dma_bvalid) @(posedge clk);
//         $display("[CFG-DMA] addr=0x%08h  data=0x%08h", addr, data);
//     endtask

//     // =========================================================================
//     // DTCM AXI4 Slave Model  (pipelined AW-FIFO + always-ready W)
//     // =========================================================================
//     localparam AW_FIFO_D = 4;
//     localparam AW_FIFO_W = ID_W + ADDR_W + 8;   // id[3:0] + addr[31:0] + len[7:0]

//     reg [AW_FIFO_W-1:0]        aw_fifo  [0:AW_FIFO_D-1];
//     reg [$clog2(AW_FIFO_D):0]  aw_wr_ptr = '0;
//     reg [$clog2(AW_FIFO_D):0]  aw_rd_ptr = '0;

//     wire aw_fifo_empty = (aw_wr_ptr == aw_rd_ptr);
//     wire aw_fifo_full  = ((aw_wr_ptr - aw_rd_ptr) == AW_FIFO_D[($clog2(AW_FIFO_D)):0]);

//     assign m_dma_awready = ~aw_fifo_full;   // accept AW whenever FIFO not full
//     assign m_dma_wready  = 1'b1;            // always accept W data

//     // Push AW into FIFO
//     always_ff @(posedge clk or negedge rst_n) begin
//         if (!rst_n) aw_wr_ptr <= '0;
//         else if (m_dma_awvalid && m_dma_awready) begin
//             aw_fifo[aw_wr_ptr[$clog2(AW_FIFO_D)-1:0]] <= {m_dma_awid, m_dma_awaddr, m_dma_awlen};
//             aw_wr_ptr <= aw_wr_ptr + 1'b1;
//         end
//     end

//     // W data consumer + B response
//     reg [ID_W-1:0]    cur_awid;
//     reg [ADDR_W-1:0]  cur_awaddr;
//     reg [7:0]         cur_awlen;
//     reg [7:0]         beat_cnt;
//     reg               w_active;

//     always_ff @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             aw_rd_ptr  <= '0;
//             beat_cnt   <= '0;
//             w_active   <= 1'b0;
//             m_dma_bvalid <= 1'b0;
//             m_dma_bid    <= '0;
//             m_dma_bresp  <= 2'b00;
//         end else begin
//             // De-assert B after handshake
//             if (m_dma_bvalid && m_dma_bready)
//                 m_dma_bvalid <= 1'b0;

//             // Dequeue next AW when idle
//             if (!w_active && !aw_fifo_empty) begin
//                 {cur_awid, cur_awaddr, cur_awlen} <= aw_fifo[aw_rd_ptr[$clog2(AW_FIFO_D)-1:0]];
//                 aw_rd_ptr <= aw_rd_ptr + 1'b1;
//                 beat_cnt  <= '0;
//                 w_active  <= 1'b1;
//             end

//             // Consume W beats and write to DTCM model
//             if (w_active && m_dma_wvalid) begin
//                 begin
//                     automatic int midx;
//                     midx = int'((cur_awaddr - DTCM_BASE) >> 2) + int'(beat_cnt);
//                     if (midx >= 0 && midx < DTCM_DEPTH)
//                         dtcm_mem[midx] <= m_dma_wdata;
//                     else
//                         $display("[WARN-DTCM] OOB addr=0x%08h beat=%0d", cur_awaddr, beat_cnt);
//                 end
//                 if (m_dma_wlast) begin
//                     m_dma_bvalid <= 1'b1;
//                     m_dma_bid    <= cur_awid;
//                     m_dma_bresp  <= 2'b00;
//                     w_active     <= 1'b0;
//                 end else begin
//                     beat_cnt <= beat_cnt + 1'b1;
//                 end
//             end
//         end
//     end

//     // =========================================================================
//     // DVP Frame Streaming Task
//     // =========================================================================
//     // Data is placed on dvp_d_i at the FALLING edge of pclk so it is
//     // stable well before the next RISING edge samples it (≥ half pclk period
//     // of setup time). This mirrors the OV-series camera timing spec.
//     //
//     // Frame structure:
//     //   VSYNC high  (start-of-frame pulse, ≥ 3 line-times)
//     //   inter-frame blanking
//     //   For each row:
//     //     HREF high for COL_NUM × 2 pclk beats
//     //     horizontal blanking
//     //   VSYNC high  (end-of-frame pulse)

//     task automatic stream_dvp_frame ();
//         int r, c;

//         // --- Start-of-frame VSYNC ---
//         // Drive vsync at negedge so it is stable before the next posedge.
//         @(negedge dvp_pclk_i); dvp_vsync_i = 1'b1;
//         repeat (10) @(negedge dvp_pclk_i);
//         dvp_vsync_i = 1'b0;
//         repeat (20) @(negedge dvp_pclk_i);   // pre-row blanking

//         $display("[STREAM] Streaming %0d rows x %0d cols...", IMG_H, IMG_W);

//         for (r = 0; r < IMG_H; r++) begin
//             // -----------------------------------------------------------------
//             // FIX: Assert HREF *and* drive the first high byte on the SAME
//             // negedge.  This ensures that the very first posedge the DRC FIFO
//             // sees with href=1 is the one that carries real pixel data, not a
//             // phantom 0x00 byte.
//             //
//             // Root-cause of the original trap:
//             //   Old code:  @(negedge) href=1;          <- negedge N
//             //              @(negedge) d_i = hi_byte;   <- negedge N+1
//             //   Posedge between N and N+1 captured {href=1, d=0x00}: phantom!
//             //   => DRC saw 113 bytes per row (1 phantom + 112 real), byte
//             //   counter was ODD when href fell => drc_trap = 1.
//             //
//             // Fix: co-drive href and first byte together so posedge N+0.5 sees
//             //   {href=1, d=hi_byte[0]}  -- first real byte, not a phantom.
//             // -----------------------------------------------------------------
//             @(negedge dvp_pclk_i);
//             dvp_href_i = 1'b1;
//             dvp_d_i    = source_image[r * IMG_W + 0][15:8]; // pre-load hi byte of col 0

//             // col 0 high byte already on bus; complete it then loop from col 1
//             @(negedge dvp_pclk_i);  // posedge between here sampled hi_byte col0
//             dvp_d_i = source_image[r * IMG_W + 0][7:0];     // lo byte of col 0

//             for (c = 1; c < IMG_W; c++) begin
//                 @(negedge dvp_pclk_i);
//                 dvp_d_i = source_image[r * IMG_W + c][15:8];
//                 @(negedge dvp_pclk_i);
//                 dvp_d_i = source_image[r * IMG_W + c][7:0];
//             end

//             // De-assert HREF on the negedge immediately after the last lo-byte
//             // posedge has sampled it (one more negedge-wait).
//             @(negedge dvp_pclk_i);
//             dvp_href_i = 1'b0;
//             dvp_d_i    = 8'h00;
//             repeat (10) @(negedge dvp_pclk_i);  // horizontal blanking
//         end

//         repeat (10) @(negedge dvp_pclk_i);  // post-frame blanking

//         // --- End-of-frame VSYNC ---
//         @(negedge dvp_pclk_i); dvp_vsync_i = 1'b1;
//         repeat (10) @(negedge dvp_pclk_i);
//         dvp_vsync_i = 1'b0;

//         $display("[STREAM] Frame transfer complete.");
//     endtask

    
//     // =========================================================================
//     // Concurrent Interrupt Monitors (Sticky Flags)
//     // =========================================================================
//     logic dma_irq_seen = 0;
//     logic drc_irq_seen = 0;

//     always @(posedge clk) begin
//         if (dma_irq && !dma_irq_seen) begin
//             $display("[IRQ] DMA Transfer Complete! (Time: %0t)", $time);
//             dma_irq_seen <= 1'b1;
//         end
//         if (drc_irq && !drc_irq_seen) begin
//             $display("[IRQ] DRC Capture Complete! (Time: %0t)", $time);
//             drc_irq_seen <= 1'b1;
//         end
//     end
    
    
//     // =========================================================================
//     // Main Test Sequence
//     // =========================================================================
//     initial begin
//         // Default levels
//         s_drc_awvalid = 0; s_drc_wvalid = 0; s_drc_bready = 1;
//         s_drc_arvalid = 0; s_drc_rready = 1;
//         s_drc_awid='0; s_drc_awlen='0; s_drc_awsize='0; s_drc_awburst=2'b01;
//         s_drc_wstrb=4'hF; s_drc_wlast=0;
//         s_drc_arid='0; s_drc_arlen='0; s_drc_arsize='0; s_drc_arburst=2'b01;

//         s_dma_awvalid = 0; s_dma_wvalid = 0; s_dma_bready = 1;
//         s_dma_arvalid = 0; s_dma_rready = 1;
//         s_dma_awid='0; s_dma_awlen='0; s_dma_awsize='0; s_dma_awburst=2'b01;
//         s_dma_wstrb=4'hF; s_dma_wlast=0;
//         s_dma_arid='0; s_dma_arlen='0; s_dma_arsize='0; s_dma_arburst=2'b01;

//         dvp_vsync_i=0; dvp_href_i=0; dvp_hsync_i=0; dvp_d_i=8'h00;

//         // Load or generate source image
//         begin : load_image
//             int i;
//             for (i = 0; i < TOTAL_PIXELS; i++)
//                 source_image[i] = 16'(i & 16'hFFFF);       // ramp fallback
//             for (i = 0; i < DTCM_DEPTH; i++)
//                 dtcm_mem[i] = 32'h0;
//         end
//         $readmemh("./python/input_image.hex", source_image, 0, TOTAL_PIXELS-1);
//         $display("[INIT] Source image loaded (pixel[0]=0x%04h)", source_image[0]);

//         @(posedge rst_n);
//         repeat (5) @(posedge clk);

//         // =====================================================================
//         // STEP 1 – DMA channel registers (no descriptor yet)
//         // =====================================================================
//         $display("[CFG] Step 1: Configuring DMA channel registers...");
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_GLOB_EN, 32'h0000_0001); // global enable
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_CHN_EN,  32'h0000_0001); // ch-0 enable
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_CHN_FLG, 32'h0000_0000); // 1-D, not cyclic
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_IRQ_MSK, 32'h0000_0001); // IRQ on completion
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_DST_BST, 32'h0000_0001); // dst burst = INCR
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_WPB,     32'd15);        // 16 beats/burst

//         // =====================================================================
//         // STEP 2 – Enable DVP RX (this starts xclk toggling)
//         // =====================================================================
//         $display("[CFG] Step 2: Configuring DVP RX controller...");
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_CAM_EN,   32'h0000_0001); // cam_rx_en = 1
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_CAM_PWDN, 32'h0000_0000); // cam_pwdn  = 0
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_RX_MODE,  32'h0000_0002); // STREAM mode
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_IRQ_MSK,  32'h0000_0003); // both IRQs
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_IMG_W,    DATA_W'(IMG_W));
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_IMG_H,    DATA_W'(IMG_H));
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_PROC,
//                       {30'b0, EN_DOWNSCALE, EN_GRAYSCALE});
//         // Trigger cam_rx_start via RW1S register
//         axi_write_drc(DRC_BASE_ADDR + DRC_OFF_START,    32'h0000_0001);
//         $display("[CFG] DVP RX enabled and cam_rx_start triggered.");

//         // =====================================================================
//         // STEP 3 – Wait for xclk to start, THEN submit the DMA descriptor
//         // =====================================================================
//         // xclk begins toggling within a few system clocks of cam_rx_en=1.
//         // We must confirm it before issuing any dvp_pclk_i edge-waits.
//         $display("[WAIT] Waiting for dvp_xclk_o to start toggling...");
//         wait_for_xclk();

//         $display("[CFG] Step 3: Submitting DMA descriptor...");
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_SRC_ADDR, 32'h0000_0000);         // unused (AXIS src)
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_DST_ADDR, DTCM_BASE);
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_XLEN,     DATA_W'(OUT_WORDS - 1));// total xfers - 1
//         axi_write_dma(DMA_BASE_ADDR + DMA_OFF_SUBMIT,   32'h0000_0001);
//         $display("[CFG] DMA armed: %0d x 32-bit words → dst=0x%08h",
//                  OUT_WORDS, DTCM_BASE);

//         // =====================================================================
//         // STEP 4 – Stream the DVP frame
//         // =====================================================================
//         $display("[STREAM] Starting DVP frame stream...");
//         stream_dvp_frame();

//         // =====================================================================
//         // STEP 5 – Wait for both interrupts
//         // =====================================================================
//         $display("[WAIT] Verifying drc_irq and dma_irq were captured...");
        
//         while (!drc_irq_seen || !dma_irq_seen) begin
//             @(posedge clk);
            
//             // Abort immediately on hardware traps
//             if (drc_trap) begin
//                 $display("[ABORT] drc_trap fired – pixel misalignment in DRC FSM.");
//                 $finish;
//             end
//             if (dma_trap) begin
//                 $display("[ABORT] dma_trap fired – DMA address/length error.");
//                 $finish;
//             end
//         end

//         $display("[PASS] Both hardware blocks completed successfully.");

//         if (drc_trap) $display("[WARN] drc_trap – DVP pixel misalignment");
//         if (dma_trap) $display("[WARN] dma_trap – DMA address error");

//         // =====================================================================
//         // STEP 6 – Sanity check + dump DTCM to file
//         // =====================================================================
//         begin : check_and_dump
//             int nonzero, fd, i;
//             nonzero = 0;
//             for (i = 0; i < OUT_WORDS; i++)
//                 if (dtcm_mem[i] !== 32'h0) nonzero++;
//             $display("[CHECK] %0d / %0d DTCM words non-zero.", nonzero, OUT_WORDS);
//             if (nonzero == 0)
//                 $display("[FAIL]  All DTCM words are zero – check DMA or pixel pipeline.");
//             else
//                 $display("[PASS]  Pixel data present in DTCM.");

//             fd = $fopen("./python/output_dtcm.hex", "w");
//             for (i = 0; i < OUT_WORDS; i++)
//                 $fdisplay(fd, "%08x", dtcm_mem[i]);
//             $fclose(fd);
//             $display("[DONE]  DTCM → python/output_dtcm.hex (%0d words)", OUT_WORDS);
//         end

//         repeat (20) @(posedge clk);
//         $display("[SIM]   Finished successfully at time %0t.", $time);
//         $finish;
//     end

//     // =========================================================================
//     // Timeout
//     // =========================================================================
//     initial begin
//         #100_000_000; // 100 ms
//         $display("[TIMEOUT] Simulation exceeded 100 ms.");
//         $display("[DEBUG]   dvp_xclk_o=%b  dvp_pclk_i=%b", dvp_xclk_o, dvp_pclk_i);
//         $display("[DEBUG]   drc_irq=%b  dma_irq=%b  drc_trap=%b  dma_trap=%b",
//                  drc_irq, dma_irq, drc_trap, dma_trap);
//         $display("[DEBUG]   m_dma_awvalid=%b  m_dma_wvalid=%b  w_active=%b",
//                  m_dma_awvalid, m_dma_wvalid, w_active);
//         $finish;
//     end

//     // =========================================================================
//     // Always-on monitors
//     // =========================================================================
//     always @(posedge drc_trap)
//         $display("[TRAP]  drc_trap at %0t – pixel misalignment!", $time);
//     always @(posedge dma_trap)
//         $display("[TRAP]  dma_trap at %0t – DMA address error!", $time);

// endmodule

// `timescale 1ns / 1ps

// module tb_dvp_dma;

//     // =========================================================================
//     // Parameters
//     // =========================================================================
//     localparam ADDR_W        = 32;
//     localparam DATA_W        = 32;
//     localparam ID_W          = 4;
//     localparam DRC_BASE_ADDR = 32'h6001_0000;
//     localparam DMA_BASE_ADDR = 32'h6000_0000;
    
//     // --- RUNTIME FEATURE TOGGLES ---
//     localparam logic EN_GRAYSCALE = 1'b0; 
//     localparam logic EN_DOWNSCALE = 1'b0; // Set to 0 to output full 14x14 image!
    
//     localparam IMG_W         = 14; 
//     localparam IMG_H         = 14;
//     localparam TOTAL_PIXELS  = IMG_W * IMG_H;
    
//     localparam OUT_W         = EN_DOWNSCALE ? (IMG_W / 2) : IMG_W;
//     localparam OUT_H         = EN_DOWNSCALE ? (IMG_H / 2) : IMG_H;
//     localparam OUT_PIXELS    = OUT_W * OUT_H;
//     localparam OUT_BYTES     = OUT_PIXELS * 2; 
//     localparam OUT_WORDS     = OUT_BYTES / 4;  
    
//     localparam DTCM_BASE     = 32'h0000_0000;

//     // =========================================================================
//     // Signals
//     // =========================================================================
//     logic clk, rst_n;
//     logic dvp_pclk_i;
    
//     logic [7:0] dvp_d_i;
//     logic       dvp_href_i, dvp_vsync_i, dvp_hsync_i;
//     wire        dvp_xclk_o, dvp_pwdn_o;

//     // AXI Slaves
//     logic [ID_W-1:0]   s_drc_awid, s_drc_arid, s_drc_bid, s_drc_rid;
//     logic [ADDR_W-1:0] s_drc_awaddr, s_drc_araddr;
//     logic [7:0]        s_drc_awlen, s_drc_arlen;
//     logic [2:0]        s_drc_awsize, s_drc_arsize;
//     logic [1:0]        s_drc_awburst, s_drc_arburst, s_drc_bresp, s_drc_rresp;
//     logic [DATA_W-1:0] s_drc_wdata, s_drc_rdata;
//     logic [3:0]        s_drc_wstrb;
//     logic s_drc_awvalid, s_drc_awready, s_drc_wlast, s_drc_wvalid, s_drc_wready;
//     logic s_drc_bvalid, s_drc_bready, s_drc_arvalid, s_drc_arready;
//     logic s_drc_rlast, s_drc_rvalid, s_drc_rready;

//     logic [ID_W-1:0]   s_dma_awid, s_dma_arid, s_dma_bid, s_dma_rid;
//     logic [ADDR_W-1:0] s_dma_awaddr, s_dma_araddr;
//     logic [7:0]        s_dma_awlen, s_dma_arlen;
//     logic [2:0]        s_dma_awsize, s_dma_arsize;
//     logic [1:0]        s_dma_awburst, s_dma_arburst, s_dma_bresp, s_dma_rresp;
//     logic [DATA_W-1:0] s_dma_wdata, s_dma_rdata;
//     logic [3:0]        s_dma_wstrb;
//     logic s_dma_awvalid, s_dma_awready, s_dma_wlast, s_dma_wvalid, s_dma_wready;
//     logic s_dma_bvalid, s_dma_bready, s_dma_arvalid, s_dma_arready;
//     logic s_dma_rlast, s_dma_rvalid, s_dma_rready;

//     // AXI Master
//     wire [ID_W-1:0]   m_dma_awid, m_dma_bid;
//     wire [ADDR_W-1:0] m_dma_awaddr;
//     wire [7:0]        m_dma_awlen;
//     wire [1:0]        m_dma_awburst, m_dma_bresp;
//     wire              m_dma_awvalid, m_dma_awready;
//     wire [DATA_W-1:0] m_dma_wdata;
//     wire              m_dma_wlast, m_dma_wvalid, m_dma_wready;
//     wire              m_dma_bvalid, m_dma_bready;

//     wire drc_irq, drc_trap, dma_irq, dma_trap;

//     reg [15:0] source_image [0:TOTAL_PIXELS-1];
//     reg [31:0] dtcm_mem     [0:4095]; 

//     initial begin: mem_init
//         for (int i = 0; i < 4096; i++) dtcm_mem[i] = 32'h0;
//         for (int j = 0; j < TOTAL_PIXELS; j++) source_image[j] = 16'h0;
//     end

//     // Clocks
//     initial clk = 0;
//     always #5 clk = ~clk; 

//     initial begin
//         dvp_pclk_i = 0;
//         #3; 
//         forever #40 dvp_pclk_i = ~dvp_pclk_i; 
//     end

//     initial begin
//         rst_n = 0;
//         #55 rst_n = 1;
//     end

//     // =========================================================================
//     // BACKGROUND INTERRUPT MONITORS (Sticky Flags)
//     // =========================================================================
//     logic dma_done = 0;
//     logic drc_done = 0;
//     always @(posedge clk) begin
//         if (dma_irq) dma_done <= 1'b1;
//         if (drc_irq) drc_done <= 1'b1;
//     end

//     // =========================================================================
//     // DUT
//     // =========================================================================
//     dvp_dma_wrapper #(
//         .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
//         .DRC_BASE_ADDR(DRC_BASE_ADDR), .DMA_BASE_ADDR(DMA_BASE_ADDR),
//         .FRM_COL_NUM(IMG_W), .FRM_ROW_NUM(IMG_H)
//     ) dut (
//         .clk(clk), .rst_n(rst_n),
//         .dvp_d_i(dvp_d_i), .dvp_href_i(dvp_href_i), .dvp_vsync_i(dvp_vsync_i), .dvp_hsync_i(dvp_hsync_i),
//         .dvp_pclk_i(dvp_pclk_i), .dvp_xclk_o(dvp_xclk_o), .dvp_pwdn_o(dvp_pwdn_o),
        
//         .s_axi_drc_awid(s_drc_awid), .s_axi_drc_awaddr(s_drc_awaddr), .s_axi_drc_awlen(s_drc_awlen), .s_axi_drc_awsize(s_drc_awsize), .s_axi_drc_awburst(s_drc_awburst), .s_axi_drc_awvalid(s_drc_awvalid), .s_axi_drc_awready(s_drc_awready), .s_axi_drc_wdata(s_drc_wdata), .s_axi_drc_wstrb(s_drc_wstrb), .s_axi_drc_wlast(s_drc_wlast), .s_axi_drc_wvalid(s_drc_wvalid), .s_axi_drc_wready(s_drc_wready), .s_axi_drc_bid(s_drc_bid), .s_axi_drc_bresp(s_drc_bresp), .s_axi_drc_bvalid(s_drc_bvalid), .s_axi_drc_bready(s_drc_bready), .s_axi_drc_arid(s_drc_arid), .s_axi_drc_araddr(s_drc_araddr), .s_axi_drc_arlen(s_drc_arlen), .s_axi_drc_arsize(s_drc_arsize), .s_axi_drc_arburst(s_drc_arburst), .s_axi_drc_arvalid(s_drc_arvalid), .s_axi_drc_arready(s_drc_arready), .s_axi_drc_rid(s_drc_rid), .s_axi_drc_rdata(s_drc_rdata), .s_axi_drc_rresp(s_drc_rresp), .s_axi_drc_rlast(s_drc_rlast), .s_axi_drc_rvalid(s_drc_rvalid), .s_axi_drc_rready(s_drc_rready),
//         .s_axi_dma_awid(s_dma_awid), .s_axi_dma_awaddr(s_dma_awaddr), .s_axi_dma_awlen(s_dma_awlen), .s_axi_dma_awsize(s_dma_awsize), .s_axi_dma_awburst(s_dma_awburst), .s_axi_dma_awvalid(s_dma_awvalid), .s_axi_dma_awready(s_dma_awready), .s_axi_dma_wdata(s_dma_wdata), .s_axi_dma_wstrb(s_dma_wstrb), .s_axi_dma_wlast(s_dma_wlast), .s_axi_dma_wvalid(s_dma_wvalid), .s_axi_dma_wready(s_dma_wready), .s_axi_dma_bid(s_dma_bid), .s_axi_dma_bresp(s_dma_bresp), .s_axi_dma_bvalid(s_dma_bvalid), .s_axi_dma_bready(s_dma_bready), .s_axi_dma_arid(s_dma_arid), .s_axi_dma_araddr(s_dma_araddr), .s_axi_dma_arlen(s_dma_arlen), .s_axi_dma_arsize(s_dma_arsize), .s_axi_dma_arburst(s_dma_arburst), .s_axi_dma_arvalid(s_dma_arvalid), .s_axi_dma_arready(s_dma_arready), .s_axi_dma_rid(s_dma_rid), .s_axi_dma_rdata(s_dma_rdata), .s_axi_dma_rresp(s_dma_rresp), .s_axi_dma_rlast(s_dma_rlast), .s_axi_dma_rvalid(s_dma_rvalid), .s_axi_dma_rready(s_dma_rready),
//         .m_axi_dma_awid(m_dma_awid), .m_axi_dma_awaddr(m_dma_awaddr), .m_axi_dma_awlen(m_dma_awlen), .m_axi_dma_awburst(m_dma_awburst), .m_axi_dma_awvalid(m_dma_awvalid), .m_axi_dma_awready(m_dma_awready), .m_axi_dma_wdata(m_dma_wdata), .m_axi_dma_wlast(m_dma_wlast), .m_axi_dma_wvalid(m_dma_wvalid), .m_axi_dma_wready(m_dma_wready), .m_axi_dma_bid(m_dma_bid), .m_axi_dma_bresp(m_dma_bresp), .m_axi_dma_bvalid(m_dma_bvalid), .m_axi_dma_bready(m_dma_bready),
        
//         .drc_irq(drc_irq), .drc_trap(drc_trap), .dma_irq(dma_irq), .dma_trap(dma_trap)
//     );


//     // =========================================================================
//     // AXI Slave Write Tasks
//     // =========================================================================
//     task automatic write_drc(input [31:0] addr, input [31:0] data);
//         logic aw_done = 0; logic w_done  = 0;
//         @(posedge clk); #1;
//         s_drc_awvalid = 1; s_drc_awaddr = addr; s_drc_awid = 0; s_drc_awburst = 2'b01; s_drc_awlen = 0;
//         s_drc_wvalid = 1; s_drc_wdata = data; s_drc_wlast = 1; s_drc_wstrb = 4'hF;
//         while (!aw_done || !w_done) begin
//             @(posedge clk);
//             if (s_drc_awready && !aw_done) begin #1; s_drc_awvalid = 0; aw_done = 1; end
//             if (s_drc_wready && !w_done) begin #1; s_drc_wvalid = 0; s_drc_wlast = 0; w_done = 1; end
//         end
//         while (!s_drc_bvalid) @(posedge clk);
//         $display("[CFG] DRC 0x%08h <= 0x%08h", addr, data);
//     endtask

//     task automatic write_dma(input [31:0] addr, input [31:0] data);
//         logic aw_done = 0; logic w_done  = 0;
//         @(posedge clk); #1;
//         s_dma_awvalid = 1; s_dma_awaddr = addr; s_dma_awid = 0; s_dma_awburst = 2'b01; s_dma_awlen = 0;
//         s_dma_wvalid = 1; s_dma_wdata = data; s_dma_wlast = 1; s_dma_wstrb = 4'hF;
//         while (!aw_done || !w_done) begin
//             @(posedge clk);
//             if (s_dma_awready && !aw_done) begin #1; s_dma_awvalid = 0; aw_done = 1; end
//             if (s_dma_wready && !w_done) begin #1; s_dma_wvalid = 0; s_dma_wlast = 0; w_done = 1; end
//         end
//         while (!s_dma_bvalid) @(posedge clk);
//         $display("[CFG] DMA 0x%08h <= 0x%08h", addr, data);
//     endtask

//     // =========================================================================
//     // DTCM Slave
//     // =========================================================================
//     reg [1:0] dtcm_state = 0;
//     reg [ID_W-1:0] cap_awid;
//     reg [31:0] cap_awaddr;
//     reg [7:0]  w_beat = 0;

//     assign m_dma_awready = (dtcm_state == 0);
//     assign m_dma_wready  = (dtcm_state == 1);
//     assign m_dma_bvalid  = (dtcm_state == 2);
//     assign m_dma_bid     = cap_awid;
//     assign m_dma_bresp   = 2'b00;

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             dtcm_state <= 0;
//         end else begin
//             case (dtcm_state)
//                 0: begin
//                     if (m_dma_awvalid) begin
//                         cap_awid   <= m_dma_awid;
//                         cap_awaddr <= m_dma_awaddr;
//                         w_beat     <= 0;
//                         dtcm_state <= 1;
//                     end
//                 end
//                 1: begin
//                     if (m_dma_wvalid) begin
//                         integer mem_idx = (cap_awaddr - DTCM_BASE) + w_beat;
//                         if (mem_idx >= 0 && mem_idx < 4096) begin 
//                             dtcm_mem[mem_idx] <= m_dma_wdata;
//                             dtcm_i <= m_dma_wdata;
//                         end
//                         if (m_dma_wlast) dtcm_state <= 2;
//                         else w_beat <= w_beat + 1;
//                     end
//                 end
//                 2: if (m_dma_bready) dtcm_state <= 0;
//             endcase
//         end
//     end

//     reg [31:0] dtcm_i;

//     // =========================================================================
//     // MAIN TEST SEQUENCE
//     // =========================================================================
//     initial begin
//         s_drc_awvalid = 0; s_drc_wvalid = 0; s_drc_bready = 1;
//         s_drc_arvalid = 0; s_drc_rready = 1;
//         s_dma_awvalid = 0; s_dma_wvalid = 0; s_dma_bready = 1;
//         s_dma_arvalid = 0; s_dma_rready = 1;
        
//         dvp_vsync_i = 0; dvp_href_i = 0; dvp_hsync_i = 0; dvp_d_i = 0;
        
//         $readmemh("./python/input_image.hex", source_image, 0, TOTAL_PIXELS-1);
//         $display("[INIT] Read image hex file.");

//         @(posedge rst_n);
//         repeat(10) @(posedge clk);
        
//         // 1. DMA Config
//         write_dma(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); 
//         write_dma(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); 
//         write_dma(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); 
    

//         write_dma(DMA_BASE_ADDR + 32'h0008, 32'd15); 

//         write_dma(DMA_BASE_ADDR + 32'h0009, 32'd0); 

//         write_dma(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     
//         write_dma(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   
//         write_dma(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); 
//         $display("[CFG] DMA programmed to fetch %0d words", OUT_WORDS);

//         // 2. DRC Config
//         write_drc(DRC_BASE_ADDR + 32'h00, 32'h01);
//         write_drc(DRC_BASE_ADDR + 32'h01, 32'h00);
//         write_drc(DRC_BASE_ADDR + 32'h02, 32'h02);
//         write_drc(DRC_BASE_ADDR + 32'h03, 32'h0000_0003); 
//         write_drc(DRC_BASE_ADDR + 32'h04, IMG_W);
//         write_drc(DRC_BASE_ADDR + 32'h05, IMG_H);         
//         write_drc(DRC_BASE_ADDR + 32'h06, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
//         write_drc(DRC_BASE_ADDR + 32'h10, 32'h0000_0001); 
//         $display("[CFG] DVP RX started.");

//         #5000;

//         // 3. Stream Virtual Image
//         $display("[STREAM] Sending VSYNC...");
//         @(negedge dvp_pclk_i);
//         dvp_vsync_i = 1; 
//         repeat(20) @(negedge dvp_pclk_i); 
//         dvp_vsync_i = 0;
//         repeat(50) @(negedge dvp_pclk_i); 
        
//         $display("[STREAM] Streaming %0d rows...", IMG_H);
//         for (int r = 0; r < IMG_H; r++) begin
            
//             // NEGEDGE FIX: Drive signals on the falling edge!
//             @(negedge dvp_pclk_i);
//             dvp_href_i = 1;
            
//             for (int c = 0; c < IMG_W; c++) begin
//                 dvp_d_i = source_image[r*IMG_W + c][15:8];
//                 @(negedge dvp_pclk_i);
//                 dvp_d_i = source_image[r*IMG_W + c][7:0];  
//                 @(negedge dvp_pclk_i);
//             end
            
//             // NEGEDGE FIX: Drop href perfectly aligned to the end of the row
//             dvp_href_i = 0;
//             repeat(30) @(negedge dvp_pclk_i); 
//         end
        
//         repeat(50) @(negedge dvp_pclk_i);
//         dvp_vsync_i = 1; 
//         repeat(20) @(negedge dvp_pclk_i); 
//         dvp_vsync_i = 0;
//         $display("[STREAM] Frame transfer complete.");

//         // 4. Check sticky flags
//         $display("[WAIT] Validating IRQs...");
//         while (!dma_done || !drc_done) begin
//             @(posedge clk);
//         end
//         $display("[PASS] Both hardware blocks completed successfully.");
        
//         begin
//             int fd;
//             fd = $fopen("./python/output_dtcm.hex", "w");
//             for (int i = 0; i < OUT_WORDS; i++) begin
//                 $fdisplay(fd, "%08x", dtcm_mem[i]);
//             end
//             $fclose(fd);
//             $display("[PASS] Memory dumped to output_dtcm.hex");
//         end

//         #1000;
//         $finish;
//     end

//     initial begin
//         #10_000_000;
//         $display("[TIMEOUT] Simulation stalled.");
//         $finish;
//     end

// endmodule

// single axi interface dvp dma wrapper testbench
`timescale 1ns / 1ps

module tb_dvp_dma;

    localparam ADDR_W        = 32;
    localparam DATA_W        = 32;
    localparam ID_W          = 4;
    localparam DRC_BASE_ADDR = 32'h6001_0000;
    localparam DMA_BASE_ADDR = 32'h6000_0000;
    
    localparam logic EN_GRAYSCALE = 1'b0; 
    localparam logic EN_DOWNSCALE = 1'b0; 
    
    localparam IMG_W         = 14; 
    localparam IMG_H         = 14;
    localparam TOTAL_PIXELS  = IMG_W * IMG_H;
    
    localparam OUT_W         = EN_DOWNSCALE ? (IMG_W / 2) : IMG_W;
    localparam OUT_H         = EN_DOWNSCALE ? (IMG_H / 2) : IMG_H;
    localparam OUT_PIXELS    = (OUT_W == 0 || OUT_H == 0) ? 1 : (OUT_W * OUT_H);
    
    localparam OUT_BYTES     = OUT_PIXELS * 2; 
    localparam OUT_WORDS     = OUT_BYTES / 4;  
    
    localparam DTCM_BASE     = 32'h0000_0000;

    logic clk, rst_n;
    logic dvp_pclk_i;
    logic pclk_en;
    
    logic [7:0] dvp_d_i;
    logic       dvp_href_i, dvp_vsync_i, dvp_hsync_i;
    wire        dvp_xclk_o, dvp_pwdn_o;

    // Single Consolidated Slave Interface
    logic [ID_W-1:0]   s_axi_awid, s_axi_arid, s_axi_bid, s_axi_rid;
    logic [ADDR_W-1:0] s_axi_awaddr, s_axi_araddr;
    logic [7:0]        s_axi_awlen, s_axi_arlen;
    logic [2:0]        s_axi_awsize, s_axi_arsize;
    logic [1:0]        s_axi_awburst, s_axi_arburst, s_axi_bresp, s_axi_rresp;
    logic [DATA_W-1:0] s_axi_wdata, s_axi_rdata;
    logic [3:0]        s_axi_wstrb;
    logic s_axi_awvalid, s_axi_awready, s_axi_wlast, s_axi_wvalid, s_axi_wready;
    logic s_axi_bvalid, s_axi_bready, s_axi_arvalid, s_axi_arready;
    logic s_axi_rlast, s_axi_rvalid, s_axi_rready;

    // Master Interface (DMA out to DTCM)
    // FIX: Changed driven signals from 'wire' to 'logic' to resolve PROCASSWIRE errors
    wire [ID_W-1:0]   m_dma_awid;
    logic [ID_W-1:0]  m_dma_bid;
    wire [ADDR_W-1:0] m_dma_awaddr;
    wire [7:0]        m_dma_awlen;
    wire [1:0]        m_dma_awburst;
    logic [1:0]       m_dma_bresp;
    wire              m_dma_awvalid;
    logic             m_dma_awready;
    wire [DATA_W-1:0] m_dma_wdata;
    wire              m_dma_wlast, m_dma_wvalid;
    logic             m_dma_wready;
    logic             m_dma_bvalid;
    wire              m_dma_bready;

    wire drc_irq, drc_trap, dma_irq, dma_trap;

    reg [15:0] source_image [0:TOTAL_PIXELS-1];
    reg [31:0] dtcm_mem     [0:4095]; 

    initial begin
        for (int i = 0; i < 4096; i++) dtcm_mem[i] = 32'h0;
        for (int i = 0; i < TOTAL_PIXELS; i++) source_image[i] = 16'h0;
    end

    // Clocks
    initial clk = 0;
    always #5 clk = ~clk; 

    initial begin
        pclk_en = 0; dvp_pclk_i = 0;
        #3; 
        forever #40 if(pclk_en) dvp_pclk_i = ~dvp_pclk_i; 
    end

    initial begin
        rst_n = 0;
        #55 rst_n = 1;
    end

    // Background Monitors
    logic dma_done = 0;
    logic drc_done = 0;
    always @(posedge clk) begin
        if (dma_irq) dma_done <= 1'b1;
        if (drc_irq) drc_done <= 1'b1;
        if (drc_trap) $display("[ERROR] drc_trap FIRED! Hardware aborted the frame.");
    end

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    dvp_dma_wrapper #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
        .DRC_BASE_ADDR(DRC_BASE_ADDR), .DMA_BASE_ADDR(DMA_BASE_ADDR),
        .FRM_COL_NUM(640), .FRM_ROW_NUM(480)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .dvp_d_i(dvp_d_i), .dvp_href_i(dvp_href_i), .dvp_vsync_i(dvp_vsync_i), .dvp_hsync_i(dvp_hsync_i),
        .dvp_pclk_i(dvp_pclk_i), .dvp_xclk_o(dvp_xclk_o), .dvp_pwdn_o(dvp_pwdn_o),
        
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize), .s_axi_awburst(s_axi_awburst), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready), 
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready), 
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready), 
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize), .s_axi_arburst(s_axi_arburst), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready), 
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        
        .m_axi_dma_awid(m_dma_awid), .m_axi_dma_awaddr(m_dma_awaddr), .m_axi_dma_awlen(m_dma_awlen), .m_axi_dma_awburst(m_dma_awburst), .m_axi_dma_awvalid(m_dma_awvalid), .m_axi_dma_awready(m_dma_awready),
        .m_axi_dma_wdata(m_dma_wdata), .m_axi_dma_wlast(m_dma_wlast), .m_axi_dma_wvalid(m_dma_wvalid), .m_axi_dma_wready(m_dma_wready),
        .m_axi_dma_bid(m_dma_bid), .m_axi_dma_bresp(m_dma_bresp), .m_axi_dma_bvalid(m_dma_bvalid), .m_axi_dma_bready(m_dma_bready),
        
        .drc_irq(drc_irq), .drc_trap(drc_trap), .dma_irq(dma_irq), .dma_trap(dma_trap)
    );

    // =========================================================================
    // Unified AXI Write Task
    // =========================================================================
    task automatic write_axi(input [31:0] addr, input [31:0] data);
        logic aw_done = 0; logic w_done  = 0;
        @(posedge clk); #1;
        s_axi_awvalid = 1; s_axi_awaddr = addr; s_axi_awid = 0; s_axi_awburst = 2'b01; s_axi_awlen = 0;
        s_axi_wvalid = 1; s_axi_wdata = data; s_axi_wlast = 1; s_axi_wstrb = 4'hF;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (s_axi_awready && !aw_done) begin #1; s_axi_awvalid = 0; aw_done = 1; end
            if (s_axi_wready && !w_done) begin #1; s_axi_wvalid = 0; s_axi_wlast = 0; w_done = 1; end
        end
        while (!s_axi_bvalid) @(posedge clk);
        $display("[CFG] Wrote 0x%08h to 0x%08h", data, addr);
    endtask

    // =========================================================================
    // FIX: DTCM Memory Slave (ROBUST ARRAY-BASED VERSION)
    // SystemVerilog dynamic queues ([$]) removed to fix Verilator Internal Fault.
    // Replaced with a fully synthesizable static circular FIFO.
    // =========================================================================
    localparam AW_Q_DEPTH = 16;
    logic [ADDR_W-1:0] aw_fifo_addr [0:AW_Q_DEPTH-1];
    logic [ID_W-1:0]   aw_fifo_id   [0:AW_Q_DEPTH-1];
    logic [4:0] aw_wr_ptr = 0;
    logic [4:0] aw_rd_ptr = 0;
    logic [7:0] w_beat    = 0;
    
    wire [4:0] aw_count = aw_wr_ptr - aw_rd_ptr;
    
    assign m_dma_awready = (aw_count < AW_Q_DEPTH);
    assign m_dma_wready  = (aw_count > 0);
    assign m_dma_bresp   = 2'b00;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_wr_ptr <= 0;
            aw_rd_ptr <= 0;
            w_beat    <= 0;
            m_dma_bvalid <= 0;
            m_dma_bid    <= 0;
        end else begin
            // 1. Clear B response handshake
            if (m_dma_bvalid && m_dma_bready) begin
                m_dma_bvalid <= 0;
            end
            
            // 2. Push Address Request
            if (m_dma_awvalid && m_dma_awready) begin
                aw_fifo_addr[aw_wr_ptr[3:0]] <= m_dma_awaddr;
                aw_fifo_id[aw_wr_ptr[3:0]]   <= m_dma_awid;
                aw_wr_ptr <= aw_wr_ptr + 1;
            end
            
            // 3. Process Write Data
            if (m_dma_wvalid && m_dma_wready) begin
                int cur_addr;
                int mem_idx;
                
                cur_addr = aw_fifo_addr[aw_rd_ptr[3:0]];
                mem_idx  = (cur_addr - DTCM_BASE) + w_beat;
                
                if (mem_idx >= 0 && mem_idx < 4096) begin
                    dtcm_mem[mem_idx] <= m_dma_wdata;
                end
                
                if (m_dma_wlast) begin
                    m_dma_bvalid <= 1;
                    m_dma_bid    <= aw_fifo_id[aw_rd_ptr[3:0]];
                    aw_rd_ptr    <= aw_rd_ptr + 1;
                    w_beat       <= 0;
                end else begin
                    w_beat <= w_beat + 1;
                end
            end
        end
    end

    // =========================================================================
    // MAIN TEST SEQUENCE
    // =========================================================================
    initial begin
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 1;
        s_axi_arvalid = 0; s_axi_rready = 1;
        
        dvp_vsync_i = 0; dvp_href_i = 0; dvp_hsync_i = 0; dvp_d_i = 0;
        
        $readmemh("./python/input_image.hex", source_image, 0, TOTAL_PIXELS-1);

        @(posedge rst_n);
        repeat(10) @(posedge clk);
        
        // 1. DMA Config
        $display("[CFG] Routing to DMA Core...");
        write_axi(DMA_BASE_ADDR + 32'h0000, 32'h0000_0001); 
        write_axi(DMA_BASE_ADDR + 32'h0001, 32'h0000_0001); 
        write_axi(DMA_BASE_ADDR + 32'h0002, 32'h0000_0000); 
        write_axi(DMA_BASE_ADDR + 32'h0003, 32'h0000_0001); 
        write_axi(DMA_BASE_ADDR + 32'h0007, 32'h0000_0001); 
        write_axi(DMA_BASE_ADDR + 32'h0008, 32'd15);        
        write_axi(DMA_BASE_ADDR + 32'h000A, DTCM_BASE);     
        write_axi(DMA_BASE_ADDR + 32'h000B, OUT_WORDS-1);   
        write_axi(DMA_BASE_ADDR + 32'h1000, 32'h0000_0001); 
        
        // 2. DRC Config
        $display("\n[CFG] Routing to DVP RX Controller...");
        write_axi(DRC_BASE_ADDR + 32'h00, 32'h01);
        write_axi(DRC_BASE_ADDR + 32'h01, 32'h00);
        write_axi(DRC_BASE_ADDR + 32'h02, 32'h02);
        write_axi(DRC_BASE_ADDR + 32'h03, 32'h0000_0003); 
        write_axi(DRC_BASE_ADDR + 32'h04, IMG_W);
        write_axi(DRC_BASE_ADDR + 32'h05, IMG_H);         
        write_axi(DRC_BASE_ADDR + 32'h06, {30'b0, EN_DOWNSCALE, EN_GRAYSCALE}); 
        write_axi(DRC_BASE_ADDR + 32'h10, 32'h0000_0001); 

        pclk_en = 1;
        #5000;

        // 3. Stream Virtual Image
        $display("\n[STREAM] Sending VSYNC...");
        @(negedge dvp_pclk_i);
        dvp_vsync_i = 1; 
        repeat(20) @(negedge dvp_pclk_i); 
        dvp_vsync_i = 0;
        
        repeat(50) @(negedge dvp_pclk_i); 
        
        $display("[STREAM] Streaming %0d rows...", IMG_H);
        for (int r = 0; r < IMG_H; r++) begin
            @(negedge dvp_pclk_i);
            dvp_href_i = 1;
            for (int c = 0; c < IMG_W; c++) begin
                dvp_d_i = source_image[r*IMG_W + c][15:8];
                @(negedge dvp_pclk_i);
                dvp_d_i = source_image[r*IMG_W + c][7:0];  
                @(negedge dvp_pclk_i);
            end
            dvp_href_i = 0;
            repeat(30) @(negedge dvp_pclk_i); 
        end
        
        repeat(50) @(negedge dvp_pclk_i);
        dvp_vsync_i = 1; 
        repeat(20) @(negedge dvp_pclk_i); 
        dvp_vsync_i = 0;
        $display("[STREAM] Frame transfer complete.");

        // 4. Wait for completion
        $display("\n[WAIT] Verifying drc_irq and dma_irq were captured...");
        while (!drc_done || !dma_done) begin
            @(posedge clk);
            if (drc_trap) $finish;
        end
        $display("[PASS] Both hardware blocks completed successfully.");
        
        begin
            int fd;
            fd = $fopen("./python/output_dtcm.hex", "w");
            for (int i = 0; i < OUT_WORDS; i++) begin
                $fdisplay(fd, "%08x", dtcm_mem[i]);
            end
            $fclose(fd);
            $display("[PASS] Memory dumped to output_dtcm.hex");
        end

        #1000;
        $finish;
    end

    initial begin
        #10_000_000;
        $display("[TIMEOUT] Simulation stalled.");
        $finish;
    end

endmodule
