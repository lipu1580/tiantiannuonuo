#=============================================================================
# 成员 2 输入侧工程 Makefile
#
#   make lint        仅做 Verilator 语法/位宽检查
#   make sim         编译并运行全部 testbench（日志写入 build/*.log）
#   make run-TB      运行单个 testbench，例如：make run-tb_input_top
#   make clean       清理 build 目录
#
#   工具链：Icarus Verilog 12+ / Verilator 5+
#=============================================================================

IVERILOG  ?= iverilog
VVP       ?= vvp
VERILATOR ?= verilator

BUILD     := build
RTL_DIR   := rtl/input
COMMON    := rtl/common
PKG       := $(COMMON)/packages.sv
RTL       := $(wildcard $(RTL_DIR)/*.sv)
MODEL     := sim/ads7830_model.sv
INC       := -I$(COMMON)

TBS := \
	tb_key_scan \
	tb_key_debounce \
	tb_adc_ads7830 \
	tb_fsr_filter \
	tb_event_queue \
	tb_fsr_trigger \
	tb_matrix_config \
	tb_input_event_stub \
	tb_input_top

.PHONY: all lint sim clean help

all: lint sim

help:
	@echo "make lint         Verilator lint"
	@echo "make sim          运行全部 testbench"
	@echo "make run-<tb>     运行单个 testbench"
	@echo "make clean        删除 build/"

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal -Wno-PINCONNECTEMPTY \
		$(INC) --top-module input_top $(PKG) $(RTL)

$(BUILD):
	mkdir -p $(BUILD)

# 每个 testbench 一个可执行文件；ads7830_model 对所有 TB 一起编译（未使用无副作用）
$(BUILD)/%.vvp: sim/%.sv $(PKG) $(RTL) $(MODEL) | $(BUILD)
	$(IVERILOG) -g2012 $(INC) -s $* -o $@ $< $(PKG) $(RTL) $(MODEL)

sim: $(addprefix $(BUILD)/,$(addsuffix .vvp,$(TBS)))
	@set -e; \
	for t in $(TBS); do \
		echo "=============================================================="; \
		echo "RUN $$t"; \
		echo "=============================================================="; \
		$(VVP) $(BUILD)/$$t.vvp | tee $(BUILD)/$$t.log; \
		grep -q "TEST PASSED" $(BUILD)/$$t.log || { echo "$$t FAILED"; exit 1; }; \
	done

run-%: $(BUILD)/%.vvp
	$(VVP) $< | tee $(BUILD)/$*.log

clean:
	rm -rf $(BUILD)
