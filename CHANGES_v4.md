# v4 - SoC shell: MCU SPI port, system CSRs, classifier head, result pins

Verified by `make system_sqz`: two back-to-back inferences driven only through the SPI pins
(descriptors, head config, start, result/status read-back, IRQ clear) + DVP + QSPI flash.

## New / changed units
| Unit | What it does |
|---|---|
| `rtl/spi_slave_axi.sv` (AXI master M3) | MCU SPI slave, mode 0, SCK <= clk/8. `0x02 addr data{data..}` write (auto-increment), `0x03 addr dummy8 data` read. Reaches the whole memory map. |
| `rtl/sys_csr.sv` (AXI slave S5) | control / status / IRQ / result / head-config registers + descriptor window, `host_irq` |
| `sys_controller` classifier head | after the last layer: score[c] = sum of class map c, argmax -> RESULT, pins |
| `sys_controller` run control | DONE -> idle; every START re-arms camera + DMA for a new frame |
| `accelerator_top` | 4-master interconnect, reset synchroniser, result pins, trap aggregation |
| `adma_desc_queue.v` (IP bug) | done-flag clear only ever hit descriptor slot 0 -> 2nd use of slot 1 never raised its IRQ (hung on the 2nd inference; camera DMA would hang on frame 4) |
| sys-DMA config slave IDs | 4-bit IDs on a 6-bit port lost the master index -> responses always went to M0 |

## Pins
| Pin | Dir | |
|---|---|---|
| `clk`, `rst_n` | in | rst_n async assert, synchronised release |
| `dvp_*` (pclk, vsync, hsync, href, d[7:0], xclk, pwdn) | | camera |
| `qspi_sck`, `qspi_cs_n`, `qspi_io[3:0]` | | weight flash (quad, XIP) |
| `mcu_spi_sck/cs_n/mosi/miso` | | MCU control + result read-back (detection results: read SRAM over SPI) |
| `host_irq` | out | inference done (level until IRQ W1C) |
| `result_o[6:0]` | out | binary class id (up to 128 classes), enabled by PIN_CFG[0] |
| `result_valid_o` | out | result_o valid (cleared by the next START) |
| `busy_o` | out | inference running |

## Memory map (MCU view over SPI)
| Address | |
|---|---|
| 0x0000_0000 | DVP-DMA regs (word index) / 0x0001_0000 DVP-RX regs |
| 0x2000_0000 | QSPI flash XIP window / 0x2800_0000 QSPI regs |
| 0x4000_0000 | sys-DMA regs |
| 0x6000_0000 / 0x6001_4000 | activation bank A / bank B (80 KB each) |
| 0x8000_0000 | weight SRAM (32 KB) |
| 0xA000_0000 | CSRs: 00 CTRL(start, #layers) 04 STATUS 08 IRQ(W1C) 0C IRQ_EN 10 RESULT 14 SCORE 18 HEAD_CFG{words,classes} 1C HEAD_BASE 20 PIN_CFG 24 ID=0x5ACE0001 |
| 0xA001_0000 | layer descriptors, layer*64 + word*4 (format in sys_controller.sv header) |

(This replaces the 0xC000_0000 / 0x1000_0000 MCU addresses in the memory-map document, which
fell outside the 6-slave decode.)
