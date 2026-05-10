# Changelog Part 0: Verify Inline ASM Optimization in Software

## Files Modified
- `program/test_code/eval_int_c.c` — Added RISC-V inline ASM to `i64_mul_i32()`

## Changes

### 1. Replaced software 64-bit multiply with inline ASM (eval_int_c.c, lines 213-270)
- **What**: Added `#ifdef RISCV` block in `i64_mul_i32()` that uses `mul` + `mulh` inline assembly instead of the pure-C 16-bit decomposition algorithm.
- **Why**: The original `i64_mul_i32()` was a ~50-instruction software emulation of 32x32->64 multiplication using four 16-bit partial products. With the RV32IM hardware multiplier, this can be done in just 2 instructions (`mul` for low 32 bits, `mulh` for high 32 bits). This function is called by `mul_shift_q()` (used in LSTM gate activations: sigmoid, tanh element-wise ops) and `dot_shift_q()` (used in `linear_out_argmax`), so the speedup is significant.
- **How**:
  - `asm volatile("mul %[lo], %[a], %[b]")` emits the RV32M `mul` instruction producing the lower 32 bits of `a*b`
  - `asm volatile("mulh %[hi], %[a], %[b]")` emits `mulh` producing the upper 32 bits (signed)
  - The result pair `{lo, hi}` is returned directly without any software carry propagation
  - The `#else` branch preserves the original C implementation for SERVER (x86) builds
- **Verify**: After `make riscv`, check disassembly for `mul`/`mulh` instruction pairs in `i64_mul_i32`. In simulation, `linear_out_argmax` and LSTM gate computation should complete in fewer cycles.

## Analysis

### Q12 multiply path
- `mul_shift_q(a, b, 12)` calls `i64_mul_i32(a, b)` then `i64_sar_to_i32(result, 12)` — now 2 HW instructions + shift instead of ~50 SW instructions.
- `dot_shift_q()` calls `i64_mul_i32()` in a loop — each iteration is now 2 instructions instead of ~50.
- No changes needed to `q12_add` — it's plain int32 addition.

### GEMV path (RISCV build)
- `lstm_step_int()` already uses `gemv_hw()` for the GEMV portion, so `dot_shift_q()` is NOT called there.
- However, `linear_out_argmax()` still calls `dot_shift_q()` for the output projection (5897 vocab x 128 hidden), so the inline ASM optimization benefits this hot path significantly.
