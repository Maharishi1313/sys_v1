// Unit tests for the two leaf-module fixes. Use one top per run (tb_fifo, tb_pe); see run.sh.
`timescale 1ns/1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// ---------------------------------------------------------------- FIFO
module tb_fifo;
    logic clk = 0, rst_n = 0; always #5 clk = ~clk;
    logic [W-1:0] din, dout; logic wen = 0, ren = 0, full, empty; logic [3:0] level;
    int errs = 0;
    lane_fifo #(.DEPTH(5)) f (.clk, .rst_n, .data_in(din), .w_en(wen), .r_en(ren),
                         .data_out(dout), .full, .empty, .level);   // depth 5 = not a power of two
    initial begin
        repeat (2) @(posedge clk); rst_n = 1;
        if (!empty || full) begin errs++; $display("FAIL: after reset empty=%0b full=%0b", empty, full); end
        for (int i = 1; i <= 5; i++) begin @(posedge clk); din <= i*10; wen <= 1; end
        @(posedge clk); wen <= 0; @(posedge clk);
        if (empty || !full || level != 5) begin errs++; $display("FAIL: full FIFO shows empty=%0b full=%0b level=%0d", empty, full, level); end
        @(posedge clk); din <= 99; wen <= 1; @(posedge clk); wen <= 0;            // write while full must be ignored
        for (int i = 1; i <= 5; i++) begin
            @(posedge clk); ren <= 1; @(posedge clk); ren <= 0; @(posedge clk);
            if (dout != i*10) begin errs++; $display("FAIL: read #%0d got %0d expected %0d", i, dout, i*10); end
        end
        if (!empty || full || level != 0) begin errs++; $display("FAIL: end state empty=%0b full=%0b level=%0d", empty, full, level); end
        @(posedge clk); ren <= 1; @(posedge clk); ren <= 0;                       // read while empty must be ignored
        @(posedge clk); if (level != 0) begin errs++; $display("FAIL: underflow level=%0d", level); end
        if (errs == 0) $display("tb_fifo: PASS"); else $display("tb_fifo: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule

// ---------------------------------------------------------------- PE
module tb_pe;
    logic clk = 0, rst_n = 0; always #5 clk = ~clk;
    logic signed [W-1:0] a = 0, b = 0; logic va = 0, vb = 0, en = 1;
    logic [KLEN_W-1:0] k_len = 4;
    logic signed [OUT_WIDTH-1:0] s; logic ov; logic signed [W-1:0] oa, ob; logic pa, pb;
    pe_v2 p (.clk, .rst_n, .en, .k_len, .inA(a), .inB(b), .outA(oa), .outB(ob), .outS(s), .out_valid(ov),
             .pass_valid_a(pa), .pass_valid_b(pb), .flush_acc(1'b0), .in_valid_a(va), .in_valid_b(vb));
    int errs = 0, got = 0; longint res [0:7];
    always @(posedge clk) if (ov && en) begin res[got] = s; got++; end

    task automatic feed(input int n, input int av, input int bv);
        for (int i = 0; i < n; i++) begin @(posedge clk); a <= av; b <= bv; va <= 1; vb <= 1; end
        @(posedge clk); va <= 0; vb <= 0;
    endtask
    task automatic feed_hold(input int n, input int av, input int bv);   // holds each item until en=1 at an edge
        for (int i = 0; i < n; i++) begin
            a <= av; b <= bv; va <= 1; vb <= 1;
            do @(posedge clk); while (!en);
        end
        va <= 0; vb <= 0;
    endtask
    task automatic expect_res(input string name, input int idx, input longint e);
        if (got <= idx || res[idx] != e) begin errs++; $display("FAIL %s: got %0d expected %0d", name, (got>idx)?res[idx]:-1, e); end
    endtask

    initial begin
        repeat (2) @(posedge clk); rst_n = 1;
        // 1. positive overflow saturates (4 * 32767^2 = 4294705156 > 2^31-1)
        k_len = 4; got = 0; feed(4, 32767, 32767); repeat (6) @(posedge clk);
        expect_res("pos saturation", 0, 64'sd2147483647);
        // 2. negative overflow saturates
        got = 0; feed(4, -32768, 32767); repeat (6) @(posedge clk);
        expect_res("neg saturation", 0, -64'sd2147483648);
        // 3. K=9 (not N): a plain sum, 9*(7*3)=189, and 2 results back-to-back
        k_len = 9; got = 0; feed(18, 7, 3); repeat (6) @(posedge clk);
        expect_res("K=9 first", 0, 189); expect_res("K=9 second", 1, 189);
        if (got != 2) begin errs++; $display("FAIL: expected 2 results, got %0d", got); end
        // 4. freeze (en=0) in the middle must not change the result
        k_len = 6; got = 0;
        fork
            feed_hold(6, 5, -4);
            begin repeat (4) @(posedge clk); en <= 0; repeat (5) @(posedge clk); en <= 1; end
        join
        repeat (8) @(posedge clk);
        expect_res("freeze mid-run", 0, -120);
        if (got != 1) begin errs++; $display("FAIL freeze: %0d result events (expected 1)", got); end
        if (errs == 0) $display("tb_pe: PASS"); else $display("tb_pe: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
