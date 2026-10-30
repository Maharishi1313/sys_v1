// =============================================================================
//  ifmap_feeder : on-the-fly im2col  (adapted from ifmap_feeder_lite)
//
//  Reads the picture from the ifmap buffer ONE WORD AT A TIME and builds, for
//  every array row (lane) y, the stream of values that row needs:
//        lane y  <-  the window of output pixel (x0 + y*stride)
//
//  Differences from the earlier 'lite' version:
//    * NO skew chain.  Skewing is done by YOUR fifo_controller (staggered reads).
//    * The queue head of every lane is exposed (o_head) + o_ready; a single
//      i_pop moves ALL lanes together (lock-step), so the lanes always stay
//      aligned.
//
//  Element numbering:  e = (channel*PLANE + row*ROWSTRIDE + col), column fastest.
//  One buffer word holds BUS_N consecutive elements, element i = word[i*DATA_W +: DATA_W].
//  The buffer must answer with a fixed latency of ONE clock.
// =============================================================================
// module ifmap_feeder #(
//     parameter Y       = 4,
//     parameter DATA_W  = 8,
//     parameter BUS_N   = 4,    // power of 2
//     parameter IDX_W   = 16,
//     parameter PAT_W   = 16,
//     parameter QDEPTH  = 16    // power of 2, needs >= 2*BUS_N + KW
// )(
//     input  wire                 clk,
//     input  wire                 rst_n,

//     input  wire                 start,
//     input  wire [IDX_W-1:0]     cfg_base,     // element index of lane 0's first value
//     input  wire [IDX_W-1:0]     cfg_chstep,   // elements between channel planes
//     input  wire [IDX_W-1:0]     cfg_ystep,    // elements between kernel rows (dil_y * row stride)
//     input  wire [IDX_W-1:0]     cfg_nch,      // channels to reduce
//     input  wire [IDX_W-1:0]     cfg_nky,      // kernel rows
//     input  wire [IDX_W-1:0]     cfg_last,     // (Y-1)*stride + (KW-1)*dil_x
//     input  wire [7:0]           cfg_stride,
//     input  wire [PAT_W-1:0]     cfg_kpat,     // bit (k*dil_x) = 1 for k < KW
//     input  wire [IDX_W-1:0]     cfg_total,    // values per lane = nch*nky*KW

//     output wire [IDX_W-1:0]     sram_word_addr,
//     output wire                 sram_re,
//     input  wire [BUS_N*DATA_W-1:0] sram_rdata,

//     output wire                 o_ready,                 // every lane has a value
//     input  wire                 i_pop,                   // take one value from every lane
//     output wire [Y*DATA_W-1:0]  o_head,                  // lane y = o_head[y*DATA_W +: DATA_W]
//     output reg                  busy,
//     output reg                  done,
//     output wire                 o_deadlock
// );
//     localparam LOGB  = $clog2(BUS_N);
//     localparam PTR_W = $clog2(QDEPTH);

//     // ---------------- A. address generator ----------------
//     reg                run;
//     reg [IDX_W-1:0]    ch_cnt, ky_cnt, r_cnt;
//     reg [IDX_W-1:0]    ch_start, row_start;
//     wire               stall;

//     wire [LOGB-1:0]    off       = row_start[LOGB-1:0];
//     wire [IDX_W-1:0]   word_base = row_start >> LOGB;
//     wire [IDX_W-1:0]   r_max     = (cfg_last + {{(IDX_W-LOGB){1'b0}}, off}) >> LOGB;

//     wire issue = run & ~stall;
//     assign sram_re        = issue;
//     assign sram_word_addr = word_base + r_cnt;

//     always @(posedge clk) begin
//         if (!rst_n) begin
//             run <= 0; ch_cnt <= 0; ky_cnt <= 0; r_cnt <= 0; ch_start <= 0; row_start <= 0;
//         end else if (start) begin
//             run <= 1; ch_cnt <= 0; ky_cnt <= 0; r_cnt <= 0;
//             ch_start <= cfg_base; row_start <= cfg_base;
//         end else if (issue) begin
//             if (r_cnt == r_max) begin
//                 r_cnt <= 0;
//                 if (ky_cnt == cfg_nky - 1) begin
//                     ky_cnt <= 0;
//                     if (ch_cnt == cfg_nch - 1) run <= 0;
//                     else begin
//                         ch_cnt    <= ch_cnt + 1;
//                         ch_start  <= ch_start + cfg_chstep;
//                         row_start <= ch_start + cfg_chstep;
//                     end
//                 end else begin
//                     ky_cnt    <= ky_cnt + 1;
//                     row_start <= row_start + cfg_ystep;
//                 end
//             end else r_cnt <= r_cnt + 1;
//         end
//     end

