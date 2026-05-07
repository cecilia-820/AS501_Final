# Changelog Part 5: Parallelize GEMV Accelerator (8-way MAC)

## Files Modified
- `rtl/accel/gemv_accel.sv` — Replaced sequential MAC with 8-way parallel MAC + adder tree

## Changes

### 1. Added N_PE parameter and parallel MAC datapath
- **What**: Added `localparam int unsigned N_PE = 8` and combinational logic for 8 parallel multipliers plus a 3-stage adder tree.
- **Why**: The old sequential MAC did 1 multiply-accumulate per cycle in StCompute, taking K cycles for a K-element dot product. With 8 PEs, it takes ceil(K/8) cycles — an 8x speedup on the compute phase.
- **How**:
  - 8 products: `product[i] = row_buf[col+i] * vec_buf[col+i]` (masked to 0 if index >= cols)
  - Adder tree stage 1: `sum_s1[0..3]` = pairwise sums of 8 products → 4 values
  - Adder tree stage 2: `sum_s2[0..1]` = pairwise sums of 4 values → 2 values
  - Adder tree stage 3: `sum_s3` = final sum of 2 values → 1 value
  - All combinational (single-cycle)

### 2. Modified StCompute state (gemv_accel.sv)
- **What**: Instead of incrementing `col_cnt` by 1 each cycle, it now advances by N_PE (8).
- **Why**: Each cycle processes 8 elements simultaneously.
- **How**:
  - First iteration (`col_cnt == 0`): `acc = sum_s3` (reset accumulator with first batch)
  - Subsequent iterations: `acc = acc + sum_s3` (accumulate)
  - `col_cnt += 8`, capped at `cols` to trigger store transition
  - When `col_cnt >= cols`: transition to StStore
  - Non-multiple-of-8 handling: the product masking (`if col+i < cols then multiply, else 0`) ensures invalid lanes contribute 0 to the sum

### 3. Moved accumulator update to combinational (acc_d)
- **What**: Changed `acc_q` update from sequential (inside always_ff) to combinational (`acc_d` in always_comb, registered in always_ff).
- **Why**: The parallel MAC result needs to be computed combinationally and then registered. The old sequential approach (`acc_q <= acc_q + product`) doesn't work with 8 simultaneous products.

### 4. Removed unused `row_elem_q` signal
- **What**: Removed the single-element row latch that was unused.
- **Why**: The row buffer `row_buf[MAX_DIM]` stores all elements; no single-element latch needed.

### 5. External interface unchanged
- **What**: MMIO registers (MAT_ADDR, VEC_ADDR, OUT_ADDR, ROWS, COLS, CTRL, STATUS) remain identical.
- **Why**: Software (`gemv_accel.h`, `gemv_hw()`) doesn't need to change. The parallelization is purely internal.

## Performance Analysis
- **Old**: K cycles for K-element dot product (128 cols → 128 compute cycles per row)
- **New**: ceil(K/8) cycles (128 cols → 16 compute cycles per row)
- **Bottleneck shift**: With 8x faster compute, the dominant cost becomes DMA loads (K cycles for StLoadRow per row), unchanged. Total per-row improvement for K=128: old = 128+128 = 256 cycles compute+load → new = 16+128 = 144 cycles.
- **Overall GEMV speedup**: ~1.8x for K=128 (load-dominated). For larger K or with double-buffering, speedup would be higher.

## Verify
- In simulation, StCompute duration should be ~ceil(K/8) cycles instead of K cycles.
- Output values should be bit-identical to the sequential version (same accumulation order, same Q12 shift).
- `[ACCEL] DONE!` message should appear sooner after `LOAD_ROW done`.
