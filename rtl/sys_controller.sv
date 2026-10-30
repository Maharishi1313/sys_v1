// =============================================================================
//  sys_controller.sv
//
//  Standalone inference sequencer for the CNN accelerator SoC.
//  This module replaces any CPU.  It is instantiated as Master 0 (M0) on the
//  AXI4 interconnect inside accelerator_top.
//
//  Responsibilities
//  ────────────────
//  1.  On START: configure QSPI (XIP) and the DVP-RX core, arm cam_frontend
//      (crop + RGB565 -> int8 row-planar stripes straight into act_mem).
//  2.  Run the job list at once - a job (one layer, or one row-stripe of a layer)
//      can wait until the camera has written enough rows and can release a camera
//      stripe slot when it is done, so inference overlaps the frame capture.
//  3.  For each job ("layer") in the descriptor SRAM:
//        a.  Assert sys_axi_ctrl=1 so the weight SRAM AXI slave accepts writes.
//        b.  Issue a sys-DMA transfer: QSPI flash → weight SRAM.
//        c.  Poll TRANSFER_DONE until the DMA IRQ fires.
//        d.  Assert sys_axi_ctrl=0 so the compute engine owns the SRAMs.
//        e.  Drive all cfg_* and reqt_* wires from the current layer descriptor.
//        f.  Loop over the required number of 4-channel passes:
//              - Write pass-specific requant params directly to output wires.
//              - Pulse core_start for one clock.
//              - Wait for layer_done.
//              - Wait 64 extra clocks for the maxpool flush pipeline to drain.
//        g.  (activation addresses are absolute in act_mem - no bank flipping)
//  4.  After the last layer: optional classifier head (argmax of the per-class
//      sums of the final output maps, read back over AXI), then pulse
//      infer_done and return to idle until the next start.
//
//  AXI Write Helper
//  ────────────────
//  All register writes (DMA config, DVP config) go through a tiny internal
//  AXI4-lite write engine (m_aw/m_w/m_b channels).  It issues one word at a
//  time.  The module stalls in its current state until the write completes.
//
//  Address Map (from interconnect SLV_ID bits [31:29] in accelerator_top)
//  ────────────────────────────────────────────────────────────────────────
//  0x0000_0000  DVP subsystem (S0)
//    0x0000_0000  DVP-DMA registers (atfox272/dma, CHN0)
//    0x0001_0000  DVP-RX controller registers
//  0x2000_0000  QSPI controller (S1)
//  0x4000_0000  Sys-DMA registers (atfox272/dma, CHN0)  (S2)
//  0x6000_0000  Ping-pong SRAM  (S3)
//  0x8000_0000  Weight SRAM     (S4)
//  0xA000_0000  SPI slave / MCU (S5)
//
//  atfox272/dma register offsets  (axi4_ctrl CONF_OFFSET = 1 -> one AXI address per
//  register, i.e. address = BASE + WORD_INDEX, NOT x4; see adma_reg_map.v and
//  reference/tb_dvp_dma.sv)
//  ──────────────────────────────────────────────────────────────────
//  DMA global:
//    0x0000   DMA_CONTROL      [0]=ENABLE
//  Per-channel (channel c, channel offset = c << 4):
//    0x0001   CHN_CONTROL      [0]=ENABLE
//    0x0002   CHN_FLAGS        [0]=2D  [1]=CYCLIC
//    0x0003   CHN_IRQ_MASK     [0]=irq_complete  [1]=irq_queued
//    0x0004   CHN_ARBIT_RATE
//    0x0005   ATX_ID
//    0x0006   ATX_SRC_BURST    0=FIXED 1=INCR 2=WRAP
//    0x0007   ATX_DST_BURST
//    0x0008   ATX_WD_PER_BURST  words-per-burst minus 1
//    0x0009   SRC_ADDR         WORD address (the DMA AXI master is word addressed;
//    0x000A   DST_ADDR          accelerator_top shifts its AxADDR left by 2)
//    0x000B   TRANSFER_X_LEN   words in a row minus 1
//    0x000C   TRANSFER_Y_LEN   rows minus 1  (0 for 1-D)
//    0x000D   SRC_STRIDE       words between row starts (src)
//    0x000E   DST_STRIDE       words between row starts (dst)
//    0x1000   TRANSFER_SUBMIT  write any value to enqueue descriptor (channel c: + c<<4)
//    0x2000   CHN_IRQ_SOURCE   (RO)
//    0x2002   TRANSFER_DONE    bitmap (RO)
//
//  DVP-RX controller offsets (base 0x0001_0000, also one address per register):
//    +0x00 cam_en  +0x01 cam_pwdn  +0x02 rx_mode  +0x03 irq_mask
//    +0x04 img_w   +0x05 img_h     +0x06 proc_ctrl{downscale,grayscale}
//    +0x10 cam_rx_start (RW1S)
//
//  Layer descriptor / start register write port (cfg_we/cfg_addr/cfg_wdata)
//  ─────────────────────────────────────────────────────────────────────────
//  Stand-in for the MCU SPI slave (not integrated yet).  Byte addresses follow
//  the SoC memory-map document:
//    0xC000_0000 + layer*64 + word*4   descriptor word (16 words / layer)
//    0x1000_0000                       active_num_layers (non-zero starts the engine)
//  32 words (128 bytes) per layer: address = DESC_BASE + layer*128 + word*4.
//  W00..W15 follow the document, with fields the document leaves out (EXT):
//    W00 {flip_bank, n_passes[6:0], stride[7:0], kpat[15:0]}
//    W01..W10 base, chstep, ystep, nch, nky, last, x_tile_step, y_tile_step, ntx, nty
//    W11 reqt_total_tiles (unused by the datapath now, see W16..W20)
//    W12 {14'b0, relu_en(EXT), maxpool_en, pool_x_chunks[15:0]}
//    W13 {11'b0, pool_nopad(EXT), pool_stride[3:0], pool_y_rows[15:0]}
//    W14 flash_src_addr: byte offset of the layer's first pass block in the flash
//    W15 {6'b0, k_len[9:0](EXT), weight_words[15:0] (informative)}
//  Output placement (EXT, see out_writer.sv):
//    W16 out_base       [23:0]  words, inside the output bank
//    W17 out_ch_stride  [23:0]  words between channel frames
//    W18 {out_words_per_row[15:0], out_row_stride[15:0]}  words
//    W19 {14'b0, out_pad, ...}: [15:0] oc_off (channel offset, Fire concat), [16] out_pad
//    W20 {out_rows[15:0], out_valid_w[15:0]}   (valid_w 0 = no masking)
//  Weights / requant (EXT):
//    W21 {8'b0, n_passes[7:0] (overrides W00 if non-zero), z_out[7:0], passes_per_load[7:0]}
//        passes_per_load = pass blocks fetched per weight-DMA (0 = all); the compiler
//        picks the largest count whose (k_len + 12)-word blocks fit the weight SRAM
//    W22 [15:0] border_fill_channels: z_out-fill the borders of that many output frames
//        before the first pass (0 = none)
//  Row-streaming (EXT):
//    W23 [0] wait for the camera: the job starts when cam rows_done >= W24
//        [1] when the job ends, release one camera stripe slot (cam_frontend.consume)
//    W24 [15:0] camera rows needed
//    W25..W31 reserved
//  W00.flip_bank is ignored: activation addresses (W01 base, W16 out_base) are absolute
//  in act_mem (elements / words from 0x6000_0000).
//  Weight blob of a layer in flash: n_passes blocks of (k_len + 12) words:
//    k_len weight words {w[oc+3][t], .., w[oc][t]}, bias[4], mult[4], shift[4]
//
// =============================================================================

