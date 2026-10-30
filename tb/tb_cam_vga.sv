`timescale 1ns / 1ps

// =============================================================================
//  tb_cam_vga : simulation of rtl/fpga/cam_vga_test_top.sv with an OV7670 model
//    1. decodes every SCCB write (START, 0x42, register, value, STOP)
//    2. after the set-up, streams build/sqz_custom/frame565.hex as QVGA RGB565 frames
//       (PCLK 6.25 MHz, HREF per row, VSYNC pulse per frame)
//    3. checks every frame-buffer pixel and the VGA sync periods (800 x 525 pixels)
// =============================================================================
module tb_cam_vga;
    logic clk = 0, rstn = 0;
    always #5 clk = ~clk;

    wire        xclk, cam_rst_n, pwdn, sioc;
    wire        siod;
    pullup (siod);
    logic       pclk = 0, vsync = 0, href = 0;
    logic [7:0] d = 0;
    wire [3:0]  r, g, b;
    wire        hs, vs;
    wire [15:0] led;

    cam_vga_test_top dut (
        .clk100(clk), .cpu_resetn(rstn), .btnc(1'b0), .sw0(1'b0),
        .cam_xclk(xclk), .cam_reset_n(cam_rst_n), .cam_pwdn(pwdn), .cam_sioc(sioc), .cam_siod(siod),
        .cam_pclk(pclk), .cam_vsync(vsync), .cam_href(href), .cam_d(d),
        .vga_r(r), .vga_g(g), .vga_b(b), .vga_hs(hs), .vga_vs(vs), .led(led)
    );

    logic [15:0] frame [0:320*240-1];
    initial $readmemh("build/sqz_custom/frame565.hex", frame);

    // ---------------- SCCB decoder (the camera side)
    int nwr = 0, nbad = 0, nbits;
    logic [27:0] bits;
    logic sioc_q = 1, siod_q = 1;
    always @(posedge clk) begin
        sioc_q <= sioc; siod_q <= siod;
        if (sioc && siod_q && !siod) begin nbits = 0; bits = 0; end            // START
        if (!sioc_q && sioc) begin bits = {bits[26:0], siod}; nbits++; end     // sample on SIOC rise
        if (sioc && !siod_q && siod) begin                                     // STOP
            // the SIOC rise of the STOP condition itself is not a data bit
            if (nbits == 28) begin bits = 27'(bits >> 1); nbits = 27; end
            nwr++;
            if (nbits != 27 || bits[26:19] != 8'h42) nbad++;
            if (nwr <= 3 || nwr == 60 || nbits != 27 || bits[26:19] != 8'h42)
                $display("[%0t] SCCB write %0d: dev %02h reg %02h val %02h (%0d bits)",
                         $time, nwr, bits[26:19], bits[17:10], bits[8:1], nbits);
        end
    end

    // ---------------- camera stream
    always #80 pclk = ~pclk;                    // 6.25 MHz
    task automatic stream_frame();
        @(negedge pclk); vsync = 1;
        repeat (3 * 784) @(negedge pclk); vsync = 0;
        repeat (17 * 784) @(negedge pclk);
        for (int y = 0; y < 240; y++) begin
            href = 1;
            for (int x = 0; x < 320; x++) begin
                d = frame[y * 320 + x][15:8]; @(negedge pclk);
                d = frame[y * 320 + x][7:0];  @(negedge pclk);
            end
            href = 0; d = 0;
            repeat (144) @(negedge pclk);
        end
        repeat (10 * 784) @(negedge pclk);
    endtask

    // ---------------- VGA sync measurement
    longint cyc = 0, hs_last = 0, vs_last = 0, hs_per = 0, vs_per = 0;
    logic hs_q = 1, vs_q = 1;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        hs_q <= hs; vs_q <= vs;
        if (hs_q && !hs) begin hs_per = cyc - hs_last; hs_last = cyc; end
        if (vs_q && !vs) begin vs_per = cyc - vs_last; vs_last = cyc; end
    end

    initial begin
        int bad = 0;
        repeat (10) @(posedge clk);
        rstn = 1;
        wait (led[0]);
        $display("[%0t] SCCB done: %0d register writes, %0d malformed", $time, nwr, nbad);
        stream_frame();
        stream_frame();
        repeat (100) @(posedge clk);
        for (int i = 0; i < 320 * 240; i++) begin
            logic [15:0] p = frame[i];
            logic [11:0] e = {p[15:12], p[10:7], p[4:1]};
            if (dut.fb.mem[i] !== e) begin
                if (bad < 5) $display("  fb[%0d] = %03h exp %03h", i, dut.fb.mem[i], e);
                bad++;
            end
        end
        $display("frame buffer: %0d / %0d pixels wrong; frames counted %0d", bad, 320 * 240, led[15:8]);
        $display("VGA: hsync period %0d clk (exp 3200), vsync period %0d clk (exp 1680000)", hs_per, vs_per);
        if (nwr == 60 && nbad == 0 && bad == 0 && hs_per == 3200 && vs_per == 1680000 && led[3:2] == 2'b11 && led[15:8] == 8'd2)
            $display("-> VERDICT: SUCCESS");
        else
            $display("-> VERDICT: FAILED");
        $finish;
    end
endmodule
