## ============================================================================
## boolean_vital_soc.xdc -- Real Digital Boolean Board (XC7S50-CSGA324-1)
## Complete Constraints File for VitalSoC
## ============================================================================

# ----------------------------------------------------------------------------
# 100 MHz System Clock
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {clk}]
create_clock -period 10.000 -name sys_clk [get_ports {clk}]

# ----------------------------------------------------------------------------
# Bank 0 Voltage & Configuration
# ----------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ----------------------------------------------------------------------------
# CPU Reset Push-Button (Active-High)
# Mapped to on-board push button BTN0 (J2). Pressing BTN0 resets the SoC.
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports {btn_rst}]

# ----------------------------------------------------------------------------
# User Push-Buttons (btn[2:0], Active-High)
# The Boolean board has 4 push-buttons total: BTN0 is used for reset (btn_rst),
# leaving BTN1, BTN2, and BTN3 for user software.
# Unconnected register bits [4:3] read 0 per VitalSoC specification.
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {btn[0]}];  # BTN1
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {btn[1]}];  # BTN2
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports {btn[2]}];  # BTN3

# ----------------------------------------------------------------------------
# 16 On-Board Slide Switches (sw[15:0])
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN T2 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN P2 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
set_property -dict {PACKAGE_PIN P1 IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
set_property -dict {PACKAGE_PIN N2 IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
set_property -dict {PACKAGE_PIN M2 IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
set_property -dict {PACKAGE_PIN L1 IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33} [get_ports {sw[15]}]

# ----------------------------------------------------------------------------
# 16 On-Board Single-Color LEDs (led[15:0])
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN F2 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN E5 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN E6 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN C3 IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN A2 IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN B3 IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports {led[15]}]

# ----------------------------------------------------------------------------
# On-Board USB-UART Bridge (Host PC Communication)
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {UART_rxd}]
set_property -dict {PACKAGE_PIN U11 IOSTANDARD LVCMOS33} [get_ports {UART_txd}]

# ----------------------------------------------------------------------------
# I2C Master Interface (MAX30102 Pulse Oximeter Sensor)
# Connected to PmodA (3.3V):
#   PmodA Pin 1 (B13): SCL
#   PmodA Pin 2 (A13): SDA
#   PmodA Pin 5: GND
#   PmodA Pin 6: 3V3
# (FPGA internal pullups enabled; external 4.7k pullups on sensor module also supported)
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {i2c_scl}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {i2c_sda}]

## Alternative: Digilent standard I2C Pmod pinout (Pins 3 & 4 of PmodA):
# set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {i2c_scl}]; # PmodA Pin 3
# set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {i2c_sda}]; # PmodA Pin 4

## Alternative: PmodC (Pins 1 & 2):
# set_property -dict {PACKAGE_PIN T6  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {i2c_scl}]; # PmodC Pin 1
# set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {i2c_sda}]; # PmodC Pin 2
