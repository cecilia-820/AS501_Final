
##################################################################################
## AS501/AS603                                                                        ##
##################################################################################
## Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       ##
## All rights reserved.                                                         ##
##                                                                              ##
##                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) ##
##                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)##
##################################################################################

##############################################################################################
# Recommended flow A (host evaluation):
#   make preprocess
#   make export                 # default SPLIT=val
#   make server                 # default MAX_SENTENCES=1   # make server MAX_SENTENCES=0 # run all sentences
#   make report
#
# Recommended flow B (riscv build):
#   make preprocess
#   make export                 # default SPLIT=val
#   make riscv
#
# [0] preprocess: regenerate ./processed from ./dataset (from scratch)
#   - remove existing ./processed first
#   - build vocab files (vocab_src.txt, vocab_tgt.txt) from train split
#   - convert train/val/(test if exists) into *.ids and *.u32bin datasets
#   make preprocess
#
# [1] export: generate input C sources (test_code/input_data.h/.c)
#   make export              # default SPLIT =val
#   make export SPLIT=val
#   make export SPLIT=test
#
# [2] server: host build + run (split auto-detected from input_data.h)
#   make server                   #
#   make server MAX_SENTENCES=1
#   make server MAX_SENTENCES=0  Make all the sentences
#
#
# [3] riscv: bare-metal build + hex generation using current input_data.h/.c,
#            then update sim/tb/lstm_tb.sv to match the latest ELF/mem.map
#   make riscv 
#   # default is MAX_SENTENCES=1 (estimated time: 1day)
#   # set MAX_SENTENCES=0 to run all sentences
#
# [4] report: evaluate latest val/test hypothesis (auto-detect split by newest *.hyp.int_c.u32bin)
#   make report              #default SAMPLES=10
#   make report SAMPLES=10   #sample random 10 sentences
#
# [5] cleanup
#   make clean      # remove out/* and generated hypothesis files
#   make clean_all  # remove out/*, processed/, and test_code/input_data*
##############################################################################################




.PHONY: \
	all \
	export export_val_inputs export_test_inputs export_inputs \
	preprocess \
	check_riscv_tools check_elf2hex \
	sync_tb_addrs \
	build_server run_server server report \
	riscv riscv_build hex clean clean_all

SPLIT ?= val
# Default: run 1 sentence. Set MAX_SENTENCES=0 to run all sentences.
# estimated time: 1day
MAX_SENTENCES ?= 1
SAMPLES ?= 10

PYTHON ?= $(shell command -v python3 2>/dev/null || command -v python 2>/dev/null)
HOST_CC ?= gcc

TOOLCHAIN ?= /opt/riscv/bin/riscv32-unknown-elf-
RISCV_CC ?= $(TOOLCHAIN)gcc
RISCV_OBJDUMP ?= $(TOOLCHAIN)objdump
RISCV_OBJCOPY ?= $(TOOLCHAIN)objcopy
ELF2HEX ?= $(COMMON_DIR)/b2h_converter

PROGRAM_DIR := .
AS501_ROOT := ..
UTILS_DIR := $(PROGRAM_DIR)/utils
TEST_CODE_DIR := $(PROGRAM_DIR)/test_code
COMMON_DIR := $(PROGRAM_DIR)/common
OUT_DIR := $(PROGRAM_DIR)/out
PROCESSED_DIR := $(PROGRAM_DIR)/processed
PT_PATH := $(AS501_ROOT)/best_lstm_de2en_v2_int_q12.pt
MODEL_H := $(TEST_CODE_DIR)/int_model_transformer_q12.h
MODEL_C := $(TEST_CODE_DIR)/int_model_transformer_q12.c
INPUT_H := $(TEST_CODE_DIR)/input_data.h
SERVER_BIN := $(OUT_DIR)/eval_transformer_server
RISCV_ELF := $(OUT_DIR)/eval_int_riscv.elf
RISCV_DIS := $(OUT_DIR)/eval_int_riscv.dis
RISCV_IMEM_BIN := $(OUT_DIR)/eval_int_riscv_imem.bin
RISCV_IMEM_HEX := $(OUT_DIR)/eval_int_riscv_imem.hex
RISCV_DMEM_BIN := $(OUT_DIR)/eval_int_riscv_dmem.bin
RISCV_DMEM_HEX := $(OUT_DIR)/eval_int_riscv_dmem.hex
RISCV_INPUT_BIN := $(OUT_DIR)/eval_int_riscv_input.bin
RISCV_INPUT_HEX := $(OUT_DIR)/eval_int_riscv_input.hex
RISCV_RESULT_BIN := $(OUT_DIR)/eval_int_riscv_result.bin
RISCV_RESULT_HEX := $(OUT_DIR)/eval_int_riscv_result.hex

