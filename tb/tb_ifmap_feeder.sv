// Run:  iverilog -g2012 -o sim ifmap_feeder_lite.sv tb_ifmap_feeder_lite.sv && vvp sim
`timescale 1ns/1ps
module tb;
    localparam Y = 4, DATA_W = 8, BUS_N = 4, IDX_W = 16, PAT_W = 16, QDEPTH = 16;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- config regs (this is what a "uop" really is: a bunch of numbers) ----
    reg                 start = 0;
    reg [IDX_W-1:0]     cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last, cfg_total;
    reg [7:0]           cfg_stride;
    reg [PAT_W-1:0]     cfg_kpat;

    wire [IDX_W-1:0]    sram_word_addr;
    wire                sram_re;
    wire [BUS_N*DATA_W-1:0] sram_rdata;
    wire                o_ready;
    wire [Y*DATA_W-1:0] a_out;
    wire [Y-1:0]        a_valid;
    wire                busy, done, o_deadlock;

    ifmap_feeder_lite #(.Y(Y), .DATA_W(DATA_W), .BUS_N(BUS_N), .IDX_W(IDX_W),
                        .PAT_W(PAT_W), .QDEPTH(QDEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cfg_base(cfg_base), .cfg_chstep(cfg_chstep), .cfg_ystep(cfg_ystep),
        .cfg_nch(cfg_nch), .cfg_nky(cfg_nky), .cfg_last(cfg_last),
        .cfg_stride(cfg_stride), .cfg_kpat(cfg_kpat), .cfg_total(cfg_total),
        .sram_word_addr(sram_word_addr), .sram_re(sram_re), .sram_rdata(sram_rdata),
        .o_ready(o_ready), .i_pop(o_ready),     // no weights in this test: pop when ready
        .a_out(a_out), .a_valid(a_valid), .busy(busy), .done(done), .o_deadlock(o_deadlock));

    // ---- SRAM model: 1-clock read latency ----
    reg [BUS_N*DATA_W-1:0] sram [0:1023];
    reg [BUS_N*DATA_W-1:0] sram_q;
    always @(posedge clk) if (sram_re) sram_q <= sram[sram_word_addr];
    assign sram_rdata = sram_q;

    // ---- the picture: value depends only on (c,y,x) ----
    function [7:0] elem(input integer c, input integer yy, input integer xx);
        elem = (c*37 + yy*11 + xx*3 + 1) & 255;
    endfunction

    // ---- capture what each lane receives ----
    reg [7:0] cap [0:Y*512-1];
    integer   cap_n [0:Y-1];
    integer   reads, cycles;
    integer   k;
    always @(posedge clk) begin
        if (sram_re) reads = reads + 1;
        if (busy) cycles = cycles + 1;
        for (k = 0; k < Y; k = k + 1)
            if (a_valid[k]) begin
                cap[k*512 + cap_n[k]] = a_out[k*DATA_W +: DATA_W];
                cap_n[k] = cap_n[k] + 1;
            end
    end

    integer total_errors = 0;

    // C,H,W  : picture size            KH,KW : kernel size
    // DX,DY  : dilation x / y          S     : horizontal stride
    // CH0,IY0,IX0 : first channel / row / column that lane 0's window starts at
    // NCH    : channels to add up (pointwise: all input channels, depthwise: 1)
    task run_test(input [255:0] name, input integer C, H, W, KH, KW, DX, DY, S,
                  input integer CH0, IY0, IX0, NCH);
        integer c, yy, xx, e, ky, kx, t, errs, idx, t0;
        reg [7:0] exp_v;
        begin
            // 1. fill SRAM with the picture (element e -> word e/BUS_N, slot e%BUS_N)
            for (e = 0; e < 1024*BUS_N; e = e + 1) sram[e/BUS_N][(e%BUS_N)*DATA_W +: DATA_W] = 0;
            for (c = 0; c < C; c = c + 1)
              for (yy = 0; yy < H; yy = yy + 1)
                for (xx = 0; xx < W; xx = xx + 1) begin
                    e = (c*H + yy)*W + xx;
                    sram[e/BUS_N][(e%BUS_N)*DATA_W +: DATA_W] = elem(c, yy, xx);
                end
            // 2. "compile the uop": compute the config numbers
            cfg_base   = (CH0*H + IY0)*W + IX0;
            cfg_chstep = H*W;
            cfg_ystep  = DY*W;
            cfg_nch    = NCH;
            cfg_nky    = KH;
            cfg_last   = (Y-1)*S + (KW-1)*DX;
            cfg_stride = S;
            cfg_kpat   = 0;
            for (kx = 0; kx < KW; kx = kx + 1) cfg_kpat[kx*DX] = 1'b1;
            cfg_total  = NCH*KH*KW;
            // 3. run
            for (k = 0; k < Y; k = k + 1) cap_n[k] = 0;
            reads = 0; cycles = 0;
            @(posedge clk); #1 start = 1; @(posedge clk); #1 start = 0;
            t0 = 0;
            while (!done && t0 < 5000) begin @(posedge clk); t0 = t0 + 1; end
            repeat (Y+2) @(posedge clk);           // let skewed lanes finish
            // 4. compare against plain im2col
            errs = 0;
            if (t0 >= 5000) begin errs = errs + 1; $display("  TIMEOUT"); end
            for (yy = 0; yy < Y; yy = yy + 1) begin
                if (cap_n[yy] != NCH*KH*KW) begin
                    errs = errs + 1;
                    $display("  lane %0d got %0d values, expected %0d", yy, cap_n[yy], NCH*KH*KW);
                end
                idx = 0;
                for (c = 0; c < NCH; c = c + 1)
                  for (ky = 0; ky < KH; ky = ky + 1)
                    for (kx = 0; kx < KW; kx = kx + 1) begin
                        exp_v = elem(CH0+c, IY0+ky*DY, IX0+yy*S+kx*DX);
                        if (idx < cap_n[yy] && cap[yy*512+idx] !== exp_v) begin
                            errs = errs + 1;
                            if (errs < 6) $display("  lane %0d value #%0d: got %0d expected %0d",
                                                   yy, idx, cap[yy*512+idx], exp_v);
                        end
                        idx = idx + 1;
                    end
            end
            total_errors = total_errors + errs;
            $display("%-34s %s | SRAM reads %3d | explicit im2col would need %3d words | busy cycles %3d | per-lane values %0d",
                     name, (errs==0) ? "PASS" : "FAIL", reads,
                     (Y*NCH*KH*KW + BUS_N-1)/BUS_N, cycles, NCH*KH*KW);
        end
    endtask

    initial begin
        reads = 0; cycles = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        //        name                          C  H  W KH KW DX DY S CH0 IY0 IX0 NCH
        run_test("paper-like 3x3 (3x6 picture)", 1, 3, 6, 3, 3, 1, 1, 1,  0,  0,  0,  1);
        run_test("3x3 dilation 2",               1, 5,10, 3, 3, 2, 2, 1,  0,  0,  0,  1);
        run_test("3x3 stride 2, unaligned x",    1, 3,10, 3, 3, 1, 1, 2,  0,  0,  1,  1);
        run_test("5x5 kernel",                   1, 5,12, 5, 5, 1, 1, 1,  0,  0,  0,  1);
        run_test("POINTWISE 1x1, 5 ch, aligned", 5, 2, 8, 1, 1, 1, 1, 1,  0,  0,  4,  5);
        run_test("POINTWISE 1x1, unaligned",     5, 2, 8, 1, 1, 1, 1, 1,  0,  0,  2,  5);
        run_test("DEPTHWISE 3x3 on channel 2",   3, 4, 8, 3, 3, 1, 1, 1,  2,  1,  1,  1);
        run_test("DEPTHWISE 3x3 dil2 channel 1", 3, 5,10, 3, 3, 2, 2, 1,  1,  0,  0,  1);

        if (total_errors == 0) $display("\nALL TESTS PASSED");
        else                   $display("\n%0d ERRORS", total_errors);
        $finish;
    end
endmodule
