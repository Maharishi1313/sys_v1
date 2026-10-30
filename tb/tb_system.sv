`timescale 1ns / 1ps

module tb_system;

    // =========================================================================
    // Signals & Clocks
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    
    always #5 clk = ~clk; // 100MHz System Clock

    // Camera DVP
    logic       dvp_pclk = 0;
    logic       dvp_vsync = 0;
    logic       dvp_hsync = 0;
    logic       dvp_href = 0;
    logic [7:0] dvp_d = 0;
    wire        dvp_xclk, dvp_pwdn;
    
    // SPI MCU Interface
    logic mcu_spi_sck = 0;
    logic mcu_spi_cs_n = 1;
    logic mcu_spi_mosi = 0;
    wire  mcu_spi_miso;
    wire  host_irq;

    // QSPI Flash
    wire       qspi_sck, qspi_cs_n;
    wire [3:0] qspi_io;
    
    // Log File
    int log_fd;

    // =========================================================================
    // DUT
    // =========================================================================
    accelerator_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .dvp_pclk_i(dvp_pclk),
        .dvp_vsync_i(dvp_vsync),
        .dvp_hsync_i(dvp_hsync),
        .dvp_href_i(dvp_href),
        .dvp_d_i(dvp_d),
        .dvp_xclk_o(dvp_xclk),
        .dvp_pwdn_o(dvp_pwdn),
        .qspi_sck(qspi_sck),
        .qspi_cs_n(qspi_cs_n),
        .qspi_io(qspi_io),
        .mcu_spi_sck(mcu_spi_sck),
        .mcu_spi_cs_n(mcu_spi_cs_n),
        .mcu_spi_mosi(mcu_spi_mosi),
        .mcu_spi_miso(mcu_spi_miso),
        .host_irq(host_irq)
    );

    // QSPI Flash Model
    W25Q16JV flash_model (
        .CSn(qspi_cs_n),
        .CLK(qspi_sck),
        .DIO(qspi_io[0]),
        .DO(qspi_io[1]),
        .WPn(qspi_io[2]),
        .HOLDn(qspi_io[3])
    );

    // =========================================================================
    // External MCU SPI Bus Functional Model (BFM)
    // =========================================================================
    task automatic mcu_spi_write32(input [31:0] addr, input [31:0] data);
        logic [71:0] shift_reg;
        shift_reg = {8'h02, addr, data}; // 0x02 Write CMD + Addr + Data
        
        @(posedge clk);
        mcu_spi_cs_n = 0;
        
        for (int i = 71; i >= 0; i--) begin
            mcu_spi_mosi = shift_reg[i];
            #20 mcu_spi_sck = 1;
            #20 mcu_spi_sck = 0;
        end
        
        #20 mcu_spi_cs_n = 1;
        $fdisplay(log_fd, "[%0t] [MCU SPI] Wrote 0x%08h to Addr 0x%08h", $time, data, addr);
    endtask

    // =========================================================================
    // DVP Camera Bus Functional Model (BFM)
    // =========================================================================
    always #20 dvp_pclk = ~dvp_pclk; // 25MHz PCLK

    task automatic stream_chunk(input int chunk_rows, input int img_w);
        $fdisplay(log_fd, "[%0t] [CAMERA] Streaming %0d rows...", $time, chunk_rows);
        
        @(negedge dvp_pclk);
        dvp_vsync = 1;
        repeat(10) @(negedge dvp_pclk);
        dvp_vsync = 0;
        repeat(20) @(negedge dvp_pclk);
        
        for (int r = 0; r < chunk_rows; r++) begin
            @(negedge dvp_pclk);
            dvp_href = 1;
            for (int c = 0; c < img_w; c++) begin
                dvp_d = 8'hAA; // Dummy high byte
                @(negedge dvp_pclk);
                dvp_d = 8'h55; // Dummy low byte
                @(negedge dvp_pclk);
            end
            dvp_href = 0;
            repeat(15) @(negedge dvp_pclk);
        end
        $fdisplay(log_fd, "[%0t] [CAMERA] Chunk complete.", $time);
    endtask

    // =========================================================================
    // Main Verification Sequence
    // =========================================================================
    initial begin
        // Initialize logging
        log_fd = $fopen("./log/system_trace.log", "w");
        $fdisplay(log_fd, "=== SQUEEZENET STANDALONE ACCELERATOR TRACE ===");

        // Reset Sequence
        rst_n = 0;
        #100;
        rst_n = 1;
        $fdisplay(log_fd, "[%0t] [SYS] Hardware out of reset.", $time);

        #500;

        // 1. MCU programs the Layer Descriptors via SPI to Layer SRAM (Base 0xC000_0000)
        $fdisplay(log_fd, "[%0t] [SYS] MCU programming Layer 0 (Squeeze 1x1)...", $time);
        mcu_spi_write32(32'hC000_0000, 32'h0000_0100); // flip=0, passes=0 (etc)
        mcu_spi_write32(32'hC000_0038, 32'h0000_0000); // flash_src = 0x0
        mcu_spi_write32(32'hC000_003C, 32'h0000_00EB); // weight_words = 235

        $fdisplay(log_fd, "[%0t] [SYS] MCU programming Layer 1 (Expand 1x1)...", $time);
        mcu_spi_write32(32'hC000_0040, 32'h0000_0100); // Addr + 64 (0x40)
        
        $fdisplay(log_fd, "[%0t] [SYS] MCU programming Layer 2 (Expand 3x3)...", $time);
        // Note the flip_bank=1 in Word 0 for this layer
        mcu_spi_write32(32'hC000_0080, 32'h8000_0100); // Addr + 128 (0x80)

        // 2. MCU writes active_num_layers to sys_controller to trigger inference loop
        $fdisplay(log_fd, "[%0t] [SYS] MCU asserting active_num_layers = 3 to start engine.", $time);
        mcu_spi_write32(32'h1000_0000, 32'h0000_0003); // Assuming sys_controller mapped config register

        // 3. Wait for DVP to initialize (cam_rx_start triggers xclk)
        #2000;
        
        // 4. Stream Image Chunks
        stream_chunk(32, 320);
        
        // 5. Wait for inference completion
        $fdisplay(log_fd, "[%0t] [SYS] Waiting for Inference Host IRQ...", $time);
        
        fork
            begin
                wait (host_irq == 1);
                $fdisplay(log_fd, "[%0t] [SUCCESS] Host IRQ received. Inference complete.", $time);
                $display("=== VERILATOR TEST PASSED ===");
            end
            begin
                #50_000_000; // 500us Timeout
                $fdisplay(log_fd, "[%0t] [ERROR] Simulation Timeout.", $time);
                $display("=== VERILATOR TEST FAILED (TIMEOUT) ===");
            end
        join_any
        
        $fclose(log_fd);
        $finish;
    end

    // =========================================================================
    // Critical Debug Probes (Logged quietly to file)
    // =========================================================================
    always @(posedge clk) begin
        if (dut.sys_ctrl.state != dut.sys_ctrl.state) // Capture state changes only
            $fdisplay(log_fd, "[%0t] [FSM] State transition: %0d", $time, dut.sys_ctrl.state);
            
        if (dut.layer_done)
            $fdisplay(log_fd, "[%0t] [CORE] Layer Compute Done.", $time);
            
        if (dut.sys_dma_irq[0])
            $fdisplay(log_fd, "[%0t] [DMA] Weight Load Complete.", $time);
            
        if (dut.sys_dma_irq[1])
            $fdisplay(log_fd, "[%0t] [DMA] Concat/Reshape Complete.", $time);
            
        if (dut.dvp_rx_inst.drc_trap)
            $fdisplay(log_fd, "[%0t] [FATAL] DVP DRC Trap Fired!", $time);
    end

endmodule