MEMORY_BYTE_WIDTH ?= 4
DMEM_SIZE ?= 134217728

VOCAB_SRC := $(PROCESSED_DIR)/vocab_src.txt
VOCAB_TGT := $(PROCESSED_DIR)/vocab_tgt.txt
REPORT_PY := $(UTILS_DIR)/report.py
UPDATE_TB_PY := $(UTILS_DIR)/update_tb_pc_addrs.py

all: export

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

export_val_inputs:
	@test -n "$(PYTHON)" || (echo "Python interpreter not found. Set PYTHON=python3 or install Python." && exit 127)
	$(PYTHON) $(PROGRAM_DIR)/utils/export_inputs_to_header.py \
		--processed $(PROCESSED_DIR) \
		--split val \
		--out-h $(INPUT_H) \
		--out-c $(INPUT_C)

export_test_inputs:
	@test -n "$(PYTHON)" || (echo "Python interpreter not found. Set PYTHON=python3 or install Python." && exit 127)
	$(PYTHON) $(PROGRAM_DIR)/utils/export_inputs_to_header.py \
		--processed $(PROCESSED_DIR) \
		--split test \
		--out-h $(INPUT_H) \
		--out-c $(INPUT_C)

export_inputs:
ifeq ($(SPLIT),test)
	$(MAKE) export_test_inputs
else
	$(MAKE) export_val_inputs
endif

export: export_inputs

preprocess:
	@test -n "$(PYTHON)" || (echo "Python interpreter not found. Set PYTHON=python3 or install Python." && exit 127)
	rm -rf $(PROCESSED_DIR)
	$(PYTHON) $(UTILS_DIR)/preprocess_uint32_all.py

build_server: | $(OUT_DIR)
	$(HOST_CC) -O2 -std=c11 -DSERVER -DMAX_SENTENCES_OVERRIDE=$(MAX_SENTENCES) -o $(SERVER_BIN) \
		$(TEST_CODE_DIR)/eval_transformer_q.c \
		$(TEST_CODE_DIR)/result.c \
		$(MODEL_C) \
		$(TEST_CODE_DIR)/input_data.c \
		$(TEST_CODE_DIR)/arena.c

run_server: build_server
	cd $(PROGRAM_DIR) && $(SERVER_BIN)
server: run_server

report:
	@test -n "$(PYTHON)" || (echo "Python interpreter not found. Set PYTHON=python3 or install Python." && exit 127)
	@set -e; \
	VAL_HYP="$(PROCESSED_DIR)/val.hyp.int_c.u32bin"; \
	TEST_HYP="$(PROCESSED_DIR)/test.hyp.int_c.u32bin"; \
	if [ -f "$$TEST_HYP" ] && { [ ! -f "$$VAL_HYP" ] || [ "$$TEST_HYP" -nt "$$VAL_HYP" ]; }; then \
		FLAGS="--test"; \
		HYP_BIN="$(PROCESSED_DIR)/test.hyp.int_c.u32bin"; \
		REF_BIN="$(PROCESSED_DIR)/test.tgt.u32bin"; \
		SRC_BIN="$(PROCESSED_DIR)/test.src.u32bin"; \
		echo "[Report] detected split=test ($$HYP_BIN)"; \
	elif [ -f "$$VAL_HYP" ]; then \
		FLAGS=""; \
		HYP_BIN="$(PROCESSED_DIR)/val.hyp.int_c.u32bin"; \
		REF_BIN="$(PROCESSED_DIR)/val.tgt.u32bin"; \
		SRC_BIN="$(PROCESSED_DIR)/val.src.u32bin"; \
		echo "[Report] detected split=val ($$HYP_BIN)"; \
	else \
		echo "[Report] No hypothesis file found. Run make server first."; \
		exit 1; \
	fi; \
	PYTHONIOENCODING=utf-8 $(PYTHON) $(REPORT_PY) \
		$$FLAGS \
		--hyp-bin $$HYP_BIN \
		--ref-bin $$REF_BIN \
		--src-bin $$SRC_BIN \
		--vocab-src $(VOCAB_SRC) \
		--vocab-tgt $(VOCAB_TGT) \
		--samples $(SAMPLES)

