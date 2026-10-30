#!/bin/sh
# Usage:  ./run.sh            -> unit tests + main testbench (default config)
#         ./run.sh all        -> also the stress configurations (2-value buffer words, tiny FIFOs)
set -e
# INITIALDLY: the small unit tests drive stimulus with <= inside initial blocks (fine in Verilator 5; conv_tb uses #1 instead)
FLAGS="--binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-INITIALDLY"
SRCS="buffer.sv mme.sv fifo_controller.sv fifo.sv pe4x4.v pe_v2.v ifmap_feeder.sv"
OUT=${OUT:-/tmp/mme_build}; mkdir -p "$OUT"

echo "== unit tests =="
for t in tb_fifo tb_pe; do
  verilator $FLAGS --top-module $t tb_units.sv fifo.sv pe_v2.v -Mdir $OUT/$t -o sim >/dev/null
  $OUT/$t/sim | grep -E "PASS|FAIL"
done

run_cfg () {   # name, extra verilator flags
  verilator $FLAGS $2 --top-module conv_tb conv_tb.sv $SRCS -Mdir $OUT/$1 -o sim >/dev/null
  echo "== conv_tb  [$1] =="
  $OUT/$1/sim | grep -E "config|^\[|->|coverage|^TOTAL|PASSED|FAILED|PASS [12]"
}
run_cfg default ""
if [ "$1" = "all" ]; then
  run_cfg b2        "-DUSE_B2"
  run_cfg depth5    "-DFIFO_DEPTH_OVR=5"
  run_cfg b2_depth5 "-DUSE_B2 -DFIFO_DEPTH_OVR=5"
fi
