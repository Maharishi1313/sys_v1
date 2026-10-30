`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module maxpool_inline #(
    parameter MAX_DL_WORDS = 56 
)(
    input  logic clk, 
    input  logic rst_n, 
    input  logic start,
    
    input  logic [31:0] oc_base,     
    input  logic [15:0] cfg_pool_x_chunks, 
    input  logic [15:0] cfg_pool_y_rows,   
    input  logic [3:0]  cfg_pool_stride,   
    input  logic        cfg_pool_nopad,    // 0: 3x3 pad 1 (window centred on even conv pixels)
                                           // 1: 3x3 pad 0 (window 2i..2i+2, SqueezeNet-style)
    input  logic signed [7:0] pad_val,     

    input  logic [31:0] in_data,
    input  logic        in_val,
    input  logic [1:0]  in_c,        

    output logic [31:0] out_data,
    output logic [31:0] out_addr,
    output logic        out_val,
    output logic [1:0]  out_ch          // channel (0..3 of the pass) of out_data
);
    // -------------------------------------------------------------------------
    // 1. Dynamic Delay Lines & Flush Controller
    // -------------------------------------------------------------------------
    logic [31:0] dl_W1 [0:(MAX_DL_WORDS*4)-1];
    logic [31:0] dl_W0 [0:(MAX_DL_WORDS*4)-1];

    logic [31:0] processed_chunks;
    logic [15:0] flush_cnt;
    wire [31:0]  total_chunks = cfg_pool_x_chunks * cfg_pool_y_rows * 4;
    wire         is_flushing  = (flush_cnt > 0);
    wire         active_val   = in_val || is_flushing;
    wire [31:0]  safe_in_data = is_flushing ? {4{pad_val}} : in_data;

    always_ff @(posedge clk) begin
        if (start) begin
            processed_chunks <= 0;
            flush_cnt <= 0;
        end else begin
            if (in_val) begin
                processed_chunks <= processed_chunks + 1;
                // FIX: Flush one full row (X_chunks * 4 channels) to push the final Y row through,
                // plus one chunk: a window is emitted while its right neighbour chunk streams in,
                // so the last chunk of the last row (centre = last conv row in no-pad mode)
                // needs the first chunk of the row after the ghost row.
                if (processed_chunks == total_chunks - 1) flush_cnt <= cfg_pool_x_chunks * 4 + 4;
            end else if (flush_cnt > 0) begin
                flush_cnt <= flush_cnt - 1;
            end
        end
    end

    logic [1:0]  c_cnt; 
    logic [15:0] x_cnt, y_cnt; 
    wire  [15:0] x_limit = cfg_pool_x_chunks - 1;

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            c_cnt <= 0; x_cnt <= 0; y_cnt <= 0;
        end else if (active_val) begin
            if (c_cnt == 3) begin
                c_cnt <= 0;
                if (x_cnt == x_limit) begin
                    x_cnt <= 0;
                    y_cnt <= y_cnt + 1; // FIX: Uncapped Y so it enters the ghost row
                end else x_cnt <= x_cnt + 1;
            end else c_cnt <= c_cnt + 1;
        end
    end

    logic [15:0] dl_ptr;
    wire  [15:0] ptr_limit = (cfg_pool_x_chunks * 4) - 1;
    always_ff @(posedge clk) begin
        if (!rst_n || start) dl_ptr <= 0;
        else if (active_val) dl_ptr <= (dl_ptr == ptr_limit) ? 0 : dl_ptr + 1;
    end

    // -------------------------------------------------------------------------
    // 2. Per-Channel X-Shift Registers
    // -------------------------------------------------------------------------
    logic [31:0] C2[0:3], C1[0:3], C0[0:3];
    logic [31:0] P2[0:3], P1[0:3], P0[0:3];

    always_ff @(posedge clk) begin
        if (active_val) begin
            C2[c_cnt] <= safe_in_data;
            C1[c_cnt] <= dl_W1[dl_ptr];
            C0[c_cnt] <= dl_W0[dl_ptr];
            P2[c_cnt] <= C2[c_cnt];
            P1[c_cnt] <= C1[c_cnt];
            P0[c_cnt] <= C0[c_cnt];
            
            dl_W1[dl_ptr] <= safe_in_data;
            dl_W0[dl_ptr] <= dl_W1[dl_ptr];
        end
    end

    // -------------------------------------------------------------------------
    // 3. Pipeline Stage 1: Math Extraction & Padding
    // -------------------------------------------------------------------------
    logic [31:0] s2_N2, s2_N1, s2_N0;
    logic [31:0] s2_C2, s2_C1, s2_C0;
    logic [31:0] s2_P2, s2_P1, s2_P0;
    logic [15:0] s2_cx, s2_cy;
    logic [1:0]  s2_c;
    logic        s2_val;

    always_ff @(posedge clk) begin
        s2_val <= active_val;
        if (active_val) begin
            s2_N2 <= safe_in_data;  s2_N1 <= dl_W1[dl_ptr]; s2_N0 <= dl_W0[dl_ptr];
            s2_C2 <= C2[c_cnt];     s2_C1 <= C1[c_cnt];     s2_C0 <= C0[c_cnt];
            s2_P2 <= P2[c_cnt];     s2_P1 <= P1[c_cnt];     s2_P0 <= P0[c_cnt];
            
            s2_cx <= (x_cnt == 0) ? cfg_pool_x_chunks - 1 : x_cnt - 1;
            s2_cy <= (x_cnt == 0) ? y_cnt - 2 : y_cnt - 1;
            s2_c  <= c_cnt;
        end
    end

    logic [31:0] E_N2, E_N1, E_N0, E_C2, E_C1, E_C0, E_P2, E_P1, E_P0;
    always_comb begin
        E_C2 = s2_C2; E_C1 = s2_C1; E_C0 = s2_C0;
        
        // X-Boundary Padding
        E_P2 = (s2_cx == 0) ? {4{pad_val}} : s2_P2;
        E_P1 = (s2_cx == 0) ? {4{pad_val}} : s2_P1;
        E_P0 = (s2_cx == 0) ? {4{pad_val}} : s2_P0;
        E_N2 = (s2_cx == cfg_pool_x_chunks - 1) ? {4{pad_val}} : s2_N2;
        E_N1 = (s2_cx == cfg_pool_x_chunks - 1) ? {4{pad_val}} : s2_N1;
        E_N0 = (s2_cx == cfg_pool_x_chunks - 1) ? {4{pad_val}} : s2_N0;

        // Y-Boundary Padding
        if (s2_cy == 16'hFFFF || s2_cy == 0) begin 
            E_P0 = {4{pad_val}}; E_C0 = {4{pad_val}}; E_N0 = {4{pad_val}};
        end
        if (s2_cy >= cfg_pool_y_rows - 1) begin 
            E_P2 = {4{pad_val}}; E_C2 = {4{pad_val}}; E_N2 = {4{pad_val}};
        end
    end

    function automatic logic signed [7:0] max9(
        input logic signed [7:0] d1, d2, d3, d4, d5, d6, d7, d8, d9
    );
        logic signed [7:0] m1, m2, m3, m4, m5, m6, m7;
        m1 = (d1 > d2) ? d1 : d2; m2 = (d3 > d4) ? d3 : d4;
        m3 = (d5 > d6) ? d5 : d6; m4 = (d7 > d8) ? d7 : d8;
        m5 = (m1 > m2) ? m1 : m2; m6 = (m3 > m4) ? m3 : m4;
        m7 = (m5 > m6) ? m5 : m6; return (m7 > d9) ? m7 : d9;
    endfunction

    logic signed [7:0] max0, max1, max2, max3;
    always_comb begin
        // FIX: Explicit $signed casts prevent zero-extension of partial 8-bit slices
        max0 = max9($signed(E_P0[31:24]), $signed(E_C0[7:0]), $signed(E_C0[15:8]), $signed(E_P1[31:24]), $signed(E_C1[7:0]), $signed(E_C1[15:8]), $signed(E_P2[31:24]), $signed(E_C2[7:0]), $signed(E_C2[15:8]));
        max1 = max9($signed(E_C0[7:0]), $signed(E_C0[15:8]), $signed(E_C0[23:16]), $signed(E_C1[7:0]), $signed(E_C1[15:8]), $signed(E_C1[23:16]), $signed(E_C2[7:0]), $signed(E_C2[15:8]), $signed(E_C2[23:16]));
        max2 = max9($signed(E_C0[15:8]), $signed(E_C0[23:16]), $signed(E_C0[31:24]), $signed(E_C1[15:8]), $signed(E_C1[23:16]), $signed(E_C1[31:24]), $signed(E_C2[15:8]), $signed(E_C2[23:16]), $signed(E_C2[31:24]));
        max3 = max9($signed(E_C0[23:16]), $signed(E_C0[31:24]), $signed(E_N0[7:0]), $signed(E_C1[23:16]), $signed(E_C1[31:24]), $signed(E_N1[7:0]), $signed(E_C2[23:16]), $signed(E_C2[31:24]), $signed(E_N2[7:0]));
    end

    // -------------------------------------------------------------------------
    // 4. SRAM Packing (Dynamic Stride)
    // -------------------------------------------------------------------------
    logic [15:0] hold_reg [0:3];
    logic [31:0] out_addr_cnt [0:3];
    wire  [31:0] out_words_per_ch = (cfg_pool_stride == 2) ? (cfg_pool_x_chunks / 2) * (cfg_pool_y_rows / 2) : (cfg_pool_x_chunks) * (cfg_pool_y_rows);

    always_ff @(posedge clk) begin
        if (!rst_n) out_val <= 0;
        else if (start) begin
            out_val <= 0;
            for(int i=0; i<4; i++) out_addr_cnt[i] <= (oc_base + i) * out_words_per_ch;
        end else begin
            out_val <= 0;
            if (s2_val && s2_cy < cfg_pool_y_rows) begin
                if (cfg_pool_stride == 2) begin
                    // stride-2 outputs sit on even window centres (pad 1) or odd
                    // ones (pad 0): pixels 0/2 of a word vs pixels 1/3
                    if (s2_cy[0] == cfg_pool_nopad) begin 
                        if (s2_cx[0] == 0) begin 
                            hold_reg[s2_c] <= cfg_pool_nopad ? {max3, max1} : {max2, max0};
                        end else begin 
                            out_data <= cfg_pool_nopad ? {max3, max1, hold_reg[s2_c]}
                                                       : {max2, max0, hold_reg[s2_c]};
                            out_ch   <= s2_c;
                            out_addr <= out_addr_cnt[s2_c];
                            out_val  <= 1;
                            out_addr_cnt[s2_c] <= out_addr_cnt[s2_c] + 1;
                        end
                    end
                end else begin 
                    out_data <= {max3, max2, max1, max0};
                    out_ch   <= s2_c;
                    out_addr <= out_addr_cnt[s2_c];
                    out_val  <= 1;
                    out_addr_cnt[s2_c] <= out_addr_cnt[s2_c] + 1;
                end
            end
        end
    end
endmodule
