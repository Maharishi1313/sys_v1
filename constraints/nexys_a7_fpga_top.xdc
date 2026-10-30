## =============================================================================
## Nexys A7-100T - fpga_top (camera + SqueezeNet SoC + VGA)
## Pin numbers from the Digilent Nexys-A7-100T master XDC - verify against yours.
## =============================================================================
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk_board]
create_clock -period 10.000 -name clk_board [get_ports clk_board]

## ---- buttons / switch / LEDs
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports cpu_resetn]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports btnc]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports sw0]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33} [get_ports {led[15]}]

## ---- VGA (12-bit)
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports {vga_r[0]}]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports {vga_r[1]}]
set_property -dict {PACKAGE_PIN C5 IOSTANDARD LVCMOS33} [get_ports {vga_r[2]}]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports {vga_r[3]}]
set_property -dict {PACKAGE_PIN C6 IOSTANDARD LVCMOS33} [get_ports {vga_g[0]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {vga_g[1]}]
set_property -dict {PACKAGE_PIN B6 IOSTANDARD LVCMOS33} [get_ports {vga_g[2]}]
set_property -dict {PACKAGE_PIN A6 IOSTANDARD LVCMOS33} [get_ports {vga_g[3]}]
set_property -dict {PACKAGE_PIN B7 IOSTANDARD LVCMOS33} [get_ports {vga_b[0]}]
set_property -dict {PACKAGE_PIN C7 IOSTANDARD LVCMOS33} [get_ports {vga_b[1]}]
set_property -dict {PACKAGE_PIN D7 IOSTANDARD LVCMOS33} [get_ports {vga_b[2]}]
set_property -dict {PACKAGE_PIN D8 IOSTANDARD LVCMOS33} [get_ports {vga_b[3]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports vga_hs]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports vga_vs]

## ---- OV7670 on Pmod JA (data) + JB (control)       <- change to match your wiring
##   JA1..JA4 = D0..D3, JA7..JA10 = D4..D7
##   JB1 PCLK  JB2 HREF  JB3 VSYNC  JB4 XCLK  JB7 SIOC  JB8 SIOD  JB9 RESET  JB10 PWDN
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports {cam_d[0]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {cam_d[1]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {cam_d[2]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {cam_d[3]}]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {cam_d[4]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {cam_d[5]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {cam_d[6]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {cam_d[7]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports cam_pclk]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports cam_href]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports cam_vsync]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports cam_xclk]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports cam_sioc]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports cam_siod]
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports cam_reset_n]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports cam_pwdn]

## camera pins are sampled / driven asynchronously (PCLK is over-sampled, never a clock)
set_false_path -from [get_ports {cam_pclk cam_href cam_vsync cam_d[*] cam_siod}]
set_false_path -to   [get_ports {cam_xclk cam_sioc cam_siod cam_reset_n cam_pwdn led[*]}]

## ---- weight flash on Pmod JC (weights from address 0)   <- change to match your module
##   Digilent PmodSF3-style pinout: 1 CS#  2 DQ0 (MOSI)  3 DQ1 (MISO)  4 SCK  7 DQ2 (WP#)  8 DQ3 (HOLD#)
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33}                        [get_ports flash_cs_n]
set_property -dict {PACKAGE_PIN F6 IOSTANDARD LVCMOS33 PULLUP TRUE}            [get_ports {flash_io[0]}]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33 PULLUP TRUE}            [get_ports {flash_io[1]}]
set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33 SLEW FAST}              [get_ports flash_sck]
set_property -dict {PACKAGE_PIN E7 IOSTANDARD LVCMOS33 PULLUP TRUE}            [get_ports {flash_io[2]}]
set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33 PULLUP TRUE}            [get_ports {flash_io[3]}]

## SoC <-> video clock domains only exchange synchronised status bits
## (only relevant with USE_CLK_WIZ; harmless otherwise)
set_false_path -to [get_ports {flash_sck flash_cs_n flash_io[*] vga_*}]
