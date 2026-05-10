################################################################################
# AS501/AS603 Final Project — Transformer Build System
################################################################################
# Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST
# All rights reserved.
#  Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
################################################################################
#
# 사용 가능한 타겟:
#   make train              학습 (train 파일 + 별도 val 파일)
#   make export_weights     체크포인트 → Q12 C 배열 변환
#   make server             HOST 추론
#   make riscv              RISC-V ELF + hex
#   make clean / clean_all
#   make help
#
# 가변 인자:
#   make train EPOCHS=50 BATCH=256 BEAM_SIZE=4
#   make riscv MAX_SENTENCES=1
################################################################################

################################################################################
## 디렉토리
################################################################################
PROG_DIR    := .
TC_DIR      := $(PROG_DIR)/test_code
PROC_DIR    := $(PROG_DIR)/processed
OUT_DIR     := $(PROG_DIR)/out
COMMON_DIR  := $(PROG_DIR)/common
TRAIN_DIR   := $(TC_DIR)/output

################################################################################
## 학습 데이터 경로
################################################################################
TRAIN_SRC    := $(TC_DIR)/train_lc_norm_tok.de
TRAIN_TGT    := $(TC_DIR)/train_lc_norm_tok.en
# ── 별도 val 파일 ─────────────────────────────────────────────────────────────
VAL_SRC      := $(TC_DIR)/val_lc_norm_tok.de
VAL_TGT      := $(TC_DIR)/val_lc_norm_tok.en
# ─────────────────────────────────────────────────────────────────────────────
TRAIN_SCRIPT := $(TC_DIR)/train_transformer.py

################################################################################
## 학습 하이퍼파라미터
################################################################################
EPOCHS          ?= 30
BATCH           ?= 256
WARMUP          ?= 4000
MIN_FREQ        ?= 1
N_INPUT         ?= 1
BEAM_SIZE       ?= 4       # Beam Search 크기 (높을수록 BLEU ↑)
BLEU_SAMPLES    ?= 200     # BLEU 평가 샘플 수 (0=전체)
BLEU_EVERY      ?= 5       # 몇 epoch마다 BLEU 계산
CHECKPOINT      ?= $(TRAIN_DIR)/transformer_best.pt

################################################################################
## 서버 실행
################################################################################
MAX_SENTENCES   ?= 1
ifeq ($(MAX_SENTENCES), 0)
  MAX_SENT_FLAG :=
else
  MAX_SENT_FLAG := --max-sentences $(MAX_SENTENCES)
endif

################################################################################
## RISC-V 툴체인
################################################################################
RISCV_PREFIX    ?= riscv32-unknown-elf-
CC               := $(RISCV_PREFIX)gcc
OBJCOPY          := $(RISCV_PREFIX)objcopy
OBJDUMP          := $(RISCV_PREFIX)objdump
LINKER_SCRIPT    := $(COMMON_DIR)/sections_tb.lds
STARTUP          := $(COMMON_DIR)/start.s
B2H              := $(COMMON_DIR)/b2h_converter

RISCV_ARCH      := rv32im
RISCV_ABI       := ilp32
PROG_NAME       := eval_transformer_riscv

CFLAGS_RISCV    := -march=$(RISCV_ARCH)                       \
                   -mabi=$(RISCV_ABI)                         \
                   -O2 -Wall -Wextra -std=c11                 \
                   -DRISCV                                    \
                   -DMAX_SENTENCES_OVERRIDE=$(MAX_SENTENCES)  \
                   -I$(TC_DIR)                                \
                   -nostdlib -fno-builtin

LDFLAGS_RISCV   := -T $(LINKER_SCRIPT)                       \
                   -Wl,-Map=$(OUT_DIR)/mem.map                \
                   -Wl,--gc-sections

SRCS_RISCV      := $(STARTUP)                               \
                   $(TC_DIR)/eval_transformer_q.c           \
                   $(TC_DIR)/int_model_transformer_q12.c    \
                   $(TC_DIR)/arena.c                        \
                   $(TC_DIR)/result.c

################################################################################
## HOST 컴파일
################################################################################
CC_HOST          := gcc
PROG_NAME_SERVER := eval_transformer_server

CFLAGS_SERVER   := -O2 -Wall -Wextra -std=c11                \
                   -DSERVER                                   \
                   -DMAX_SENTENCES_OVERRIDE=$(MAX_SENTENCES)  \
                   -I$(TC_DIR)

