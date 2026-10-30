// `timescale 1ns / 1ps
// `ifndef GLOBAL_SVH
// `include "global.svh"
// `endif

// module tb_accelerator_all_patches;
//   logic clk = 0, rst_n = 0;
//   always #5 clk = ~clk;

//   logic start = 0, bank_sel = 0, flush_acc = 0, ext_stall = 0;
//   logic [KLEN_W-1:0] k_len;
//   logic [23:0] cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last;
//   logic [7:0]  cfg_stride;
//   logic [15:0] cfg_kpat;
//   logic [23:0] cfg_x_tile_step, cfg_y_tile_step, cfg_ntx, cfg_nty;
//   logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base;
  
//   logic [31:0]        reqt_total_tiles, reqt_oc_base;
//   logic signed [31:0] reqt_bias [0:3];
//   logic signed [31:0] reqt_mult [0:3];
//   logic [31:0]        reqt_shift [0:3];
//   logic signed [7:0]  reqt_z_out;
//   logic               reqt_relu_en;

//   logic [$clog2(WBUF_SIZE)-1:0] ext_wbuf_addr;
//   logic [W*B-1:0]               ext_wbuf_data;
//   logic                         ext_wbuf_wen;
//   logic layer_done, busy;

//   accelerator_top dut (.*);

//   int bias_all [0:23], mult_all [0:23], shift_all [0:23];
//   int golden_out [0:23][0:55][0:55];
//   string hex_file, golden_file;

//   initial begin
//     int fd, c_idx, y_idx, x_idx, val;
//     int b_val, m_val, s_val;
//     int total_errors = 0;
//     logic [31:0] sram_val;
//     logic [7:0] hw_pixel;

//     // Load static weights and parameters
//     $readmemh("./hex/weights_24ch.hex", dut.weight_sram.mem);

//     fd = $fopen("./artifacts/requant_params_24ch.txt", "r");
//     for (int i = 0; i < 24; i++) begin
//       $fscanf(fd, "%d %d %d\n", b_val, m_val, s_val);
//       bias_all[i] = b_val; mult_all[i] = m_val; shift_all[i] = s_val;
//     end
//     $fclose(fd);

//     repeat (4) @(posedge clk);
//     rst_n = 1;
//     repeat (3) @(posedge clk);

//     $display("=== STARTING FULL 4-PATCH STREAMING SIMULATION ===");
//     bank_sel         = 0;
//     reqt_total_tiles = 784; 
//     reqt_z_out       = -128; 
//     reqt_relu_en     = 1;
    
//     k_len            = 27; 
//     cfg_base         = 0;          
//     cfg_chstep       = 12996; // 114 * 114
//     cfg_ystep        = 114;   
//     cfg_nch          = 3;     
//     cfg_nky          = 3;     
//     cfg_last         = 8;     
//     cfg_stride       = 2;     
//     cfg_kpat         = 3'b111;
//     cfg_x_tile_step  = 8;     
//     cfg_y_tile_step  = 228;   
//     cfg_ntx          = 14;    
//     cfg_nty          = 56;    

//     // OUTER LOOP: Iterate over all 4 patches
//     for (int p = 0; p < 4; p++) begin
//       $display("\n--- Processing Patch %0d ---", p);
      
//       // Dynamically load patch hex file into Ping-Pong SRAM Bank A
//       case(p)
//         0: $readmemh("./hex/ifmap_patch_0.hex", dut.pp_sram.bank_a);
//         1: $readmemh("./hex/ifmap_patch_1.hex", dut.pp_sram.bank_a);
//         2: $readmemh("./hex/ifmap_patch_2.hex", dut.pp_sram.bank_a);
//         3: $readmemh("./hex/ifmap_patch_3.hex", dut.pp_sram.bank_a);
//       endcase

//       // Load matching golden output text file
//       case(p)
//         0: golden_file = "./artifacts/golden_patch_out_0.txt";
//         1: golden_file = "./artifacts/golden_patch_out_1.txt";
//         2: golden_file = "./artifacts/golden_patch_out_2.txt";
//         3: golden_file = "./artifacts/golden_patch_out_3.txt";
//       endcase

//       fd = $fopen(golden_file, "r");
//       while (!$feof(fd)) begin
//         if ($fscanf(fd, "%d %d %d %d\n", c_idx, y_idx, x_idx, val) == 4)
//           golden_out[c_idx][y_idx][x_idx] = val;
//       end
//       $fclose(fd);

