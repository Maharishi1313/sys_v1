// =============================================================================
//  global.svh  -- ASSUMED VALUES (your original global.svh was not uploaded).
//  Replace with yours if different; the design only needs these names.
//    W          bits per value (signed integer, not FP16)
//    N          systolic array size (N x N)         -> 4
//    B          values per SRAM/buffer word          -> 4 (or 2: -DUSE_B2)
//    FIF_DEPTH  entries per lane FIFO (must be >= N+1)
//    KLEN_W     bits of the "MACs per output" register (new)
// =============================================================================
`ifndef GLOBAL_SVH
`define GLOBAL_SVH
localparam int W         = 8;
localparam int N         = 4;
`ifdef USE_B2
localparam int B         = 2;
`else
localparam int B         = 4;
`endif
localparam int ACC_WIDTH = 24;
localparam int OUT_WIDTH = ACC_WIDTH;
localparam int FIF_LINES = N;
`ifdef FIFO_DEPTH_OVR
localparam int FIF_DEPTH = `FIFO_DEPTH_OVR;   // stress: any value >= N+1
`else
localparam int FIF_DEPTH = 8;      // deliberately small (< K) so the stall logic is exercised
`endif
localparam int IBUF_SIZE = 65536;  // words per activation / ifmap buffer
localparam int WBUF_SIZE = 8192;   // words per weight buffer
localparam int KLEN_W    = 10;    // K up to 1023 (SqueezeNet max: fire8/9 expand3x3 = 64*9 = 576)
`endif