SRCS_SERVER     := $(TC_DIR)/eval_transformer_q.c           \
                   $(TC_DIR)/int_model_transformer_q12.c    \
                   $(TC_DIR)/arena.c                        \
                   $(TC_DIR)/result.c

################################################################################
## BLEU 평가
################################################################################
REPORT_SCRIPT   := $(PROG_DIR)/utils/report_iomem_dump.py
IOMEM_DUMP      := $(OUT_DIR)/lstm_iomem_dump.txt

################################################################################
## Phony
################################################################################
.PHONY: all train resume export_weights server report riscv \
        clean clean_all help \
        _check_data _check_checkpoint _check_weights \
        _copy_weights _gen_hex _mkdir

all: help

################################################################################
## [1] make train
##     train 파일로 학습, val 파일로 검증 (BLEU 매 5 epoch 출력)
################################################################################
train: _check_data _mkdir
	@echo "============================================================"
	@echo " [train] Transformer 학습"
	@echo "   TRAIN_SRC : $(TRAIN_SRC)"
	@echo "   TRAIN_TGT : $(TRAIN_TGT)"
	@echo "   VAL_SRC   : $(VAL_SRC)"
	@echo "   VAL_TGT   : $(VAL_TGT)"
	@echo "   EPOCHS    : $(EPOCHS)"
	@echo "   BATCH     : $(BATCH)"
	@echo "   BEAM_SIZE : $(BEAM_SIZE)  (BLEU 평가용)"
	@echo "   목표 BLEU  : 15.0"
	@echo "============================================================"
	python3 $(TRAIN_SCRIPT)              \
	    --src         $(TRAIN_SRC)       \
	    --tgt         $(TRAIN_TGT)       \
	    --val_src     $(VAL_SRC)         \
	    --val_tgt     $(VAL_TGT)         \
	    --out_dir     $(TRAIN_DIR)       \
	    --epochs      $(EPOCHS)          \
	    --batch       $(BATCH)           \
	    --warmup      $(WARMUP)          \
	    --min_freq    $(MIN_FREQ)        \
	    --beam_size   $(BEAM_SIZE)       \
	    --bleu_samples $(BLEU_SAMPLES)   \
	    --bleu_every  $(BLEU_EVERY)      \
	    --n_input     $(N_INPUT)
	$(MAKE) _copy_weights
	@echo "============================================================"
	@echo " [train] 완료. 다음: make server  또는  make riscv"
	@echo "============================================================"

################################################################################
## [1b] make resume
##      이전 체크포인트에서 이어서 학습
##      make resume EPOCHS=60   # 30 epoch까지 했으면 60까지 이어서
################################################################################
resume: _check_data _mkdir
	@echo "============================================================"
	@echo " [resume] 이전 체크포인트에서 이어서 학습"
	@echo "   CHECKPOINT: $(CHECKPOINT)"
	@echo "   목표 EPOCHS: $(EPOCHS)"
	@echo "============================================================"
	python3 $(TRAIN_SCRIPT)              \
	    --src         $(TRAIN_SRC)       \
	    --tgt         $(TRAIN_TGT)       \
	    --val_src     $(VAL_SRC)         \
	    --val_tgt     $(VAL_TGT)         \
	    --out_dir     $(TRAIN_DIR)       \
	    --epochs      $(EPOCHS)          \
	    --batch       $(BATCH)           \
	    --warmup      $(WARMUP)          \
	    --min_freq    $(MIN_FREQ)        \
	    --beam_size   $(BEAM_SIZE)       \
	    --bleu_samples $(BLEU_SAMPLES)   \
	    --bleu_every  $(BLEU_EVERY)      \
	    --n_input     $(N_INPUT)         \
	    --resume                         \
	    --checkpoint  $(CHECKPOINT)
	$(MAKE) _copy_weights
	@echo " [resume] 완료"

################################################################################
## [2] make export_weights
################################################################################
export_weights: _check_checkpoint _mkdir
	@echo " [export_weights] $(CHECKPOINT) → C 배열 변환"
	python3 $(TRAIN_SCRIPT)              \
	    --src         $(TRAIN_SRC)       \
	    --tgt         $(TRAIN_TGT)       \
	    --val_src     $(VAL_SRC)         \
	    --val_tgt     $(VAL_TGT)         \
	    --out_dir     $(TRAIN_DIR)       \
	    --n_input     $(N_INPUT)         \
	    --export_only                    \
	    --checkpoint  $(CHECKPOINT)
	$(MAKE) _copy_weights

