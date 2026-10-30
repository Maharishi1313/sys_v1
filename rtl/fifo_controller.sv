`ifndef GLOBAL_SVH
`include "global.svh"
`endif

/* verilator lint_off UNUSEDSIGNAL */
// =============================================================================
//  fifo_controller  (fixed + extended)
//
//  KEPT from your design : one FIFO per lane, and the SKEW is made by starting
//                          lane k exactly k "steps" after lane 0 (staggered read
//                          enables).  The same stagger is used for A and B.
//
//  FIXED
//   1. 'en_ctr' was used before it was declared.
//   2. en_ctr counted to N+1, so en_sig[N-k] wrote index -1 (out of range).
//   3. nothing was cleared when a tile ended (addr, line_ctr, en_ctr...), so a
//      second tile ran with no stagger and wrong addresses.  Everything is now
//      loaded by 'start'.
//   4. the buffer read address ran forever, with no length and no flow
//      control: data was silently lost when a FIFO was full.  Now: exactly
//      k_steps steps are fetched, and a request is only made when there is room.
//   5. fifo_out_valid <= fifo_ren ignored 'empty': a blocked read was reported
//      as valid data.  Valid now means "a real read happened".
//   6. a lane that ran dry in the middle of a tile broke the A/B alignment.
//      Now the WHOLE array freezes ('adv'=0) until every active lane has data.
//   7. line_ctr was [-1:0] (2 bits) when N==B.  Width is now always >= 1.
//   8b NEW input 'hold': freezes the whole array (use it for output back-pressure).
//   8. col_ctr was dead logic; removed.  feed_done is now an OUTPUT
//      (it was an input that the testbench had to guess).
//
//  NEW  A side takes lane streams from the ifmap_feeder (src_a*) instead of a
//       pre-lowered buffer.  B side (weights) still comes from a buffer.
// =============================================================================




/* verilator lint_off UNUSEDSIGNAL */
module fifo_controller (
    input  logic clk,
    input  logic rst_n,

    // ---- tile / layer command ----
    input  logic start,                                  // 1-clock pulse
    input  logic [KLEN_W-1:0] k_steps,                   // K = values per lane per tile
    input  logic [31:0]       num_tiles,                 // Total contexts (cfg_ntx * cfg_nty)
    input  logic [$clog2(WBUF_SIZE)-1:0] b_base,          // first weight word of this tile/layer
    input  logic hold,                                   // external freeze

    // ---- buffer interface B (weights); 1-clock read latency ----
    output logic [$clog2(WBUF_SIZE)-1:0] buf_addr_b,
    output logic buf_req_b,
    input  logic [W*B-1:0] buffer_in_b,
    input  logic buffer_in_valid_b,

    // ---- A source = ifmap_feeder lanes (all lanes move together) ----
    input  logic [W*N-1:0] src_a,
    input  logic src_a_valid,
    output logic src_a_pop,

    // ---- to PE array ----
    output logic [W-1:0] fifo_out_a[0:FIF_LINES-1],
    output logic [FIF_LINES-1:0] fifo_out_valid_a,
    output logic [W-1:0] fifo_out_b[0:FIF_LINES-1],
    output logic [FIF_LINES-1:0] fifo_out_valid_b,

    output logic adv,         // global advance for the whole PE array (0 = freeze)
    output logic feed_done,   // 1-clock pulse: all tiles have left the FIFOs
    output logic busy
);
  localparam int LINES  = N / B;
  localparam int LINE_W = (LINES > 1) ? $clog2(LINES) : 1;
  localparam int ADDR_W = $clog2(WBUF_SIZE);
  localparam int LVL_W  = $clog2(FIF_DEPTH) + 1;

  wire [31:0] eff_tiles = (num_tiles == 0) ? 32'd1 : num_tiles;

  // ------------------------------------------------------------------ FIFOs
  logic [W-1:0] fifo_din_a[0:N-1], fifo_dout_a[0:N-1];
  logic [W-1:0] fifo_din_b[0:N-1], fifo_dout_b[0:N-1];
  logic [N-1:0] fifo_wen_a, fifo_ren_a, fifo_full_a, fifo_empty_a;
  logic [N-1:0] fifo_wen_b, fifo_ren_b, fifo_full_b, fifo_empty_b;
  logic [LVL_W-1:0] lvl_a[0:N-1], lvl_b[0:N-1];

  genvar j;
  generate
    for (j = 0; j < N; j++) begin : fifo_gen
      lane_fifo #(.DEPTH(FIF_DEPTH)) fifo_a_j (
          .clk(clk), .rst_n(rst_n & ~start), .data_in(fifo_din_a[j]), .w_en(fifo_wen_a[j]),
          .r_en(fifo_ren_a[j]), .data_out(fifo_dout_a[j]), .full(fifo_full_a[j]),
          .empty(fifo_empty_a[j]), .level(lvl_a[j]));
      lane_fifo #(.DEPTH(FIF_DEPTH)) fifo_b_j (
          .clk(clk), .rst_n(rst_n & ~start), .data_in(fifo_din_b[j]), .w_en(fifo_wen_b[j]),
          .r_en(fifo_ren_b[j]), .data_out(fifo_dout_b[j]), .full(fifo_full_b[j]),
          .empty(fifo_empty_b[j]), .level(lvl_b[j]));
    end
  endgenerate

  // ------------------------------------------------------------ registers
  logic run;
  logic [$clog2(N):0]         c_ctr;
  logic [KLEN_W-1:0]          rem [0:N-1];
  logic [KLEN_W-1:0]          k_steps_r;
  logic [31:0]                tiles_rem;                 // tiles left to drain into PE array
  logic [31:0]                b_tiles_rem;               // tiles left to fetch from weight SRAM
  logic [31:0]                bw_issued, bw_total;       // weight words requested / needed per tile
  logic [ADDR_W-1:0]          b_base_r;
  logic [LINE_W-1:0]          line_ctr;

  // ---------------------------------------------------------------- B fetch
  logic [LVL_W-1:0] lvl_max_b;
  always_comb begin
    lvl_max_b = '0;
    for (int k = 0; k < N; k++) if (lvl_b[k] > lvl_max_b) lvl_max_b = lvl_b[k];
  end
  wire b_room = (int'(lvl_max_b) + 2 <= FIF_DEPTH);

  assign buf_req_b  = run & (b_tiles_rem != 0) & (bw_issued < bw_total) & b_room;
  assign buf_addr_b = b_base_r + bw_issued[ADDR_W-1:0];

  // ----------------------------------------------------------------- A pop
  assign src_a_pop = run & src_a_valid & ~(|fifo_full_a);

  // ------------------------------------------------- write side (A and B)
  always_comb begin
    for (int k = 0; k < N; k++) begin
      fifo_din_a[k] = src_a[W*k +: W];
      fifo_din_b[k] = '0;
    end
    fifo_wen_a = {N{src_a_pop}};
    fifo_wen_b = '0;
    if (buffer_in_valid_b) begin
      for (int i = 0; i < B; i++) begin
        fifo_din_b[line_ctr*B+i] = buffer_in_b[W*i +: W];
        fifo_wen_b[line_ctr*B+i] = 1'b1;
      end
    end
  end

  // --------------------------------------- read side: stagger + freeze logic
  logic [N-1:0] act;
  logic any_act, need_fail, all_rem_zero;
  always_comb begin
    all_rem_zero = 1'b1;
    for (int k = 0; k < N; k++) begin
      act[k] = run && (int'(c_ctr) >= k) && (rem[k] != '0);
      if (rem[k] != '0) all_rem_zero = 1'b0;
    end
    any_act    = |act;
    need_fail  = |(act & (fifo_empty_a | fifo_empty_b));
    adv        = ~(any_act & need_fail) & ~hold;
    fifo_ren_a = act & {N{adv}};
    fifo_ren_b = act & {N{adv}};
  end

  assign feed_done = run & all_rem_zero & (tiles_rem == 32'd1);
  assign busy      = run;

  // ---------------------------------------------------------- sequential
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      run <= 1'b0; c_ctr <= '0; bw_issued <= '0; bw_total <= '0; b_base_r <= '0;
      line_ctr <= '0; k_steps_r <= '0; tiles_rem <= '0; b_tiles_rem <= '0;
      for (int k = 0; k < N; k++) rem[k] <= '0;
      fifo_out_valid_a <= '0;
      fifo_out_valid_b <= '0;
    end else begin
      if (adv) begin
        fifo_out_valid_a <= fifo_ren_a;
        fifo_out_valid_b <= fifo_ren_b;
      end

      if (buffer_in_valid_b) line_ctr <= (line_ctr == LINE_W'(LINES-1)) ? '0 : line_ctr + 1'b1;

      if (start) begin
        run              <= 1'b1;
        c_ctr            <= '0;
        line_ctr         <= '0;
        bw_issued        <= '0;
        bw_total         <= (KLEN_W+LINE_W+1)'(k_steps) * (KLEN_W+LINE_W+1)'(LINES);
        b_base_r         <= b_base;
        k_steps_r        <= k_steps;
        tiles_rem        <= eff_tiles;
        b_tiles_rem      <= eff_tiles;
        fifo_out_valid_a <= '0;
        fifo_out_valid_b <= '0;
        for (int k = 0; k < N; k++) rem[k] <= k_steps;
      end else if (run) begin
        // Weight fetch counter (replays weights from b_base_r for each spatial tile)
        if (buf_req_b) begin
          if (bw_issued + 1'b1 == bw_total) begin
            bw_issued   <= '0;
            b_tiles_rem <= b_tiles_rem - 1'b1;
          end else begin
            bw_issued <= bw_issued + 1'b1;
          end
        end

        // Staggered drain into PE array
        if (adv & any_act) begin
          if (int'(c_ctr) < N-1) c_ctr <= c_ctr + 1'b1;
          for (int k = 0; k < N; k++) if (fifo_ren_a[k]) rem[k] <= rem[k] - 1'b1;
        end

        // End of current tile
        if (all_rem_zero) begin
          if (tiles_rem <= 32'd1) begin
            run       <= 1'b0;
            tiles_rem <= '0;
          end else begin
            tiles_rem <= tiles_rem - 1'b1;
            c_ctr     <= '0;
            for (int k = 0; k < N; k++) rem[k] <= k_steps_r;
          end
        end
      end
    end
  end

  always_comb begin
    for (int k = 0; k < FIF_LINES; k++) begin
      fifo_out_a[k] = fifo_dout_a[k];
      fifo_out_b[k] = fifo_dout_b[k];
    end
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
