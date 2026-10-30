module drc_pclk_sync (
    // Input declaration
    // -- Global
    input   clk,
    input   rst_n,
    // -- DVP Camera interface
    input   dvp_pclk_i,
    // Output declaration
    // -- Pixel FIFO
    output  pclk_sync
);
    // Internal module
    edgedet #(
        .RISING_EDGE(1'b1) // Rising
    ) pclk_det (
        .clk    (clk),
        .rst_n  (rst_n),
        .en     (1'b1),
        .i      (dvp_pclk_i),
        .o      (pclk_sync)
    );
endmodule
