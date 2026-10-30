`timescale 1ns / 1ps

// =============================================================================
//  spi_boot_master : FPGA-side "MCU" that programs and runs the SoC over its SPI port
//
//  The boot program is a ROM of 64-bit entries {AXI address[63:32], data[31:0]} made by
//  scripts/compile_squeezenet.py (boot_rom.mem); entry FFFFFFFF_FFFFFFFF ends it.  It
//  holds the camera CSRs, the classifier-head CSRs, every job descriptor and, last,
//  the START write (CTRL = number of jobs).
//
//  1. after power-up waits START_DELAY clocks, then plays the ROM as SPI write frames
//     (0x02 | addr | data {| data ...}); entries with consecutive addresses are merged into
//     one auto-increment frame (a job's 25 descriptor words = one frame)
//  2. waits for host_irq, reads RESULT (0xA000_0010) with an SPI read frame
//     (0x03 | addr | 8 dummy clocks | data), shows it on result_*, clears the IRQ
//  3. CONTINUOUS = 1: writes START again (a new camera frame) and repeats step 2
//
//  SPI mode 0, MSB first, SCK = clk / (2 * HALF) (HALF >= 4: the SoC samples SCK with
//  synchronisers, so SCK must stay <= clk/8).
// =============================================================================
module spi_boot_master #(
    parameter string BOOT_HEX    = "boot_rom.mem",
    parameter int    ROM_DEPTH   = 4096,
    parameter int    HALF        = 8,            // SCK half period in clk cycles
    parameter int    START_DELAY = 1000,         // clocks after reset before the first frame
    parameter bit    CONTINUOUS  = 1'b1
)(
    input  logic        clk,
    input  logic        rst_n,

    output logic        spi_sck,
    output logic        spi_cs_n,
    output logic        spi_mosi,
    input  logic        spi_miso,
    input  logic        host_irq,

    output logic [15:0] result_class,
    output logic        result_valid,            // high once the first result is in
    output logic [15:0] frames_done,
    output logic        booted                   // the whole boot program has been sent
);
    localparam logic [31:0] CTRL   = 32'hA000_0000;
    localparam logic [31:0] IRQ    = 32'hA000_0008;
    localparam logic [31:0] RESULT = 32'hA000_0010;
    localparam logic [63:0] TERM   = 64'hFFFF_FFFF_FFFF_FFFF;
    localparam int AW = $clog2(ROM_DEPTH);

    // ------------------------------------------------------------ boot ROM (block RAM)
    logic [63:0] rom [0:ROM_DEPTH-1];
    initial $readmemh(BOOT_HEX, rom);
    logic [AW-1:0] rom_addr;
    logic [63:0]   rom_q;
    always_ff @(posedge clk) rom_q <= rom[rom_addr];

    // ------------------------------------------------------------ bit shifter
    // shifts sh_n bits of sh_tx out (MSB first) and collects MISO into sh_rx
    logic        sh_go, sh_busy;
    logic [5:0]  sh_n, sh_cnt;
    logic [31:0] sh_tx, sh_rx;
    logic [15:0] div;
    logic        sh_phase;                       // 0: SCK low half, 1: SCK high half

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh_busy <= 1'b0; sh_cnt <= '0; sh_rx <= '0; div <= '0; sh_phase <= 1'b0;
            spi_sck <= 1'b0; spi_mosi <= 1'b0;
        end else if (sh_go) begin
            sh_busy  <= 1'b1;
            sh_cnt   <= sh_n;
            sh_phase <= 1'b0;
            div      <= '0;
            spi_mosi <= sh_tx[sh_n - 6'd1];
        end else if (sh_busy) begin
            if (div == 16'(HALF - 1)) begin
                div <= '0;
                if (!sh_phase) begin                 // rising edge: the slave samples MOSI
                    spi_sck  <= 1'b1;
                    sh_rx    <= {sh_rx[30:0], spi_miso};
                    sh_phase <= 1'b1;
                end else begin                       // falling edge: next bit
                    spi_sck  <= 1'b0;
                    sh_phase <= 1'b0;
                    sh_cnt   <= sh_cnt - 6'd1;
                    if (sh_cnt == 6'd1) sh_busy <= 1'b0;
                    else                spi_mosi <= sh_tx[sh_cnt - 6'd2];
                end
            end else div <= div + 16'd1;
        end
    end

    // ------------------------------------------------------------ frame sequencer
    typedef enum logic [4:0] {
        S_DELAY, S_LOAD, S_LOADW, S_LOAD2, S_CS, S_CMD, S_ADDR, S_DATA, S_MERGE, S_END, S_GAP,
        S_WAIT_IRQ, S_RD_CS, S_RD_CMD, S_RD_ADDR, S_RD_DUMMY, S_RD_DATA, S_RD_END,
        S_CLR, S_RESTART
    } st_t;
    st_t         st, after_gap;
    logic [31:0] delay;
    logic [AW-1:0] idx;
    logic [31:0] start_jobs, w_addr, w_data;
    logic        wr_is_boot;                     // the frame being sent comes from the ROM

    // one-shot helper: start a shift of n bits of v
    task automatic shift(input logic [31:0] v, input logic [5:0] n);
        sh_tx <= v; sh_n <= n; sh_go <= 1'b1;
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_DELAY; after_gap <= S_LOAD; delay <= '0; idx <= '0; rom_addr <= '0;
            start_jobs <= '0; w_addr <= '0; w_data <= '0;
            wr_is_boot <= 1'b0; spi_cs_n <= 1'b1; sh_go <= 1'b0; sh_tx <= '0; sh_n <= '0;
            result_class <= '0; result_valid <= 1'b0; frames_done <= '0; booted <= 1'b0;
        end else begin
            sh_go <= 1'b0;
            case (st)
            S_DELAY: if (delay == START_DELAY) st <= S_LOAD; else delay <= delay + 1;

            // ---- boot program: one write frame per run of consecutive addresses
            S_LOAD:  begin rom_addr <= idx; st <= S_LOADW; end
            S_LOADW: st <= S_LOAD2;                             // ROM read latency
            S_LOAD2: begin
                if (rom_q == TERM) begin
                    booted <= 1'b1;
                    st     <= S_WAIT_IRQ;
                end else begin
                    w_addr     <= rom_q[63:32];
                    w_data     <= rom_q[31:0];
                    if (rom_q[63:32] == CTRL) start_jobs <= rom_q[31:0];
                    wr_is_boot <= 1'b1;
                    rom_addr   <= idx + 1'b1;               // prefetch the next entry
                    st         <= S_CS;
                end
            end

            S_CS: if (!sh_busy) begin spi_cs_n <= 1'b0; delay <= 0; st <= S_CMD; end
            S_CMD: if (delay == HALF) begin shift(32'h02, 6'd8); delay <= 0; st <= S_ADDR; end
                   else delay <= delay + 1;
            S_ADDR: if (!sh_busy && !sh_go) begin shift(w_addr, 6'd32); st <= S_DATA; end
            S_DATA: if (!sh_busy && !sh_go) begin shift(w_data, 6'd32); st <= S_MERGE; end
            // continue the frame while the next ROM entry is the next address
            S_MERGE: if (!sh_busy && !sh_go) begin
                if (wr_is_boot && rom_q != TERM && rom_q[63:32] == w_addr + 32'd4 && rom_q[63:32] != CTRL) begin
                    w_addr   <= rom_q[63:32];
                    w_data   <= rom_q[31:0];
                    idx      <= idx + 1'b1;
                    rom_addr <= idx + 2'd2;
                    st       <= S_DATA;
                end else st <= S_END;
            end
            S_END: begin
                if (delay == HALF) begin
                    spi_cs_n <= 1'b1; delay <= 0; st <= S_GAP;
                    if (wr_is_boot) idx <= idx + 1'b1;
                end else delay <= delay + 1;
            end
            S_GAP: if (delay == 4 * HALF) begin delay <= 0; st <= after_gap; end
                   else delay <= delay + 1;

            // ---- run: wait for the result, read it, clear the IRQ, restart
            S_WAIT_IRQ: if (host_irq) st <= S_RD_CS;
            S_RD_CS: begin spi_cs_n <= 1'b0; delay <= 0; st <= S_RD_CMD; end
            S_RD_CMD: if (delay == HALF) begin shift(32'h03, 6'd8); st <= S_RD_ADDR; end
                      else delay <= delay + 1;
            S_RD_ADDR:  if (!sh_busy && !sh_go) begin shift(RESULT, 6'd32); st <= S_RD_DUMMY; end
            S_RD_DUMMY: if (!sh_busy && !sh_go) begin shift(32'h0, 6'd8);   st <= S_RD_DATA; end
            S_RD_DATA:  if (!sh_busy && !sh_go) begin shift(32'h0, 6'd32);  delay <= 0; st <= S_RD_END; end
            S_RD_END: if (!sh_busy && !sh_go) begin
                if (delay == HALF) begin
                    spi_cs_n     <= 1'b1;
                    result_class <= sh_rx[15:0];
                    result_valid <= sh_rx[31];
                    frames_done  <= frames_done + 16'd1;
                    delay        <= 0;
                    // clear the IRQ: a single write frame, then maybe restart
                    w_addr <= IRQ; w_data <= 32'd1; wr_is_boot <= 1'b0;
                    after_gap <= S_CLR;
                    st <= S_GAP;
                end else delay <= delay + 1;
            end
            S_CLR: begin                                 // send the IRQ-clear frame
                after_gap <= CONTINUOUS ? S_RESTART : S_WAIT_IRQ;
                st <= S_CS;
            end
            S_RESTART: begin                             // START again: next camera frame
                w_addr <= CTRL; w_data <= start_jobs; wr_is_boot <= 1'b0;
                after_gap <= S_WAIT_IRQ;
                st <= S_CS;
            end
            default: st <= S_DELAY;
            endcase
        end
    end
endmodule