`timescale 1ns/1ps
`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module sys_controller #(
    parameter ADDR_W  = 32,
    parameter DATA_W  = 32,
    parameter ID_W    = 4,
    // ── Address bases ─────────────────────────────────────────────────────────
    // Interconnect decodes [31:29]; these are the base addresses for each slave.
    parameter [ADDR_W-1:0] DVP_BASE      = 32'h0000_0000, // S0 – DVP subsystem
    parameter [ADDR_W-1:0] QSPI_BASE     = 32'h2000_0000, // S1 – QSPI flash
    parameter [ADDR_W-1:0] SDMA_BASE     = 32'h4000_0000, // S2 – Sys-DMA
    parameter [ADDR_W-1:0] PPSRAM_BASE   = 32'h6000_0000, // S3 – activation memory (act_mem)
    parameter [ADDR_W-1:0] WSRAM_BASE    = 32'h8000_0000, // S4 – Weight SRAM
    // ── Sub-block offsets inside DVP_BASE ─────────────────────────────────────
    parameter [ADDR_W-1:0] DVPDMA_OFF    = 32'h0000_0000,
    parameter [ADDR_W-1:0] DVPDRC_OFF    = 32'h0001_0000,
    // ── DMA Channel Offsets (register index, 16 registers per channel) ───────
    parameter [ADDR_W-1:0] DMA_CH0_OFF   = 32'h0000_0000, // Weights
    // ── QSPI XIP setup (registers at QSPI_BASE + 0x0800_0000 + offset) ───────
    parameter [ADDR_W-1:0] QSPI_CFG_OFF  = 32'h0800_0000,
    parameter [31:0]       QSPI_CLKDIV   = 32'd0,        // SCK = clk / 2
    parameter [31:0]       QSPI_MODE     = 32'd2,        // 2 = QUAD
    parameter [31:0]       QSPI_DUMMY    = 32'd6,        // 0x6B: 6 here = 8 dummy SCK at the
                                                         // flash (as reference/tb_qspi_subsystem.sv)
    parameter [31:0]       QSPI_XIP_CMD  = 32'h6B,       // Fast Read Quad Output
    parameter [31:0]       QSPI_XIP_MASK = 32'hF800_0000,
    // ── Descriptor programming addresses (MCU view) ──────────────────────────
    parameter [ADDR_W-1:0] DESC_BASE     = 32'hC000_0000,
    parameter [ADDR_W-1:0] START_ADDR    = 32'h1000_0000,
    // ── Layer ROM dimensions ──────────────────────────────────────────────────
    parameter MAX_LAYERS  = 128          // descriptor slots (jobs), block RAM
)(
    input  logic clk,
    input  logic rst_n,

    // ── Descriptor / start programming (MCU stand-in, see header) ────────────
    input  logic              cfg_we,
    input  logic [ADDR_W-1:0] cfg_addr,
    input  logic [31:0]       cfg_wdata,

    // ── AXI4 Master (M0) – only write channel used for register programming ──
    output logic [ID_W-1:0]   m_awid,
    output logic [ADDR_W-1:0] m_awaddr,
    output logic [7:0]        m_awlen,
    output logic [2:0]        m_awsize,
    output logic [1:0]        m_awburst,
    output logic              m_awvalid,
    input  logic              m_awready,

    output logic [DATA_W-1:0] m_wdata,
    output logic [DATA_W/8-1:0] m_wstrb,
    output logic              m_wlast,
    output logic              m_wvalid,
    input  logic              m_wready,

    input  logic [ID_W-1:0]   m_bid,
    input  logic [1:0]        m_bresp,
    input  logic              m_bvalid,
    output logic              m_bready,

    // Read channel (tied off – we poll via registered IRQ lines instead)
    output logic [ID_W-1:0]   m_arid,
    output logic [ADDR_W-1:0] m_araddr,
    output logic [7:0]        m_arlen,
    output logic [2:0]        m_arsize,
    output logic [1:0]        m_arburst,
    output logic              m_arvalid,
    input  logic              m_arready,
    input  logic [ID_W-1:0]   m_rid,
    input  logic [DATA_W-1:0] m_rdata,
    input  logic [1:0]        m_rresp,
    input  logic              m_rlast,
    input  logic              m_rvalid,
    output logic              m_rready,

    // ── IRQ inputs ────────────────────────────────────────────────────────────
    input  logic [1:0]        sys_dma_irq,    // [0]=WLoad Done, [1]=Concat Done

    // ── Compute engine direct-wire control ───────────────────────────────────
    output logic              sys_axi_ctrl,   // 1 = AXI owns SRAMs, 0 = compute owns
    output logic              core_start,     // 1-cycle pulse
    output logic              flush_acc,
    output logic              cam_arm,          // 1-cycle: cam_frontend takes the next frame
    output logic              cam_consume,      // 1-cycle: a camera stripe slot is free again
    input  logic [15:0]       cam_rows_done,
    input  logic [15:0]       cam_frame_w,      // sensor frame size (DVP-RX img_w / img_h)
    input  logic [15:0]       cam_frame_h,
    input  logic              layer_done,

    // ── Compute engine configuration wires ───────────────────────────────────
    output logic [KLEN_W-1:0]           cfg_k_len,
    output logic [23:0]                 cfg_base,
    output logic [23:0]                 cfg_chstep,
    output logic [23:0]                 cfg_ystep,
    output logic [23:0]                 cfg_nch,
    output logic [23:0]                 cfg_nky,
    output logic [23:0]                 cfg_last,
    output logic [7:0]                  cfg_stride,
    output logic [15:0]                 cfg_kpat,
    output logic [23:0]                 cfg_x_tile_step,
    output logic [23:0]                 cfg_y_tile_step,
    output logic [23:0]                 cfg_ntx,
    output logic [23:0]                 cfg_nty,
    output logic [$clog2(WBUF_SIZE)-1:0] cfg_b_base,
    output logic [31:0]                 reqt_total_tiles,
    output logic [31:0]                 reqt_oc_base,
    output logic signed [31:0]          reqt_bias  [0:3],
    output logic signed [31:0]          reqt_mult  [0:3],
    output logic signed [31:0]          reqt_shift [0:3],
    output logic signed [7:0]           reqt_z_out,
    output logic                        reqt_relu_en,
    output logic                        cfg_maxpool_en,
    output logic [15:0]                 cfg_pool_x_chunks,
    output logic [15:0]                 cfg_pool_y_rows,
    output logic [3:0]                  cfg_pool_stride,
    output logic                        cfg_pool_nopad,
    output logic [23:0]                 cfg_out_base,
    output logic [23:0]                 cfg_out_ch_stride,
    output logic [15:0]                 cfg_out_row_stride,
    output logic [15:0]                 cfg_out_words_per_row,
    output logic                        cfg_out_pad,
    output logic [15:0]                 cfg_out_oc_off,
    output logic [15:0]                 cfg_out_valid_w,
    output logic [15:0]                 cfg_out_rows,
    output logic                        fill_start,
    output logic [15:0]                 fill_channels,
    input  logic                        fill_done,

    // ── Result / host interface ───────────────────────────────────────────────
    // ── Classifier head (argmax) configuration, from sys_csr ─────────────────
    input  logic [15:0]       head_classes,     // 0 = no head
    input  logic [15:0]       head_words,       // 32-bit words per class map
    input  logic [31:0]       head_base,        // byte offset inside the output bank

    output logic              infer_done,       // 1-cycle pulse at the end of an inference
    output logic              busy,
    output logic              result_valid,
    output logic [15:0]       result_class_id,
    output logic signed [31:0] result_score,
    output logic [7:0]        cur_layer,
    output logic [7:0]        cur_pass
);

