VERILATOR ?= verilator

#地址
BUILF_DIR = build/verilator/$(RTL_NAME)
RTL_DIR := rtl/audio
TB_DIR := sim

#目标与tb文件
RTL_NAME := sample_tick_gen
TB_NAME := tb_sample_tick_gen
suffix := .sv
RTL_FILE = $(addsuffix $(suffix), $(RTL_NAME))
TB_FILE = $(addsuffix $(suffix), $(TB_NAME))

VFLAGS = --binary --timing 

.PHONY: tick clean

tick:
	mkdir -p $(BUILF_DIR)
	$(VERILATOR) $(VFLAGS) --top-module $(TB_NAME) --Mdir $(BUILF_DIR) $(RTL_DIR)/$(RTL_FILE) $(TB_DIR)/$(TB_FILE)
	$(BUILF_DIR)/V$(TB_NAME)

clean:
	rm -rf build