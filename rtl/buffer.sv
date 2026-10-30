// STAND-IN for your 'buffer' module (not uploaded). Behaviour inferred from how
// mme_tb.sv uses it: synchronous read, 1 clock latency, r_valid_out follows ren.
module buffer #(
    parameter int WIDTH = 64,
    parameter int SIZE  = 1024,
    parameter int INIT  = 0,
    parameter string INIT_FILE = ""
)(
    input  logic clk,
    input  logic rst_n,
    input  logic [$clog2(SIZE)-1:0] r_addr,
    input  logic ren,
    output logic [WIDTH-1:0] dout,
    output logic r_valid_out,
    input  logic wen,
    input  logic [WIDTH-1:0] din,
    input  logic [$clog2(SIZE)-1:0] w_addr
);
    logic [WIDTH-1:0] mem [0:SIZE-1];
    initial if (INIT != 0) $readmemh(INIT_FILE, mem);

    always_ff @(posedge clk) begin
        if (!rst_n) begin r_valid_out <= 1'b0; dout <= '0; end
        else begin
            r_valid_out <= ren;
            if (ren) dout <= mem[r_addr];
        end
        if (wen) mem[w_addr] <= din;
    end
endmodule