//     reg              v_q;
//     reg [IDX_W-1:0]  r_q;
//     reg [LOGB-1:0]   off_q;
//     always @(posedge clk) begin
//         if (!rst_n) begin v_q <= 0; r_q <= 0; off_q <= 0; end
//         else begin
//             v_q <= issue;
//             if (issue) begin r_q <= r_cnt; off_q <= off; end
//         end
//     end

//     // ---------------- B. lane pick logic ----------------
//     //   shift   = r*BUS_N - off - y*stride
//     //   pick[i] = kpat[i + shift]      (0 outside the pattern)
//     reg [Y*BUS_N-1:0]   pick;
//     reg [PTR_W-1:0]     pos  [0:Y*BUS_N-1];
//     reg [PTR_W:0]       nwr  [0:Y-1];

//     integer y, i, n, sh, pidx, rq_i, off_i, st_i;
//     always @* begin
//         rq_i  = r_q;
//         off_i = off_q;
//         st_i  = cfg_stride;
//         for (y = 0; y < Y; y = y + 1) begin
//             n  = 0;
//             sh = rq_i*BUS_N - off_i - y*st_i;
//             for (i = 0; i < BUS_N; i = i + 1) begin
//                 pidx = i + sh;
//                 if (v_q && pidx >= 0 && pidx < PAT_W && cfg_kpat[pidx]) begin
//                     pick[y*BUS_N+i] = 1'b1;
//                     pos [y*BUS_N+i] = n;
//                     n = n + 1;
//                 end else begin
//                     pick[y*BUS_N+i] = 1'b0;
//                     pos [y*BUS_N+i] = 0;
//                 end
//             end
//             nwr[y] = n;
//         end
//     end

//     // ---------------- C. per-lane queue ----------------
//     reg [DATA_W-1:0] mem    [0:Y*QDEPTH-1];
//     reg [PTR_W-1:0]  wr_ptr [0:Y-1];
//     reg [PTR_W-1:0]  rd_ptr;
//     reg [PTR_W:0]    count  [0:Y-1];
//     reg [IDX_W-1:0]  pop_cnt;

//     reg              all_nonempty;
//     reg [PTR_W:0]    count_max;
//     integer          q;
//     always @* begin
//         all_nonempty = 1'b1;
//         count_max    = 0;
//         for (q = 0; q < Y; q = q + 1) begin
//             if (count[q] == 0)        all_nonempty = 1'b0;
//             if (count[q] > count_max) count_max    = count[q];
//         end
//     end
//     assign o_ready    = all_nonempty;
//     assign stall      = (count_max + 2*BUS_N > QDEPTH);
//     assign o_deadlock = stall & ~all_nonempty & ~v_q;

//     wire pop = i_pop & all_nonempty;

//     integer yy, ii;
//     always @(posedge clk) begin
//         if (!rst_n) begin
//             rd_ptr <= 0; pop_cnt <= 0; busy <= 0; done <= 0;
//             for (yy = 0; yy < Y; yy = yy + 1) begin wr_ptr[yy] <= 0; count[yy] <= 0; end
//         end else begin
//             done <= 1'b0;
//             if (start) begin
//                 rd_ptr <= 0; pop_cnt <= 0; busy <= 1'b1;
//                 for (yy = 0; yy < Y; yy = yy + 1) begin wr_ptr[yy] <= 0; count[yy] <= 0; end
//             end else begin
//                 for (yy = 0; yy < Y; yy = yy + 1) begin
//                     for (ii = 0; ii < BUS_N; ii = ii + 1)
//                         if (pick[yy*BUS_N+ii])
//                             mem[yy*QDEPTH + ((wr_ptr[yy] + pos[yy*BUS_N+ii]) & (QDEPTH-1))]
//                                 <= sram_rdata[ii*DATA_W +: DATA_W];
//                     wr_ptr[yy] <= wr_ptr[yy] + nwr[yy];
//                     count [yy] <= count[yy] + nwr[yy] - (pop ? 1 : 0);
//                 end
//                 if (pop) begin
//                     rd_ptr  <= rd_ptr + 1;
//                     pop_cnt <= pop_cnt + 1;
//                     if (pop_cnt + 1 == cfg_total) begin busy <= 1'b0; done <= 1'b1; end
//                 end
//             end
//         end
//     end

