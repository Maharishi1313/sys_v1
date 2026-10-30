# v3 - SoC integration bring-up (SqueezeNet-1.1 layers 1-2 through the full system)

New test: `make system_sqz` (tb/tb_system_sqz.sv, data from scripts/gen_sqz_l2.py -> hex/sqz_l2/).
Image patch streamed on the DVP pins, weights fetched from the W25Q16JV model over QSPI-XIP by the
sys-DMA, sys_controller sequences everything. Result: layer 0 (conv3x3/s2+ReLU+maxpool) and layer 1
(fire2 squeeze 1x1+ReLU) bit-exact vs a model of the HW arithmetic; vs ONNX max 1 LSB
(20/46656 and 58/11664 values, the count float-QDQ vs fixed-point predicts).

## Bugs fixed (each one blocked or corrupted the run)
| Where | Problem | Fix |
|---|---|---|
| accelerator_top | sys_controller was a stub (M0 tied off), nothing ran | instantiated, IRQs wired, temporary `mcu_cfg_*` port in place of the SPI slave |
| accelerator_top | atfox272 DMA AXI masters are **word** addressed, interconnect/slaves are byte addressed | `<<2` on DVP-DMA AWADDR and sys-DMA AR/AWADDR; controller programs `addr>>2` |
| accelerator_top | QSPI `io_o/io_oe` unconnected - controller could never drive the flash | tri-state pads |
| accelerator_top | sys-DMA pins `m_arsize_o/m_awsize_o/m_wstrb_o` don't exist | constants |
| axi4_sram_slave, QSPI | no BID/RID - interconnect routes responses by echoed ID; DVP DMA stalled after 2 bursts | ID echo |
| ifmap_axi_wrapper | AXI writes always went to the *output* bank; doc map (A @0x6000_0000, B @0x6001_4000) ignored | bank decoded from address |
| sys_controller | DMA / DRC register offsets were byte offsets (x4); IPs use one address per register | word-index offsets (as reference/tb_dvp_dma.sv) |
| sys_controller | QSPI controller never configured for XIP | CLKDIV/MODE/DUMMY/XIP_* sequence (DUMMY=6 for 0x6B, as reference) |
| sys_controller | DVP XLEN ignored 2 bytes/pixel | fixed |
| sys_controller | per-pass param/weight offsets hard-coded for k_len=27 (39-word blocks) | block = k_len+12 words |
| sys_controller | param reads done with `sys_axi_ctrl=0` (WSRAM owned by compute -> wrong data) | AXI owns SRAMs while reading params, compute from PASS_START |
| sys_controller | `reqt_shift[3]` copied from the stale staging register | taken from the read data |
| sys_controller | write engine waited AW then W - double W beat if a slave takes W first | independent handshakes |
| sys_controller | fixed 64-clock maxpool drain | `x_chunks*4 + 32` |
| sys_controller | descriptor SRAM had no write port; no k_len / relu_en in the descriptor | write port + EXT fields (see file header) |
| maxpool_inline | only pad-1 pooling (ShuffleNet); SqueezeNet uses 3x3/s2 pad 0 | `cfg_pool_nopad` (descriptor W13[20]) |
| maxpool_inline | in pad-0 mode the last word of every channel was never written | flush one extra chunk |
| fifo.sv | `module fifo` collided with rtl/common/fifo/sync_fifo/fifo.v | renamed `lane_fifo` |
| pixel_converter, ifmap_axi_wrapper | syntax errors (missing / trailing comma) | fixed |

## Assumptions made by the test (not hardware)
* Flash SR2.QE preset to 1 (needed for Quad Output Read 0x6B).
* The DVP stream carries the already-normalised uint8 `div_q` tensor, planar CHW (no RGB565->planar /
  mean-std in hardware); pixel_converter's XOR 0x80 does uint8 -> int8.
* One 113x113 input patch (80 KB banks cannot hold 3x224x224); ONNX compared on the 27x27 interior.
