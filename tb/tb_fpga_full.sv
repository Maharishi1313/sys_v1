`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// =============================================================================
//  tb_fpga_full : the complete customised SqueezeNet-1.1 on the FPGA top level
//
//  fpga_top = accelerator_top + spi_boot_master (boot_rom.mem: camera/head CSRs, 88 job
//  descriptors, START).  The W25Q16JV model holds flash_image (weights of all 26 convs);
//  a camera BFM streams the 320x240 RGB565 test frame at a 30 fps pixel rate.
//  Checks: class on the result pins and in the boot master (read over SPI) == golden,
//          classifier maps in act_mem bit-exact, no camera overrun / traps.
//  Data: scripts/compile_squeezenet.py -> build/sqz_custom/
// =============================================================================
module tb_fpga_full;

    localparam string D = "build/sqz_custom/";
    localparam int CAM_W = 320, CAM_H = 240;

    logic clk = 0, rst_btn = 1;
    always #5 clk = ~clk;                                  // 100 MHz

    logic       cam_pclk = 0, pclk_en = 0, cam_vsync = 0, cam_href = 0;
    logic [7:0] cam_d = 0;
    wire        cam_xclk, cam_pwdn, flash_sck, flash_cs_n, host_irq;
    wire [3:0]  flash_io;
    wire [7:0]  led;
    wire [6:0]  result_o;
    pullup (flash_io[2]);
    pullup (flash_io[3]);
    always #100 if (pclk_en) cam_pclk = ~cam_pclk;        // 5 MHz

    fpga_top #(.BOOT_HEX({D, "boot_rom.mem"}), .CONTINUOUS(1'b0)) dut (
        .clk_board(clk), .rst_btn(rst_btn),
        .cam_pclk(cam_pclk), .cam_vsync(cam_vsync), .cam_href(cam_href), .cam_d(cam_d),
        .cam_xclk(cam_xclk), .cam_pwdn(cam_pwdn),
        .flash_sck(flash_sck), .flash_cs_n(flash_cs_n), .flash_io(flash_io),
        .led(led), .result_o(result_o), .host_irq(host_irq)
    );

    W25Q16JV flash (.CSn(flash_cs_n), .CLK(flash_sck), .DIO(flash_io[0]), .DO(flash_io[1]),
                    .WPn(flash_io[2]), .HOLDn(flash_io[3]));

    logic [15:0] frame [0:CAM_W*CAM_H-1];
    logic [31:0] cls_exp [0:36*52-1];
    int gold_cls, cls_base, cls_words;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    initial $timeformat(-3, 3, " ms", 10);

    initial begin
        int fd; string key, line;
        $readmemh({D, "frame565.hex"}, frame);
        $readmemh({D, "cls_exp.hex"}, cls_exp);
        fd = $fopen({D, "golden.txt"}, "r");
        while ($fgets(line, fd)) begin
            int v;
            if ($sscanf(line, "class %d", v) == 1) gold_cls = v;
            if ($sscanf(line, "cls_base_word %d", v) == 1) cls_base = v;
            if ($sscanf(line, "cls_words %d", v) == 1) cls_words = v;
        end
        $fclose(fd);
        #1;
        $readmemh({D, "flash_sim.hex"}, flash.memory);
        flash.status_reg[9] = 1'b1;                       // QE: quad reads (set once on the board)
    end

    task automatic stream_frame();
        @(negedge cam_pclk); cam_vsync = 1;
        repeat (20) @(negedge cam_pclk); cam_vsync = 0;
        repeat (50) @(negedge cam_pclk);
        for (int r = 0; r < CAM_H; r++) begin
            @(negedge cam_pclk); cam_href = 1;
            for (int c = 0; c < CAM_W; c++) begin
                cam_d = frame[r * CAM_W + c][15:8];
                @(negedge cam_pclk);
                cam_d = frame[r * CAM_W + c][7:0];
                @(negedge cam_pclk);
            end
            cam_href = 0;
            repeat (30) @(negedge cam_pclk);
        end
        repeat (50) @(negedge cam_pclk); cam_vsync = 1;
        repeat (20) @(negedge cam_pclk); cam_vsync = 0;
    endtask

    // progress: one line per job
    logic [7:0] last_job = 8'hFF;
    always @(posedge clk) begin
        if (dut.soc.core_start && dut.soc.sys_ctrl.layer_idx != last_job) begin
            last_job <= dut.soc.sys_ctrl.layer_idx;
            $display("[%0t] job %2d  k=%0d passes=%0d  (cam rows %0d)", $time, dut.soc.sys_ctrl.layer_idx,
                     dut.soc.cfg_k_len, dut.soc.sys_ctrl.j_n_passes, dut.soc.cam_rows_done);
        end
    end

    initial begin
        int bad = 0;
        repeat (20) @(posedge clk);
        rst_btn = 0;
        wait (dut.soc.cam_arm);
        $display("[%0t] boot master finished the descriptors, SoC started (%0d cycles)", $time, cyc);
        pclk_en = 1;
        #5000;
        fork
            stream_frame();
            begin
                fork
                    wait (dut.boot.frames_done == 16'd1);
                    begin
                        repeat (90_000_000) @(posedge clk);
                        $display("[%0t] TIMEOUT: job %0d state %0d", $time, dut.soc.sys_ctrl.layer_idx, dut.soc.sys_ctrl.state);
                        $display("-> VERDICT: FAILED (timeout)");
                        $finish;
                    end
                join_any
                disable fork;
            end
        join
        repeat (100) @(posedge clk);

        for (int i = 0; i < cls_words; i++)
            if (dut.soc.act.peek(cls_base + i) !== cls_exp[i]) bad++;
        $display("\n[%0t] inference done after %0d cycles (%0.1f ms at 100 MHz)", $time, cyc, cyc / 1e5);
        $display("  classifier maps vs bit-exact model : %0d / %0d words differ", bad, cls_words);
        $display("  result pins %0d (valid %0d), boot master read over SPI: class %0d valid %0d, golden %0d",
                 result_o, led[6], dut.boot.result_class, dut.boot.result_valid, gold_cls);
        $display("  camera overrun %0d, STATUS traps %0d", dut.soc.cam_overrun, dut.soc.csr.trap_sticky);
        if (bad == 0 && result_o == gold_cls[6:0] && dut.boot.result_class == gold_cls[15:0] &&
            dut.boot.result_valid && !dut.soc.cam_overrun && dut.soc.csr.trap_sticky == 0)
            $display("-> VERDICT: SUCCESS (full SqueezeNet on fpga_top: SPI boot, camera, flash weights, class %0d)", gold_cls);
        else
            $display("-> VERDICT: FAILED");
        $finish;
    end
endmodule
