# Step 1 Changelog: LSTM to Transformer SW Switch

## Overview
Replaced LSTM inference code with Transformer (encoder-decoder) inference code.
No RTL/HW changes. GEMV accelerator exists but is NOT called. All computation is pure CPU software.

## Files Changed

### New files (copied from TF_Training_DH/test_code/)
- `program/test_code/eval_transformer_q.c` — Transformer inference (replaces eval_int_c.c)
- `program/test_code/int_model_transformer_q12.c` — Quantized Q12 weight arrays
- `program/test_code/int_model_transformer_q12.h` — Model constants and weight declarations

### Modified files
- **program/test_code/eval_transformer_q.c**
  - Added `#ifdef RISCV` inline ASM block for `i64_mul_i32()` with `"=&r"` early-clobber
  - Changed DEFAULT_OUT paths to match existing report infrastructure
  - Set `args.max_sentences = MAX_SENTENCES_OVERRIDE` for server builds

- **program/test_code/int_model_transformer_q12.c**
  - Added `#define PLACE_IN_MODEL __attribute__((section(".weights"), used))`
  - Applied `PLACE_IN_MODEL` to all 52 weight array definitions (prevents IMEM overflow)

- **program/test_code/input_data.h**
  - Changed from inline `static const` definitions to `extern` declarations
  - Required because Harvard architecture CPU cannot load data from IMEM addresses

- **program/test_code/input_data.c**
  - Rewritten with TF input data (1 sentence: "ein mann boxt")
  - Uses `__attribute__((section(".input"), used))` to place in IOMEM

- **program/Makefile**
  - SRCS: eval_int_c.c -> eval_transformer_q.c, int_model_q12.c -> int_model_transformer_q12.c
  - Added `--no-relax` linker flag (critical: prevents gp register mis-initialization)
  - Added `-O2` optimization, `-DMAX_SENTENCES_OVERRIDE` for server builds
  - Simplified `run_server` target (TF code uses hardcoded output paths)

- **program/utils/update_tb_pc_addrs.py**
  - Updated PC_SYMBOL_MAP for TF function names
  - Made missing symbols non-fatal (warning instead of error)

- **sim/tb/lstm_tb.sv**
  - Updated HANG_PC from 0x34 to 0x3c (shifted by --no-relax adding 8 bytes for gp setup)
  - Replaced LSTM PC entries with TF entries (PC_LAYER_NORM, PC_MULTI_HEAD_ATTENTION)
  - Updated counters: lstm_step_hit_cnt -> mha_hit_cnt, gemv_hw_hit_cnt -> ln_hit_cnt
  - ResultStart auto-updated by update_tb_pc_addrs.py

## Key Issues and Resolutions

### 1. IMEM Overflow (weight arrays in .rodata)
**Problem**: TF weight arrays (28MB source) were `const int32_t` without section attribute, causing them to land in `.rodata` -> INSTRAM (128KB limit).
**Fix**: Added `PLACE_IN_MODEL __attribute__((section(".weights"), used))` to all arrays.

### 2. Input Data in IMEM (Harvard architecture)
**Problem**: Input data defined as `static const` in header -> placed in `.rodata` -> INSTRAM. CPU data loads cannot access IMEM addresses (separate instruction/data buses).
**Fix**: Created separate `input_data.c` with `.input` section attribute, changed header to `extern` declarations.

### 3. Linker Relaxation Bug (gp register)
**Problem**: RISC-V linker relaxation (`--relax`, default) incorrectly optimized the `lui gp, %hi(__global_pointer$)` instruction to a NOP, leaving gp=0. Any gp-relative data access then used address 0+offset instead of 0x200000+offset, crashing with DMEM out-of-range.
**Fix**: Added `-Wl,--no-relax` to prevent linker relaxation. This adds 8 bytes to code (full `lui+addi` for gp), shifting HANG_PC from 0x34 to 0x3c.

### 4. Inline ASM Early-Clobber
**Problem**: `i64_mul_i32()` needed `"=&r"` constraint on `mul`/`mulh` outputs to prevent register reuse between the two instructions.
**Fix**: Added `#ifdef RISCV` block with proper `"=&r"` constraints.

## Results

| Metric | Value |
|--------|-------|
| Server BLEU | N/A (1 sentence only) |
| Server HYP | "man running men ." |
| RTL HYP | "man running man ." |
| RTL Cycles | 172,412,938 (~172M) |
| RTL Wall Time | 884 sec (~15 min) |
| IMEM Usage | ~7 KB / 128 KB |
| DMEM Usage | ~10.2 MB / 16 MB |
| Compilation | -O2 with --no-relax |

## Model Parameters
- D_MODEL=64, N_HEADS=4, D_HEAD=16, D_FF=128
- 2 encoder layers, 2 decoder layers
- SRC_VOCAB=18726, TGT_VOCAB=10214
- Pre-LayerNorm variant, softermax (base-2 exponential)