_copy_weights: _check_weights
	@echo " [copy] C 배열 → test_code/"
	cp $(TRAIN_DIR)/int_model_transformer_q12.c $(TC_DIR)/int_model_transformer_q12.c
	cp $(TRAIN_DIR)/int_model_transformer_q12.h $(TC_DIR)/int_model_transformer_q12.h
	cp $(TRAIN_DIR)/input_data.h                $(TC_DIR)/input_data.h
	@mkdir -p $(PROC_DIR)
	cp $(TRAIN_DIR)/vocab_src.txt               $(PROC_DIR)/vocab_src.txt
	cp $(TRAIN_DIR)/vocab_tgt.txt               $(PROC_DIR)/vocab_tgt.txt
	@echo " [copy] 완료"

################################################################################
## [3] make server
################################################################################
server: _check_weights _mkdir
	@echo " [server] HOST 추론  (MAX_SENTENCES=$(MAX_SENTENCES))"
	$(CC_HOST) $(CFLAGS_SERVER) $(SRCS_SERVER) \
	    -o $(OUT_DIR)/$(PROG_NAME_SERVER) -lm
	$(OUT_DIR)/$(PROG_NAME_SERVER)              \
	    --out-hyp            $(PROC_DIR)/val.hyp.tf_q.u32bin          \
	    --out-result-txt     $(PROC_DIR)/val.result_mem.tf_q.txt      \
	    --out-result-summary $(PROC_DIR)/val.result_summary.tf_q.txt  \
	    $(MAX_SENT_FLAG)
	@echo " [server] 완료"
	@cat $(PROC_DIR)/val.result_summary.tf_q.txt 2>/dev/null || true

################################################################################
## [4] make report (시뮬레이션 후 sim/ 에서 run_report.sh 로 실행)
################################################################################
report:
	@echo "============================================================"
	@echo " BLEU 계산은 시뮬레이션 이후 sim/ 에서 실행하세요:"
	@echo "   cd ../sim && bash run_report.sh"
	@echo "============================================================"

