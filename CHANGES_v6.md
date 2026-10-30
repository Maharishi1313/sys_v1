# v6 - Option A step 1: camera front end, unified activation memory, row-streaming

Verified:
* `make system_cam` - 320x240 RGB565 frame on the DVP pins at a 30 fps pixel rate (PCLK 5 MHz),
  224x224 centre crop on chip, conv1+ReLU+maxpool and fire2-squeeze run in 14 row stripes WHILE the
  frame arrives (first stripe 3.6 ms after the frame starts, stage done 3.5 ms after the last row),
  all 224 rows correct in their slots, no overrun, 55x55x16 squeeze map bit-exact vs the full-image
  model, argmax head on pins + SPI.
* `make system_sqz` - fire2 patch test through the new path (RAW camera mode), 2 inferences, bit-exact.
* `make conv_default` - unchanged.

## New units
| Unit | |
|---|---|
| `rtl/cam_frontend.sv` (AXI master M1, replaces pixel_converter + DVP DMA path) | crop window, RGB565 -> RGB888 -> int8, row-planar rows (R[w] G[w] B[w]) so conv1 reads them directly (chstep = w, ystep = 3w); stripe slots with halo rows written twice; rows_done for the controller; consume handshake; overrun flag; RAW mode (bytes as received). Line buffer = 3 byte-enable word planes (BRAM friendly). |
| `rtl/act_mem.sv` (S3, replaces ping_pong_buffer + ifmap_axi_wrapper) | one 160 KB space (5 dual-port 32 KB sub-banks), compute R/W and AXI concurrently; AXI W never stalled, colliding compute writes queued in order (16 deep, `cq_overflow` -> STATUS[10]) |

## Changed
* `sys_controller`: arms cam_frontend, runs the job list immediately; descriptor W23[0] wait for
  camera rows >= W24, W23[1] release a camera slot at job end; absolute activation addresses
  (W01 base / W16 out_base), bank flipping removed; DRC frame size from CSR; dead DVP-DMA,
  z_out-load and DMA-concat states removed.
* `sys_csr`: camera registers 0x40..0x60 (frame, crop, mode, slot buffer, stripe geometry, status);
  STATUS[11] camera overrun.  HEAD_BASE is now an absolute AXI byte address.
* `dvp_dma_wrapper`: exports the pixel stream; its DMA is idle (kept for the register map).
* Top: `DVP_IMG_W/H` parameters removed (camera geometry is in CSRs).

## Finding
The interconnect's W path (sa_W_channel register stage + skid buffer) duplicates a beat when the
slave drops WREADY inside a burst (seen as rows shifted by one word).  act_mem now never
back-pressures W; other slaves only take single beats.  Worth fixing in the IP before anything
else back-pressures W.

## Memory plan used for stage 1 at 224 (act_mem words)
camera slots 0..9575 (3 x 19 rows x 672 B), pool stripe buffer 9600.., padded fire2-squeeze map
13312..27903 (16 x 57 x 16 words).  ~68 % of act_mem.
