`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// =============================================================================
//  tb_system_sqz : full-SoC run of SqueezeNet-1.1 conv1 + pool + the whole fire2 module
//
//    L0  conv 3x3/s2 (3->64) + ReLU + MaxPool 3x3/s2       bank A -> B   weights in 4 chunks
//    L1  fire2 squeeze 1x1 (64->16) + ReLU, padded frame   bank B -> A   weights in 2 chunks
//    L2  fire2 expand1x1 (16->64) + ReLU   concat ch 0..63   bank A -> B
//    L3  fire2 expand3x3 (16->64) + ReLU   concat ch 64..127 bank A -> B   K = 144, pad 1
//    head: argmax over the 128 concat channels -> result pins / RESULT CSR
//
//  Everything goes through the real SoC path:
//    * an MCU SPI master BFM programs descriptors / CSRs over the SPI pins
//      (spi_slave_axi -> AXI M3 -> sys_csr at 0xA000_0000) and reads the result back
//    * sys_controller programs QSPI (XIP), DVP-RX, DVP-DMA and sys-DMA over AXI
//    * the input patch is streamed on the DVP pins -> dvp_rx_core -> cam_frontend
//      (RAW mode: bytes as received, uint8 -> int8) -> interconnect -> act_mem words 0..
//      L0 waits (descriptor W23/W24) until the front end has written all rows
//    * weights + requant params are fetched by the sys-DMA from the W25Q16JV flash
//      model (QSPI XIP) into the weight SRAM, one descriptor-sized chunk at a time
//  Checks:
//    1. act_mem A when the frame is written == expected int8 image patch
//    2. weight SRAM after every weight DMA  == the flash words of that chunk
//    3. bank B when L1 starts (pool output) == bit-exact model 16x16 / ONNX 15x15
//    4. bank A at the end (squeeze frame)   == bit-exact model incl. z_out border and the
//                                              valid_w-masked column / ONNX 15x15
//    5. bank B at the end (fire2 concat)    == bit-exact model 16x16 / ONNX 14x14
//    6. head: argmax on the pins, RESULT/SCORE over SPI, SPI SRAM read, IRQ clear
//    7. a second inference back to back (restart over SPI, new frame)
//  Data comes from scripts/gen_sqz_fire2.py (hex/sqz_fire2/).
// =============================================================================
module tb_system_sqz;

    localparam string D = "hex/sqz_fire2/";
    localparam int DVP_W = 160, DVP_H = 40;              // DVP frame (pixels, 2 bytes each)
    localparam int FRAME_BYTES = DVP_W * DVP_H * 2;
    localparam int IFMAP_WORDS = (3 * 65 * 65 + 3) / 4;  // words that hold the input patch
    localparam int N_LAYERS = 4;
    localparam int L0_WORDS = 64 * 64;                   // pool:    64 ch x 16 rows x 4 words
    localparam int L1_WORDS = 16 * 108;                  // squeeze: 16 ch x 18 rows x 6 words
    localparam int L3_WORDS = 128 * 64;                  // concat: 128 ch x 16 rows x 4 words
    localparam int FLASH_BYTES = 'h6000;
    localparam bit DVP_SWAP = 0;                         // RAW mode stores bytes in DVP order
    localparam int BANK_B = 20480;                       // act_mem word of the old bank B

    // -------------------------------------------------------------------------
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                                 // 100 MHz

    logic       dvp_pclk = 0, pclk_en = 0;
    logic       dvp_vsync = 0, dvp_hsync = 0, dvp_href = 0;
    logic [7:0] dvp_d = 0;
    wire        dvp_xclk, dvp_pwdn;
    always #40 if (pclk_en) dvp_pclk = ~dvp_pclk;        // 12.5 MHz PCLK (as reference TB)

    wire        qspi_sck, qspi_cs_n;
    wire [3:0]  qspi_io;
    pullup (qspi_io[2]);                                  // WP#  / HOLD# idle high
    pullup (qspi_io[3]);

    logic        spi_sck = 0, spi_cs_n = 1, spi_mosi = 0;
    wire         host_irq, spi_miso, result_valid, busy;
    wire  [6:0]  result_pins;
    localparam int SPI_HALF = 80;                         // ns -> 6.25 MHz SCK (<= clk/8)
    localparam logic [31:0] CSR = 32'hA000_0000, DESC = 32'hA001_0000;

    accelerator_top dut (
        .clk(clk), .rst_n(rst_n),
        .dvp_pclk_i(dvp_pclk), .dvp_vsync_i(dvp_vsync), .dvp_hsync_i(dvp_hsync),
        .dvp_href_i(dvp_href), .dvp_d_i(dvp_d), .dvp_xclk_o(dvp_xclk), .dvp_pwdn_o(dvp_pwdn),
        .qspi_sck(qspi_sck), .qspi_cs_n(qspi_cs_n), .qspi_io(qspi_io),
        .mcu_spi_sck(spi_sck), .mcu_spi_cs_n(spi_cs_n), .mcu_spi_mosi(spi_mosi), .mcu_spi_miso(spi_miso),
        .host_irq(host_irq),
        .result_o(result_pins), .result_valid_o(result_valid), .busy_o(busy)
    );

    W25Q16JV flash (.CSn(qspi_cs_n), .CLK(qspi_sck), .DIO(qspi_io[0]), .DO(qspi_io[1]),
                    .WPn(qspi_io[2]), .HOLDn(qspi_io[3]));

    // -------------------------------------------------------------------------
    logic [7:0]  frame     [0:FRAME_BYTES-1];
    logic [7:0]  flash_img [0:FLASH_BYTES-1];
    logic [31:0] desc      [0:32*N_LAYERS-1];
    logic [31:0] ifmap_exp [0:FRAME_BYTES/4-1];
    logic [31:0] l0_model [0:L0_WORDS-1], l0_onnx [0:L0_WORDS-1];
    logic [31:0] l1_model [0:L1_WORDS-1], l1_onnx [0:L1_WORDS-1];
    logic [31:0] l3_model [0:L3_WORDS-1], l3_onnx [0:L3_WORDS-1];
    logic [31:0] snap_b   [0:L0_WORDS-1];                 // bank B when L1 starts

    int errors = 0, max_diff = 0;
    // act_mem is one address space; the generator places the maps at A (0..) and B (20480..)
    function automatic logic [31:0] bank_rd(input bit b_half, input int w);
        return dut.act.peek(w + (b_half ? BANK_B : 0));
    endfunction
    longint cyc = 0;
    initial $timeformat(-6, 2, " us", 10);
    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        $readmemh({D, "frame.hex"},     frame);
        $readmemh({D, "flash.hex"},     flash_img);
        $readmemh({D, "desc.hex"},      desc);
        $readmemh({D, "ifmap_exp.hex"}, ifmap_exp);
        $readmemh({D, "l0_model.hex"},  l0_model);
        $readmemh({D, "l0_onnx.hex"},   l0_onnx);
        $readmemh({D, "l1_model.hex"},  l1_model);
        $readmemh({D, "l1_onnx.hex"},   l1_onnx);
        $readmemh({D, "l3_model.hex"},  l3_model);
        $readmemh({D, "l3_onnx.hex"},   l3_onnx);
        #1;  // after the flash model's own MEM.TXT load
        for (int i = 0; i < FLASH_BYTES; i++) flash.memory[i] = flash_img[i];
        // Quad Output Read (0x6B, used for XIP) needs SR2.QE = 1 - a pre-programmed
        // part ships with it set; nothing in the SoC boot flow writes the status register
        flash.status_reg[9] = 1'b1;
    end

    // -------------------------------------------------------------------------
    // MCU SPI master BFM (mode 0, MSB first)
    task automatic spi_xfer_bits(input logic [31:0] v, input int n, output logic [31:0] rx);
        rx = 0;
        for (int i = n - 1; i >= 0; i--) begin
            spi_mosi = v[i];
            #SPI_HALF spi_sck = 1; rx = {rx[30:0], spi_miso};
            #SPI_HALF spi_sck = 0;
        end
    endtask

    task automatic spi_write32(input [31:0] addr, input [31:0] data);
        logic [31:0] rx;
        spi_cs_n = 0; #SPI_HALF;
        spi_xfer_bits(32'h02, 8, rx); spi_xfer_bits(addr, 32, rx); spi_xfer_bits(data, 32, rx);
        #SPI_HALF spi_cs_n = 1; #(4 * SPI_HALF);
    endtask

    task automatic spi_read32(input [31:0] addr, output logic [31:0] data);
        logic [31:0] rx;
        spi_cs_n = 0; #SPI_HALF;
        spi_xfer_bits(32'h03, 8, rx); spi_xfer_bits(addr, 32, rx);
        spi_xfer_bits(32'h0, 8, rx);                      // dummy byte
        spi_xfer_bits(32'h0, 32, data);
        #SPI_HALF spi_cs_n = 1; #(4 * SPI_HALF);
    endtask

    task automatic stream_frame();
        @(negedge dvp_pclk); dvp_vsync = 1;
        repeat (20) @(negedge dvp_pclk); dvp_vsync = 0;
        repeat (50) @(negedge dvp_pclk);
        for (int r = 0; r < DVP_H; r++) begin
            @(negedge dvp_pclk); dvp_href = 1;
            for (int c = 0; c < DVP_W; c++) begin
                int b = 2 * (r * DVP_W + c);
                dvp_d = DVP_SWAP ? frame[b + 1] : frame[b];
                @(negedge dvp_pclk);
                dvp_d = DVP_SWAP ? frame[b] : frame[b + 1];
                @(negedge dvp_pclk);
            end
            dvp_href = 0;
            repeat (30) @(negedge dvp_pclk);
        end
        repeat (50) @(negedge dvp_pclk); dvp_vsync = 1;
        repeat (20) @(negedge dvp_pclk); dvp_vsync = 0;
    endtask

    // -------------------------------------------------------------------------
    // Compare int8 maps: channel c, row y, element x lives in word
    // c*wpc + y*rs + x/4.  Checks y in [y0,y1), x in [x0,x1).
    //   sel 0/1: snapshot of bank B (pool) vs model / ONNX
    //   sel 2/3: bank A (squeeze frame)    vs model / ONNX
    //   sel 4/5: bank B (fire2 concat)     vs model / ONNX     odd sel = ONNX (|diff| <= 1 allowed)
    function automatic int cmp_map(string tag, input int sel, input int nch, input int wpc,
                                   input int rs, input int y0, input int y1, input int x0,
                                   input int x1, input int max_print);
        int n = 0, checked = 0;
        for (int c = 0; c < nch; c++)
            for (int y = y0; y < y1; y++)
                for (int x = x0; x < x1; x++) begin
                    int w = c * wpc + y * rs + x / 4, p = x % 4;
                    logic [31:0] hw_w, ex_w;
                    logic signed [7:0] hw, ex;
                    case (sel)
                        0: begin hw_w = snap_b[w];                         ex_w = l0_model[w]; end
                        1: begin hw_w = snap_b[w];                         ex_w = l0_onnx[w];  end
                        2: begin hw_w = bank_rd(0, w); ex_w = l1_model[w]; end
                        3: begin hw_w = bank_rd(0, w); ex_w = l1_onnx[w];  end
                        4: begin hw_w = bank_rd(1, w); ex_w = l3_model[w]; end
                        default: begin hw_w = bank_rd(1, w); ex_w = l3_onnx[w]; end
                    endcase
                    hw = hw_w[8*p +: 8];
                    ex = ex_w[8*p +: 8];
                    checked++;
                    if (hw !== ex) begin
                        n++;
                        if (sel % 2 == 1 && (hw > ex ? hw - ex : ex - hw) > max_diff)
                            max_diff = hw > ex ? hw - ex : ex - hw;
                        if (n <= max_print)
                            $display("    %s mismatch C%0d Y%0d X%0d : hw %0d exp %0d", tag, c, y, x, hw, ex);
                    end
                end
        $display("  %-34s : %0d / %0d values differ", tag, n, checked);
        return n;
    endfunction

    // -------------------------------------------------------------------------
    //  Monitors
    // -------------------------------------------------------------------------
    logic [7:0] last_layer = 8'hFF;
    always @(posedge clk) begin
        if (dut.core_start) begin
            if (dut.sys_ctrl.layer_idx != last_layer) begin
                $display("[%0t] [FSM ] layer %0d: k_len=%0d n_pass=%0d maxpool=%0d pad_out=%0d oc_off=%0d valid_w=%0d cam_rows=%0d",
                         $time, dut.sys_ctrl.layer_idx, dut.cfg_k_len,
                         dut.sys_ctrl.j_n_passes, dut.cfg_maxpool_en,
                         dut.cfg_out_pad, dut.cfg_out_oc_off, dut.cfg_out_valid_w, dut.cam_rows_done);
                // check 3: pool output snapshot before L1 overwrites anything
                if (dut.sys_ctrl.layer_idx == 1)
                    for (int i = 0; i < L0_WORDS; i++) snap_b[i] = bank_rd(1, i);
            end
            last_layer <= dut.sys_ctrl.layer_idx;
        end
        if (dut.fill_start)
            $display("[%0t] [FSM ]   border fill of %0d output frames", $time, dut.fill_channels);
    end

    // check 2: weight SRAM == flash words of the chunk after every weight DMA
    always @(posedge clk) begin
        if (dut.sys_dma_irq) begin
            automatic int l    = dut.sys_ctrl.layer_idx;
            automatic int blk  = dut.sys_ctrl.cur_blk_words;
            automatic int nw   = dut.sys_ctrl.cur_chunk_n * blk;
            automatic int src  = desc[l*32 + 14] + 4 * dut.sys_ctrl.chunk_first * blk;
            automatic int bad  = 0;
            for (int i = 0; i < nw; i++) begin
                automatic logic [31:0] e = {flash_img[src+4*i+3], flash_img[src+4*i+2],
                                            flash_img[src+4*i+1], flash_img[src+4*i]};
                if (dut.weight_sram.weight_sram.mem[i] !== e) begin
                    bad++;
                    if (bad <= 5) $display("    WSRAM[%0d] = %08h exp %08h", i, dut.weight_sram.weight_sram.mem[i], e);
                end
            end
            $display("[%0t] [DMA ] layer %0d passes %0d..%0d: %0d words flash -> WSRAM, %0d mismatches",
                     $time, l, dut.sys_ctrl.chunk_first, dut.sys_ctrl.chunk_first + dut.sys_ctrl.cur_chunk_n - 1,
                     nw, bad);
            errors += bad;
        end
    end

    // check 1: act_mem A == input patch when the front end has written the frame
    logic fd_q = 0;
    always @(posedge clk) begin
        fd_q <= dut.cam_frame_done;
        if (dut.cam_frame_done && !fd_q) begin
            automatic int bad = 0;
            for (int i = 0; i < IFMAP_WORDS; i++)
                if (bank_rd(0, i) !== ifmap_exp[i]) begin
                    bad++;
                    if (bad <= 5) $display("    bank[%0d] = %08h exp %08h", i, bank_rd(0, i), ifmap_exp[i]);
                end
            $display("[%0t] [DVP ] frame -> cam_frontend (raw) -> act_mem: %0d / %0d words mismatch, %0d rows, overrun %0d",
                     $time, bad, IFMAP_WORDS, dut.cam_rows_done, dut.cam_overrun);
            if (dut.cam_overrun) errors++;
            errors += bad;
        end
    end

    always @(posedge clk) begin
        if (dut.dvp_rx_inst.drc_trap) $display("[%0t] [DVP ] ERROR: drc_trap", $time);
        if (dut.cam_overrun && !fd_q && dut.cam_frame_done) $display("[%0t] [CAM ] ERROR: overrun", $time);
    end

    task automatic check_maps(input string run);
        $display("\n=== %s L0 conv1+pool (bank B at L1 start, 64 x 16 x 16) ===", run);
        errors += cmp_map("L0 vs bit-exact model 16x16", 0, 64, 64, 4, 0, 16, 0, 16, 5);
        void'(cmp_map("L0 vs ONNX 15x15",                1, 64, 64, 4, 0, 15, 0, 15, 3));
        $display("=== %s L1 squeeze (bank A, padded frame 16 x 18 x 24) ===", run);
        errors += cmp_map("L1 frame vs model (incl. border)", 2, 16, 108, 6, 0, 18, 0, 24, 5);
        void'(cmp_map("L1 vs ONNX 15x15",                3, 16, 108, 6, 1, 16, 4, 19, 3));
        $display("=== %s L2+L3 fire2 concat (bank B, 128 x 16 x 16) ===", run);
        errors += cmp_map("concat vs bit-exact model 16x16", 4, 128, 64, 4, 0, 16, 0, 16, 5);
        void'(cmp_map("concat vs ONNX 14x14",            5, 128, 64, 4, 0, 14, 0, 14, 3));
    endtask

    // expected head result: argmax of the per-channel sums of the concat output
    int exp_cls = 0;
    longint exp_score = 0;
    initial begin
        #2;
        for (int c = 0; c < 128; c++) begin
            longint sum = 0;
            for (int w = 0; w < 64; w++)
                for (int p = 0; p < 4; p++) sum += $signed(l3_model[c * 64 + w][8*p +: 8]);
            if (c == 0 || sum > exp_score) begin exp_score = sum; exp_cls = c; end
        end
    end

    task automatic wait_irq(input string what);
        fork
            wait (host_irq);
            begin
                int tmo = 8_000_000;
                void'($value$plusargs("timeout=%d", tmo));
                repeat (tmo) @(posedge clk);
                $display("[%0t] TIMEOUT (%s): FSM state %0d, layer %0d, pass %0d", $time, what,
                         dut.sys_ctrl.state, dut.sys_ctrl.layer_idx, dut.sys_ctrl.pass_idx);
                $display("-> VERDICT: FAILED (timeout)");
                $finish;
            end
        join_any
        disable fork;
    endtask

    // -------------------------------------------------------------------------
    //  Main sequence
    // -------------------------------------------------------------------------
    initial begin
        logic [31:0] id, r_res, r_score, r_stat, r_word, r_irq;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        spi_read32(CSR + 32'h24, id);
        $display("[%0t] [MCU ] SPI read ID = %08h %s", $time, id, id == 32'h5ACE_0001 ? "ok" : "WRONG");
        if (id != 32'h5ACE_0001) errors++;
        $display("[%0t] [MCU ] SPI: %0d layer descriptors, head config, start", $time, N_LAYERS);
        for (int i = 0; i < 32 * N_LAYERS; i++) spi_write32(DESC + 4 * i, desc[i]);
        spi_write32(CSR + 32'h18, {16'd64, 16'd128});    // head: 128 classes x 64 words
        spi_write32(CSR + 32'h1C, 32'h6000_0000 + 4 * BANK_B);   // class 0 = concat output
        // camera front end: RAW bytes of the whole 160x40 frame into one stripe at A
        spi_write32(CSR + 32'h40, {16'(DVP_H), 16'(DVP_W)});
        spi_write32(CSR + 32'h44, 32'd0);
        spi_write32(CSR + 32'h48, {16'(DVP_H), 16'(DVP_W)});
        spi_write32(CSR + 32'h4C, 32'd1);
        spi_write32(CSR + 32'h50, 32'h6000_0000);
        spi_write32(CSR + 32'h54, 32'd0);
        spi_write32(CSR + 32'h58, {8'd1, 8'd0, 16'(DVP_H)});
        spi_write32(CSR + 32'h5C, 2 * DVP_W);
        spi_write32(CSR + 32'h00, N_LAYERS);              // start

        wait (dut.cam_arm);
        pclk_en = 1;
        #5000;
        $display("[%0t] [CAM ] streaming %0dx%0d frame (patch 3x65x65 uint8)", $time, DVP_W, DVP_H);
        stream_frame();
        wait_irq("inference 1");
        $display("[%0t] [SYS ] host_irq after %0d cycles", $time, cyc);
        repeat (10) @(posedge clk);
        check_maps("run 1:");

        spi_read32(CSR + 32'h04, r_stat);
        spi_read32(CSR + 32'h10, r_res);
        spi_read32(CSR + 32'h14, r_score);
        spi_read32(32'h6000_0000 + 4 * (BANK_B + 1234), r_word);  // output word, straight from SRAM
        $display("\n=== Classifier head / result interface ===");
        $display("  expected argmax class %0d (score %0d)", exp_cls, exp_score);
        $display("  result pins     : valid=%0d class=%0d", result_valid, result_pins);
        $display("  SPI RESULT/SCORE: valid=%0d class=%0d score=%0d   STATUS=%08h",
                 r_res[31], r_res[15:0], $signed(r_score), r_stat);
        $display("  SPI SRAM read   : output word 1234 = %08h (exp %08h)", r_word, l3_model[1234]);
        if (!result_valid || result_pins != exp_cls[6:0]) errors++;
        if (!r_res[31] || r_res[15:0] != exp_cls[15:0] || $signed(r_score) != exp_score) errors++;
        if (r_stat[1:0] != 2'b10 || r_stat[10:8] != 0) errors++;    // done, not busy, no traps
        if (r_word != l3_model[1234]) errors++;
        spi_write32(CSR + 32'h08, 32'h1);                 // clear the done IRQ
        spi_read32(CSR + 32'h08, r_irq);
        $display("  IRQ after W1C   : host_irq=%0d IRQ=%0d", host_irq, r_irq[0]);
        if (host_irq || r_irq[0]) errors++;

        // ---- second inference back to back: restart over SPI, new frame ----
        $display("\n=== Second inference (restart over SPI, new frame) ===");
        for (int i = 0; i < 2 * BANK_B; i++) dut.act.poke(i, 32'h0);   // no stale data
        last_layer = 8'hFF;
        spi_write32(CSR + 32'h00, N_LAYERS);
        if (result_valid) begin $display("  result_valid not cleared by START"); errors++; end
        #20000;
        stream_frame();
        wait_irq("inference 2");
        spi_read32(CSR + 32'h10, r_res);
        $display("[%0t] [SYS ] 2nd inference: pins class=%0d valid=%0d, SPI RESULT class=%0d valid=%0d",
                 $time, result_pins, result_valid, r_res[15:0], r_res[31]);
        if (!r_res[31] || r_res[15:0] != exp_cls[15:0] || result_pins != exp_cls[6:0]) errors++;
        check_maps("run 2:");

        $display("");
        $display("  max |hw - ONNX| = %0d LSB (float QDQ vs fixed-point requant; gen_sqz_fire2.py prints the expected counts)",
                 max_diff);
        if (max_diff > 1) errors++;
        if (errors == 0) $display("-> VERDICT: SUCCESS (SPI, DVP, chunked QSPI/DMA weights, conv1+pool+fire2 bit-exact, ONNX within 1 LSB, argmax head + pins, 2 inferences)");
        else             $display("-> VERDICT: FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
