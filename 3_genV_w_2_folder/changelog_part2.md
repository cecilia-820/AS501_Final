# Changelog Part 2: Create DMA Controller

## Files Created
- `rtl/dma/dma_controller.sv` — DMA controller module
- `rtl/dma/dma_controller.h` — C header with MMIO helpers

## Changes

### 1. Created dma_controller.sv
- **What**: New DMA controller that transfers bulk data between external DMEM (4-cycle latency) and on-chip SPM (1-cycle latency).
- **Why**: CPU doing word-by-word loads from DMEM to SPM would cost 4+ cycles per word. DMA frees the CPU to poll STATUS while data moves autonomously.
- **How**:
  - 5 MMIO registers: SRC_ADDR (0x00), DST_ADDR (0x04), LEN (0x08), CTRL (0x0C), STATUS (0x10)
  - Control port: 1-cycle ready (same pattern as GEMV accel)
  - FSM: `StIdle -> StReadReq -> StReadWait -> StWriteReq -> StWriteWait -> (loop or StDone)`
  - Direction auto-detected: if `src_addr` is in DMEM range -> DMEM-to-SPM; if in SPM range -> SPM-to-DMEM
  - DMEM access: pulse `mem_req_o` for 1 cycle, then count 4 cycles (matching D_MEMORY behavior)
  - SPM access: pulse `spm_req_o` for 1 cycle, data available after 1 cycle (registered read)
  - Two separate memory ports: `mem_*` for DMEM arbiter, `spm_*` for SPM arbiter
  - Per-word transfer: read from source, buffer data, write to destination, increment addresses, decrement counter
  - Parameters: `DMEM_START_BYTE`, `DMEM_END_BYTE`, `SPM_START_BYTE`, `SPM_END_BYTE`, `LATENCY_CYCLES`
- **Verify**: Write SRC=DMEM addr, DST=SPM addr, LEN=N, CTRL=1. Poll STATUS until done bit set. Then CPU can read SPM directly at 1-cycle latency.

### 2. Created dma_controller.h
- **What**: C header with `#define` macros for MMIO registers and helper functions `dma_to_spm()` / `dma_from_spm()`.
- **Why**: Provides clean software API for DMA operations.
- **How**: `dma_to_spm(dmem_src, spm_offset, n_words)` writes registers then polls STATUS. `dma_from_spm(spm_offset, dmem_dst, n_words)` does the reverse.
