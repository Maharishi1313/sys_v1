# What was wrong / what changed

Evidence levels:  **[R]** reproduced on your ORIGINAL file in simulation ·
**[M]** mutation-tested (putting the bug back into the fixed design makes `conv_tb` fail) ·
**[L]** found by reading, not simulated on the original.

## pe_v2.v
| # | Problem | Effect | Fix |
|---|---|---|---|
| 1 | `if(overflow)..; if(underflow).. else acc_next = acc_next_i` : the final `else` overwrites the overflow case | positive overflow never saturates. 4×32767² gave **-262140** instead of 2147483647 **[R]** | real `else if` chain |
| 2 | The MAC counter wraps at **N** (array size = 4), not at the number of products per output | only dot products of length 4 are possible; K=9 or K=C_in is wrong **[M]** | new input `k_len` (MACs per output), set per tile |
| 3 | no way to freeze the PE | a starved feeder creates a bubble, and a bubble in a skewed array pairs the wrong A and B values **[M]** (without the freeze: 26835 errors) | new input `en`: all registers hold when 0 |
| 4 | dead `outA_r/outB_r` registers | none (lint noise) | removed |

## pe4x4.v
| # | Problem | Fix |
|---|---|---|
| 5 | The 4 PEs of a row share ONE bus, but nothing says which column (= output channel) a result belongs to | new outputs `col1..col4` **[L]** |
| 6 | (after adding `en`) while frozen the PE keeps `out_valid` high; capturing it each clock duplicates results **[M]** | capture only when `en` |
| 7 | `en`, `k_len` plumbing | added |

## fifo.sv
| # | Problem | Effect | Fix |
|---|---|---|---|
| 8 | `empty = (head == tail)` is also true when the FIFO is **full** | a full FIFO reports empty=1 and cannot be read **[R]**, **[M]** | `empty = (count == 0)` |
| 9 | no fill level | controller cannot do flow control | new output `level` |

## fifo_controller.sv  (rewritten, same idea: FIFOs + staggered read enables)
| # | Problem | Fix |
|---|---|---|
| 10 | `en_ctr` used (line 170, 189) before its declaration (line 203): illegal in the LRM, rejected by strict tools | declared first |
| 11 | `en_ctr` counts to N+1, so `en_sig[N-k]` is written with index -1 **[L]** | counter saturates at N-1 |
| 12 | `en_ctr`, `addr_reg_*`, `line_ctr`, `inter_ctr` are cleared only by reset, so tile #2 starts with no stagger and wrong addresses **[L]** | everything is loaded by `start` |
| 13 | buffer address increments forever; no length, no flow control; writes to a full FIFO are dropped silently | fetch exactly `k_steps` steps, request only if there is room (credit rule `level+2 <= DEPTH`) |
| 14 | `fifo_out_valid <= fifo_ren` : a read blocked by `empty` is reported as valid data **[L]** | valid = a real read happened |
| 15 | a lane running dry mid-tile breaks the A/B pairing **[M]** | whole array freezes (`adv=0`) until every active lane has data |
| 16 | `line_ctr` is `[-1:0]` (2 bits) when B == N and indexes outside the FIFO array | width >= 1, wraps at N/B |
| 17 | `col_ctr` is never used; `feed_done` was an *input* nobody could drive correctly | removed / now an output |
| 18 | NEW: A side reads lane streams from `ifmap_feeder` (on-the-fly im2col) instead of a pre-lowered buffer | `src_a`, `src_a_valid`, `src_a_pop` |
| 19 | NEW: `hold` input freezes the array (use it for output-buffer back-pressure) | `ext_stall` on `mme` |

## mme.sv
Now contains feeder + controller + PE array. Ports: removed `feed_done` input; added `start`, `k_len`, `cfg_*`,
`col1..4`, `tile_done`, `busy`, `ext_stall`. `flush_acc` stays (abort/clear only; do NOT pulse it between tiles).

## mme_tb.sv (your old testbench)  -> replaced by conv_tb.sv
`feed_done` and `flush_acc` were never initialised (X) for the first 500 ns, and both were pulsed together at the end, which kills
whatever is still in the pipeline. It also had no checker. It cannot be used any more because `mme`'s ports changed.

## Assumed because the files were not uploaded
`global.svh` (W=16, N=4, B=4, ACC_WIDTH=40, OUT_WIDTH=32, FIF_DEPTH=8, BUF_SIZE=8192), `buffer` (stand-in: 1-clock read
latency, `r_valid_out` follows `ren`), `op_buffer` (not needed: the testbench captures the result buses itself).
Rules the design needs: `B` and `FIF_DEPTH`>= N+1; feeder queue depth >= 2*B + kernel width.
