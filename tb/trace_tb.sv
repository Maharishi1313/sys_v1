// trace_tb : runs ONE tile of the tiny 3x6 example from the explainer document and prints
// what every part of the machine does on every clock.   (1..18 picture, 3x3 kernel, 4 columns)
//   column 0 = all-ones kernel (window SUM)   column 1 = centre only
//   column 2 = top-left only                  column 3 = bottom-right only
`timescale 1ns/1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif
module trace_tb;
    logic clk = 0, rst_n = 0; always #5 clk = ~clk;
    logic start = 0;
    logic [KLEN_W-1:0] k_len = 9;
    logic [15:0] cfg_base = 0, cfg_chstep = 18, cfg_ystep = 6, cfg_nch = 1, cfg_nky = 3, cfg_last = 5, cfg_kpat = 16'b111;
    logic [7:0] cfg_stride = 1;
    logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base = 0;
    logic [$clog2(IBUF_SIZE)-1:0] ibuf_a_raddr;
    logic [$clog2(WBUF_SIZE)-1:0] ibuf_b_raddr;
    logic [B*W-1:0] ibuf_a_din, ibuf_b_din;
    logic ibuf_a_ren, ibuf_b_ren, ibuf_a_rvalid, ibuf_b_rvalid;
    logic [OUT_WIDTH-1:0] ob1, ob2, ob3, ob4; logic v1, v2, v3, v4; logic [1:0] c1, c2, c3, c4;
    logic tile_done, busy;

    buffer #(.WIDTH(W*B), .SIZE(IBUF_SIZE)) ibuf_a_inst (.clk, .rst_n, .r_addr(ibuf_a_raddr), .ren(ibuf_a_ren), .dout(ibuf_a_din),
        .r_valid_out(ibuf_a_rvalid), .wen(1'b0), .din('0), .w_addr('0));
    buffer #(.WIDTH(W*B), .SIZE(WBUF_SIZE)) ibuf_b_inst (.clk, .rst_n, .r_addr(ibuf_b_raddr), .ren(ibuf_b_ren), .dout(ibuf_b_din),
        .r_valid_out(ibuf_b_rvalid), .wen(1'b0), .din('0), .w_addr('0));
    mme dut (.clk, .rst_n, .start, .k_len, .cfg_base, .cfg_chstep, .cfg_ystep, .cfg_nch, .cfg_nky, .cfg_last, .cfg_stride, .cfg_kpat, .cfg_b_base,
        .ibuf_a_raddr, .ibuf_a_din, .ibuf_a_ren, .ibuf_a_rvalid, .ibuf_b_raddr, .ibuf_b_din, .ibuf_b_ren, .ibuf_b_rvalid,
        .outputbus1(ob1), .outputbus2(ob2), .outputbus3(ob3), .outputbus4(ob4), .valid1(v1), .valid2(v2), .valid3(v3), .valid4(v4),
        .col1(c1), .col2(c2), .col3(c3), .col4(c4), .tile_done, .busy, .ext_stall(1'b0), .flush_acc(1'b0));

    function automatic int wt(input int col, input int t);          // weight of column 'col' at k-step t (t = ky*3+kx)
        case (col) 0: return 1; 1: return (t == 4); 2: return (t == 0); default: return (t == 8); endcase
    endfunction

    int cyc = 0;
    string s_rd, s_fd, s_ren, s_val, s_res;
    always @(posedge clk) if (busy || start) begin
        s_rd  = dut.ibuf_a_ren ? $sformatf("A-rd addr%0d", dut.fd_addr) : "           -";
        s_fd  = dut.fd_pop ? "pop" : "   ";
        s_ren = $sformatf("%0b%0b%0b%0b", dut.fifo_controller_inst.fifo_ren_a[0], dut.fifo_controller_inst.fifo_ren_a[1],
                          dut.fifo_controller_inst.fifo_ren_a[2], dut.fifo_controller_inst.fifo_ren_a[3]);
        s_val = $sformatf("%0b%0b%0b%0b", dut.fifo_out_valid_a[0], dut.fifo_out_valid_a[1], dut.fifo_out_valid_a[2], dut.fifo_out_valid_a[3]);
        s_res = "";
        if (v1) s_res = {s_res, $sformatf(" row0.col%0d=%0d", c1, $signed(ob1))};
        if (v2) s_res = {s_res, $sformatf(" row1.col%0d=%0d", c2, $signed(ob2))};
        if (v3) s_res = {s_res, $sformatf(" row2.col%0d=%0d", c3, $signed(ob3))};
        if (v4) s_res = {s_res, $sformatf(" row3.col%0d=%0d", c4, $signed(ob4))};
        $display("%3d | %-12s | %s | A-FIFO lvl %0d %0d %0d %0d | ren(L0..L3)=%s | a-valid@PE=%s | adv=%0b |%s",
                 cyc, s_rd, s_fd, dut.fifo_controller_inst.lvl_a[0], dut.fifo_controller_inst.lvl_a[1],
                 dut.fifo_controller_inst.lvl_a[2], dut.fifo_controller_inst.lvl_a[3], s_ren, s_val, dut.adv, s_res);
        cyc++;
    end

    initial begin
        for (int a = 0; a < 16; a++) begin ibuf_a_inst.mem[a] = '0; ibuf_b_inst.mem[a] = '0; end
        for (int e = 0; e < 18; e++) ibuf_a_inst.mem[e / B][(e % B)*W +: W] = e + 1;             // picture 1..18
        for (int t = 0; t < 9; t++) for (int j = 0; j < 4; j++) ibuf_b_inst.mem[t*(N/B) + j / B][(j % B)*W +: W] = wt(j, t);
        repeat (3) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
        #1 start = 1; @(posedge clk); #1 start = 0;
        $display("cyc | ifmap SRAM    | feeder->FIFO | A FIFO levels | stagger read enables | valid into PE | freeze | results leaving the array");
        wait (tile_done); repeat (3) @(posedge clk);
        $finish;
    end
endmodule
