`timescale 1ns / 1ps

// =============================================================================
//  ov7670_sccb_init : writes the OV7670 register table over SCCB (I2C-like) once
//
//  Mode: QVGA 320x240, RGB565 (first byte = R5 G3, second = G3 B5), PCLK = XCLK/4
//  (25 MHz XCLK -> 6.25 MHz PCLK, ~15 fps).  Table based on the Linux ov7670 driver
//  (default + QVGA + RGB565 settings).
//
//  SCCB write = START, 0x42 (device write address), register, value, STOP.  The ACK bit
//  of each byte is not checked (SIOD is released during it).  SIOC is driven push-pull,
//  SIOD as open drain (needs the pull-up of the module / the XDC PULLUP).
//  Table entries {reg, val}: reg 0xF0 = wait val milliseconds, 0xFF = end.
// =============================================================================
module ov7670_sccb_init #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SCCB_HZ = 100_000,
    parameter int MS_DIV  = CLK_HZ / 1000        // clocks per millisecond (smaller in simulation)
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,                          // 1-cycle: (re)run the whole table
    output logic sioc,
    inout  wire  siod,
    output logic done                            // table written
);
    // ------------------------------------------------------------ register table
    function automatic logic [15:0] tbl(input int i);
        case (i)
            0:  tbl = 16'h1280;   // COM7: reset all registers
            1:  tbl = 16'hF00A;   //   wait 10 ms
            2:  tbl = 16'h1101;   // CLKRC: internal clock = XCLK / 2
            3:  tbl = 16'h1214;   // COM7: QVGA, RGB
            4:  tbl = 16'h40D0;   // COM15: RGB565, full output range 00..FF
            5:  tbl = 16'h8C00;   // RGB444: off
            6:  tbl = 16'h0400;   // COM1
            7:  tbl = 16'h3A04;   // TSLB: normal byte order
            8:  tbl = 16'h1500;   // COM10: VSYNC active high, HREF normal, PCLK free running
            9:  tbl = 16'h0C04;   // COM3: DCW (down-sampling) enable
            10: tbl = 16'h3E19;   // COM14: scaled PCLK, divide by 2, manual scaling
            11: tbl = 16'h703A;   // SCALING_XSC
            12: tbl = 16'h7135;   // SCALING_YSC
            13: tbl = 16'h7211;   // SCALING_DCWCTR: down-sample by 2 in x and y
            14: tbl = 16'h73F1;   // SCALING_PCLK_DIV: divide by 2
            15: tbl = 16'hA202;   // SCALING_PCLK_DELAY
            16: tbl = 16'h1714;   // HSTART  (QVGA window from the Linux driver)
            17: tbl = 16'h1802;   // HSTOP
            18: tbl = 16'h3224;   // HREF
            19: tbl = 16'h1903;   // VSTART
            20: tbl = 16'h1A7B;   // VSTOP
            21: tbl = 16'h030A;   // VREF
            22: tbl = 16'h1E00;   // MVFP: no mirror / flip (0x30 = mirror + flip)
            23: tbl = 16'h0F41;   // COM6
            24: tbl = 16'h1602;   // reserved (driver default)
            25: tbl = 16'h0E61;   // COM5 (driver default)
            26: tbl = 16'h3311;   // CHLF
            27: tbl = 16'h3C78;   // COM12: no HREF when VSYNC is low
            28: tbl = 16'h6900;   // GFIX
            29: tbl = 16'h7400;   // REG74
            30: tbl = 16'hB084;   // reserved - needed for correct colours
            31: tbl = 16'hB10C;   // ABLC1
            32: tbl = 16'hB20E;   // reserved
            33: tbl = 16'hB380;   // THL_ST
            34: tbl = 16'h13E0;   // COM8: AGC / AEC off while setting them up
            35: tbl = 16'h0000;   // GAIN
            36: tbl = 16'h1000;   // AECH
            37: tbl = 16'h0D40;   // COM4
            38: tbl = 16'h1438;   // COM9: AGC ceiling 16x
            39: tbl = 16'hA505;   // BD50MAX
            40: tbl = 16'hAB07;   // BD60MAX
            41: tbl = 16'h2495;   // AEW
            42: tbl = 16'h2533;   // AEB
            43: tbl = 16'h26E3;   // VPT
            44: tbl = 16'h9F78;   // HAECC1..7
            45: tbl = 16'hA068;
            46: tbl = 16'hA103;
            47: tbl = 16'hA6D8;
            48: tbl = 16'hA7D8;
            49: tbl = 16'hA8F0;
            50: tbl = 16'hA990;
            51: tbl = 16'hAA94;
            52: tbl = 16'h4FB3;   // colour matrix for RGB (MTX1..6)
            53: tbl = 16'h50B3;
            54: tbl = 16'h5100;
            55: tbl = 16'h523D;
            56: tbl = 16'h53A7;
            57: tbl = 16'h54E4;
            58: tbl = 16'h589E;   // MTXS
            59: tbl = 16'h3DC0;   // COM13: gamma, UV saturation auto
            60: tbl = 16'h13E7;   // COM8: fast AEC, AGC, AWB, AEC on
            61: tbl = 16'hF064;   // wait 100 ms for the sensor to settle
            default: tbl = 16'hFFFF;
        endcase
    endfunction

    // ------------------------------------------------------------ bit engine
    // one SCCB bit = 4 quarter periods; SIOC high in quarters 1 and 2
    localparam int QUARTER = CLK_HZ / SCCB_HZ / 4;
    typedef enum logic [2:0] {IDLE, NEXT, START, BITS, STOP, WAIT, DONE} st_t;
    st_t         st;
    logic [6:0]  idx;
    logic [15:0] ent;
    logic [26:0] sh;                             // 3 bytes, each followed by an ACK slot
    logic [4:0]  nbit;
    logic [1:0]  q;
    logic [31:0] cnt;
    logic        sda_low;                        // 1: pull SIOD low, 0: release (pull-up)

    assign siod = sda_low ? 1'b0 : 1'bz;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; idx <= '0; ent <= '0; sh <= '0; nbit <= '0; q <= '0; cnt <= '0;
            sioc <= 1'b1; sda_low <= 1'b0; done <= 1'b0;
        end else begin
            case (st)
            IDLE: if (start) begin idx <= '0; done <= 1'b0; st <= NEXT; end
            NEXT: begin
                ent <= tbl(idx);
                cnt <= '0;
                if (tbl(idx) == 16'hFFFF)        st <= DONE;
                else if (tbl(idx)[15:8] == 8'hF0) st <= WAIT;
                else begin
                    // byte, ACK slot (1 = released), byte, ACK, byte, ACK
                    sh   <= {8'h42, 1'b1, tbl(idx)[15:8], 1'b1, tbl(idx)[7:0], 1'b1};
                    nbit <= 5'd27;
                    st   <= START;
                end
            end
            START: begin                         // SIOD falls while SIOC is high
                if (cnt == QUARTER) sda_low <= 1'b1;
                if (cnt == 2 * QUARTER) begin sioc <= 1'b0; cnt <= '0; q <= '0; st <= BITS; end
                else cnt <= cnt + 1;
            end
            BITS: begin
                if (cnt == QUARTER - 1) begin
                    cnt <= '0;
                    q   <= q + 2'd1;
                    case (q)
                        2'd0: sda_low <= !sh[26];            // data changes while SIOC is low
                        2'd1: sioc    <= 1'b1;
                        2'd2: ;                              // SIOC high: sensor samples
                        2'd3: begin
                            sioc <= 1'b0;
                            sh   <= {sh[25:0], 1'b0};
                            nbit <= nbit - 5'd1;
                            if (nbit == 5'd1) st <= STOP;
                        end
                    endcase
                end else cnt <= cnt + 1;
            end
            STOP: begin                          // SIOD rises while SIOC is high
                if (cnt == 0)           sda_low <= 1'b1;
                if (cnt == QUARTER)     sioc    <= 1'b1;
                if (cnt == 2 * QUARTER) sda_low <= 1'b0;
                if (cnt == 4 * QUARTER) begin cnt <= '0; idx <= idx + 7'd1; st <= NEXT; end
                else cnt <= cnt + 1;
            end
            WAIT: begin
                if (cnt == 32'(ent[7:0]) * MS_DIV) begin idx <= idx + 7'd1; st <= NEXT; end
                else cnt <= cnt + 1;
            end
            DONE: begin done <= 1'b1; if (start) begin idx <= '0; done <= 1'b0; st <= NEXT; end end
            default: st <= IDLE;
            endcase
        end
    end
endmodule
