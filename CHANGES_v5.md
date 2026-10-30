# v5 - weight chunking, KLEN_W=10, output frames (padding / concat / width masking), fire2 on SoC

Verified: `make system_sqz` (conv1+pool + complete fire2, two back-to-back inferences, bit-exact,
ONNX within 1 LSB), `make conv_default` (incl. new K=576 case, normal + random stalls).

## 1. Weight loading configured by the descriptor (WSRAM stays 32 KB)
* Flash blob of a layer = n_passes blocks of (k_len + 12) words (weights + bias/mult/shift of 4 oc).
  z_out moved to the descriptor (W21[15:8]) - no header word in the blob any more.
* W21[7:0] passes_per_load: the sys-DMA fetches that many pass blocks per transfer (0 = whole
  layer). The compiler picks the largest count with passes_per_load*(k_len+12) <= 8192 words, e.g.
  fire9 expand3x3 (k=576): 13 passes/load -> 5 loads; every layer up to fire5 loads in one go.
* FSM: chunk_first / cur_chunk_n; after the last pass of a chunk it re-enters the weight DMA.

## 2. KLEN_W 9 -> 10 (K up to 1023; SqueezeNet needs 576)

## 3. Output frames (rtl/out_writer.sv, descriptor W16..W20, W22)
* word(c,row,xw) = out_base + (oc_off+oc)*ch_stride + (row+pad)*row_stride + pad + xw
* padded frames for 3x3/pad-1 consumers (one border word left/right, one border row top/bottom),
  border filled with z_out by out_writer before the layer (W22 = number of frames)
* oc_off: Fire concat without any copy (expand1x1 -> ch 0.., expand3x3 -> ch E1..)
* valid_w: pixels beyond the real width (tile padding, e.g. 55 -> 56) are written as z_out
* requant_and_pack / maxpool_inline now only emit (channel, word); their own address outputs are unused

## Descriptor: 32 words / layer (DESC_BASE + layer*128 + word*4), layout in sys_controller.sv header

## Fine-tuning pipeline (ml/finetune_squeezenet.py, runs on Colab/Kaggle, NOT run locally)
camera-faithful preprocessing (320x240 RGB565, centre crop 224 at (48,8)), fine-tune on N classes,
normalisation folded into conv1, int8 QDQ export with the HW constraints enforced (input scale 1/zp 0,
shared concat scale, maxpool keeps scale), accuracy report, raw RGB565 test frames.