check_riscv_tools:
	@command -v $(RISCV_CC) >/dev/null 2>&1 || (echo "RISC-V GCC not found: $(RISCV_CC)" && echo "Set TOOLCHAIN=... (e.g. /opt/riscv/bin/riscv32-unknown-elf-)" && exit 127)
	@command -v $(RISCV_OBJDUMP) >/dev/null 2>&1 || (echo "RISC-V OBJDUMP not found: $(RISCV_OBJDUMP)" && echo "Set TOOLCHAIN=... (e.g. /opt/riscv/bin/riscv32-unknown-elf-)" && exit 127)
	@command -v $(RISCV_OBJCOPY) >/dev/null 2>&1 || (echo "RISC-V OBJCOPY not found: $(RISCV_OBJCOPY)" && echo "Set TOOLCHAIN=... (e.g. /opt/riscv/bin/riscv32-unknown-elf-)" && exit 127)

check_elf2hex:
	@test -x $(ELF2HEX) || (echo "ELF2HEX converter not found or not executable: $(ELF2HEX)" && exit 127)

riscv: sync_tb_addrs

riscv_build: check_riscv_tools | $(OUT_DIR)
	$(RISCV_CC) -march=rv32im_zicsr -mabi=ilp32 -O2 -DRISCV -DMAX_SENTENCES_OVERRIDE=$(MAX_SENTENCES) -Wl,-Bstatic,--no-relax,-T$(COMMON_DIR)/sections_tb.lds,-Map=$(OUT_DIR)/mem.map -ffreestanding -nostartfiles \
		-o $(RISCV_ELF) \
		$(COMMON_DIR)/start.s \
		$(TEST_CODE_DIR)/eval_transformer_q.c \
		$(TEST_CODE_DIR)/arena.c \
		$(TEST_CODE_DIR)/result.c \
		$(TEST_CODE_DIR)/input_data.c \
		$(MODEL_C)
	$(RISCV_OBJDUMP) --disassemble-all -d $(RISCV_ELF) > $(RISCV_DIS)

hex: riscv_build check_elf2hex
	$(RISCV_OBJCOPY) -O binary -j .text $(RISCV_ELF) $(RISCV_IMEM_BIN)
	$(ELF2HEX) $(RISCV_IMEM_BIN) $(RISCV_IMEM_HEX) $(MEMORY_BYTE_WIDTH) $(DMEM_SIZE)
	$(RISCV_OBJCOPY) -O binary -j .data -j .sdata -j .rodata -j .weights $(RISCV_ELF) $(RISCV_DMEM_BIN)
	$(ELF2HEX) $(RISCV_DMEM_BIN) $(RISCV_DMEM_HEX) $(MEMORY_BYTE_WIDTH) $(DMEM_SIZE)
	$(RISCV_OBJCOPY) --dump-section .input=$(RISCV_INPUT_BIN) $(RISCV_ELF)
	$(ELF2HEX) $(RISCV_INPUT_BIN) $(RISCV_INPUT_HEX) $(MEMORY_BYTE_WIDTH) $(DMEM_SIZE)
	$(RISCV_OBJCOPY) --dump-section .result=$(RISCV_RESULT_BIN) $(RISCV_ELF)
	$(ELF2HEX) $(RISCV_RESULT_BIN) $(RISCV_RESULT_HEX) $(MEMORY_BYTE_WIDTH) $(DMEM_SIZE)

sync_tb_addrs: hex
	@test -n "$(PYTHON)" || (echo "Python interpreter not found. Set PYTHON=python3 or install Python." && exit 127)
	$(PYTHON) $(UPDATE_TB_PY)

clean:
	rm -rf $(OUT_DIR) \
		$(PROCESSED_DIR)/val.result_mem.int_c.txt \
		$(PROCESSED_DIR)/val.result_summary.int_c.txt \
		$(PROCESSED_DIR)/val.hyp.int_c.u32bin \
		$(PROCESSED_DIR)/test.hyp.int_c.u32bin

clean_all:
	rm -rf $(OUT_DIR) \
		$(PROCESSED_DIR) \
		$(TEST_CODE_DIR)/input_data.h \
		$(TEST_CODE_DIR)/input_data.c \
		$(TEST_CODE_DIR)/input_data_val.h \
		$(TEST_CODE_DIR)/input_data_val.c \
		$(TEST_CODE_DIR)/input_data_test.h \
		$(TEST_CODE_DIR)/input_data_test.c
