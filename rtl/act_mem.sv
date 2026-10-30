`timescale 1ns / 1ps

// =============================================================================
//  act_mem : unified activation memory (replaces ping_pong_buffer + ifmap_axi_wrapper)
//
//  NBANK sub-banks of BANK_WORDS 32-bit words (default 5 x 8192 = 160 KB), one address
//  space.  The old bank A / bank B windows are simply the two halves:
//      AXI 0x6000_0000 + 4*w   <->   word w        (bank A = w < 20480, bank B = w >= 20480)
//
//  Every sub-bank is simple dual-port (1 read + 1 write port per cycle, the FPGA BRAM /
//  2-port SRAM primitive).  Requesters:
//    * compute read  (feeder)      fixed 1-cycle latency, never stalled
//    * compute write (out_writer)  never stalled; if it collides with an AXI write beat
//      on the same sub-bank it waits in a small in-order queue (CQ_DEPTH) and is
//      committed on the next free cycle (cq_overflow flags a too-small queue)
//    * AXI4 slave (camera front end, sys-DMA, SPI, controller), INCR bursts, one
//      transaction per direction at a time.  W beats are never back-pressured (the
//      interconnect's W path mis-handles WREADY dropping inside a burst: a beat got
//      duplicated); R beats wait while compute reads the same sub-bank.
//  So the camera can fill one region while the engine computes on another.
// =============================================================================
module act_mem #(
    parameter ADDR_W     = 32,
    parameter ID_W       = 6,
    parameter BANK_WORDS = 8192,
    parameter NBANK      = 5,          // peek/poke below are written for up to 5 banks
    parameter WIN_BITS   = 29,         // byte-offset bits of the slave window (0x6000_0000/3 bits)
    parameter CQ_DEPTH   = 16,         // queued compute writes (collisions with AXI writes)
    localparam WORDS     = BANK_WORDS * NBANK,
    localparam AW        = $clog2(WORDS),
    localparam BW        = $clog2(BANK_WORDS)
)(
    input  logic              clk,
    input  logic              rst_n,

    // ---- AXI4 slave ----
    input  logic [ID_W-1:0]   s_awid,
    input  logic [ADDR_W-1:0] s_awaddr,
    input  logic [7:0]        s_awlen,
    input  logic              s_awvalid,
    output logic              s_awready,
    input  logic [31:0]       s_wdata,
    input  logic              s_wlast,
    input  logic              s_wvalid,
    output logic              s_wready,
    output logic [ID_W-1:0]   s_bid,
    output logic [1:0]        s_bresp,
    output logic              s_bvalid,
    input  logic              s_bready,
    input  logic [ID_W-1:0]   s_arid,
    input  logic [ADDR_W-1:0] s_araddr,
    input  logic [7:0]        s_arlen,
    input  logic              s_arvalid,
    output logic              s_arready,
    output logic [ID_W-1:0]   s_rid,
    output logic [31:0]       s_rdata,
    output logic [1:0]        s_rresp,
    output logic              s_rlast,
    output logic              s_rvalid,
    input  logic              s_rready,

    // ---- compute ports (word addresses) ----
    input  logic [AW-1:0]     c_raddr,
    input  logic              c_ren,
    output logic [31:0]       c_rdata,
    output logic              c_rvalid,
    input  logic [AW-1:0]     c_waddr,
    input  logic              c_wen,
    input  logic [31:0]       c_wdata,
    output logic              cq_overflow   // sticky: compute write lost (queue too small)
);
    function automatic int unsigned bank_of(input logic [AW-1:0] a);
        return a / BANK_WORDS;
    endfunction

    // ------------------------------------------------------------ AXI write side
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} w_st_t;
    w_st_t       w_st;
    logic [AW:0] w_ptr;                         // one extra bit: out-of-range detection
    wire  [AW-1:0] w_word = w_ptr[AW-1:0];
    wire         w_inrange = (w_ptr < WORDS);
    wire         a_we = (w_st == W_DATA) && s_wvalid && s_wready && w_inrange;

    assign s_awready = (w_st == W_IDLE);
    assign s_wready  = (w_st == W_DATA);

    // ------------------------------------------------------------ compute write queue
    // A compute write goes straight to its sub-bank unless an AXI beat uses that bank
    // this cycle or older compute writes are still queued (keeps them in order).
    logic [AW-1:0] cq_addr [0:CQ_DEPTH-1];
    logic [31:0]   cq_data [0:CQ_DEPTH-1];
    logic [$clog2(CQ_DEPTH):0] cq_cnt;
    logic [$clog2(CQ_DEPTH)-1:0] cq_rd, cq_wr;
    wire           cq_empty  = (cq_cnt == 0);
    wire  [AW-1:0] cq_haddr  = cq_addr[cq_rd];
    wire           cq_pop    = !cq_empty && !(a_we && bank_of(w_word) == bank_of(cq_haddr));
    wire           c_direct  = c_wen && cq_empty && !(a_we && bank_of(w_word) == bank_of(c_waddr));
    wire           c_push    = c_wen && !c_direct;
    // the compute write that owns a bank port this cycle (queued head, else direct)
    wire           cw_en     = cq_pop || c_direct;
    wire  [AW-1:0] cw_addr   = cq_pop ? cq_haddr        : c_waddr;
    wire  [31:0]   cw_data   = cq_pop ? cq_data[cq_rd]  : c_wdata;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cq_cnt <= '0; cq_rd <= '0; cq_wr <= '0; cq_overflow <= 1'b0;
        end else begin
            if (c_push) begin
                if (cq_cnt == CQ_DEPTH && !cq_pop) cq_overflow <= 1'b1;
                else begin
                    cq_addr[cq_wr] <= c_waddr;
                    cq_data[cq_wr] <= c_wdata;
                    cq_wr <= cq_wr + 1'b1;
                end
            end
            if (cq_pop) cq_rd <= cq_rd + 1'b1;
            cq_cnt <= cq_cnt + (c_push && !(cq_cnt == CQ_DEPTH && !cq_pop) ? 1 : 0) - (cq_pop ? 1 : 0);
        end
    end
    assign s_bresp   = 2'b00;
    assign s_bvalid  = (w_st == W_RESP);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_st <= W_IDLE; w_ptr <= '0; s_bid <= '0;
        end else begin
            case (w_st)
            W_IDLE: if (s_awvalid) begin
                if (s_awaddr[WIN_BITS-1:2] >= WORDS) w_ptr <= {1'b1, {AW{1'b0}}};
                else                                 w_ptr <= {1'b0, s_awaddr[AW+1:2]};
                s_bid <= s_awid;
                w_st  <= W_DATA;
            end
            W_DATA: if (s_wvalid && s_wready) begin
                if (w_inrange) w_ptr <= w_ptr + 1'b1;
                if (s_wlast) w_st <= W_RESP;
            end
            W_RESP: if (s_bready) w_st <= W_IDLE;
            default: w_st <= W_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------ AXI read side
    // one beat in flight: issue -> bank read -> capture into the R register
    typedef enum logic [1:0] {R_IDLE, R_DATA} r_st_t;
    r_st_t       r_st;
    logic [AW:0] r_ptr;
    logic [7:0]  r_left;
    logic        a_issue_q, a_rvalid_q;
    logic [$clog2(NBANK)-1:0] a_rbank_q;
    wire  [AW-1:0] r_word = r_ptr[AW-1:0];
    wire         r_inrange = (r_ptr < WORDS);
    wire         r_conflict = c_ren && (bank_of(c_raddr) == bank_of(r_word));
    wire         a_issue = (r_st == R_DATA) && !s_rvalid && !a_issue_q && !r_conflict;
    wire         a_re    = a_issue && r_inrange;

    assign s_arready = (r_st == R_IDLE) && !s_rvalid;
    assign s_rresp   = 2'b00;

    // ------------------------------------------------------------ sub-banks
    logic [31:0] dout [0:NBANK-1];
    logic [$clog2(NBANK)-1:0] c_rbank_q;

    for (genvar b = 0; b < NBANK; b++) begin : g_bank
        logic [31:0] mem [0:BANK_WORDS-1];
        wire          a_hit = a_we && bank_of(w_word) == b;
        wire          we   = a_hit || (cw_en && bank_of(cw_addr) == b);
        wire [BW-1:0] wa   = a_hit ? BW'(w_word % BANK_WORDS) : BW'(cw_addr % BANK_WORDS);
        wire [31:0]   wd   = a_hit ? s_wdata : cw_data;
        wire          re   = (c_ren && bank_of(c_raddr) == b) || (a_re && bank_of(r_word) == b);
        wire [BW-1:0] ra   = (c_ren && bank_of(c_raddr) == b) ? BW'(c_raddr % BANK_WORDS)
                                                               : BW'(r_word % BANK_WORDS);
        always_ff @(posedge clk) begin
            if (we) mem[wa] <= wd;
            if (re) dout[b] <= mem[ra];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_rvalid <= 1'b0; c_rbank_q <= '0;
            r_st <= R_IDLE; r_ptr <= '0; r_left <= '0; a_issue_q <= 1'b0; a_rvalid_q <= 1'b0; a_rbank_q <= '0;
            s_rvalid <= 1'b0; s_rlast <= 1'b0; s_rdata <= '0; s_rid <= '0;
        end else begin
            c_rvalid <= c_ren;
            if (c_ren) c_rbank_q <= $clog2(NBANK)'(bank_of(c_raddr));

            a_issue_q  <= a_issue;
            a_rvalid_q <= a_re;
            if (a_issue) a_rbank_q <= $clog2(NBANK)'(bank_of(r_word));
            if (a_issue_q) begin
                s_rvalid <= 1'b1;
                s_rdata  <= a_rvalid_q ? dout[a_rbank_q] : 32'h0;   // out of range reads 0
            end else if (s_rvalid && s_rready) begin
                s_rvalid <= 1'b0;
                if (s_rlast) r_st <= R_IDLE;
            end

            case (r_st)
            R_IDLE: if (s_arvalid && s_arready) begin
                if (s_araddr[WIN_BITS-1:2] >= WORDS) r_ptr <= {1'b1, {AW{1'b0}}};
                else                                 r_ptr <= {1'b0, s_araddr[AW+1:2]};
                r_left <= s_arlen;
                s_rid  <= s_arid;
                r_st   <= R_DATA;
            end
            R_DATA: if (a_issue) begin
                if (r_inrange) r_ptr <= r_ptr + 1'b1;
                s_rlast <= (r_left == 8'd0);
                r_left  <= r_left - 8'd1;
            end
            default: ;
            endcase
        end
    end

    assign c_rdata = dout[c_rbank_q];

    // ------------------------------------------------------------ testbench access
    function automatic logic [31:0] peek(input int unsigned a);
        logic [31:0] v;
        v = 'x;
        case (a / BANK_WORDS)
            0: v = g_bank[0].mem[a % BANK_WORDS];
            1: v = g_bank[1].mem[a % BANK_WORDS];
            2: v = g_bank[2].mem[a % BANK_WORDS];
            3: v = g_bank[3].mem[a % BANK_WORDS];
            4: v = g_bank[4].mem[a % BANK_WORDS];
            default: ;
        endcase
        return v;
    endfunction
    task automatic poke(input int unsigned a, input logic [31:0] v);
        case (a / BANK_WORDS)
            0: g_bank[0].mem[a % BANK_WORDS] = v;
            1: g_bank[1].mem[a % BANK_WORDS] = v;
            2: g_bank[2].mem[a % BANK_WORDS] = v;
            3: g_bank[3].mem[a % BANK_WORDS] = v;
            4: g_bank[4].mem[a % BANK_WORDS] = v;
            default: ;
        endcase
    endtask
endmodule
