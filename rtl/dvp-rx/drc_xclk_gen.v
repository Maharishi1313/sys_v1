module drc_xclk_gen
#(
    parameter INTL_CLK_PERIOD   = 125_000_000
)
(
    // Input declaration
    // -- Global
    input                       clk,
    input                       rst_n,
    // -- DRC CSRs
    input                       cam_rx_en,
    input                       cam_pwdn,
    // -- Output declaration
    // -- DVP Camera interface
    output                      dvp_xclk_o,
    output                      dvp_pwdn_o
);
    // Local parameters
    localparam CAM_MAX_FREQ = 24000000;
    localparam PRES_CTN_MAX = INTL_CLK_PERIOD / CAM_MAX_FREQ;   // 125/24 = 5
    localparam PRESC_CTN_W  = $clog2(PRES_CTN_MAX);
    // Internal signal
    // -- wire declaration
    wire    [1:0]               cam_presc;      // Camera prescaler
    wire    [PRESC_CTN_W-1:0]   presc_ctn_d;
    wire                        presc_ctn_ex;   // Prescaler counter exceeded
    wire                        xclk_toggle;
    // -- reg declaration
    reg     [PRESC_CTN_W-1:0]   presc_ctn_q;
    reg                         xclk_q;
    
    // Combination logic
    // -- Output
    assign dvp_xclk_o   = xclk_q;
    assign dvp_pwdn_o   = cam_pwdn;
    assign presc_ctn_ex = (presc_ctn_q == PRES_CTN_MAX-1);
    assign xclk_toggle  = (presc_ctn_q == (PRES_CTN_MAX/2 - 1)) & cam_rx_en;
    assign presc_ctn_d  = (cam_rx_en & !presc_ctn_ex) ? presc_ctn_q + 1'b1 : {PRESC_CTN_W{1'b0}};
    
    // Flip-flop
    // -- Prescaler counter
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            presc_ctn_q <= {PRESC_CTN_W{1'b0}};
        end
        else begin
            presc_ctn_q <= presc_ctn_d;
        end
    end
    // -- XCLK generator
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            xclk_q <= 1'b0;
        end
        else if(xclk_toggle) begin
            xclk_q <= ~xclk_q;
        end
    end
endmodule
