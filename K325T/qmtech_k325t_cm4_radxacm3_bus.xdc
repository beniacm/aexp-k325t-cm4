## CM4 bus section for a Radxa CM3 (RK3566) in the carrier instead of the Luckfox Core3566
## (build.sh radxacm3 puts this in place of the "CM bus" section of qmtech_k325t_cm4.xdc).
## Radxa follows the Raspberry Pi functions: the bridge is the Rockchip's spi3-m0 master
## (/dev/spidev3.0, the same device name as on the Luckfox):
##   CLK BCM11 D13 (GPIO4_B3), MOSI BCM10 C13 (GPIO4_B2), MISO BCM9 D14 (GPIO4_B0), CS0 BCM8 A12 (GPIO4_A6)
## rk_miso (D14) is the only FPGA output on the bus; the AExp core uses no other CM4 line (no video
## input: the Linux picture is the MEGA65 core's feature).
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_sck]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_mosi]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33 PULLUP TRUE}   [get_ports rk_cs_n]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33 DRIVE 8}       [get_ports rk_miso]
## Unused pins keep the base file's UNUSEDPIN PULLUP (as the MEGA65 radxacm3 core, proven on this
## board): BCM7 (B12) turned out to be GPIO4_C5, an ordinary 3.3 V pad, not SARADC_VIN3 (pin test
## 2026-11-10), so a weak pull-up is harmless there; carrier inputs driven only by the FPGA do not
## float; BCM15 (A15, the module's debug-console RX) idles high as it should (a pull-down = break).
