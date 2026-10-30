`ifndef GLOBAL_SVH
`include "global.svh"
`endif

// Lane FIFO. FIXES vs. original:
//   * empty was (head == tail), which is ALSO true when the FIFO is full
//     (pointers wrap to the same place).  Now empty = (count == 0).
//   * new output 'level' (= count) so the controller can do flow control.
module lane_fifo #(
    parameter int DEPTH = 4
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [W-1:0] data_in,
    input  logic w_en,
    input  logic r_en,

    output logic [W-1:0] data_out,      // registered: valid 1 clock after r_en
    output logic full,
    output logic empty,
    output logic [$clog2(DEPTH):0] level
);

  logic [W-1:0] mem [0:DEPTH-1];
  logic [$clog2(DEPTH)-1:0] head, tail;
  logic [$clog2(DEPTH):0] count;

  wire do_w = w_en & ~full;
  wire do_r = r_en & ~empty;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
      head <= '0; tail <= '0; data_out <= '0; count <= '0;
    end else begin
      case ({do_w, do_r})
        2'b10:   count <= count + 1'b1;
        2'b01:   count <= count - 1'b1;
        default: count <= count;
      endcase
      if (do_w) begin
        mem[tail] <= data_in;
        tail <= (tail == $bits(tail)'(DEPTH-1)) ? '0 : tail + 1'b1;
      end
      if (do_r) begin
        data_out <= mem[head];
        head <= (head == $bits(head)'(DEPTH-1)) ? '0 : head + 1'b1;
      end
    end
  end

  assign full  = (count == ($bits(count))'(DEPTH));
  assign empty = (count == '0);
  assign level = count;
endmodule
