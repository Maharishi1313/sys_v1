// =============================================================================
//  conv_tb : depthwise + pointwise (+ dense 3x3) convolution on a 28x28 image
//            through   ifmap_feeder -> FIFOs/skew -> pe4x4
//  Self-checking: every one of the 16 results of every tile is compared with a
//  golden value computed directly from the tensors.
//
//  The ifmap is stored in the buffer like this (see ifmap_feeder):
//    * depthwise / dense 3x3 ("same" padding): each channel is a 30x30 padded
//      plane with ROW STRIDE 32  (-> rows start on a word boundary), plane = 960
//    * pointwise: each channel is the plain 28x28 plane = 784 contiguous values
//  Weights are stored 'one k-step per word':  word[t] = { w_col3, w_col2, w_col1, w_col0 }
// =============================================================================
`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module conv_tb;
  localparam int IMG = 28;
  localparam int PSTR = 32;  // padded row stride (elements)
  localparam int PROWS = 30;
  localparam int PPLN = PROWS * PSTR;  // 960
  localparam int FPLN = IMG * IMG;  // 784
  localparam int LINES = N / B;  // buffer words per k-step on the weight side

  // layer sizes
  localparam int DW_C = 4;  // depthwise channels
  localparam int PW_CIN = 16, PW_COUT = 8;  // pointwise
  localparam int D3_CIN = 2, D3_COUT = 4;  // dense 3x3

  // ------------------------------------------------------------ clock/reset
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------ DUT wiring
  logic start = 0, flush_acc = 0, ext_stall = 0;
  bit                stress = 0;  // 1 = inject random array freezes
  logic [KLEN_W-1:0] k_len;
  logic [15:0] cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last, cfg_kpat;
  logic [7:0] cfg_stride;
  logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base;

  logic [$clog2(IBUF_SIZE)-1:0] ibuf_a_raddr;
  logic [$clog2(WBUF_SIZE)-1:0] ibuf_b_raddr;
  logic [B*W-1:0] ibuf_a_din, ibuf_b_din;
  logic ibuf_a_ren, ibuf_b_ren, ibuf_a_rvalid, ibuf_b_rvalid;

  logic [OUT_WIDTH-1:0] ob1, ob2, ob3, ob4;
  logic v1, v2, v3, v4;
  logic [1:0] c1, c2, c3, c4;
  logic tile_done, busy;

  logic [15:0] cfg_x_tile_step = 0, cfg_y_tile_step = 0, cfg_ntx = 1, cfg_nty = 1;
  logic layer_done;

  buffer #(
      .WIDTH(W * B),
      .SIZE(IBUF_SIZE),
      .INIT(0),
      .INIT_FILE("")
  ) ibuf_a_inst (
      .clk(clk),
      .rst_n(rst_n),
      .r_addr(ibuf_a_raddr),
      .ren(ibuf_a_ren),
      .dout(ibuf_a_din),
      .r_valid_out(ibuf_a_rvalid),
      .wen(1'b0),
      .din('0),
      .w_addr('0)
  );
  buffer #(
      .WIDTH(W * B),
      .SIZE(WBUF_SIZE),
      .INIT(0),
      .INIT_FILE("")
  ) ibuf_b_inst (
      .clk(clk),
      .rst_n(rst_n),
      .r_addr(ibuf_b_raddr),
      .ren(ibuf_b_ren),
      .dout(ibuf_b_din),
      .r_valid_out(ibuf_b_rvalid),
      .wen(1'b0),
      .din('0),
      .w_addr('0)
  );

  mme dut (
      .clk(clk),
      .rst_n(rst_n),
      .start(start),
      .k_len(k_len),
      .cfg_base(cfg_base),
      .cfg_chstep(cfg_chstep),
      .cfg_ystep(cfg_ystep),
      .cfg_nch(cfg_nch),
      .cfg_nky(cfg_nky),
      .cfg_last(cfg_last),
      .cfg_stride(cfg_stride),
      .cfg_kpat(cfg_kpat),
      .cfg_b_base(cfg_b_base),
      .cfg_x_tile_step(cfg_x_tile_step),
      .cfg_y_tile_step(cfg_y_tile_step),
      .cfg_ntx(cfg_ntx),
      .cfg_nty(cfg_nty),
      .layer_done(layer_done),
      .ibuf_a_raddr(ibuf_a_raddr),
      .ibuf_a_din(ibuf_a_din),
      .ibuf_a_ren(ibuf_a_ren),
      .ibuf_a_rvalid(ibuf_a_rvalid),
      .ibuf_b_raddr(ibuf_b_raddr),
      .ibuf_b_din(ibuf_b_din),
      .ibuf_b_ren(ibuf_b_ren),
      .ibuf_b_rvalid(ibuf_b_rvalid),
      .outputbus1(ob1),
      .outputbus2(ob2),
      .outputbus3(ob3),
      .outputbus4(ob4),
      .valid1(v1),
      .valid2(v2),
      .valid3(v3),
      .valid4(v4),
      .col1(c1),
      .col2(c2),
      .col3(c3),
      .col4(c4),
      .tile_done(tile_done),
      .busy(busy),
      .ext_stall(ext_stall),
      .flush_acc(flush_acc)
  );

  // random freezes (about 1 clock in 6) while 'stress' is on
  always @(posedge clk) ext_stall <= stress && ($urandom_range(0, 5) == 0);

  // ------------------------------------------------------------ result monitor
  int hit [0:3][0:3];
  int capv[0:3][0:3];
  always @(posedge clk) begin
    if (v1) begin
      hit[0][c1]++;
      capv[0][c1] = $signed(ob1);
    end
    if (v2) begin
      hit[1][c2]++;
      capv[1][c2] = $signed(ob2);
    end
    if (v3) begin
      hit[2][c3]++;
      capv[2][c3] = $signed(ob3);
    end
    if (v4) begin
      hit[3][c4]++;
      capv[3][c4] = $signed(ob4);
    end
  end

  // ------------------------------------------------------------ coverage probes (informational)
  int frz_cycles = 0, a_stall_cycles = 0, b_throttle_cycles = 0, fd_deadlock_cycles = 0;
  always @(posedge clk)
    if (rst_n) begin
      if (dut.fifo_controller_inst.run && !dut.adv) frz_cycles++;  // array frozen (lane ran dry)
      if (dut.fifo_controller_inst.run && dut.fd_ready && (|dut.fifo_controller_inst.fifo_full_a))
        a_stall_cycles++;  // A FIFO full -> feeder held
      if (dut.fifo_controller_inst.run && !dut.fifo_controller_inst.b_room)
        b_throttle_cycles++;  // B fetch throttled (FIFO nearly full)
      if (dut.fd_deadlock) fd_deadlock_cycles++;
    end

  // ------------------------------------------------------------ tensors
  int ifm[0:PW_CIN-1][0:IMG-1][0:IMG-1];  // input feature maps (largest case = pointwise)
  int w_dw[0:DW_C-1][0:8];  // depthwise weights [c][ky*3+kx]
  int w_pw[0:PW_COUT-1][0:PW_CIN-1];  // pointwise weights [oc][ic]
  int w_d3[0:D3_COUT-1][0:D3_CIN-1][0:2][0:2];  // dense 3x3 weights

  function automatic int padv(input int c, input int yy, input int xx);  // 30x30 zero-padded view
    if (yy < 1 || yy > IMG || xx < 1 || xx > IMG) return 0;
    return ifm[c][yy-1][xx-1];
  endfunction

  // ------------------------------------------------------------ buffer access
  task automatic put_a(input int e, input int v);  // ifmap element e
    logic [W-1:0] tmp;
    tmp = v[W-1:0];
    ibuf_a_inst.mem[e/B][(e%B)*W+:W] = tmp;
  endtask
  task automatic put_b(input int word, input int slot, input int v);
    logic [W-1:0] tmp;
    tmp = v[W-1:0];
    ibuf_b_inst.mem[word][slot*W+:W] = tmp;
  endtask
  task automatic put_wstep(input int base_word, input int t, input int j, input int v);
    // weight of column j at k-step t
    put_b(base_word + t * LINES + j / B, j % B, v);
  endtask
  task automatic clear_buffers();
    for (int a = 0; a < IBUF_SIZE; a++) begin
      ibuf_a_inst.mem[a] = '0;
    end
    for (int a = 0; a < WBUF_SIZE; a++) begin
      ibuf_b_inst.mem[a] = '0;
    end
  endtask

  // ------------------------------------------------------------ run one tile
  int tiles = 0, cyc_total = 0, errors = 0, timeouts = 0;
  task automatic run_tile(input int kk, input int base, input int chstep, input int ystep,
                          input int nch, input int nky, input int last, input int stride,
                          input int kpat, input int bbase);
    int to;
    for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++) begin
        hit[i][j]  = 0;
        capv[i][j] = 0;
      end
    k_len = kk;
    cfg_base = base;
    cfg_chstep = chstep;
    cfg_ystep = ystep;
    cfg_nch = nch;
    cfg_nky = nky;
    cfg_last = last;
    cfg_stride = stride;
    cfg_kpat = kpat;
    cfg_b_base = bbase;
    @(posedge clk);
    #1 start = 1;
    @(posedge clk);
    #1 start = 0;  // drive 1 ns after the edge: no race with the DUT
    to = 0;
    do begin
      @(posedge clk);
      to++;
    end while (!tile_done && to < 3000);
    if (to >= 3000) begin
      timeouts++;
      $display("  TIMEOUT tile %0d (base=%0d)", tiles, base);
    end
    cyc_total += to;
    @(posedge clk);
    @(posedge clk);  // let the monitor see the last results
    tiles++;
  endtask

  task automatic check(input string what, input int i, input int j, input longint exp_v,
                       input bit cmp = 1'b1);
    if (hit[i][j] != 1) begin
      errors++;
      if (errors < 10)
        $display("  %s PE(%0d,%0d): got %0d result events (expected 1)", what, i, j, hit[i][j]);
    end else if (cmp && capv[i][j] != exp_v) begin
      errors++;
      if (errors < 10)
        $display("  %s PE(%0d,%0d): got %0d expected %0d", what, i, j, capv[i][j], exp_v);
    end
  endtask

  // ================================================================= TESTS
  // ---- 1. DEPTHWISE 3x3, "same" padding, DW_C channels --------------------
  task automatic test_depthwise();
    longint s;
    int e0 = errors, t0 = tiles, c0 = cyc_total;
    $display("[depthwise 3x3]  %0dx%0d x %0d channels, pad 1 -> %0d output tiles", IMG, IMG, DW_C,
             DW_C * IMG * (IMG / 4));
    clear_buffers();
    for (int c = 0; c < DW_C; c++) begin
      for (int t = 0; t < 9; t++) w_dw[c][t] = $urandom_range(0, 100) - 50;
      for (int y = 0; y < IMG; y++)
      for (int x = 0; x < IMG; x++) ifm[c][y][x] = $urandom_range(0, 200) - 100;
      for (int yy = 0; yy < PROWS; yy++)
      for (int xx = 0; xx < PSTR; xx++)
      put_a(c * PPLN + yy * PSTR + xx, (xx < 30) ? padv(c, yy, xx) : 0);
      // only column 0 gets the weights (columns 1..3 = 0): in depthwise a column cannot
      // work on another channel because every column sees the same activations
      for (int t = 0; t < 9; t++) begin
        put_wstep(c * 9 * LINES, t, 0, w_dw[c][t]);
        for (int j = 1; j < 4; j++) put_wstep(c * 9 * LINES, t, j, 0);
      end
    end
    for (int c = 0; c < DW_C; c++)
      for (int oy = 0; oy < IMG; oy++)
        for (int xg = 0; xg < IMG / 4; xg++) begin
          //          K  base                       chstep ystep nch nky last stride kpat  b_base
          run_tile(9, c * PPLN + oy * PSTR + xg * 4, PPLN, PSTR, 1, 3, 3 + 2, 1, 3'b111,
                   c * 9 * LINES);
          for (int i = 0; i < 4; i++) begin
            s = 0;
            for (int ky = 0; ky < 3; ky++)
            for (int kx = 0; kx < 3; kx++)
            s += padv(c, oy + ky, xg * 4 + i + kx) * w_dw[c][ky*3+kx];
            check("dw col0", i, 0, s);
            for (int j = 1; j < 4; j++) check("dw unused col", i, j, 0);
          end
        end
    $display("  -> %0d tiles, %0d errors, %0d cycles/tile (K=9)\n", tiles - t0, errors - e0,
             (cyc_total - c0) / (tiles - t0));
  endtask

  // ---- 1b. DEEP-K 1x1: K = 576 > 511 (needs KLEN_W >= 10) -------------------
  //  SqueezeNet fire8/9 expand3x3 reduces 64 ch x 3 x 3 = 576 values per output.
  //  ifmap: DK channel planes of DKP pixels; weights for 4 output columns.
  localparam int DK = 576, DKP = 16;
  int dk_a[0:DK-1][0:DKP-1];
  int dk_w[0:3][0:DK-1];
  task automatic test_deep_k();
    longint s;
    int e0 = errors, t0 = tiles, c0 = cyc_total;
    $display("[deep-K 1x1]     %0d pixels, %0d -> 4 channels, K=%0d (> 511)", DKP, DK, DK);
    clear_buffers();
    for (int c = 0; c < DK; c++)
      for (int p = 0; p < DKP; p++) begin
        dk_a[c][p] = $urandom_range(0, 200) - 100;
        put_a(c * DKP + p, dk_a[c][p]);
      end
    for (int j = 0; j < 4; j++)
      for (int c = 0; c < DK; c++) begin
        dk_w[j][c] = $urandom_range(0, 100) - 50;
        put_wstep(0, c, j, dk_w[j][c]);
      end
    for (int pg = 0; pg < DKP / 4; pg++) begin
      //        K   base    chstep ystep nch nky last stride kpat b_base
      run_tile(DK, pg * 4, DKP,   0,    DK, 1,  3,   1,     1,   0);
      for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) begin
          s = 0;
          for (int c = 0; c < DK; c++) s += dk_a[c][pg*4+i] * dk_w[j][c];
          check("deepK", i, j, s);
        end
    end
    $display("  -> %0d tiles, %0d errors, %0d cycles/tile (K=%0d)\n", tiles - t0, errors - e0,
             (cyc_total - c0) / (tiles - t0), DK);
  endtask

  // ---- 2. POINTWISE 1x1 ----------------------------------------------------
  task automatic test_pointwise();
    longint s;
    int e0 = errors, t0 = tiles, c0 = cyc_total;
    $display("[pointwise 1x1]  %0dx%0d, %0d -> %0d channels, K=%0d (> FIFO depth %0d)", IMG, IMG,
             PW_CIN, PW_COUT, PW_CIN, FIF_DEPTH);
    clear_buffers();
    for (int c = 0; c < PW_CIN; c++) begin
      for (int y = 0; y < IMG; y++)
      for (int x = 0; x < IMG; x++) begin
        ifm[c][y][x] = $urandom_range(0, 200) - 100;
        put_a(c * FPLN + y * IMG + x, ifm[c][y][x]);
      end
    end
    for (int oc = 0; oc < PW_COUT; oc++)
      for (int ic = 0; ic < PW_CIN; ic++) w_pw[oc][ic] = $urandom_range(0, 100) - 50;
    for (int g = 0; g < PW_COUT / 4; g++)
      for (int ic = 0; ic < PW_CIN; ic++)
        for (int j = 0; j < 4; j++) put_wstep(g * PW_CIN * LINES, ic, j, w_pw[g*4+j][ic]);

    for (int g = 0; g < PW_COUT / 4; g++)
      for (int pg = 0; pg < FPLN / 4; pg++) begin
        //           K       base   chstep ystep nch     nky last stride kpat  b_base
        run_tile(PW_CIN, pg * 4, FPLN, 0, PW_CIN, 1, 3, 1, 1, g * PW_CIN * LINES);
        for (int i = 0; i < 4; i++) begin
          int p = pg * 4 + i;
          for (int j = 0; j < 4; j++) begin
            s = 0;
            for (int ic = 0; ic < PW_CIN; ic++) s += ifm[ic][p/IMG][p%IMG] * w_pw[g*4+j][ic];
            check("pw", i, j, s);
          end
        end
      end
    $display("  -> %0d tiles, %0d errors, %0d cycles/tile (K=%0d)\n", tiles - t0, errors - e0,
             (cyc_total - c0) / (tiles - t0), PW_CIN);
  endtask

  // ---- 3. bonus: DENSE 3x3 (reduces over channels AND the 3x3 window) ------
  task automatic test_dense3x3();
    longint s;
    int K = D3_CIN * 9;
    int e0 = errors, t0 = tiles, c0 = cyc_total;
    $display("[dense 3x3]      %0dx%0d, %0d -> %0d channels, pad 1, K=%0d", IMG, IMG, D3_CIN,
             D3_COUT, K);
    clear_buffers();
    for (int c = 0; c < D3_CIN; c++) begin
      for (int y = 0; y < IMG; y++)
      for (int x = 0; x < IMG; x++) ifm[c][y][x] = $urandom_range(0, 200) - 100;
      for (int yy = 0; yy < PROWS; yy++)
      for (int xx = 0; xx < PSTR; xx++)
      put_a(c * PPLN + yy * PSTR + xx, (xx < 30) ? padv(c, yy, xx) : 0);
    end
    for (int oc = 0; oc < D3_COUT; oc++)
      for (int ic = 0; ic < D3_CIN; ic++)
        for (int ky = 0; ky < 3; ky++)
          for (int kx = 0; kx < 3; kx++) w_d3[oc][ic][ky][kx] = $urandom_range(0, 100) - 50;
    for (int ic = 0; ic < D3_CIN; ic++)
      for (int ky = 0; ky < 3; ky++)
        for (int kx = 0; kx < 3; kx++)
          for (int j = 0; j < 4; j++) put_wstep(0, ic * 9 + ky * 3 + kx, j, w_d3[j][ic][ky][kx]);

    for (int oy = 0; oy < IMG; oy++)
      for (int xg = 0; xg < IMG / 4; xg++) begin
        run_tile(K, oy * PSTR + xg * 4, PPLN, PSTR, D3_CIN, 3, 3 + 2, 1, 3'b111, 0);
        for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) begin
          s = 0;
          for (int ic = 0; ic < D3_CIN; ic++)
          for (int ky = 0; ky < 3; ky++)
          for (int kx = 0; kx < 3; kx++)
          s += padv(ic, oy + ky, xg * 4 + i + kx) * w_d3[j][ic][ky][kx];
          check("dense3x3", i, j, s);
        end
      end
    $display("  -> %0d tiles, %0d errors, %0d cycles/tile (K=%0d)\n", tiles - t0, errors - e0,
             (cyc_total - c0) / (tiles - t0), K);
  endtask

  // ---- 4. DEPTHWISE 3x3, STRIDE 2, rows stored tightly (row stride 30) -----
  //         row stride 30 is not a multiple of the 4-value word, so kernel rows
  //         start at different positions inside a word (word offsets 0 and 2),
  //         and stride 2 makes lane y start at 2*y.
  task automatic test_dw_stride2();
    longint s;
    int ox;
    int e0 = errors, t0 = tiles, c0 = cyc_total;
    $display("[depthwise 3x3 stride 2, unaligned rows]  %0dx%0d -> 14x14", IMG, IMG);
    clear_buffers();
    for (int t = 0; t < 9; t++) w_dw[0][t] = $urandom_range(0, 100) - 50;
    for (int y = 0; y < IMG; y++)
      for (int x = 0; x < IMG; x++) ifm[0][y][x] = $urandom_range(0, 200) - 100;
    for (int yy = 0; yy < 30; yy++)
      for (int xx = 0; xx < 30; xx++) put_a(yy * 30 + xx, padv(0, yy, xx));
    for (int t = 0; t < 9; t++) begin
      put_wstep(0, t, 0, w_dw[0][t]);
      for (int j = 1; j < 4; j++) put_wstep(0, t, j, 0);
    end
    for (int oy = 0; oy < 14; oy++)
      for (int xg = 0; xg < 4; xg++) begin
        //          K  base            chstep ystep nch nky last      stride kpat   b_base
        run_tile(9, 60 * oy + 8 * xg, 900, 30, 1, 3, 3 * 2 + 2, 2, 3'b111, 0);
        for (int i = 0; i < 4; i++) begin
          ox = xg * 4 + i;
          s  = 0;
          for (int ky = 0; ky < 3; ky++)
          for (int kx = 0; kx < 3; kx++) s += padv(0, 2 * oy + ky, 2 * ox + kx) * w_dw[0][ky*3+kx];
          check("dw s2", i, 0, s, ox < 14);  // lanes past column 13 are just ignored
          for (int j = 1; j < 4; j++) check("dw s2 unused col", i, j, 0, 1'b1);
        end
      end
    $display("  -> %0d tiles, %0d errors, %0d cycles/tile\n", tiles - t0, errors - e0,
             (cyc_total - c0) / (tiles - t0));
  endtask

  // ---- 5. DEPTHWISE 3x3, DILATION 2 (atrous), tight rows --------------------
  task automatic test_dw_dil2();
    longint s;
    int ox;
    int e0 = errors, t0 = tiles, c0 = cyc_total;
    $display("[depthwise 3x3 dilation 2 (atrous)]  30x30 padded -> 26x26");
    clear_buffers();
    for (int t = 0; t < 9; t++) w_dw[0][t] = $urandom_range(0, 100) - 50;
    for (int y = 0; y < IMG; y++)
      for (int x = 0; x < IMG; x++) ifm[0][y][x] = $urandom_range(0, 200) - 100;
    for (int yy = 0; yy < 30; yy++)
      for (int xx = 0; xx < 30; xx++) put_a(yy * 30 + xx, padv(0, yy, xx));
    for (int t = 0; t < 9; t++) begin
      put_wstep(0, t, 0, w_dw[0][t]);
      for (int j = 1; j < 4; j++) put_wstep(0, t, j, 0);
    end
    for (int oy = 0; oy < 26; oy++)
      for (int xg = 0; xg < 7; xg++) begin
        //          K  base          chstep ystep(=2*30) nch nky last(=3+2*2) stride kpat        b_base
        run_tile(9, oy * 30 + xg * 4, 900, 60, 1, 3, 3 + 2 * 2, 1, 5'b10101, 0);
        for (int i = 0; i < 4; i++) begin
          ox = xg * 4 + i;
          s  = 0;
          for (int ky = 0; ky < 3; ky++)
          for (int kx = 0; kx < 3; kx++) s += padv(0, oy + 2 * ky, ox + 2 * kx) * w_dw[0][ky*3+kx];
          check("dw dil2", i, 0, s, ox < 26);
          for (int j = 1; j < 4; j++) check("dw dil2 unused col", i, j, 0, 1'b1);
        end
      end
    $display("  -> %0d tiles, %0d errors, %0d cycles/tile\n", tiles - t0, errors - e0,
             (cyc_total - c0) / (tiles - t0));
  endtask

  // Example in conv_tb.sv: Full-Layer Autonomous 5-Counter Execution of Dense 3x3
  task automatic test_dense3x3_5counter();
    longint s;
    int K = D3_CIN * 9;
    int e0 = errors, t0 = tiles;
    $display("[dense 3x3 - 5-COUNTER AUTONOMOUS] 1 start pulse runs all %0d tiles!",
             IMG * (IMG / 4));
    clear_buffers();
    for (int c = 0; c < D3_CIN; c++) begin
      for (int y = 0; y < IMG; y++)
        for (int x = 0; x < IMG; x++) ifm[c][y][x] = $urandom_range(0, 200) - 100;
          for (int yy = 0; yy < PROWS; yy++)
            for (int xx = 0; xx < PSTR; xx++)
              put_a(c * PPLN + yy * PSTR + xx, (xx < 30) ? padv(c, yy, xx) : 0);
    end
    for (int oc = 0; oc < D3_COUT; oc++)
      for (int ic = 0; ic < D3_CIN; ic++)
        for (int ky = 0; ky < 3; ky++)
          for (int kx = 0; kx < 3; kx++) w_d3[oc][ic][ky][kx] = $urandom_range(0, 100) - 50;
    for (int ic = 0; ic < D3_CIN; ic++)
      for (int ky = 0; ky < 3; ky++)
        for (int kx = 0; kx < 3; kx++)
          for (int j = 0; j < 4; j++) put_wstep(0, ic * 9 + ky * 3 + kx, j, w_d3[j][ic][ky][kx]);

    // Configure all 5 counters once:
    k_len           = K;
    cfg_base        = 0;  // Starts at (oy=0, xg=0)
    cfg_chstep      = PPLN;  // Counter 3 step (960)
    cfg_ystep       = PSTR;  // Counter 2 step (32)
    cfg_nch         = D3_CIN;  // Counter 3 limit (2)
    cfg_nky         = 3;  // Counter 2 limit (3)
    cfg_last        = 3 + 2;  // Counter 1 span (5)
    cfg_stride      = 1;
    cfg_kpat        = 3'b111;
    cfg_x_tile_step = 4;  // Counter 4 step: +4 elements horizontally per tile
    cfg_y_tile_step = PSTR;  // Counter 5 step: +32 elements vertically per output row
    cfg_ntx         = IMG / 4;  // Counter 4 limit: 7 horizontal tiles per row
    cfg_nty         = IMG;  // Counter 5 limit: 28 vertical rows
    cfg_b_base      = 0;

    for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++) begin
        hit[i][j]  = 0;
        capv[i][j] = 0;
      end

    // Issue ONE start pulse for the entire 28x28 layer!
    @(posedge clk);
    #1 start = 1;
    @(posedge clk);
    #1 start = 0;

    for (int oy = 0; oy < IMG; oy++) begin
      for (int xg = 0; xg < IMG / 4; xg++) begin
        // Wait for the clock edge where tile_done is asserted
        do @(posedge clk); while (!tile_done);
        @(posedge clk); // Let the result monitor latch the 16th output (PE(3,3))
        #1;
        for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) begin
          s = 0;
          for (int ic = 0; ic < D3_CIN; ic++)
          for (int ky = 0; ky < 3; ky++)
          for (int kx = 0; kx < 3; kx++)
          s += padv(ic, oy + ky, xg * 4 + i + kx) * w_d3[j][ic][ky][kx];
          check("dense3x3_5cnt", i, j, s);
          hit[i][j] = 0;  // clear for the next streaming tile
        end
        tiles++;
      end
    end
    // Restore defaults for single-tile tests
    cfg_ntx = 1;
    cfg_nty = 1;
    $display("  -> %0d autonomous tiles completed, %0d errors\n", tiles - t0, errors - e0);
  endtask

  // ------------------------------------------------------------ main
  initial begin
    k_len = 1;
    cfg_base = 0;
    cfg_chstep = 0;
    cfg_ystep = 0;
    cfg_nch = 1;
    cfg_nky = 1;
    cfg_last = 0;
    cfg_stride = 1;
    cfg_kpat = 1;
    cfg_b_base = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);
    $display("=== config: W=%0d N=%0d B=%0d (buffer word = %0d bits) FIF_DEPTH=%0d ===\n", W, N, B,
             W * B, FIF_DEPTH);

    $display("######## PASS 1: normal run ########\n");
    test_depthwise();
    test_pointwise();
    test_deep_k();
    test_dense3x3();
    test_dw_stride2();
    test_dw_dil2();
    test_dense3x3_5counter();

    $display("######## PASS 2: same tests with random array freezes (ext_stall) ########\n");
    stress = 1;
    test_depthwise();
    test_pointwise();
    test_deep_k();
    test_dense3x3();
    test_dw_stride2();
    test_dw_dil2();
    test_dense3x3_5counter();

    stress = 0;

    $display(
        "coverage: array frozen %0d clks | A-FIFO full (feeder held) %0d clks | B fetch throttled %0d clks | feeder deadlock flag %0d",
        frz_cycles, a_stall_cycles, b_throttle_cycles, fd_deadlock_cycles);
    $display("TOTAL: %0d tiles, %0d errors, %0d timeouts", tiles, errors, timeouts);
    if (errors == 0 && timeouts == 0) $display("ALL TESTS PASSED");
    else $display("SOME TESTS FAILED");
    $finish;
  end
endmodule
