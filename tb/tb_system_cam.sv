`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// =============================================================================
//  tb_system_cam : Option A row-streaming at full resolution
//
//  A 320x240 RGB565 frame is streamed on the DVP pins at a real 30 fps pixel rate
//  (PCLK 5 MHz).  cam_frontend crops 224x224 at (48, 8), converts to int8 R/G/B row
//  planes and writes 16-row stripes (+3 halo rows) into 3 slots of act_mem.  The job
//  list (28 jobs = 14 stripes x {conv1+ReLU+maxpool, fire2 squeeze}) starts at once:
//  each conv1 job waits for its camera rows and releases its slot when done, so the
//  network runs while the frame is still arriving.
//  Checks:
//    1. every cropped row lands in its slot (and the halo copy in the previous slot)
//    2. no camera overrun (the engine keeps up with 30 fps)
//    3. the 16 x 55 x 55 squeeze map (padded frame) == full-image bit-exact model
//       (stripes must reproduce the full computation exactly); ONNX stats reported
//    4. argmax head over the 16 squeeze channels, on the pins and over SPI
//  Data: scripts/gen_cam_stage1.py -> hex/cam_stage1/
// =============================================================================
module tb_system_cam;

    localparam string D = "hex/cam_stage1/";
    localparam int CAM_W = 320, CAM_H = 240, CROP = 224, ROWW = 168;   // words per cropped row
    localparam int ADV = 16, HALO = 3, SLOTS = 3, SLOT_W = 19 * ROWW;
    localparam int N_JOBS = 28, DESC_WORDS = 25;                        // words 25..31 are 0
    localparam int SQ_BASE = 13312, SQ_WORDS = 16 * 912;
    localparam int FLASH_BYTES = 'h2000;
    localparam int SPI_HALF = 50;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic       dvp_pclk = 0, pclk_en = 0;
    logic       dvp_vsync = 0, dvp_hsync = 0, dvp_href = 0;
    logic [7:0] dvp_d = 0;
    wire        dvp_xclk, dvp_pwdn;
    always #100 if (pclk_en) dvp_pclk = ~dvp_pclk;       // 5 MHz: 320x240 RGB565 at ~30 fps

    wire        qspi_sck, qspi_cs_n;
    wire [3:0]  qspi_io;
    pullup (qspi_io[2]);
    pullup (qspi_io[3]);

    logic        spi_sck = 0, spi_cs_n = 1, spi_mosi = 0;
    wire         host_irq, spi_miso, result_valid, busy;
    wire  [6:0]  result_pins;
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

    logic [15:0] frame     [0:CAM_W*CAM_H-1];
    logic [31:0] crop_exp  [0:CROP*ROWW-1];
    logic [7:0]  flash_img [0:FLASH_BYTES-1];
    logic [31:0] desc      [0:32*N_JOBS-1];
    logic [31:0] sq_model  [0:SQ_WORDS-1], sq_onnx [0:SQ_WORDS-1];

    int errors = 0;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    initial $timeformat(-6, 2, " us", 10);

    initial begin
        $readmemh({D, "frame565.hex"}, frame);
        $readmemh({D, "crop_exp.hex"}, crop_exp);
        $readmemh({D, "flash.hex"},    flash_img);
        $readmemh({D, "desc.hex"},     desc);
        $readmemh({D, "sq_model.hex"}, sq_model);
        $readmemh({D, "sq_onnx.hex"},  sq_onnx);
        #1;
        for (int i = 0; i < FLASH_BYTES; i++) flash.memory[i] = flash_img[i];
        flash.status_reg[9] = 1'b1;                       // QE (quad read), see tb_system_sqz
    end

    // ---------------- MCU SPI master BFM ----------------
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
        spi_xfer_bits(32'h0, 8, rx);
        spi_xfer_bits(32'h0, 32, data);
        #SPI_HALF spi_cs_n = 1; #(4 * SPI_HALF);
    endtask

    // ---------------- camera (OV7670-like DVP timing) ----------------
    task automatic stream_frame();
        @(negedge dvp_pclk); dvp_vsync = 1;
        repeat (20) @(negedge dvp_pclk); dvp_vsync = 0;
        repeat (50) @(negedge dvp_pclk);
        for (int r = 0; r < CAM_H; r++) begin
            @(negedge dvp_pclk); dvp_href = 1;
            for (int c = 0; c < CAM_W; c++) begin
                dvp_d = frame[r * CAM_W + c][15:8];       // RGB565 high byte first
                @(negedge dvp_pclk);
                dvp_d = frame[r * CAM_W + c][7:0];
                @(negedge dvp_pclk);
            end
            dvp_href = 0;
            repeat (30) @(negedge dvp_pclk);
        end
        repeat (50) @(negedge dvp_pclk); dvp_vsync = 1;
        repeat (20) @(negedge dvp_pclk); dvp_vsync = 0;
    endtask

    // ---------------- check 1: each cropped row in its slot(s) ----------------
    logic [15:0] rows_q = 0;
    int row_bad = 0, rows_checked = 0;
    function automatic int check_row(input int r, input int slot, input int local_row);
        int bad = 0;
        for (int w = 0; w < ROWW; w++)
            if (dut.act.peek(slot * SLOT_W + local_row * ROWW + w) !== crop_exp[r * ROWW + w]) bad++;
        return bad;
    endfunction
    always @(posedge clk) begin
        rows_q <= dut.cam_rows_done;
        if (dut.cam_rows_done == rows_q + 16'd1) begin
            automatic int r = rows_q, s = r / ADV, l = r % ADV, b;
            b = check_row(r, s % SLOTS, l);
            if (s > 0 && l < HALO) b += check_row(r, (s - 1) % SLOTS, l + ADV);
            if (b != 0 && row_bad < 5) $display("[%0t] [CAM ] row %0d: %0d words wrong", $time, r, b);
            if (b != 0 && row_bad == 0)
                for (int w = 0; w < ROWW; w++)
                    if (dut.act.peek((s % SLOTS) * SLOT_W + l * ROWW + w) !== crop_exp[r * ROWW + w])
                        $display("      word %0d (act %0d): got %08h exp %08h  | exp[w-1] %08h exp[w+1] %08h", w,
                                 (s % SLOTS) * SLOT_W + l * ROWW + w,
                                 dut.act.peek((s % SLOTS) * SLOT_W + l * ROWW + w), crop_exp[r * ROWW + w],
                                 crop_exp[r * ROWW + w - 1], crop_exp[r * ROWW + w + 1]);
            row_bad += (b != 0);
            rows_checked++;
        end
    end

    // ---------------- progress ----------------
    int conv_jobs = 0;
    realtime first_conv_t, frame_done_t;
    logic [7:0] last_job = 8'hFF;
    logic fd_q = 0;
    always @(posedge clk) begin
        fd_q <= dut.cam_frame_done;
        if (dut.cam_frame_done && !fd_q) begin
            frame_done_t = $realtime;
            $display("[%0t] [CAM ] frame written: %0d rows, %0d conv1 stripes already done, overrun %0d",
                     $time, dut.cam_rows_done, conv_jobs, dut.cam_overrun);
        end
        if (dut.core_start && dut.sys_ctrl.layer_idx != last_job) begin
            last_job <= dut.sys_ctrl.layer_idx;
            if (dut.sys_ctrl.layer_idx % 2 == 0) begin
                if (conv_jobs == 0) first_conv_t = $realtime;
                conv_jobs++;
                $display("[%0t] [FSM ] stripe %2d: conv1+pool on %0d conv rows (camera rows written %0d)",
                         $time, dut.sys_ctrl.layer_idx / 2, dut.cfg_nty, dut.cam_rows_done);
            end
        end
    end

    // ---------------- main ----------------
    initial begin
        logic [31:0] r_res, r_stat, id;
        longint best = 0, sum;
        int exp_cls = 0, n_sq = 0, n_on = 0, n_on1 = 0, max_on = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        spi_read32(CSR + 32'h24, id);
        if (id != 32'h5ACE_0001) begin $display("SPI ID wrong %08h", id); errors++; end
        $display("[%0t] [MCU ] SPI: %0d jobs, camera config, head, start", $time, N_JOBS);
        for (int j = 0; j < N_JOBS; j++)
            for (int w = 0; w < DESC_WORDS; w++) spi_write32(DESC + 128 * j + 4 * w, desc[32 * j + w]);
        // camera: 320x240 sensor, crop 224x224 at (48,8) (reset values), RGB row-planar,
        // 3 slots of 16+3 rows at act_mem word 0
        spi_write32(CSR + 32'h4C, 32'd0);
        spi_write32(CSR + 32'h50, 32'h6000_0000);
        spi_write32(CSR + 32'h54, 4 * SLOT_W);
        spi_write32(CSR + 32'h58, {8'(SLOTS), 8'(HALO), 16'(ADV)});
        spi_write32(CSR + 32'h5C, 4 * ROWW);
        spi_write32(CSR + 32'h18, {16'd912, 16'd16});   // head: 16 channel frames of 912 words
        spi_write32(CSR + 32'h1C, 32'h6000_0000 + 4 * SQ_BASE);
        spi_write32(CSR + 32'h00, N_JOBS);

        wait (dut.cam_arm);
        pclk_en = 1;
        #5000;
        $display("[%0t] [CAM ] streaming 320x240 RGB565 at PCLK 5 MHz", $time);
        fork
            stream_frame();
            begin
                fork
                    wait (host_irq);
                    begin
                        repeat (8_000_000) @(posedge clk);
                        $display("[%0t] TIMEOUT: FSM state %0d job %0d pass %0d rows %0d", $time,
                                 dut.sys_ctrl.state, dut.sys_ctrl.layer_idx, dut.sys_ctrl.pass_idx, dut.cam_rows_done);
                        $display("-> VERDICT: FAILED (timeout)");
                        $finish;
                    end
                join_any
                disable fork;
            end
        join
        $display("[%0t] [SYS ] host_irq after %0d cycles", $time, cyc);

        // ---- checks ----
        $display("\n=== camera front end ===");
        $display("  rows checked %0d / %0d, rows with wrong data %0d, overrun %0d",
                 rows_checked, CROP, row_bad, dut.cam_overrun);
        if (rows_checked != CROP || row_bad != 0 || dut.cam_overrun) errors++;

        $display("=== fire2 squeeze map 16 x 55 x 55 (padded frame 16 x 57 x 64 bytes) ===");
        for (int w = 0; w < SQ_WORDS; w++) begin
            logic [31:0] hw = dut.act.peek(SQ_BASE + w);
            if (hw !== sq_model[w]) n_sq++;
            for (int p = 0; p < 4; p++) begin
                int d = $signed(hw[8*p +: 8]) - $signed(sq_onnx[w][8*p +: 8]);
                d = d < 0 ? -d : d;
                if (d != 0) n_on++;
                if (d > 1)  n_on1++;
                if (d > max_on) max_on = d;
            end
        end
        $display("  vs full-image bit-exact model : %0d / %0d words differ", n_sq, SQ_WORDS);
        $display("  vs ONNX original model (conv1 not folded): %0d values differ, %0d by more than 1, max %0d",
                 n_on, n_on1, max_on);
        errors += n_sq;

        for (int c = 0; c < 16; c++) begin
            sum = 0;
            for (int w = 0; w < 912; w++)
                for (int p = 0; p < 4; p++) sum += $signed(sq_model[c * 912 + w][8*p +: 8]);
            if (c == 0 || sum > best) begin best = sum; exp_cls = c; end
        end
        spi_read32(CSR + 32'h10, r_res);
        spi_read32(CSR + 32'h04, r_stat);
        $display("=== head ===  expected class %0d; pins %0d (valid %0d); SPI RESULT %0d (valid %0d); STATUS %08h",
                 exp_cls, result_pins, result_valid, r_res[15:0], r_res[31], r_stat);
        if (!result_valid || result_pins != exp_cls[6:0] || r_res[15:0] != exp_cls[15:0]) errors++;
        if (r_stat[11:8] != 0) errors++;                 // traps / camera overrun

        $display("\n  camera frame complete at %0.2f ms, first conv1 stripe at %0.2f ms, inference done at %0.2f ms",
                 frame_done_t / 1e6, first_conv_t / 1e6, $realtime / 1e6);
        if (errors == 0) $display("-> VERDICT: SUCCESS (224x224 crop on chip, 14 stripes streamed during capture, bit-exact, no overrun)");
        else             $display("-> VERDICT: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