//       // Inner Loop: 6 passes (4 channels each) per patch
//       for (int pass = 0; pass < 6; pass++) begin
//         cfg_b_base   = pass * 27;
//         reqt_oc_base = pass * 4;
        
//         for (int i = 0; i < 4; i++) begin
//           reqt_bias[i]  = bias_all[pass*4 + i];
//           reqt_mult[i]  = mult_all[pass*4 + i];
//           reqt_shift[i] = shift_all[pass*4 + i];
//         end
        
//         @(posedge clk); #1 start = 1; @(posedge clk); #1 start = 0;
//         do @(posedge clk); while (!layer_done);
//       end

//       // Verify patch results stored in bank_b
//       for (int c = 0; c < 24; c++) begin
//         for (int y = 0; y < 56; y++) begin
//           for (int x = 0; x < 56; x += 4) begin
//             int addr = (c * 784) + (y * 14) + (x / 4);
//             sram_val = dut.pp_sram.bank_b[addr];
            
//             for (int p_pix = 0; p_pix < 4; p_pix++) begin
//               hw_pixel = sram_val[p_pix*8 +: 8];
//               if (hw_pixel != golden_out[c][y][x+p_pix]) begin
//                 total_errors++;
//                 if (total_errors < 15) 
//                   $display("Patch %0d Mismatch [C%0d, Y%0d, X%0d]: Expected %0d, Got %0d", p, c, y, x+p_pix, golden_out[c][y][x+p_pix], hw_pixel);
//               end
//             end
//           end
//         end
//       end
//       $display("Patch %0d Verified Successfully.", p);
//     end

//     if (total_errors == 0) $display("\n-> VERDICT: SUCCESS (0 errors across all 4 patches / 301,056 pixels)!");
//     else                   $display("\n-> VERDICT: FAILED (%0d total errors)", total_errors);
//     $finish;
//   end
// endmodule


// `timescale 1ns / 1ps
// `ifndef GLOBAL_SVH
// `include "global.svh"
// `endif

// module tb_accelerator_all_patches;
//   logic clk = 0, rst_n = 0;
//   always #5 clk = ~clk;

//   logic start = 0, bank_sel = 0, flush_acc = 0, ext_stall = 0;
//   logic [KLEN_W-1:0] k_len;
//   logic [23:0] cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last;
//   logic [7:0]  cfg_stride;
//   logic [15:0] cfg_kpat;
//   logic [23:0] cfg_x_tile_step, cfg_y_tile_step, cfg_ntx, cfg_nty;
//   logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base;
  
//   logic [31:0]        reqt_total_tiles, reqt_oc_base;
//   logic signed [31:0] reqt_bias [0:3];
//   logic signed [31:0] reqt_mult [0:3];
//   logic signed [31:0]        reqt_shift [0:3];
//   logic signed [7:0]  reqt_z_out;
//   logic               reqt_relu_en;

//   logic [$clog2(WBUF_SIZE)-1:0] ext_wbuf_addr = 0;
//   logic [W*B-1:0]               ext_wbuf_data = 0;
//   logic                         ext_wbuf_wen = 0;
//   logic layer_done, busy;

//   accelerator_top dut (.*);

//   int bias_all [0:23], mult_all [0:23], shift_all [0:23];
//   int golden_out [0:23][0:55][0:55];
//   string golden_file;


//   initial begin
//     int fd, c_idx, y_idx, x_idx, val;
//     int b_val, m_val, s_val, z_val;
//     int total_errors = 0;
//     logic [31:0] sram_val;
//     logic signed [7:0] hw_pixel; // FIXED: Explicitly signed

    

//     $readmemh("./hex/weights_24ch.hex", dut.weight_sram.mem);

//     fd = $fopen("./artifacts/requant_params_24ch.txt", "r");
//     if ($fscanf(fd, "%d\n", z_val) == 1) reqt_z_out = z_val;
    
//     for (int i = 0; i < 24; i++) begin
//       if ($fscanf(fd, "%d %d %d\n", b_val, m_val, s_val) == 3) begin
//         bias_all[i] = b_val; mult_all[i] = m_val; shift_all[i] = s_val;
//       end
//     end
//     $fclose(fd);