// =============================================================================
//  Layer Descriptor SRAM [MODIFIED]
//  Each entry encodes one full CNN layer.  Extend this for multi-layer models.
//  Fields are laid out as one packed struct per layer.
//
//  For SqueezeNet Conv1: 3-input 24-output 3x3 conv, stride 2, with maxpool.
//  The requant params (bias/mult/shift/z_out) are stored per output channel
//  in the weight SRAM alongside the weight data; they're loaded per pass.
//  Here we store only the constant geometry and per-layer scalar params.
//
//  [MODIFIED] Converted from Initialized ROM to uninitialized SRAM structure.
//  The external MCU will write this via the SPI Slave AXI Master to program
//  the network descriptor before asserting a software start flag.
// =============================================================================

// Descriptor RAM: MAX_LAYERS jobs x 32 words, written by the MCU (cfg port), read
// one job at a time into cur_w[] (ST_JOB_LOAD).  A block RAM instead of ~600
// flip-flops per job: 128 jobs = 16 KB.
localparam DESC_WORDS = 25;                      // words 25..31 are reserved
logic [31:0] desc_mem [0:MAX_LAYERS*32-1];
logic [31:0] desc_q;
logic [$clog2(MAX_LAYERS*32)-1:0] desc_raddr;
logic [31:0] cur_w [0:DESC_WORDS-1];
logic [5:0]  ld_cnt;

// Total actual layers programmed (written by MCU)
logic [7:0]         active_num_layers;

wire                    desc_hit   = cfg_we && (cfg_addr[ADDR_W-1:16] == DESC_BASE[ADDR_W-1:16]);
wire [$clog2(MAX_LAYERS*32)-1:0] desc_waddr = cfg_addr[2 +: $clog2(MAX_LAYERS*32)];

always_ff @(posedge clk) begin
    if (desc_hit) desc_mem[desc_waddr] <= cfg_wdata;
    desc_q <= desc_mem[desc_raddr];
end
assign desc_raddr = {layer_idx[$clog2(MAX_LAYERS)-1:0], ld_cnt[4:0]};

// Fields of the current job (layout in the file header)
wire [7:0]          j_n_passes        = (cur_w[21][23:16] != 8'd0) ? cur_w[21][23:16] : {1'b0, cur_w[0][30:24]};
wire [7:0]          j_cfg_stride      = cur_w[0][23:16];
wire [15:0]         j_cfg_kpat        = cur_w[0][15:0];
wire [23:0]         j_cfg_base        = cur_w[1][23:0];
wire [23:0]         j_cfg_chstep      = cur_w[2][23:0];
wire [23:0]         j_cfg_ystep       = cur_w[3][23:0];
wire [23:0]         j_cfg_nch         = cur_w[4][23:0];
wire [23:0]         j_cfg_nky         = cur_w[5][23:0];
wire [23:0]         j_cfg_last        = cur_w[6][23:0];
wire [23:0]         j_cfg_x_tile_step = cur_w[7][23:0];
wire [23:0]         j_cfg_y_tile_step = cur_w[8][23:0];
wire [23:0]         j_cfg_ntx         = cur_w[9][23:0];
wire [23:0]         j_cfg_nty         = cur_w[10][23:0];
wire [31:0]         j_reqt_total_tiles= cur_w[11];
wire [15:0]         j_pool_x_chunks   = cur_w[12][15:0];
wire                j_maxpool_en      = cur_w[12][16];
wire                j_reqt_relu_en    = cur_w[12][17];
wire [15:0]         j_pool_y_rows     = cur_w[13][15:0];
wire [3:0]          j_pool_stride     = cur_w[13][19:16];
wire                j_pool_nopad      = cur_w[13][20];
wire [ADDR_W-1:0]   j_flash_src_addr  = cur_w[14];
wire [15:0]         j_weight_words    = cur_w[15][15:0];
wire [KLEN_W-1:0]   j_k_len           = cur_w[15][16 +: KLEN_W];
wire [23:0]         j_out_base        = cur_w[16][23:0];
wire [23:0]         j_out_cs          = cur_w[17][23:0];
wire [15:0]         j_out_rs          = cur_w[18][15:0];
wire [15:0]         j_out_wpr         = cur_w[18][31:16];
wire [15:0]         j_out_oc_off      = cur_w[19][15:0];
wire                j_out_pad         = cur_w[19][16];
wire [15:0]         j_out_valid_w     = cur_w[20][15:0];
wire [15:0]         j_out_rows        = cur_w[20][31:16];
wire [7:0]          j_ppl             = cur_w[21][7:0];
wire signed [7:0]   j_reqt_z_out      = cur_w[21][15:8];
wire [7:0]          j_fill_ch         = cur_w[22][7:0];
wire                j_wait_cam        = cur_w[23][0];
wire                j_consume         = cur_w[23][1];
wire [15:0]         j_cam_rows        = cur_w[24][15:0];

