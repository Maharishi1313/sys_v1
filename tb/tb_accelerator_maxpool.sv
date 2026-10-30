`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module tb_accelerator_maxpool;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic start = 0, bank_sel = 0, flush_acc = 0, ext_stall = 0;
  logic [KLEN_W-1:0] k_len;
  logic [23:0] cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last;
  logic [7:0]  cfg_stride;
  logic [15:0] cfg_kpat;
  logic [23:0] cfg_x_tile_step, cfg_y_tile_step, cfg_ntx, cfg_nty;
  logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base;
  
  logic [31:0]        reqt_total_tiles, reqt_oc_base;
  logic signed [31:0] reqt_bias [0:3], reqt_mult [0:3], reqt_shift [0:3];
  logic signed [7:0]  reqt_z_out;
  logic               reqt_relu_en, cfg_maxpool_en;
  
  logic [15:0] cfg_pool_x_chunks, cfg_pool_y_rows;
  logic [3:0]  cfg_pool_stride;

  logic [$clog2(WBUF_SIZE)-1:0] ext_wbuf_addr = 0;
  logic [W*B-1:0]               ext_wbuf_data = 0;
  logic                         ext_wbuf_wen = 0;
  logic layer_done, busy;

  accelerator_top dut (.*);

  int bias_all [0:23], mult_all [0:23], shift_all [0:23];
  int golden_out [0:23][0:27][0:27]; 
  string golden_file;

  logic [31:0] param_mem [0:71]; 
  logic [31:0] z_out_mem [0:0];
  int dbg_fd;

  initial begin
    int fd, c_idx, y_idx, x_idx, val;
    int total_errors = 0;
    logic [31:0] sram_val;
    logic signed [7:0] hw_pixel, exp_pixel;

    dbg_fd = $fopen("./logs/maxpool_trace.txt", "w");
    $fdisplay(dbg_fd, "=== MAXPOOL PIPELINE TRACE ===");

    $readmemh("weights_24ch.hex", dut.weight_sram.mem);
    $readmemh("z_out.hex", z_out_mem);
    reqt_z_out = z_out_mem[0][7:0];

    $readmemh("requant_params.hex", param_mem);
    for (int i = 0; i < 24; i++) begin
        bias_all[i]  = param_mem[i*3 + 0];
        mult_all[i]  = param_mem[i*3 + 1];
        shift_all[i]  = param_mem[i*3 + 2];
    end

    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    $display("\n=== STARTING DEBUG DATAPATH SIMULATION ===");
    bank_sel          = 0;
    reqt_total_tiles  = 784; 
    reqt_relu_en      = 1;
    
    cfg_maxpool_en    = 1; 
    cfg_pool_x_chunks = 14; 
    cfg_pool_y_rows   = 56;
    cfg_pool_stride   = 2;
    
    k_len = 27; cfg_base = 0; cfg_chstep = 12996; cfg_ystep = 114;   
    cfg_nch = 3; cfg_nky = 3; cfg_last = 8; cfg_stride = 2;     
    cfg_kpat = 3'b111; cfg_x_tile_step = 8; cfg_y_tile_step = 228;   
    cfg_ntx = 14; cfg_nty = 56;    

    // We only process Patch 0 in debug mode to keep the log file readable
    for (int p = 0; p < 1; p++) begin
      int patch_errors = 0;
      
      $readmemh("ifmap_patch_0.hex", dut.pp_sram.bank_a);
      fd = $fopen("maxpool_golden_out_0.txt", "r");
      while (!$feof(fd)) begin
        if ($fscanf(fd, "%d %d %d %d\n", c_idx, y_idx, x_idx, val) == 4)
          golden_out[c_idx][y_idx][x_idx] = val;
      end
      $fclose(fd);

      for (int pass = 0; pass < 6; pass++) begin
        cfg_b_base   = pass * 27;
        reqt_oc_base = pass * 4;
        
        for (int i = 0; i < 4; i++) begin
          reqt_bias[i]  = bias_all[pass*4 + i];
          reqt_mult[i]  = mult_all[pass*4 + i];
          reqt_shift[i] = shift_all[pass*4 + i];
        end
        
        @(posedge clk); #1 start = 1; @(posedge clk); #1 start = 0;
        do @(posedge clk); while (!layer_done);
        
        repeat(64) @(posedge clk); // Flush full line
      end

      for (int c = 0; c < 4; c++) begin // Only verify first pass to limit terminal flood
        for (int y = 0; y < 28; y++) begin
          for (int x = 0; x < 28; x += 4) begin
            int addr = (c * 196) + (y * 7) + (x / 4);
            sram_val = dut.pp_sram.bank_b[addr];
            
            for (int p_pix = 0; p_pix < 4; p_pix++) begin
              hw_pixel = sram_val[p_pix*8 +: 8];
              exp_pixel = golden_out[c][y][x+p_pix];
              if (hw_pixel !== exp_pixel) begin
                total_errors++;
                patch_errors++;
                if (patch_errors <= 25) 
                  $display("Mismatch [C%0d, Y%0d, X%0d]: Expected %0d, Got %0d", c, y, x+p_pix, exp_pixel, hw_pixel);
              end
            end
          end
        end
      end
    end
    
    $fclose(dbg_fd);
    $finish;
  end

  // ===========================================================================
  // THE DEEP TRACE LOGIC
  // ===========================================================================
  always @(posedge clk) begin
    // 1. Trace Requantizer Output (Is it 0?)
    if (dut.reqt_wen) begin
      $fdisplay(dbg_fd, "[REQUANT] Ch:%0d | Addr:%0d | WData:%h", dut.c4, dut.reqt_waddr, dut.reqt_wdata);
    end
    
    // 2. Trace MaxPool Internal Windows
    if (dut.maxpool_inst.s2_val) begin
      $fdisplay(dbg_fd, "[MAXPOOL WINDOW] CX:%0d CY:%0d CH:%0d | max0:%d max1:%d max2:%d max3:%d", 
                dut.maxpool_inst.s2_cx, dut.maxpool_inst.s2_cy, dut.maxpool_inst.s2_c, 
                dut.maxpool_inst.max0, dut.maxpool_inst.max1, dut.maxpool_inst.max2, dut.maxpool_inst.max3);
    end
    
    // 3. Trace MaxPool SRAM Output
    if (dut.pool_wen) begin
      $fdisplay(dbg_fd, "[POOL WRITE] Addr:%0d | WData:%h", dut.pool_waddr, dut.pool_wdata);
    end
  end
endmodule
