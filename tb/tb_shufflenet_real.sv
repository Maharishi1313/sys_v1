`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module tb_shufflenet_real;
  // ------------------------------------------------------------ clock/reset
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------ DUT wiring
  logic start = 0, flush_acc = 0, ext_stall = 0;
  logic [KLEN_W-1:0] k_len;
  
  logic [7:0] cfg_stride;
  logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base;
  logic [23:0] cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last;
  logic [15:0] cfg_kpat; // kpat remains 16
  logic [23:0] cfg_x_tile_step, cfg_y_tile_step, cfg_ntx, cfg_nty;

  logic [$clog2(IBUF_SIZE)-1:0] ibuf_a_raddr;
  logic [$clog2(WBUF_SIZE)-1:0] ibuf_b_raddr;
  logic [B*W-1:0] ibuf_a_din, ibuf_b_din;
  logic ibuf_a_ren, ibuf_b_ren, ibuf_a_rvalid, ibuf_b_rvalid;

  logic [OUT_WIDTH-1:0] ob1, ob2, ob3, ob4;
  logic v1, v2, v3, v4;
  logic [1:0] c1, c2, c3, c4;
  logic tile_done, layer_done, busy;

  // ------------------------------------------------------------ SRAM Buffers
  buffer #(.WIDTH(W * B), .SIZE(IBUF_SIZE), .INIT(0), .INIT_FILE("")) ibuf_a_inst (
      .clk(clk), .rst_n(rst_n), .r_addr(ibuf_a_raddr), .ren(ibuf_a_ren), .dout(ibuf_a_din),
      .r_valid_out(ibuf_a_rvalid), .wen(1'b0), .din('0), .w_addr('0)
  );

  buffer #(.WIDTH(W * B), .SIZE(WBUF_SIZE), .INIT(0), .INIT_FILE("")) ibuf_b_inst (
      .clk(clk), .rst_n(rst_n), .r_addr(ibuf_b_raddr), .ren(ibuf_b_ren), .dout(ibuf_b_din),
      .r_valid_out(ibuf_b_rvalid), .wen(1'b0), .din('0), .w_addr('0)
  );

  // ------------------------------------------------------------ Matrix-Multiply Engine
  mme dut (
      .clk(clk), .rst_n(rst_n), .start(start), .k_len(k_len),
      .cfg_base(cfg_base), .cfg_chstep(cfg_chstep), .cfg_ystep(cfg_ystep),
      .cfg_nch(cfg_nch), .cfg_nky(cfg_nky), .cfg_last(cfg_last),
      .cfg_stride(cfg_stride), .cfg_kpat(cfg_kpat), .cfg_b_base(cfg_b_base),
      .cfg_x_tile_step(cfg_x_tile_step), .cfg_y_tile_step(cfg_y_tile_step),
      .cfg_ntx(cfg_ntx), .cfg_nty(cfg_nty),
      .layer_done(layer_done),
      .ibuf_a_raddr(ibuf_a_raddr), .ibuf_a_din(ibuf_a_din), .ibuf_a_ren(ibuf_a_ren), .ibuf_a_rvalid(ibuf_a_rvalid),
      .ibuf_b_raddr(ibuf_b_raddr), .ibuf_b_din(ibuf_b_din), .ibuf_b_ren(ibuf_b_ren), .ibuf_b_rvalid(ibuf_b_rvalid),
      .outputbus1(ob1), .outputbus2(ob2), .outputbus3(ob3), .outputbus4(ob4),
      .valid1(v1), .valid2(v2), .valid3(v3), .valid4(v4),
      .col1(c1), .col2(c2), .col3(c3), .col4(c4),
      .tile_done(tile_done), .busy(busy), .ext_stall(ext_stall), .flush_acc(flush_acc)
  );

  // ------------------------------------------------------------ Result Monitor
  int hit[0:3][0:3];
  int capv[0:3][0:3];
  int golden_real[0:111][0:111][0:3];
  int errors = 0, tiles = 0;

  always @(posedge clk) begin
    if (v1) begin hit[0][c1]++; capv[0][c1] = $signed(ob1); end
    if (v2) begin hit[1][c2]++; capv[1][c2] = $signed(ob2); end
    if (v3) begin hit[2][c3]++; capv[2][c3] = $signed(ob3); end
    if (v4) begin hit[3][c4]++; capv[3][c4] = $signed(ob4); end
  end

  // ============================================================
  //  DEBUG MAC TRACER (Traces PE(0,0) for the very first tile)
  // ============================================================
  int trace_fd;
  initial begin
    trace_fd = $fopen("./logs/mac_trace_pe00.txt", "w");
    $fdisplay(trace_fd, "Tracing PE(0,0) MAC Sequence for Tile 0");
    $fdisplay(trace_fd, "======================================================================");
    $fdisplay(trace_fd, "Cycle | Valid_A | Valid_B |   in_A   |   in_B   | Mult_Out | Acc_Reg");
    $fdisplay(trace_fd, "----------------------------------------------------------------------");
    forever begin
      @(posedge clk);
      // Wait for valid data arriving at PE(0,0) Stage 3
      if (dut.pe4x4_inst.row[0].colm[0].PE.en) begin
        if (dut.pe4x4_inst.row[0].colm[0].PE.in_valid_r2_a || dut.pe4x4_inst.row[0].colm[0].PE.in_valid_r2_b) begin
           $fdisplay(trace_fd, "%5d |    %b    |    %b    | %8d | %8d | %8d | %8d",
              $time/10,
              dut.pe4x4_inst.row[0].colm[0].PE.in_valid_r2_a,
              dut.pe4x4_inst.row[0].colm[0].PE.in_valid_r2_b,
              $signed(dut.pe4x4_inst.row[0].colm[0].PE.inA_reg),  // Value fed to multiplier A
              $signed(dut.pe4x4_inst.row[0].colm[0].PE.inB_reg),  // Value fed to multiplier B
              $signed(dut.pe4x4_inst.row[0].colm[0].PE.product_reg), // Output of multiplier
              $signed(dut.pe4x4_inst.row[0].colm[0].PE.acc)       // Current accumulator state
           );
        end
      end
      if (tile_done) break; // Stop tracing after the first tile finishes
    end
    $fdisplay(trace_fd, "======================================================================");
    $fclose(trace_fd);
  end

  // ------------------------------------------------------------ Main Execution
  initial begin
    int fd, log_fd, oy_idx, ox_idx, o0, o1, o2, o3;
    longint s;

    // Open Main Error Log
    log_fd = $fopen("./logs/debug_log.txt", "w");
    $fdisplay(log_fd, "--- SHUFFLENET HARDWARE MISMATCH LOG ---");

    // 1. System Reset
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    $display("=== config: W=%0d N=%0d B=%0d IBUF_SIZE=%0d WBUF_SIZE=%0d ===", W, N, B, IBUF_SIZE, WBUF_SIZE);
    
    // 2. Load SRAM Buffers and Golden Model
    $readmemh("./hex/ifmap.hex", ibuf_a_inst.mem);
    $readmemh("./hex/weights.hex", ibuf_b_inst.mem);

    fd = $fopen("./artifacts/golden_out.txt", "r");
    if (fd == 0) begin
      $display("FATAL ERROR: golden_out.txt not found!");
      $finish;
    end
    while (!$feof(fd)) begin
      if ($fscanf(fd, "%d %d %d %d %d %d\n", oy_idx, ox_idx, o0, o1, o2, o3) == 6) begin
        golden_real[oy_idx][ox_idx][0] = o0;
        golden_real[oy_idx][ox_idx][1] = o1;
        golden_real[oy_idx][ox_idx][2] = o2;
        golden_real[oy_idx][ox_idx][3] = o3;
      end
    end
    $fclose(fd);

    for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++) begin hit[i][j] = 0; capv[i][j] = 0; end

    // 3. Configure 5-Counter hardware for Unaligned CHW (C_IN=3), Stride 2, 224x224 -> 112x112
    k_len           = 27;         // K = 3 in_channels * 3 * 3
    cfg_base        = 0;          
    cfg_chstep      = 51076;      // 226 * 226 (Tightly packed, unaligned spatial plane)
    cfg_ystep       = 226;        // Exactly 1 unaligned row down
    cfg_nch         = 3;          // 3 input channels (RGB)
    cfg_nky         = 3;          
    cfg_last        = 8;          // (4-1)*stride 2 + (3-1)*dil 1
    cfg_stride      = 2;          
    cfg_kpat        = 3'b111;
    cfg_x_tile_step = 8;          // 4 spatial pixels * stride 2
    cfg_y_tile_step = 452;        // 226 unaligned width * stride 2
    cfg_ntx         = 28;         // 112 output pixels / 4 columns
    cfg_nty         = 112;        // 112 output rows
    cfg_b_base      = 0;

    
    // 4. Trigger Hardware
    @(posedge clk);
    #1 start = 1;
    @(posedge clk);
    #1 start = 0;

    // 5. Monitor and Verify Output Stream
    for (int oy = 0; oy < 112; oy++) begin
      for (int xg = 0; xg < 28; xg++) begin

        do @(posedge clk); while (!tile_done);
        @(posedge clk);
        #1;  // Wait for PE(3,3) result to latch

        for (int i = 0; i < 4; i++) begin
          for (int j = 0; j < 4; j++) begin
            s = golden_real[oy][xg*4+i][j];
            
            if (hit[i][j] != 1 || capv[i][j] != s) begin
              errors++;
              if (errors < 500) begin // Limit log to first 500 errors to prevent massive file sizes
                $fdisplay(log_fd, "Mismatch | (Y=%0d, X=%0d, Ch=%0d) | Expected: %8d | Hardware Output: %8d | Events: %0d", 
                          oy, (xg*4+i), j, s, capv[i][j], hit[i][j]);
              end
            end
            
            hit[i][j] = 0;
          end
        end
        tiles++;
      end
    end

    $display("-> INFERENCE COMPLETE: %0d tiles evaluated.", tiles);
    if (errors == 0) $display("-> VERDICT: SUCCESS (0 errors)!");
    else $display("-> VERDICT: FAILED (%0d errors). Check debug_log.txt and mac_trace_pe00.txt!", errors);
    
    $fclose(log_fd);
    $finish;
  end
endmodule