################################################################################
## [5] make riscv
################################################################################
riscv: _check_weights _mkdir
	@echo "============================================================"
	@echo " [riscv] RISC-V 컴파일  (MAX_SENTENCES=$(MAX_SENTENCES))"
	@echo "============================================================"
	$(CC) $(CFLAGS_RISCV) $(SRCS_RISCV) $(LDFLAGS_RISCV) \
	    -o $(OUT_DIR)/$(PROG_NAME).elf
	$(OBJDUMP) -d $(OUT_DIR)/$(PROG_NAME).elf \
	    > $(OUT_DIR)/$(PROG_NAME).dis
	$(MAKE) _gen_hex
	@echo " [riscv] 완료"
	@ls -lh $(OUT_DIR)/*.hex 2>/dev/null || true

## sections_tb.lds 실제 섹션 기준 hex 추출
_gen_hex:
	@echo " [hex] IMEM  (INSTRAM:   0x00000000, 128KB)"
	$(OBJCOPY) -O binary                        \
	    --only-section=.text                    \
	    --only-section=.rodata                  \
	    --only-section=.srodata                 \
	    $(OUT_DIR)/$(PROG_NAME).elf             \
	    $(OUT_DIR)/$(PROG_NAME).imem.bin
	$(B2H) $(OUT_DIR)/$(PROG_NAME).imem.bin     \
	       $(OUT_DIR)/$(PROG_NAME).imem.hex

	@echo " [hex] DMEM  (DATARAM_L: 0x00200000, 16MB)"
	$(OBJCOPY) -O binary                        \
	    --only-section=.data                    \
	    --only-section=.sdata                   \
	    --only-section=.weights                 \
	    --only-section=.label                   \
	    --only-section=.arena                   \
	    --only-section=.bss                     \
	    $(OUT_DIR)/$(PROG_NAME).elf             \
	    $(OUT_DIR)/$(PROG_NAME).dmem.bin
	$(B2H) $(OUT_DIR)/$(PROG_NAME).dmem.bin     \
	       $(OUT_DIR)/$(PROG_NAME).dmem.hex

	@echo " [hex] IOMEM (DATARAM_H: 0x20000000, 512KB)"
	$(OBJCOPY) -O binary                        \
	    --only-section=.input                   \
	    --only-section=.result                  \
	    $(OUT_DIR)/$(PROG_NAME).elf             \
	    $(OUT_DIR)/$(PROG_NAME).iomem.bin
	$(B2H) $(OUT_DIR)/$(PROG_NAME).iomem.bin    \
	       $(OUT_DIR)/$(PROG_NAME).iomem.hex

################################################################################
## [6] clean
################################################################################
clean:
	rm -f $(OUT_DIR)/*.elf $(OUT_DIR)/*.dis $(OUT_DIR)/*.bin \
	      $(OUT_DIR)/*.hex $(OUT_DIR)/*.log $(OUT_DIR)/mem.map \
	      $(OUT_DIR)/$(PROG_NAME_SERVER)                     \
	      $(PROC_DIR)/val.hyp.tf_q.u32bin                    \
	      $(PROC_DIR)/val.result_mem.tf_q.txt                \
	      $(PROC_DIR)/val.result_summary.tf_q.txt
	@echo " [clean] 완료"

clean_all: clean
	rm -rf $(TRAIN_DIR)
	rm -f $(TC_DIR)/int_model_transformer_q12.c              \
	      $(TC_DIR)/int_model_transformer_q12.h              \
	      $(TC_DIR)/input_data.h
	rm -f $(PROC_DIR)/vocab_src.txt $(PROC_DIR)/vocab_tgt.txt
	@echo " [clean_all] 완료"

################################################################################
## 체크 헬퍼
################################################################################
_check_data:
	@test -f $(TRAIN_SRC) || { echo "[ERROR] 없음: $(TRAIN_SRC)"; exit 1; }
	@test -f $(TRAIN_TGT) || { echo "[ERROR] 없음: $(TRAIN_TGT)"; exit 1; }
	@test -f $(VAL_SRC)   || { \
	    echo "[ERROR] val 파일 없음: $(VAL_SRC)"; \
	    echo "        val_lc_norm_tok.de 를 test_code/ 에 배치하세요."; exit 1; }
	@test -f $(VAL_TGT)   || { \
	    echo "[ERROR] val 파일 없음: $(VAL_TGT)"; \
	    echo "        val_lc_norm_tok.en 를 test_code/ 에 배치하세요."; exit 1; }
	@python3 -c "import torch" 2>/dev/null || { \
	    echo "[ERROR] PyTorch 미설치.  pip install torch numpy"; exit 1; }

_check_checkpoint:
	@test -f $(CHECKPOINT) || { \
	    echo "[ERROR] 체크포인트 없음: $(CHECKPOINT)"; \
	    echo "        먼저 make train 을 실행하세요."; exit 1; }
	@python3 -c "import torch" 2>/dev/null || { \
	    echo "[ERROR] PyTorch 미설치."; exit 1; }

_check_weights:
	@test -f $(TRAIN_DIR)/int_model_transformer_q12.c || { \
	    echo "[ERROR] 가중치 없음. make train 먼저 실행하세요."; exit 1; }

_mkdir:
	@mkdir -p $(OUT_DIR) $(PROC_DIR) $(TRAIN_DIR)

################################################################################
## help
################################################################################
help:
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║  AS501 Final Project — Transformer Build System              ║"
	@echo "╠══════════════════════════════════════════════════════════════╣"
	@echo "║  필수 파일 (test_code/ 안에 배치):                          ║"
	@echo "║    train_lc_norm_tok.de / .en  ← 학습 데이터               ║"
	@echo "║    val_lc_norm_tok.de   / .en  ← 검증 데이터 (별도)        ║"
	@echo "╠══════════════════════════════════════════════════════════════╣"
	@echo "║  HOST 플로우                                                 ║"
	@echo "║    make train              학습 (처음부터)                  ║"
	@echo "║    make resume EPOCHS=60   이어서 학습 (가중치 유지)        ║"
	@echo "║    make server             HOST 추론                        ║"
	@echo "║  RISC-V 플로우                                               ║"
	@echo "║    make train  또는  make resume                            ║"
	@echo "║    make riscv              ELF + hex 생성                   ║"
	@echo "║    cd ../sim && bash run_vcs.sh                             ║"
	@echo "╠══════════════════════════════════════════════════════════════╣"
	@echo "║  가변 인자 예시                                              ║"
	@echo "║    make train  EPOCHS=30 BATCH=256 BEAM_SIZE=4              ║"
	@echo "║    make resume EPOCHS=60           ← 30→60 이어서 학습      ║"
	@echo "║    make resume EPOCHS=80           ← 60→80 이어서 학습      ║"
	@echo "║    make riscv  MAX_SENTENCES=1                              ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"
	@echo ""
