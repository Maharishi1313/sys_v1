# Round 2: pipelined Booth PE + int8 operands + 32-bit accumulator/output

All numbers below were checked in simulation (Verilator 5.020). Regression: 4 configurations x 3,220 convolution tiles
(+ random freezes) = 0 errors; unit tests PASS; 7 re-inserted bugs all detected.

## 1. Files that CHANGED
| File | What changed | Why |
|---|---|---|
| `global.svh` | `W` 16 -> **8**; `ACC_WIDTH` 40 -> **32**; `OUT_WIDTH` `2*W` -> **32** (now written explicitly) | int8 operands, 32-bit accumulator, 32-bit PE output. `OUT_WIDTH = 2*W` would have given 16 bits. |
| `pe_v2.v` | Rewritten around **your** `pe_v2_1.v` (same 3 stages, Booth multiplier, zero gate) + the round-1 additions (`en`, `k_len`) + a **33-bit saturating accumulate**. New parameters `ACCW`, `OUTW` (default = global). | see section 3 |
| `conv_tb.sv` | Test data is now full-range int8 (30 % zeros, -128, 127 corners) | exercise the Booth corners and the zero gate |
| `tb_units.sv` | PE test rewritten (random dot products, K=1..20, random freezes, 32-bit saturation) + new `tb_pe_sat` (same RTL with a 20-bit accumulator) | saturation cannot be reached with int8 data at K <= 65535, so it is tested by presetting `acc` and with a narrow accumulator |
| `run.sh` | compiles the 6 multiplier files, runs `tb_pe_sat` | |

## 2. Files ADDED (yours, copied untouched)
`Booth_Multiplier.v  Booth_Encoder.v  Wallace_Tree.v  CSA.v  FA.v  KSA.v`
Tested exhaustively on all 65,536 signed 8x8 combinations: **0 errors**.
New: `trace_tb.sv` prints a clock-by-clock trace of one tile (the one used in the explainer document).

## 3. Files that did NOT need a code change (they are parameterised by W / OUT_WIDTH)
`pe4x4.v`, `fifo.sv`, `fifo_controller.sv`, `ifmap_feeder.sv`, `mme.sv`, `buffer.sv`.
With W=8 the data buses shrink automatically: FIFO entries are 8 bits, one buffer word (B=4 values) is 32 bits,
the four result buses are 32 bits. The skew/valid timing is identical because the new PE has the same 3 stages as before.

## 4. Problems found in the files you uploaded
| # | Where | Problem | Evidence |
|---|---|---|---|
| 1 | `pe_v2_1.v` | **Saturation is dead code when ACC_WIDTH == OUT_WIDTH.** The sum `acc + product` is only 32 bits wide, so `acc_next_i > OUT_MAX` can never be true: overflow silently wraps. | reproduced on your file: acc = 2^31-16, +24 -> **-2147483640** instead of 2147483647 |
| 2 | `pe_v2_1.v` | counter wraps at `N` (= 4, the array size), so only dot products of length 4 work. | same bug as round 1 |
| 3 | `pe_v2_1.v` | no `en` freeze input. | needed by the feeder's flow control |
| 4 | `pe_v2_1.v` | dead registers `outA_r/outB_r`; `zero_s1 ? 0 : product_comb` is redundant (the multiplier inputs are already zero). | lint only |
| 5 | `Wallace_Tree.v` | the comment "C1[15] is always 0" is wrong (it is the majority of bit 15 of the three partial products, so it is 1 whenever at least two of them are negative). Dropping it is still **correct**, because everything is modulo 2^16 and the true product fits in 16 bits. | exhaustive test, 0 errors |
| 6 | (note) | with int8 x int8, overflow of a 32-bit accumulator needs more than 131,072 products into ONE output (max product = 16384). The saturation logic is a safety net that is practically never reached. You may delete it to save an adder bit and two comparators. | arithmetic |

Not changed (intentional): `zero_s2` branch (acc is simply left alone when the product is zero) - it is equivalent to adding 0.

## 5. Rules the PE now has (important)
* `k_len` must stay constant from `start` until `tile_done` (the equality compare would miss if it changed while products are in flight).
* `en = 0` freezes every register in the PE; capture of results on `outputbusN` happens only when `en = 1`.

## 6. Ideas NOT implemented (only if timing needs it)
* Stage 2 contains two carry-propagate adders in series (the 16-bit KSA that makes -M inside `Booth_Encoder`, then the final KSA)
  plus two CSA levels. Typical fixes: build -M as `~M` and feed the missing "+1" into the Wallace tree as an extra bit; and/or
  put a register after the second CSA (a 4-stage PE). A 4th stage only shifts when results appear (the controller counts
  results, it does not assume a latency), but `zero_s2` and the valid flags then need one more delay register.
