# Running the customised SqueezeNet-1.1 on the FPGA

Verified in simulation on the FPGA top level: `make fpga_full` (fpga_top = SoC + spi_boot_master,
flash model with flash_image, camera frame at 30 fps): class 11 "coffee mug" on the pins and over SPI,
classifier maps bit-exact, 88 jobs, ~239 ms per inference at 100 MHz (boot over SPI: 12 ms, once).

## 1. Compile the model  (any PC, numpy + pillow)
    python3 scripts/compile_squeezenet.py --flash-base 0x0          # or: make model
`--flash-base` = byte offset of the weights in the flash.  If the flash also holds the FPGA bitstream,
put the weights behind it (e.g. `--flash-base 0x400000` on a 16 MB flash) - the offset is built into
the job descriptors, so recompile whenever it changes.  Outputs in build/sqz_custom/:

| file | use |
|---|---|
| flash_image.bin / flash_image.hex | weights (774,576 bytes) - program into the flash at flash-base |
| boot_rom.mem | ROM image for rtl/fpga/spi_boot_master.sv (2,212 SPI writes: camera CSRs, head, 88 jobs, START) |
| job_list.txt | memory plan + job list (read this to understand what the chip does) |
| classes.txt | class id -> name (the LEDs / result pins show the id) |
| frame565.hex, golden.txt, cls_exp.hex, flash_sim.hex | simulation only |

## 2. Simulate first
    make fpga_full            # ~10 min, must print VERDICT: SUCCESS

## 3. Program the flash
* Vivado: `write_cfgmem -format mcs -size 16 -interface SPIx4 -loadbit "up 0x0 top.bit" -loaddata "up 0x400000 build/sqz_custom/flash_image.bin" -file all.mcs`, then program the configuration memory.
* Any other programmer: write flash_image.bin (or the Intel HEX, which already carries the absolute addresses) at flash-base.
* Quad Enable (QE) must be set in the flash status register (the SoC reads with 0x6B quad output). Vivado's SPIx4 programming normally sets it; otherwise set it once with the flash vendor's write-status command.

## 4. Build the bitstream
* Sources: `filelist_fpga.f` (+ include dirs rtl, rtl/axi_qspi_controller), top = `fpga_top`,
  generic `BOOT_HEX = "<abs path>/build/sqz_custom/boot_rom.mem"`.
* Clock: replace `assign clk_sys = clk_board` with a clocking-wizard output; start at 50 MHz.
* Pins: clk_board, rst_btn, cam_* (OV7670 PCLK, VSYNC, HREF, D[7:0], XCLK, PWDN), flash_sck / flash_cs_n /
  flash_io[3:0], led[7:0] (led[5:0] class, led[6] valid, led[7] busy), optional result_o[6:0], host_irq.
  cam_pclk is sampled by the system clock (no clock constraint needed; false-path the camera inputs).
* If the flash is the configuration flash its SCK is a dedicated pin: route flash_sck through STARTUPE2 (Xilinx).
* Memory: act_mem 160 KB + weights 32 KB + descriptors 16 KB + boot ROM 32 KB + FIFOs -> ~60 BRAM36
  (Artix-7 100T: OK, 35T: too small).

## 5. Camera
The OV7670 must be configured over SCCB (I2C) for QVGA 320x240, RGB565, high byte first, with PCLK
<= ~5-6 MHz (30 fps) before START - by an MCU or an SCCB init block (not part of this SoC).
The SoC drives XCLK (dvp_xclk_o) and crops the centre 224x224 itself.

## 6. Run
After reset the boot block programs the SoC (~12 ms at 100 MHz, SCK = clk/16), the SoC captures one
frame, runs the 88 jobs and raises host_irq; the boot block reads RESULT over SPI, clears the IRQ and
starts the next frame (CONTINUOUS = 1).  led[5:0] = class id (classes.txt).  ~2 inferences/s at 50 MHz.