//     genvar g;
//     generate
//         for (g = 0; g < Y; g = g + 1) begin : head
//             assign o_head[g*DATA_W +: DATA_W] = mem[g*QDEPTH + rd_ptr];
//         end
//     endgenerate
// endmodule



// =============================================================================
//  ifmap_feeder : 5-Counter SAURIA On-the-Fly im2col Data Feeder
//
//  Implements all 5 Index Counters from Fornt et al. (IEEE TVLSI 2023, Sec II-B):
//    - 3 Intra-Context Counters: r_cnt (X words), ky_cnt (Y kernel rows), ch_cnt (Channels)
//    - 2 Inter-Context Counters: ctx_x_cnt (Tile X relocation), ctx_y_cnt (Tile Y relocation)
// =============================================================================
module ifmap_feeder #(
    parameter Y       = 4,
    parameter DATA_W  = 8,
    parameter BUS_N   = 4,    // power of 2
    parameter IDX_W   = 16,
    parameter PAT_W   = 16,
    parameter QDEPTH  = 16    // power of 2, needs >= 2*BUS_N + KW
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 start,
    input  wire [IDX_W-1:0]     cfg_base,        // initial base index (context 0,0)
    // --- 3 Intra-Context Counter Configs ---
    input  wire [IDX_W-1:0]     cfg_chstep,      // elements between channel planes
    input  wire [IDX_W-1:0]     cfg_ystep,       // elements between kernel rows (dil_y * row stride)
    input  wire [IDX_W-1:0]     cfg_nch,         // channels to reduce per tile
    input  wire [IDX_W-1:0]     cfg_nky,         // kernel rows
    input  wire [IDX_W-1:0]     cfg_last,        // (Y-1)*stride + (KW-1)*dil_x
    input  wire [7:0]           cfg_stride,
    input  wire [PAT_W-1:0]     cfg_kpat,        // bit (k*dil_x) = 1 for k < KW
    input  wire [IDX_W-1:0]     cfg_total,       // values per lane per context = nch*nky*KW
    // --- NEW: 2 Inter-Context (Tile Relocation) Counter Configs ---
    input  wire [IDX_W-1:0]     cfg_x_tile_step, // horizontal step to next context (e.g. Y*stride)
    input  wire [IDX_W-1:0]     cfg_y_tile_step, // vertical step to next context row (e.g. stride*ROWSTRIDE)
    input  wire [IDX_W-1:0]     cfg_ntx,         // number of horizontal contexts (tiles) >= 1
    input  wire [IDX_W-1:0]     cfg_nty,         // number of vertical contexts (tiles) >= 1

    output wire [IDX_W-1:0]     sram_word_addr,
    output wire                 sram_re,
    input  wire [BUS_N*DATA_W-1:0] sram_rdata,

    output wire                 o_ready,         // every lane has a value
    input  wire                 i_pop,           // take one value from every lane
    output wire [Y*DATA_W-1:0]  o_head,          // lane y = o_head[y*DATA_W +: DATA_W]
    output reg                  busy,
    output reg                  tile_pop_done,   // pulses at the end of EVERY context (cfg_total pops)
    output reg                  done,            // pulses when ALL (cfg_ntx * cfg_nty) contexts finish
    output wire                 o_deadlock
);
    localparam LOGB  = $clog2(BUS_N);
    localparam PTR_W = $clog2(QDEPTH);

    wire [IDX_W-1:0] eff_ntx = (cfg_ntx == 0) ? 16'd1 : cfg_ntx;
    wire [IDX_W-1:0] eff_nty = (cfg_nty == 0) ? 16'd1 : cfg_nty;

    // ---------------- A. 5-Counter Address Generator ----------------
    reg                run;
    // 3 Intra-context counters
    reg [IDX_W-1:0]    r_cnt, ky_cnt, ch_cnt;
    // 2 Inter-context relocation counters
    reg [IDX_W-1:0]    ctx_x_cnt, ctx_y_cnt;

    // Running base pointers for the 5-counter hierarchy
    reg [IDX_W-1:0]    ctx_y_start, ctx_x_start, ch_start, row_start;
    wire               stall;

    wire [LOGB-1:0]    off       = row_start[LOGB-1:0];
    wire [IDX_W-1:0]   word_base = row_start >> LOGB;
    wire [IDX_W-1:0]   r_max     = (cfg_last + {{(IDX_W-LOGB){1'b0}}, off}) >> LOGB;

    wire issue = run & ~stall;
    assign sram_re        = issue;
    assign sram_word_addr = word_base + r_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            run <= 0;
            r_cnt <= 0; ky_cnt <= 0; ch_cnt <= 0;
            ctx_x_cnt <= 0; ctx_y_cnt <= 0;
            ctx_y_start <= 0; ctx_x_start <= 0; ch_start <= 0; row_start <= 0;
        end else if (start) begin
            run <= 1;
            r_cnt <= 0; ky_cnt <= 0; ch_cnt <= 0;
            ctx_x_cnt <= 0; ctx_y_cnt <= 0;
            ctx_y_start <= cfg_base;
            ctx_x_start <= cfg_base;
            ch_start    <= cfg_base;
            row_start   <= cfg_base;
        end else if (issue) begin
            // Counter 1: Intra-row word counter (X-axis within Interest Region)
            if (r_cnt == r_max) begin
                r_cnt <= 0;
                // Counter 2: Kernel row counter (Y-axis within Interest Region)
                if (ky_cnt == cfg_nky - 1) begin
                    ky_cnt <= 0;
                    // Counter 3: Input channel counter (C-axis within Interest Region)
                    if (ch_cnt == cfg_nch - 1) begin
                        ch_cnt <= 0;
                        // Counter 4: Context X relocation (next horizontal tile)
                        if (ctx_x_cnt == eff_ntx - 1) begin
                            ctx_x_cnt <= 0;
                            // Counter 5: Context Y relocation (next vertical tile row)
                            if (ctx_y_cnt == eff_nty - 1) begin
                                run <= 0; // All contexts read!
                            end else begin
                                ctx_y_cnt   <= ctx_y_cnt + 1;
                                ctx_y_start <= ctx_y_start + cfg_y_tile_step;
                                ctx_x_start <= ctx_y_start + cfg_y_tile_step;
                                ch_start    <= ctx_y_start + cfg_y_tile_step;
                                row_start   <= ctx_y_start + cfg_y_tile_step;
                            end
                        end else begin
                            ctx_x_cnt   <= ctx_x_cnt + 1;
                            ctx_x_start <= ctx_x_start + cfg_x_tile_step;
                            ch_start    <= ctx_x_start + cfg_x_tile_step;
                            row_start   <= ctx_x_start + cfg_x_tile_step;
                        end
                    end else begin
                        ch_cnt    <= ch_cnt + 1;
                        ch_start  <= ch_start + cfg_chstep;
                        row_start <= ch_start + cfg_chstep;
                    end
                end else begin
                    ky_cnt    <= ky_cnt + 1;
                    row_start <= row_start + cfg_ystep;
                end
            end else begin
                r_cnt <= r_cnt + 1;
            end
        end
    end

    reg              v_q;
    reg [IDX_W-1:0]  r_q;
    reg [LOGB-1:0]   off_q;
    always @(posedge clk) begin
        if (!rst_n) begin v_q <= 0; r_q <= 0; off_q <= 0; end
        else begin
            v_q <= issue;
            if (issue) begin r_q <= r_cnt; off_q <= off; end
        end
    end

    // ---------------- B. lane pick logic ----------------
    reg [Y*BUS_N-1:0]   pick;
    reg [PTR_W-1:0]     pos  [0:Y*BUS_N-1];
    reg [PTR_W:0]       nwr  [0:Y-1];

    integer y, i, n, sh, pidx, rq_i, off_i, st_i;
    always @* begin
        rq_i  = r_q;
        off_i = off_q;
        st_i  = cfg_stride;
        for (y = 0; y < Y; y = y + 1) begin
            n  = 0;
            sh = rq_i*BUS_N - off_i - y*st_i;
            for (i = 0; i < BUS_N; i = i + 1) begin
                pidx = i + sh;
                if (v_q && pidx >= 0 && pidx < PAT_W && cfg_kpat[pidx]) begin
                    pick[y*BUS_N+i] = 1'b1;
                    pos [y*BUS_N+i] = n[PTR_W-1:0];
                    n = n + 1;
                end else begin
                    pick[y*BUS_N+i] = 1'b0;
                    pos [y*BUS_N+i] = 0;
                end
            end
            nwr[y] = n[PTR_W:0];
        end
    end

    // ---------------- C. per-lane queue ----------------
    reg [DATA_W-1:0] mem      [0:Y*QDEPTH-1];
    reg [PTR_W-1:0]  wr_ptr   [0:Y-1];
    reg [PTR_W-1:0]  rd_ptr;
    reg [PTR_W:0]    count    [0:Y-1];
    reg [IDX_W-1:0]  pop_cnt;       // Pops in current context (0 .. cfg_total-1)
    reg [2*IDX_W-1:0] ctx_pop_cnt;  // Contexts completed (0 .. eff_ntx*eff_nty - 1)
    wire [2*IDX_W-1:0] total_ctxs = eff_ntx * eff_nty;

    reg              all_nonempty;
    reg [PTR_W:0]    count_max;
    integer          q;
    always @* begin
        all_nonempty = 1'b1;
        count_max    = 0;
        for (q = 0; q < Y; q = q + 1) begin
            if (count[q] == 0)        all_nonempty = 1'b0;
            if (count[q] > count_max) count_max    = count[q];
        end
    end
    assign o_ready    = all_nonempty;
    assign stall      = (count_max + 2*BUS_N > QDEPTH);
    assign o_deadlock = stall & ~all_nonempty & ~v_q;

    wire pop = i_pop & all_nonempty;

    integer yy, ii;
    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr <= 0; pop_cnt <= 0; ctx_pop_cnt <= 0;
            busy <= 0; tile_pop_done <= 0; done <= 0;
            for (yy = 0; yy < Y; yy = yy + 1) begin wr_ptr[yy] <= 0; count[yy] <= 0; end
        end else begin
            tile_pop_done <= 1'b0;
            done          <= 1'b0;
            if (start) begin
                rd_ptr <= 0; pop_cnt <= 0; ctx_pop_cnt <= 0;
                busy <= 1'b1;
                for (yy = 0; yy < Y; yy = yy + 1) begin wr_ptr[yy] <= 0; count[yy] <= 0; end
            end else begin
                for (yy = 0; yy < Y; yy = yy + 1) begin
                    for (ii = 0; ii < BUS_N; ii = ii + 1)
                        if (pick[yy*BUS_N+ii])
                            mem[yy*QDEPTH + ((wr_ptr[yy] + pos[yy*BUS_N+ii]) & (QDEPTH-1))]
                                <= sram_rdata[ii*DATA_W +: DATA_W];
                    wr_ptr[yy] <= wr_ptr[yy] + nwr[yy][PTR_W-1:0];
                    count [yy] <= count[yy] + nwr[yy] - (pop ? 1'b1 : 1'b0);
                end
                if (pop) begin
                    rd_ptr <= rd_ptr + 1;
                    if (pop_cnt + 1 == cfg_total) begin
                        pop_cnt       <= 0;
                        tile_pop_done <= 1'b1;
                        if (ctx_pop_cnt + 1 == total_ctxs) begin
                            ctx_pop_cnt <= 0;
                            busy        <= 1'b0;
                            done        <= 1'b1;
                        end else begin
                            ctx_pop_cnt <= ctx_pop_cnt + 1;
                        end
                    end else begin
                        pop_cnt <= pop_cnt + 1;
                    end
                end
            end
        end
    end

    genvar g;
    generate
        for (g = 0; g < Y; g = g + 1) begin : head
            assign o_head[g*DATA_W +: DATA_W] = mem[g*QDEPTH + rd_ptr];
        end
    endgenerate
endmodule
