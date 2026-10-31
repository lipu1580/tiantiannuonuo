#=============================================================================
# 三人合并工程 Makefile（输入 + 音频 + 输出）
#
#   make lint        输入侧 Verilator 检查
#   make sim         输入侧全部 testbench（iverilog）
#   make sim-audio   音频侧（兼容 iverilog 的）testbench
#   make sim-v       音频集成 testbench（需 Verilator）
#   make sim-all     sim + sim-audio + sim-v
#   make run-<tb>    运行单个 testbench，例如：make run-tb_input_top
#   make clean       清理 build 目录
#
#   工具链：Icarus Verilog 12+ / Verilator 5+
#=============================================================================

IVERILOG  ?= iverilog
VVP       ?= vvp
VERILATOR ?= verilator

BUILD     := build
COMMON    := rtl/common
PKG       := $(COMMON)/packages.sv
RTL_INPUT := $(wildcard rtl/input/*.sv) $(wildcard rtl/input/top/*.sv)
RTL_AUDIO := $(wildcard rtl/audio/*.sv) $(wildcard rtl/audio_out/*.sv)
RTL_ALL   := $(RTL_INPUT) $(RTL_AUDIO)
RTL       := $(RTL_ALL)
MODEL     := sim/ads7830_model.sv
INC       := -I$(COMMON)

TBS := \
	tb_key_scan \
	tb_key_debounce \
	tb_key_event_decoder \
	tb_adc_ads7830 \
	tb_fsr_filter \
	tb_expression_mapper \
	tb_event_queue \
	tb_fsr_trigger \
	tb_matrix_config \
	tb_input_event_stub \
	tb_input_top

# 兼容 iverilog 的音频 testbench
AUDIO_TBS := \
	tb_adsr \
	tb_dds_oscillator \
	tb_note_freq_lut \
	tb_pcm_stream_adapter \
	tb_sample_tick_gen \
	tb_section2 \
	tb_voice \
	tb_waveform_rom

# 使用了 iverilog 不支持的 SV 特性，必须用 Verilator 跑
VTB := \
	tb_audio_core \
	tb_audio_test_source \
	tb_event_router \
	tb_voice_manager

.PHONY: all lint lint-audio sim sim-audio sim-v sim-all clean help

all: lint sim

help:
	@echo "make lint         Verilator lint"
	@echo "make sim          运行全部 testbench"
	@echo "make run-<tb>     运行单个 testbench"
	@echo "make clean        删除 build/"

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal -Wno-PINCONNECTEMPTY \
		$(INC) --top-module input_top $(PKG) $(RTL_INPUT)

lint-audio:
	$(VERILATOR) --lint-only -Wall -Wno-fatal -Wno-PINCONNECTEMPTY \
		$(INC) --top-module audio_core $(PKG) $(RTL_AUDIO)

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
		if ! $(VVP) $(BUILD)/$$t.vvp > $(BUILD)/$$t.log 2>&1; then \
			cat $(BUILD)/$$t.log; \
			echo "$$t FAILED (simulator exit status != 0)"; \
			exit 1; \
		fi; \
		cat $(BUILD)/$$t.log; \
		grep -q "TEST PASSED" $(BUILD)/$$t.log || { echo "$$t FAILED"; exit 1; }; \
	done

sim-audio: $(addprefix $(BUILD)/,$(addsuffix .vvp,$(AUDIO_TBS)))
	@set -e; \
	for t in $(AUDIO_TBS); do \
		echo "=============================================================="; \
		echo "RUN $$t"; \
		echo "=============================================================="; \
		if ! $(VVP) $(BUILD)/$$t.vvp > $(BUILD)/$$t.log 2>&1; then \
			cat $(BUILD)/$$t.log; \
			echo "$$t FAILED (simulator exit status != 0)"; \
			exit 1; \
		fi; \
		cat $(BUILD)/$$t.log; \
		grep -qE "PASS|cycle_count = " $(BUILD)/$$t.log || { echo "$$t FAILED"; exit 1; }; \
	done

sim-v: | $(BUILD)
	@set -e; \
	for t in $(VTB); do \
		echo "=============================================================="; \
		echo "RUN $$t (Verilator)"; \
		echo "=============================================================="; \
		$(VERILATOR) --binary --timing -j 1 -Wno-fatal -Wno-lint $(INC) \
			--top-module $$t sim/$$t.sv $(PKG) $(RTL_ALL) -o $$t --Mdir obj_$$t; \
		if ! ./obj_$$t/$$t > $(BUILD)/$$t.log 2>&1; then \
			cat $(BUILD)/$$t.log; \
			echo "$$t FAILED (simulator exit status != 0)"; \
			exit 1; \
		fi; \
		cat $(BUILD)/$$t.log; \
		grep -qE "PASS" $(BUILD)/$$t.log || { echo "$$t FAILED"; exit 1; }; \
	done

sim-all: sim sim-audio sim-v

run-%: $(BUILD)/%.vvp
	$(VVP) $< | tee $(BUILD)/$*.log

clean:
	rm -rf $(BUILD) obj_tb_*
