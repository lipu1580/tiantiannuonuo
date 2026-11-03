# Board oscillator: 27 MHz. audio_ce is an enable, not a clock.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]
# Baseline internal timing only. External interface timing is not certified
# by this constraint; verify I2S and I2C timing against the actual hardware.
