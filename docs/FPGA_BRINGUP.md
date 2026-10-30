# Running the customised SqueezeNet-1.1 on the FPGA (Nexys A7-100T)

Board assumed: Digilent Nexys A7-100T (100 MHz clock, 12-bit VGA, Pmods JA..JD). OV7670 on JA (D0..D7)
+ JB (PCLK, HREF, VSYNC, XCLK, SIOC, SIOD, RESET, PWDN); weight flash on JC, weights at address 0.
Constraints: constraints/nexys_a7_cam_vga_test.xdc, constraints/nexys_a7_fpga_top.xdc - check the pin
numbers against Digilent's master XDC and your jumper wiring.

## 0. Camera bring-up first (camera -> monitor, no SoC)
Vivado project: top `cam_vga_test_top`, sources rtl/fpga/{ov7670_sccb_init, ov7670_capture,
frame_buffer, vga_display, cam_vga_test_top}.sv, constraints/nexys_a7_cam_vga_test.xdc.  Simulated by
`make cam_vga` (SCCB writes decoded, frame buffer + VGA timing checked).
* LED0 = registers written, LED2 = PCLK seen, LED3 = HREF seen, LED1 blinks per frame,
  LED15..8 count frames.  BTNC rewrites the registers, SW0 hides the crop box.
* Monitor: 640x480, picture 2x zoomed, yellow box = the 224x224 the network sees.
* No LED2: check XCLK wiring / power.  No LED0 change / dark picture: check SIOC/SIOD wiring and
  pull-ups (the module usually has them).  Wrong colours: byte order (register 0x3A TSLB) or the
  colour matrix in ov7670_sccb_init.sv.  Upside down / mirrored: register 0x1E = 0x30.


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

## 4. Build the bitstream (top = fpga_top: camera + SoC + live VGA)
* Sources: every file in `filelist_fpga.f` (include dirs rtl, rtl/axi_qspi_controller; mark
  rtl/global.svh and rtl/axi_qspi_controller/*.svh as global includes if Vivado asks), top = `fpga_top`,
  constraints/nexys_a7_fpga_top.xdc.  Add build/sqz_custom/boot_rom.mem to the project (or set the
  generic `BOOT_HEX` to its absolute path).
* Clock: create a Clocking Wizard IP `clk_wiz_0` (in 100 MHz; out1 50 MHz, out2 100 MHz; active-high
  reset; locked) and add the Verilog define `USE_CLK_WIZ`.  The SoC then runs at 50 MHz, camera/VGA at 100.
* Pins: clk_board, rst_btn, cam_* (OV7670 PCLK, VSYNC, HREF, D[7:0], XCLK, PWDN), flash_sck / flash_cs_n /
  flash_io[3:0], led[7:0] (led[5:0] class, led[6] valid, led[7] busy), optional result_o[6:0], host_irq.
  cam_pclk is sampled by the system clock (no clock constraint needed; false-path the camera inputs).
* The weight flash is on a Pmod, so flash_sck is an ordinary pin (no STARTUPE2).
* Memory: act_mem 160 KB + weights 32 KB + descriptors 16 KB + boot ROM 32 KB + FIFOs -> ~60 BRAM36
  (Artix-7 100T: OK, 35T: too small).

## 5. Camera
fpga_top configures the OV7670 itself (ov7670_sccb_init: QVGA RGB565, XCLK 25 MHz, PCLK 6.25 MHz,
~15 fps) and holds the boot master in reset until that is done.  The same pins feed the SoC and
the VGA frame buffer, so the monitor shows exactly what is classified.

## 6. Run
After reset the boot block programs the SoC (~12 ms at 100 MHz, SCK = clk/16), the SoC captures one
frame, runs the 88 jobs and raises host_irq; the boot block reads RESULT over SPI, clears the IRQ and
starts the next frame (CONTINUOUS = 1).  ~2 inferences/s at 50 MHz.
LEDs: 5:0 class id (classes.txt), 6 valid, 7 busy, 8 camera configured, 9 SoC programmed,
10 frame toggle, 15:11 inference count.  VGA: the class id as 7 squares (MSB left), green when valid.