// =============================================================================
//  AXI4-Lite Write Engine
//  Issues single-word register writes on behalf of the FSM.
//  Usage: load wr_addr / wr_data, pulse wr_req, wait for wr_ack.
// =============================================================================
logic [ADDR_W-1:0] wr_addr;
logic [DATA_W-1:0] wr_data;
logic              wr_req;
logic              wr_ack;

typedef enum logic [1:0] {
    WR_IDLE,
    WR_AW,
    WR_W,
    WR_B
} wr_eng_state_t;

wr_eng_state_t wr_eng_st;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_eng_st  <= WR_IDLE;
        m_awvalid  <= 1'b0;
        m_wvalid   <= 1'b0;
        m_bready   <= 1'b0;
        wr_ack     <= 1'b0;
        m_awid     <= '0;
        m_awlen    <= 8'd0;
        m_awsize   <= 3'd2;    // 4 bytes
        m_awburst  <= 2'b01;   // INCR
        m_wstrb    <= 4'hF;
        m_wlast    <= 1'b1;    // always single-beat
    end else begin
        wr_ack <= 1'b0;
        case (wr_eng_st)
        WR_IDLE: begin
            m_awvalid <= 1'b0;
            m_wvalid  <= 1'b0;
            m_bready  <= 1'b0;
            if (wr_req) begin
                m_awaddr  <= wr_addr;
                m_wdata   <= wr_data;
                m_awvalid <= 1'b1;
                m_wvalid  <= 1'b1;
                wr_eng_st <= WR_AW;
            end
        end
        WR_AW: begin
            // AW and W handshakes are independent: a slave may take W before,
            // with, or after AW, so each valid drops on its own handshake.
            if (m_awready && m_awvalid) m_awvalid <= 1'b0;
            if (m_wready  && m_wvalid)  m_wvalid  <= 1'b0;
            if ((!m_awvalid || m_awready) && (!m_wvalid || m_wready)) begin
                m_bready  <= 1'b1;
                wr_eng_st <= WR_B;
            end
        end
        WR_W: wr_eng_st <= WR_AW;   // unused
        WR_B: begin
            // B received
            if (m_bvalid && m_bready) begin
                m_bready  <= 1'b0;
                wr_ack    <= 1'b1;
                wr_eng_st <= WR_IDLE;
            end
        end
        endcase
    end
end

// =============================================================================
//  AXI4-Lite Read Engine
//  Issues single-word reads for polling DMA status and loading reqt params.
//  Usage: load rd_addr, pulse rd_req, wait for rd_ack, read rd_rdata.
// =============================================================================
logic [ADDR_W-1:0] rd_addr;
logic              rd_req;
logic              rd_ack;
logic [DATA_W-1:0] rd_rdata;

typedef enum logic [1:0] {
    RD_IDLE,
    RD_AR,
    RD_R
} rd_eng_state_t;

rd_eng_state_t rd_eng_st;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_eng_st  <= RD_IDLE;
        m_arvalid  <= 1'b0;
        m_rready   <= 1'b0;
        rd_ack     <= 1'b0;
        m_arid     <= '0;
        m_arlen    <= 8'd0;
        m_arsize   <= 3'd2;
        m_arburst  <= 2'b01;
    end else begin
        rd_ack <= 1'b0;
        case (rd_eng_st)
        RD_IDLE: begin
            m_arvalid <= 1'b0;
            m_rready  <= 1'b0;
            if (rd_req) begin
                m_araddr  <= rd_addr;
                m_arvalid <= 1'b1;
                rd_eng_st <= RD_AR;
            end
        end
        RD_AR: begin
            if (m_arready && m_arvalid) begin
                m_arvalid <= 1'b0;
                m_rready  <= 1'b1;
                rd_eng_st <= RD_R;
            end
        end
        RD_R: begin
            if (m_rvalid && m_rready) begin
                rd_rdata  <= m_rdata;
                m_rready  <= 1'b0;
                rd_ack    <= 1'b1;
                rd_eng_st <= RD_IDLE;
            end
        end
        endcase
    end
end

// =============================================================================
//  Helper macros (as tasks) for common register-write sequences
// =============================================================================

// Write a single 32-bit word to an AXI address.
// In an always_ff FSM we implement this as a two-state sub-sequence:
// the caller asserts wr_req then waits for wr_ack.

// =============================================================================
//  Main FSM
// =============================================================================

typedef enum logic [5:0] {
    // ── Initialisation ───────────────────────────────────────────────────────
    ST_RESET,
    ST_WAIT_MCU_PROGRAM,        // [MODIFIED] Wait for MCU to signal SRAM ready
    // ── Configure QSPI controller for XIP (memory-mapped flash reads) ────────
    ST_QSPI_CLKDIV,
    ST_QSPI_MODE,
    ST_QSPI_DUMMY,
    ST_QSPI_XIP_BASE,
    ST_QSPI_XIP_MASK,
    ST_QSPI_XIP_CMD,
    ST_QSPI_XIP_CTRL,
    // ── Configure DVP-RX controller [MODIFIED OFFSETS] ──────────────────────
    ST_DVP_DRC_EN,              // 0x00 = cam_en
    ST_DVP_DRC_PWDN,            // 0x01 = cam_pwdn
    ST_DVP_DRC_MODE,            // 0x02 = rx_mode
    ST_DVP_DRC_IRQ,             // 0x03 = irq_mask
    ST_DVP_DRC_W,               // 0x04 = img_w
    ST_DVP_DRC_H,               // 0x05 = img_h (CHUNK HEIGHT)
    ST_DVP_DRC_PROC,            // 0x06 = proc_ctrl
    ST_DVP_DRC_START,           // 0x10 = cam_rx_start
    // ── Wait for a chunk to arrive ──────────────────────────────────────────
    ST_WAIT_CHUNK,              // start of the job list
    ST_WAIT_CAM,                // job waits for camera rows
    ST_JOB_LOAD,                // copy the job's descriptor words into cur_w
    // ── Layer loop ──────────────────────────────────────────────────────────
    // 6a. Gate SRAMs: sys_axi_ctrl = 1
    ST_LAYER_AXI_GATE,
    // 6b. Configure sys-DMA to load weights from QSPI flash into WSRAM
    ST_DMA_WLOAD_EN,
    ST_DMA_WLOAD_CHN_EN,
    ST_DMA_WLOAD_CHN_FLAGS,
    ST_DMA_WLOAD_IRQ_MASK,
    ST_DMA_WLOAD_ARBIT,
    ST_DMA_WLOAD_SRC_BURST,
    ST_DMA_WLOAD_DST_BURST,
    ST_DMA_WLOAD_WD_PER_BURST,
    ST_DMA_WLOAD_SRC_ADDR,
    ST_DMA_WLOAD_DST_ADDR,
    ST_DMA_WLOAD_XLEN,
    ST_DMA_WLOAD_SUBMIT,
    // 6c. Poll for DMA done
    ST_DMA_WLOAD_POLL,
    // 6e. Release SRAMs to compute: sys_axi_ctrl = 0
    ST_LAYER_COMPUTE_GATE,
    // 6e'. z_out border fill of the output frames (padded outputs)
    ST_FILL,
    ST_FILL_WAIT,
    // 6f. Pass loop: set pass params, pulse start, wait for done
    ST_PASS_SET_PARAMS,
    ST_PASS_START,
    ST_PASS_WAIT_DONE,
    ST_PASS_FLUSH,
    ST_PASS_NEXT,
    // 6g. Job end: release the camera stripe slot
    ST_LAYER_BANKFLIP,
    ST_LAYER_NEXT,
    // ── Classifier head: argmax over the per-class sums ─────────────────────
    ST_HEAD_RD,
    // ── Done ────────────────────────────────────────────────────────────────
    ST_DONE
} fsm_state_t;