//     repeat (4) @(posedge clk);
//     rst_n = 1;
//     repeat (3) @(posedge clk);

//     $display("=== STARTING FULL 4-PATCH STREAMING SIMULATION (WITH RELU) ===");
//     bank_sel         = 0;
//     reqt_total_tiles = 784; 
//     reqt_relu_en     = 1;  // FIXED: ReLU is ON
    
//     k_len            = 27; 
//     cfg_base         = 0;          
//     cfg_chstep       = 12996; // 114 * 114
//     cfg_ystep        = 114;   
//     cfg_nch          = 3;     
//     cfg_nky          = 3;     
//     cfg_last         = 8;     
//     cfg_stride       = 2;     
//     cfg_kpat         = 3'b111;
//     cfg_x_tile_step  = 8;     
//     cfg_y_tile_step  = 228;   
//     cfg_ntx          = 14;    
//     cfg_nty          = 56;    

//     for (int p = 0; p < 4; p++) begin
//       $display("\n--- Processing Patch %0d ---", p);
      
//       case(p)
//         0: $readmemh("./hex/ifmap_patch_0.hex", dut.pp_sram.bank_a);
//         1: $readmemh("./hex/ifmap_patch_1.hex", dut.pp_sram.bank_a);
//         2: $readmemh("./hex/ifmap_patch_2.hex", dut.pp_sram.bank_a);
//         3: $readmemh("./hex/ifmap_patch_3.hex", dut.pp_sram.bank_a);
//       endcase

//       case(p)
//         0: golden_file = "./artifacts/golden_patch_out_0.txt";
//         1: golden_file = "./artifacts/golden_patch_out_1.txt";
//         2: golden_file = "./artifacts/golden_patch_out_2.txt";
//         3: golden_file = "./artifacts/golden_patch_out_3.txt";
//       endcase

//       fd = $fopen(golden_file, "r");
//       while (!$feof(fd)) begin
//         if ($fscanf(fd, "%d %d %d %d\n", c_idx, y_idx, x_idx, val) == 4)
//           golden_out[c_idx][y_idx][x_idx] = val;
//       end
//       $fclose(fd);

//       for (int pass = 0; pass < 6; pass++) begin
//         cfg_b_base   = pass * 27;
//         reqt_oc_base = pass * 4;
        
//         for (int i = 0; i < 4; i++) begin
//           reqt_bias[i]  = bias_all[pass*4 + i];
//           reqt_mult[i]  = mult_all[pass*4 + i];
//           reqt_shift[i] = shift_all[pass*4 + i];
//         end
        
//         @(posedge clk); #1 start = 1; @(posedge clk); #1 start = 0;
//         do @(posedge clk); while (!layer_done);
//       end

//       for (int c = 0; c < 24; c++) begin
//         for (int y = 0; y < 56; y++) begin
//           for (int x = 0; x < 56; x += 4) begin
//             int addr = (c * 784) + (y * 14) + (x / 4);
//             sram_val = dut.pp_sram.bank_b[addr];
            
//             for (int p_pix = 0; p_pix < 4; p_pix++) begin
//               hw_pixel = sram_val[p_pix*8 +: 8];
//               if (hw_pixel != golden_out[c][y][x+p_pix]) begin
//                 total_errors++;
//                 if (total_errors < 15) 
//                   $display("Patch %0d Mismatch [C%0d, Y%0d, X%0d]: Expected %0d, Got %0d", p, c, y, x+p_pix, golden_out[c][y][x+p_pix], hw_pixel);
//               end
//             end
//           end
//         end
//       end
//       $display("Patch %0d Verified Successfully.", p);
//     end

//     if (total_errors == 0) $display("\n-> VERDICT: SUCCESS (0 errors across all 4 patches / 301,056 pixels)!");
//     else                   $display("\n-> VERDICT: FAILED (%0d total errors)", total_errors);
//     $finish;
//   end
// endmodule


