# Changelog Part 6: Update Testbench

## Files Modified
- `sim/tb/lstm_tb.sv` — Added SPM/DMA parameters and passed them to DUT

## Changes

### 1. Added SPM and DMA localparams (lstm_tb.sv, after line 19)
- **What**: Added `SPM_START_W`, `SPM_DEPTH_W`, `DMA_START_W`, `DMA_DEPTH_W` localparam declarations matching the memory map.
- **Why**: CPU_TOP now requires these parameters to configure MCU address decoding and DMA controller.
- **How**: Same word-address format as existing IMEM/DMEM/IOMEM parameters.

### 2. Updated CPU_TOP instantiation (lstm_tb.sv, DUT section)
- **What**: Added `.SPM_START_W(SPM_START_W)`, `.SPM_DEPTH_W(SPM_DEPTH_W)`, `.DMA_START_W(DMA_START_W)`, `.DMA_DEPTH_W(DMA_DEPTH_W)` to the DUT parameter list.
- **Why**: Without these, VCS would use defaults from cpu_top.sv (which happen to be correct), but explicit parameterization ensures consistency and makes the TB self-documenting.

## Verify
- VCS compilation should succeed with no unconnected port warnings.
- `DUT.u_spm.req_i` should be observable in waveforms when CPU or DMA accesses SPM.
- `DUT.u_dma.state_q` should show FSM transitions during DMA transfers.
- No new external memory modules needed — SPM and DMA controller are internal to CPU_TOP.