fsm_state_t state;

// ── Loop counters ────────────────────────────────────────────────────────────
logic [7:0]  layer_idx;     // current layer (0..active_num_layers-1)
logic [7:0]  pass_idx;      // current 4-ch pass within layer (0..n_passes-1)
logic [15:0] flush_cnt;     // countdown for maxpool pipeline drain

// ── Reqt param scratchpad (loaded from WSRAM after DMA) ─────────────────────
// WSRAM layout for Conv1:
//   word 0:          z_out (8-bit signed, stored in [7:0])
//   words 1..234:    6 blocks of 39 words
//     block p (p=0..5): words [1 + p*39 .. p*39+27] = 27 weight words
//                        words [p*39+28 .. p*39+38] = 12 param words
//                         param word  0..3  = bias[0..3]
//                         param word  4..7  = mult[0..3]
//                         param word  8..11 = shift[0..3]
//
// We read these 12 words once per pass from WSRAM via the AXI read engine.
// WSRAM base in AXI map = WSRAM_BASE.
// Word address in WSRAM: param_base_word = 1 + pass*(27+12) + 27 = 28 + pass*39

logic [3:0] param_rd_idx;  // 0..11: which param word we are reading this pass

// ── Classifier head scratch ─────────────────────────────────────────────────
logic [15:0]        head_cls, head_wd;
logic signed [31:0] head_sum, head_best;

assign busy      = (state != ST_RESET) && (state != ST_WAIT_MCU_PROGRAM);
assign cur_layer = layer_idx;
assign cur_pass  = pass_idx;
// Staging registers for params being loaded
logic signed [31:0] s_bias  [0:3];
logic signed [31:0] s_mult  [0:3];
logic signed [31:0] s_shift [0:3];
logic signed [7:0]  s_z_out;

// ── Write/read request handshake helpers ─────────────────────────────────────
logic pending_wr;  // 1 = we just loaded wr_addr/wr_data and are waiting for wr_ack
logic pending_rd;

// Derive current-layer ROM values as local signals for readability
logic [ADDR_W-1:0]  cur_flash_src;
logic [15:0]        cur_weight_words;
logic [7:0]         chunk_first;       // first pass of the weight chunk now in WSRAM
logic [7:0]         cur_chunk_n;       // passes in that chunk
logic [31:0]        cur_blk_words;     // k_len + 12

always_comb begin
    cur_flash_src   = j_flash_src_addr;
    cur_weight_words= j_weight_words;
    cur_blk_words   = 32'(j_k_len) + 32'd12;
    cur_chunk_n     = (j_ppl == 8'd0 ||
                       j_ppl > j_n_passes - chunk_first)
                      ? j_n_passes - chunk_first : j_ppl;
end

// ── Macro: issue one AXI write and wait.
// Because we are in an always_ff block, we implement this as an inline
// two-state sequence: the state machine issues wr_req=1 for one clock
// (pending_wr transitions), then waits for wr_ack before advancing state.
// ─────────────────────────────────────────────────────────────────────────────

// Write helper logic – separate from main FSM state register for clarity
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pending_wr <= 1'b0;
    else if (wr_req)  pending_wr <= 1'b1;
    else if (wr_ack)  pending_wr <= 1'b0;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pending_rd <= 1'b0;
    else if (rd_req)  pending_rd <= 1'b1;
    else if (rd_ack)  pending_rd <= 1'b0;
end