`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// module tb_accelerator_all_patches;
//   logic clk = 0, rst_n = 0;
//   always #5 clk = ~clk;

//   logic start = 0, bank_sel = 0, flush_acc = 0, ext_stall = 0;
//   logic [KLEN_W-1:0] k_len;
//   logic [23:0] cfg_base, cfg_chstep, cfg_ystep, cfg_nch, cfg_nky, cfg_last;
//   logic [7:0]  cfg_stride;
//   logic [15:0] cfg_kpat;
//   logic [23:0] cfg_x_tile_step, cfg_y_tile_step, cfg_ntx, cfg_nty;
//   logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base;
  
//   logic [31:0]        reqt_total_tiles, reqt_oc_base;
//   logic signed [31:0] reqt_bias [0:3];
//   logic signed [31:0] reqt_mult [0:3];
//   logic signed [31:0] reqt_shift [0:3];
//   logic signed [7:0]  reqt_z_out;
//   logic               reqt_relu_en;

//   logic [$clog2(WBUF_SIZE)-1:0] ext_wbuf_addr = 0;
//   logic [W*B-1:0]               ext_wbuf_data = 0;
//   logic                         ext_wbuf_wen = 0;
//   logic layer_done, busy;

//   accelerator_top dut (.*);

//   int bias_all [0:23], mult_all [0:23], shift_all [0:23];
//   int golden_out [0:23][0:55][0:55];
//   string golden_file;
//   int dbg_fd;

//   initial begin
//     $dumpfile("dump_shufflenet.fst");
//     $dumpvars(1, tb_accelerator_all_patches.dut.reqt_inst);
//     // $dumpvars(1, tb_accelerator_all_patches.dut.)
//   end


//   initial begin
//     int fd, c_idx, y_idx, x_idx, val;
//     int b_val, m_val, s_val, z_val;
//     int total_errors = 0;
//     logic [31:0] sram_val;
//     logic signed [7:0] hw_pixel, exp_pixel;

//     // Create debug log
//     dbg_fd = $fopen("./logs/requant_debug.txt", "w");
//     $fdisplay(dbg_fd, "--- SRAM Write Trace ---");

//     $readmemh("weights_24ch.hex", dut.weight_sram.mem);
    

//     fd = $fopen("requant_params_24ch.txt", "r");
//     // FIX: Python writes SIGNED DECIMAL integers. %h cannot parse '-' so it
//     // silently returns 0 for negative values (Z_out=-128 -> 0; all bias/shift -> 0).
//     // With M_fixed=0 the requantizer always outputs 0. Use %d for all fields.
//     if ($fscanf(fd, "%d\n", z_val) == 1) reqt_z_out = z_val;
//     for (int i = 0; i < 24; i++) begin
//       if ($fscanf(fd, "%d %d %d\n", b_val, m_val, s_val) == 3) begin
//         bias_all[i] = b_val; mult_all[i] = m_val; shift_all[i] = s_val;
//       end
//     end
//     $fclose(fd);

//     repeat (4) @(posedge clk);
//     rst_n = 1;
//     repeat (3) @(posedge clk);

//     $display("=== STARTING FULL 4-PATCH STREAMING SIMULATION (WITH RELU) ===");
//     bank_sel         = 0;
//     reqt_total_tiles = 784; 
//     reqt_relu_en     = 1;
    
//     k_len            = 27; 
//     cfg_base         = 0;          
//     cfg_chstep       = 12996; 
//     cfg_ystep        = 114;   
//     cfg_nch          = 3;     
//     cfg_nky          = 3;     
//     cfg_last         = 8;     
//     cfg_stride       = 2;     
//     cfg_kpat         = 3'b111;
//     cfg_x_tile_step  = 8;     
//     cfg_y_tile_step  = 228;   
//     cfg_ntx          = 14;    
//     cfg_nty          = 56;    

//     for (int p = 0; p < 4; p++) begin
//       int patch_errors = 0;
//       $display("\n--- Processing Patch %0d ---", p);
//       $fdisplay(dbg_fd, "\n--- Starting Patch %0d ---", p);
      
//       case(p)
//         0: $readmemh("ifmap_patch_0.hex", dut.pp_sram.bank_a);
//         1: $readmemh("ifmap_patch_1.hex", dut.pp_sram.bank_a);
//         2: $readmemh("ifmap_patch_2.hex", dut.pp_sram.bank_a);
//         3: $readmemh("ifmap_patch_3.hex", dut.pp_sram.bank_a);
//       endcase

//       case(p)
//         0: golden_file = "golden_patch_out_0.txt";
//         1: golden_file = "golden_patch_out_1.txt";
//         2: golden_file = "golden_patch_out_2.txt";
//         3: golden_file = "golden_patch_out_3.txt";
//       endcase

//       fd = $fopen(golden_file, "r");
//       while (!$feof(fd)) begin
//         // FIX: pixel value is written as signed decimal by Python (%d not %h).
//         // Reading '94' with %h gives 0x94=148, which as signed int8 = -108 (wrong).
//         if ($fscanf(fd, "%d %d %d %d\n", c_idx, y_idx, x_idx, val) == 4)
//           golden_out[c_idx][y_idx][x_idx] = val;
//       end
//       $fclose(fd);

//       for (int pass = 0; pass < 6; pass++) begin
//         cfg_b_base   = pass * 27;
//         reqt_oc_base = pass * 4;
        
//         for (int i = 0; i < 4; i++) begin
//           reqt_bias[i]  = bias_all[pass*4 + i];
//           reqt_mult[i]  = mult_all[pass*4 + i];
//           reqt_shift[i] = shift_all[pass*4 + i];
//         end
        
//         @(posedge clk); #1 start = 1; @(posedge clk); #1 start = 0;
//         do @(posedge clk); while (!layer_done);
//       end

//       for (int c = 0; c < 24; c++) begin
//         for (int y = 0; y < 56; y++) begin
//           for (int x = 0; x < 56; x += 4) begin
//             int addr = (c * 784) + (y * 14) + (x / 4);
//             sram_val = dut.pp_sram.bank_b[addr];
            
//             for (int p_pix = 0; p_pix < 4; p_pix++) begin
//               hw_pixel = sram_val[p_pix*8 +: 8];
//               exp_pixel = golden_out[c][y][x+p_pix];
//               if (hw_pixel !== exp_pixel) begin
//                 total_errors++;
//                 patch_errors++;
//                 if (patch_errors <= 15) 
//                   $display("Mismatch [P%0d, C%0d, Y%0d, X%0d]: Expected %0d, Got %0d", p, c, y, x+p_pix, exp_pixel, hw_pixel);
//               end
//             end
//           end
//         end
//       end
//       if (patch_errors == 0) $display("Patch %0d Verified Successfully.", p);
//     end

//     if (total_errors == 0) $display("\n-> VERDICT: SUCCESS (0 errors across all 4 patches / 301,056 pixels)!");
//     else                   $display("\n-> VERDICT: FAILED (%0d total errors)", total_errors);
    
//     $fclose(dbg_fd);
//     $finish;
//   end

//   // Hardware Activity Logger
//   always @(posedge clk) begin
//     if (dut.reqt_inst.sram_wen) begin
//       $fdisplay(dbg_fd, "Time: %0t | Ch: %0d | SRAM Addr: %0d | WData: %h", 
//                 $time, dut.reqt_inst.c4, dut.reqt_inst.sram_waddr, dut.reqt_inst.sram_wdata);
//     end
//   end
// endmodule


`timescale 1ns / 1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module tb_accelerator_all_patches;
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
  logic signed [31:0] reqt_bias [0:3];
  logic signed [31:0] reqt_mult [0:3];
  logic signed [31:0] reqt_shift [0:3];
  logic signed [7:0]  reqt_z_out;
  logic               reqt_relu_en;

  logic [$clog2(WBUF_SIZE)-1:0] ext_wbuf_addr = 0;
  logic [W*B-1:0]               ext_wbuf_data = 0;
  logic                         ext_wbuf_wen = 0;
  logic layer_done, busy;

  accelerator_top dut (.*);

  int bias_all [0:23], mult_all [0:23], shift_all [0:23];
  int golden_out [0:23][0:55][0:55];
  string golden_file;
  int dbg_fd;

  // NEW: Temporary memory arrays for $readmemh
  logic [31:0] param_mem [0:71]; 
  logic [31:0] z_out_mem [0:0];

  initial begin
    int fd, c_idx, y_idx, x_idx, val;
    int total_errors = 0;
    logic [31:0] sram_val;
    logic signed [7:0] hw_pixel, exp_pixel;

    dbg_fd = $fopen("./logs/deep_trace.txt", "w"); // Placed in root dir

    // --- HEX LOADING STRATEGY ---
    $readmemh("weights_24ch.hex", dut.weight_sram.mem);
    
    // Load Z_out
    $readmemh("z_out.hex", z_out_mem);
    reqt_z_out = z_out_mem[0][7:0];

    // Load Requant Params (72 words)
    $readmemh("requant_params.hex", param_mem);
    for (int i = 0; i < 24; i++) begin
        bias_all[i]  = param_mem[i*3 + 0];
        mult_all[i]  = param_mem[i*3 + 1];
        shift_all[i]  = param_mem[i*3 + 2];
    end

    $display("--- REQUANT PARAMS LOADED VIA HEX ---");
    $display("Z_out = %0d", reqt_z_out);
    $display("Ch 0: Bias=%0d, M_fixed=%0d, Shift=%0d", bias_all[0], mult_all[0], shift_all[0]);
    // ----------------------------

    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    $display("\n=== STARTING FULL 4-PATCH STREAMING SIMULATION ===");
    bank_sel         = 0;
    reqt_total_tiles = 784; 
    reqt_relu_en     = 1;
    
    k_len            = 27; 
    cfg_base         = 0;          
    cfg_chstep       = 12996; 
    cfg_ystep        = 114;   
    cfg_nch          = 3;     
    cfg_nky          = 3;     
    cfg_last         = 8;     
    cfg_stride       = 2;     
    cfg_kpat         = 3'b111;
    cfg_x_tile_step  = 8;     
    cfg_y_tile_step  = 228;   
    cfg_ntx          = 14;    
    cfg_nty          = 56;    

    for (int p = 0; p < 4; p++) begin
      int patch_errors = 0;
      $display("\n--- Processing Patch %0d ---", p);
      
      // Paths updated to root directory
      case(p)
        0: $readmemh("ifmap_patch_0.hex", dut.pp_sram.bank_a);
        1: $readmemh("ifmap_patch_1.hex", dut.pp_sram.bank_a);
        2: $readmemh("ifmap_patch_2.hex", dut.pp_sram.bank_a);
        3: $readmemh("ifmap_patch_3.hex", dut.pp_sram.bank_a);
      endcase

      case(p)
        0: golden_file = "golden_patch_out_0.txt";
        1: golden_file = "golden_patch_out_1.txt";
        2: golden_file = "golden_patch_out_2.txt";
        3: golden_file = "golden_patch_out_3.txt";
      endcase

      fd = $fopen(golden_file, "r");
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
        @(posedge clk);
      end

      for (int c = 0; c < 24; c++) begin
        for (int y = 0; y < 56; y++) begin
          for (int x = 0; x < 56; x += 4) begin
            int addr = (c * 784) + (y * 14) + (x / 4);
            sram_val = dut.pp_sram.bank_b[addr];
            
            for (int p_pix = 0; p_pix < 4; p_pix++) begin
              hw_pixel = sram_val[p_pix*8 +: 8];
              exp_pixel = golden_out[c][y][x+p_pix];
              if (hw_pixel !== exp_pixel) begin
                total_errors++;
                patch_errors++;
                if (patch_errors <= 15) 
                  $display("Mismatch [P%0d, C%0d, Y%0d, X%0d]: Expected %0d, Got %0d", p, c, y, x+p_pix, exp_pixel, hw_pixel);
              end
            end
          end
        end
      end
      if (patch_errors == 0) $display("Patch %0d Verified Successfully.", p);
    end

    if (total_errors == 0) $display("\n-> VERDICT: SUCCESS (0 errors across all 4 patches)!");
    else                   $display("\n-> VERDICT: FAILED (%0d total errors)", total_errors);
    
    $fclose(dbg_fd);
    $finish;
  end
  
  always @(posedge clk) begin
    if (dut.valid1) begin
      $fdisplay(dbg_fd, "[MME -> REQUANT] Time: %0t | ob1(raw 24b): %d | acc_in(sign-ext 32b): %d | M_fixed applied: %d | q_out(INT8): %d", 
                $time, $signed(dut.ob1), dut.reqt_inst.req1.acc_in, dut.reqt_inst.req1.M_fixed, dut.reqt_inst.req1.q_out);
    end
    if (dut.reqt_inst.sram_wen && dut.reqt_inst.sram_wdata != 0) begin
      $fdisplay(dbg_fd, "[SRAM WRITE] Time: %0t | Channel: %0d | Addr: %0d | WData: %h", 
                $time, dut.reqt_inst.c4, dut.reqt_inst.sram_waddr, dut.reqt_inst.sram_wdata);
    end
  end
endmodule