// ── Main FSM ─────────────────────────────────────────────────────────────────
// Default outputs (overridden inside FSM states where needed)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state           <= ST_RESET;
        wr_req          <= 1'b0;
        rd_req          <= 1'b0;
        wr_addr         <= '0;
        wr_data         <= '0;
        rd_addr         <= '0;
        sys_axi_ctrl    <= 1'b1;  // AXI owns SRAMs on reset
        core_start      <= 1'b0;
        flush_acc       <= 1'b0;
        cam_arm         <= 1'b0;
        cam_consume     <= 1'b0;
        infer_done      <= 1'b0;
        result_valid    <= 1'b0;
        result_class_id <= 16'd0;
        result_score    <= 32'sd0;
        head_cls        <= 16'd0;
        head_wd         <= 16'd0;
        head_sum        <= 32'sd0;
        head_best       <= 32'sd0;
        layer_idx       <= 8'd0;
        pass_idx        <= 8'd0;
        flush_cnt       <= 16'd0;
        ld_cnt          <= 6'd0;
        for (int i = 0; i < DESC_WORDS; i++) cur_w[i] <= '0;
        param_rd_idx    <= 4'd0;
        cfg_k_len           <= '0;
        cfg_base            <= '0;
        cfg_chstep          <= '0;
        cfg_ystep           <= '0;
        cfg_nch             <= '0;
        cfg_nky             <= '0;
        cfg_last            <= '0;
        cfg_stride          <= '0;
        cfg_kpat            <= '0;
        cfg_x_tile_step     <= '0;
        cfg_y_tile_step     <= '0;
        cfg_ntx             <= '0;
        cfg_nty             <= '0;
        cfg_b_base          <= '0;
        reqt_total_tiles    <= '0;
        reqt_oc_base        <= '0;
        reqt_relu_en        <= 1'b0;
        reqt_z_out          <= 8'sd0;
        cfg_maxpool_en      <= 1'b0;
        cfg_pool_x_chunks   <= '0;
        cfg_pool_y_rows     <= '0;
        cfg_pool_stride     <= '0;
        cfg_pool_nopad      <= 1'b0;
        cfg_out_base        <= '0;
        cfg_out_ch_stride   <= '0;
        cfg_out_row_stride  <= '0;
        cfg_out_words_per_row <= '0;
        cfg_out_pad         <= 1'b0;
        cfg_out_oc_off      <= '0;
        cfg_out_valid_w     <= '0;
        cfg_out_rows        <= '0;
        fill_start          <= 1'b0;
        fill_channels       <= '0;
        chunk_first         <= 8'd0;
        for (int i=0;i<4;i++) begin
            reqt_bias[i]  <= 32'sd0;
            reqt_mult[i]  <= 32'sd0;
            reqt_shift[i] <= 32'sd0;
            s_bias[i]     <= 32'sd0;
            s_mult[i]     <= 32'sd0;
            s_shift[i]    <= 32'sd0;
        end
        s_z_out <= 8'sd0;
        active_num_layers <= 8'd0;
    end else begin
        // Default: deassert one-cycle signals
        infer_done <= 1'b0;
        fill_start <= 1'b0;
        cam_arm    <= 1'b0;
        cam_consume<= 1'b0;
        wr_req     <= 1'b0;
        rd_req     <= 1'b0;
        core_start <= 1'b0;

        // MCU start register (number of layers to run)
        if (cfg_we && cfg_addr == START_ADDR) active_num_layers <= cfg_wdata[7:0];

        case (state)

        // ── RESET: small delay for downstream IPs ─────────────────────────
        ST_RESET: begin
            // [MODIFIED] Wait for MCU to program Layer SRAM before starting
            state <= ST_WAIT_MCU_PROGRAM; 
        end

        ST_WAIT_MCU_PROGRAM: begin
            // [MODIFIED] Wait for external trigger (e.g., a CSR bit written by MCU)
            // Assuming active_num_layers is programmed by MCU via SPI to kickstart
            if (active_num_layers > 0) begin
                result_valid <= 1'b0;
                state        <= ST_QSPI_CLKDIV;
            end
        end

        // =====================================================================
        //  QSPI controller: enable XIP so the sys-DMA can burst-read the flash
        //  through the memory window at QSPI_BASE (sequence from
        //  reference/tb_qspi_subsystem.sv)
        // =====================================================================
        ST_QSPI_CLKDIV: begin
            if (!pending_wr) begin
                wr_addr <= QSPI_BASE + QSPI_CFG_OFF + 32'h08;
                wr_data <= QSPI_CLKDIV;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_QSPI_MODE;
        end

        ST_QSPI_MODE: begin
            if (!pending_wr) begin
                wr_addr <= QSPI_BASE + QSPI_CFG_OFF + 32'h0C;
                wr_data <= QSPI_MODE;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_QSPI_DUMMY;
        end

        ST_QSPI_DUMMY: begin
            if (!pending_wr) begin
                wr_addr <= QSPI_BASE + QSPI_CFG_OFF + 32'h1C;
                wr_data <= QSPI_DUMMY;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_QSPI_XIP_BASE;
        end

        ST_QSPI_XIP_BASE: begin
            if (!pending_wr) begin
                wr_addr <= QSPI_BASE + QSPI_CFG_OFF + 32'h38;
                wr_data <= QSPI_BASE;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_QSPI_XIP_MASK;
        end

        ST_QSPI_XIP_MASK: begin
            if (!pending_wr) begin
                wr_addr <= QSPI_BASE + QSPI_CFG_OFF + 32'h3C;
                wr_data <= QSPI_XIP_MASK;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_QSPI_XIP_CMD;
        end

        ST_QSPI_XIP_CMD: begin
            if (!pending_wr) begin
                wr_addr <= QSPI_BASE + QSPI_CFG_OFF + 32'h40;
                wr_data <= QSPI_XIP_CMD;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_QSPI_XIP_CTRL;
        end

        ST_QSPI_XIP_CTRL: begin
            if (!pending_wr) begin
                wr_addr <= QSPI_BASE + QSPI_CFG_OFF + 32'h34;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_EN;
        end

        // =====================================================================
        //  [MODIFIED] DVP-RX controller setup based on actual register map
        // =====================================================================

        // 0x00 = cam_en
        ST_DVP_DRC_EN: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0000;
                wr_data <= 32'h0000_0001; 
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_PWDN;
        end

        // 0x01 = cam_pwdn (0)
        ST_DVP_DRC_PWDN: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0001;
                wr_data <= 32'h0000_0000; 
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_MODE;
        end

        // 0x02 = rx_mode (2 = STREAM)
        ST_DVP_DRC_MODE: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0002;
                wr_data <= 32'h0000_0002; 
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_IRQ;
        end

        // 0x03 = irq_mask (3 = both)
        ST_DVP_DRC_IRQ: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0003;
                wr_data <= 32'h0000_0003; 
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_W;
        end

        // 0x04 = img_w
        ST_DVP_DRC_W: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0004;
                wr_data <= {16'd0, cam_frame_w};
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_H;
        end

        // 0x05 = img_h
        ST_DVP_DRC_H: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0005;
                wr_data <= {16'd0, cam_frame_h};
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_PROC;
        end

        // 0x06 = proc_ctrl (1 = downscale, 0 = grayscale)
        ST_DVP_DRC_PROC: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0006;
                wr_data <= 32'h0000_0000; // RGB565 raw streaming, no downscale
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DVP_DRC_START;
        end

        // 0x10 = cam_rx_start
        ST_DVP_DRC_START: begin
            if (!pending_wr) begin
                wr_addr <= DVP_BASE + DVPDRC_OFF + 32'h0010;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
                cam_arm <= 1'b1;               // front end takes the frame that starts now
            end else if (wr_ack) state <= ST_WAIT_CHUNK;
        end

        // =====================================================================
        //  [MODIFIED] Wait for Chunk
        // =====================================================================
        ST_WAIT_CHUNK: begin
            // the camera is running; jobs that need its rows wait in ST_WAIT_CAM
            layer_idx   <= 8'd0;
            pass_idx    <= 8'd0;
            chunk_first <= 8'd0;
            ld_cnt      <= 6'd0;
            state       <= ST_JOB_LOAD;
        end

        // ── read the job descriptor (DESC_WORDS words, 1-cycle RAM latency)
        ST_JOB_LOAD: begin
            if (ld_cnt != 6'd0) cur_w[ld_cnt - 6'd1] <= desc_q;
            if (ld_cnt == 6'(DESC_WORDS)) state <= ST_LAYER_AXI_GATE;
            else                          ld_cnt <= ld_cnt + 6'd1;
        end

        // =====================================================================
        //  Layer loop
        // =====================================================================

        // Gate: AXI owns SRAMs so DMA can write weights
        ST_LAYER_AXI_GATE: begin
            sys_axi_ctrl <= 1'b1;
            state        <= ST_DMA_WLOAD_EN;
        end

        // ── Sys-DMA: enable global
        ST_DMA_WLOAD_EN: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + 32'h0000;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_CHN_EN;
        end

        // ── CHN_CONTROL: enable ch0
        ST_DMA_WLOAD_CHN_EN: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0001;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_CHN_FLAGS;
        end

        // ── CHN_FLAGS: 1-D transfer, no cyclic
        ST_DMA_WLOAD_CHN_FLAGS: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0002;
                wr_data <= 32'h0000_0000;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_IRQ_MASK;
        end

        // ── CHN_IRQ_MASK: irq_complete
        ST_DMA_WLOAD_IRQ_MASK: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0003;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_ARBIT;
        end

        // ── CHN_ARBIT_RATE
        ST_DMA_WLOAD_ARBIT: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0004;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_SRC_BURST;
        end

        // ── ATX_SRC_BURST: INCR
        ST_DMA_WLOAD_SRC_BURST: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0006;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_DST_BURST;
        end

        // ── ATX_DST_BURST: INCR
        ST_DMA_WLOAD_DST_BURST: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0007;
                wr_data <= 32'h0000_0001;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_WD_PER_BURST;
        end

        // ── ATX_WD_PER_BURST: 16 words – 1 = 15
        ST_DMA_WLOAD_WD_PER_BURST: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0008;
                wr_data <= 32'h0000_000F;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_SRC_ADDR;
        end

        // ── SRC_ADDR: QSPI flash base for this layer's weights
        ST_DMA_WLOAD_SRC_ADDR: begin
            if (!pending_wr) begin
                // Flash window: QSPI slave is at QSPI_BASE (0x2000_0000).
                // The QSPI AXI wrapper maps flash[0] → AXI addr QSPI_BASE.
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h0009;
                // word address of the first pass block of this weight chunk
                wr_data <= ((QSPI_BASE + cur_flash_src) >> 2) + 32'(chunk_first) * cur_blk_words;
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_DST_ADDR;
        end

        // ── DST_ADDR: weight SRAM base
        ST_DMA_WLOAD_DST_ADDR: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h000A;
                wr_data <= WSRAM_BASE >> 2;                    // word address
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_XLEN;
        end

        // ── TRANSFER_X_LEN: total weight words – 1
        ST_DMA_WLOAD_XLEN: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h000B;
                wr_data <= 32'(cur_chunk_n) * cur_blk_words - 32'd1;   // chunk words - 1
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_SUBMIT;
        end

        // ── TRANSFER_SUBMIT: enqueue
        ST_DMA_WLOAD_SUBMIT: begin
            if (!pending_wr) begin
                wr_addr <= SDMA_BASE + DMA_CH0_OFF + 32'h1000;
                wr_data <= 32'h0000_0001; // Submits descriptor 0
                wr_req  <= 1'b1;
            end else if (wr_ack) state <= ST_DMA_WLOAD_POLL;
        end

        // ── Poll for DMA completion ────────────────────────────────────────
        // We use the DMA IRQ output rather than polling a register to avoid
        // consuming interconnect bandwidth.  sys_dma_irq is wired from
        // axi_dma.irq[0] in accelerator_top.
        ST_DMA_WLOAD_POLL: begin
            if (sys_dma_irq[0]) begin
                param_rd_idx <= 4'd0;
                state        <= ST_LAYER_COMPUTE_GATE;
            end
        end

        // ── Latch the layer configuration ───────────────────────────────
        // The SRAMs stay on the AXI side (sys_axi_ctrl = 1) while the per-pass
        // params are read from the WSRAM; ST_PASS_START hands them to compute.
        ST_LAYER_COMPUTE_GATE: begin
            // Load static geometry from ROM into output wires
            cfg_k_len         <= j_k_len;
            cfg_base          <= j_cfg_base;
            cfg_chstep        <= j_cfg_chstep;
            cfg_ystep         <= j_cfg_ystep;
            cfg_nch           <= j_cfg_nch;
            cfg_nky           <= j_cfg_nky;
            cfg_last          <= j_cfg_last;
            cfg_stride        <= j_cfg_stride;
            cfg_kpat          <= j_cfg_kpat;
            cfg_x_tile_step   <= j_cfg_x_tile_step;
            cfg_y_tile_step   <= j_cfg_y_tile_step;
            cfg_ntx           <= j_cfg_ntx;
            cfg_nty           <= j_cfg_nty;
            reqt_relu_en      <= j_reqt_relu_en;
            reqt_z_out        <= j_reqt_z_out;
            reqt_total_tiles  <= j_reqt_total_tiles;
            cfg_maxpool_en    <= j_maxpool_en;
            cfg_pool_x_chunks <= j_pool_x_chunks;
            cfg_pool_y_rows   <= j_pool_y_rows;
            cfg_pool_stride   <= j_pool_stride;
            cfg_pool_nopad    <= j_pool_nopad;
            cfg_out_base      <= j_out_base;
            cfg_out_ch_stride <= j_out_cs;
            cfg_out_row_stride<= j_out_rs;
            cfg_out_words_per_row <= j_out_wpr;
            cfg_out_pad       <= j_out_pad;
            cfg_out_oc_off    <= j_out_oc_off;
            cfg_out_valid_w   <= j_out_valid_w;
            cfg_out_rows      <= j_out_rows;
            fill_channels     <= 16'(j_fill_ch);
            state             <= ST_WAIT_CAM;
        end

        // ── input rows from the camera (row-streaming): wait until written
        ST_WAIT_CAM: begin
            if (!j_wait_cam || cam_rows_done >= j_cam_rows)
                state <= (chunk_first == 8'd0 && j_fill_ch != 8'd0)
                         ? ST_FILL : ST_PASS_SET_PARAMS;
        end

        // ── z_out border of the output frames (compute owns the SRAM write port)
        ST_FILL: begin
            sys_axi_ctrl <= 1'b0;
            fill_start   <= 1'b1;
            state        <= ST_FILL_WAIT;
        end

        ST_FILL_WAIT: begin
            if (fill_done) state <= ST_PASS_SET_PARAMS;
        end

        // =====================================================================
        //  Pass loop
        //  For each pass we must read 12 param words from WSRAM.
        //  WSRAM layout (word 0 = z_out), one block of (k_len + 12) words per pass:
        //    words 1 + pass*(k_len+12) + t         (t=0..k_len-1) = weights
        //    words 1 + pass*(k_len+12) + k_len + k (k=0..11)      = param word k
        //  (Conv1 3x3x3: k_len = 27 -> 39-word blocks)
        //    bias[0..3]  = param words 0..3
        //    mult[0..3]  = param words 4..7
        //    shift[0..3] = param words 8..11
        //
        //  We issue 12 sequential AXI reads here.
        // =====================================================================
        ST_PASS_SET_PARAMS: begin
            // Read one param word per visit to this state.
            // param_rd_idx counts 0..11.
            automatic logic [31:0] pass_blk_base, param_word_offset;
            pass_blk_base     = 32'(pass_idx - chunk_first) * (32'(cfg_k_len) + 32'd12);
            param_word_offset = pass_blk_base + 32'(cfg_k_len) + {28'd0, param_rd_idx};
            sys_axi_ctrl <= 1'b1;   // WSRAM must be on the AXI side for these reads
            if (!pending_rd) begin
                rd_addr <= WSRAM_BASE + param_word_offset * 4;
                rd_req  <= 1'b1;
            end else if (rd_ack) begin
                // Store read result into correct scratchpad slot
                case (param_rd_idx)
                    4'd0:  s_bias[0]  <= rd_rdata;
                    4'd1:  s_bias[1]  <= rd_rdata;
                    4'd2:  s_bias[2]  <= rd_rdata;
                    4'd3:  s_bias[3]  <= rd_rdata;
                    4'd4:  s_mult[0]  <= rd_rdata;
                    4'd5:  s_mult[1]  <= rd_rdata;
                    4'd6:  s_mult[2]  <= rd_rdata;
                    4'd7:  s_mult[3]  <= rd_rdata;
                    4'd8:  s_shift[0] <= rd_rdata;
                    4'd9:  s_shift[1] <= rd_rdata;
                    4'd10: s_shift[2] <= rd_rdata;
                    4'd11: s_shift[3] <= rd_rdata;
                    default: ;
                endcase
                if (param_rd_idx == 4'd11) begin
                    // All 12 params loaded – copy to output wires
                    reqt_bias[0]  <= s_bias[0];  reqt_bias[1]  <= s_bias[1];
                    reqt_bias[2]  <= s_bias[2];  reqt_bias[3]  <= s_bias[3];
                    reqt_mult[0]  <= s_mult[0];  reqt_mult[1]  <= s_mult[1];
                    reqt_mult[2]  <= s_mult[2];  reqt_mult[3]  <= s_mult[3];
                    reqt_shift[0] <= s_shift[0]; reqt_shift[1] <= s_shift[1];
                    reqt_shift[2] <= s_shift[2]; reqt_shift[3] <= rd_rdata;  // word 11 arrives now
                    // Pass-specific scalar config
                    cfg_b_base   <= ($clog2(WBUF_SIZE))'(pass_blk_base);
                    reqt_oc_base <= {24'd0, pass_idx} * 32'd4;
                    param_rd_idx <= 4'd0;
                    state        <= ST_PASS_START;
                end else begin
                    param_rd_idx <= param_rd_idx + 4'd1;
                end
            end
        end

        // Pulse core_start for exactly 1 clock, handing the SRAMs to compute
        ST_PASS_START: begin
            sys_axi_ctrl <= 1'b0;
            core_start   <= 1'b1;
            state      <= ST_PASS_WAIT_DONE;
        end

        // Wait for layer_done from compute_top
        ST_PASS_WAIT_DONE: begin
            core_start <= 1'b0;
            if (layer_done) begin
                // maxpool_inline flushes one ghost row (x_chunks * 4 entries)
                // after the last requant write, plus a few pipeline stages.
                flush_cnt <= (cfg_pool_x_chunks << 2) + 16'd32;
                state     <= ST_PASS_FLUSH;
            end
        end

        // Drain the maxpool pipeline
        ST_PASS_FLUSH: begin
            if (flush_cnt == 16'd0) state <= ST_PASS_NEXT;
            else                    flush_cnt <= flush_cnt - 16'd1;
        end

        // Advance to next pass or finish layer
        ST_PASS_NEXT: begin
            if (pass_idx == (j_n_passes - 8'd1)) begin
                // All passes done for this job
                state <= ST_LAYER_BANKFLIP;
            end else if (pass_idx + 8'd1 == chunk_first + cur_chunk_n) begin
                // weight chunk used up: fetch the next one
                pass_idx     <= pass_idx + 8'd1;
                chunk_first  <= pass_idx + 8'd1;
                param_rd_idx <= 4'd0;
                state        <= ST_LAYER_AXI_GATE;
            end else begin
                pass_idx     <= pass_idx + 8'd1;
                param_rd_idx <= 4'd0;
                state        <= ST_PASS_SET_PARAMS;
            end
        end

        // Job finished: release its camera stripe slot if it consumed one
        ST_LAYER_BANKFLIP: begin
            sys_axi_ctrl <= 1'b1;
            cam_consume  <= j_consume;
            state        <= ST_LAYER_NEXT;
        end

        // Advance to next layer or finish inference
        ST_LAYER_NEXT: begin
            if (layer_idx == (active_num_layers - 1)) begin
                head_cls  <= 16'd0;
                head_wd   <= 16'd0;
                head_sum  <= 32'sd0;
                state     <= (head_classes != 16'd0) ? ST_HEAD_RD : ST_DONE;
            end else begin
                layer_idx   <= layer_idx + 8'd1;
                pass_idx    <= 8'd0;
                chunk_first <= 8'd0;
                ld_cnt      <= 6'd0;
                state       <= ST_JOB_LOAD;
            end
        end

        // =====================================================================
        //  Classifier head: score[c] = sum of every int8 value of class map c
        //  (global average pooling up to a common scale), result = argmax,
        //  lowest class index wins ties.  Map c = head_words words at the
        //  AXI byte address head_base + c*head_words*4.
        // =====================================================================
        ST_HEAD_RD: begin
            if (!pending_rd) begin
                rd_addr <= head_base
                         + ((32'(head_cls) * 32'(head_words) + 32'(head_wd)) << 2);
                rd_req  <= 1'b1;
            end else if (rd_ack) begin
                automatic logic signed [31:0] s;
                s = head_sum + 32'($signed(rd_rdata[7:0]))   + 32'($signed(rd_rdata[15:8]))
                             + 32'($signed(rd_rdata[23:16])) + 32'($signed(rd_rdata[31:24]));
                if (head_wd == head_words - 16'd1) begin
                    if (head_cls == 16'd0 || s > head_best) begin
                        head_best       <= s;
                        result_class_id <= head_cls;
                    end
                    head_sum <= 32'sd0;
                    head_wd  <= 16'd0;
                    if (head_cls == head_classes - 16'd1) state <= ST_DONE;
                    else                                   head_cls <= head_cls + 16'd1;
                end else begin
                    head_sum <= s;
                    head_wd  <= head_wd + 16'd1;
                end
            end
        end

        // =====================================================================
        //  Inference complete: publish the result, go idle until the MCU
        //  writes START again (which re-arms the camera for the next frame)
        // =====================================================================
        ST_DONE: begin
            infer_done        <= 1'b1;
            result_valid      <= (head_classes != 16'd0);
            result_score      <= head_best;
            active_num_layers <= 8'd0;
            state             <= ST_WAIT_MCU_PROGRAM;
        end

        default: state <= ST_RESET;
        endcase
    end
end

endmodule
