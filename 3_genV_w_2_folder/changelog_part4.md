# Changelog Part 4: Modify cpu_top.sv — Wire SPM, DMA, and Update Arbiter

## Files Modified
- `rtl/cpu_top.sv` — Full integration of SPM, DMA controller, updated arbiter
- `sim/run_vcs.sh` — Added new RTL files to compile list

## Changes

### 1. Added SPM and DMA parameters (cpu_top.sv, line 31-37)
- **What**: Added `SPM_START_W`, `SPM_DEPTH_W`, `DMA_START_W`, `DMA_DEPTH_W` parameters.
- **Why**: Parameters propagate to MCU and DMA controller for address decoding.

### 2. Renamed ACCEL DMA signals (cpu_top.sv, line 93-98)
- **What**: Renamed `dma_req/write/addr/wdata/rdata/ready` to `accel_dma_*` to distinguish from the new DMA controller.
- **Why**: The old `dma_*` signals connected GEMV accel to data cache. Now there's also a DMA controller with its own `dma_mem_*` signals. Clear naming prevents confusion.

### 3. Added internal signal declarations (cpu_top.sv, line 113-145)
- **What**: Declared signal groups for:
  - `spm_cpu_*` — MCU to SPM (CPU access path)
  - `dma_ctrl_*` — MCU to DMA controller (MMIO control)
  - `dma_mem_*` — DMA controller to external DMEM (data transfer)
  - `dma_spm_*` — DMA controller to SPM (data transfer)
  - `spm_*` — Merged SPM port (arbitrated)
- **Why**: Each new module needs dedicated signal groups for clean interconnection.

### 4. SPM port arbiter (cpu_top.sv, line 151-157)
- **What**: Priority MUX: DMA controller > CPU for SPM access.
- **Why**: DMA bursts have priority; CPU only accesses SPM between DMA transfers (while polling DMA STATUS via separate MMIO path).
- **How**: `spm_req = dma_spm_req ? 1'b1 : spm_cpu_req`, etc. Both readers share `spm_rdata`.

### 5. Updated DMEM arbiter to 3-way (cpu_top.sv, line 162-178)
- **What**: External DMEM bus now has 3 requestors with priority: D-cache (GEMV DMA) > DMA controller > MCU (CPU).
- **Why**: DMA controller needs DMEM access for bulk transfers. D-cache still has highest priority for GEMV accel.
- **How**: Cascaded ternary MUX: `dcache_mem_req ? ... : dma_mem_req ? ... : mcu_ext_*`. The wdata MUX uses `dcache_mem_write` (pre-asserted) for D-cache, `dma_mem_write` for DMA. **Important**: DMA controller outputs full byte addresses, so `dma_mem_addr - (DMEM_START_W << 2)` is used in the addr MUX to convert to relative offsets matching D-cache and MCU format.

### 6. Updated MCU instantiation (cpu_top.sv, line 200-241)
- **What**: Passed new parameters (`SPM_START_W`, etc.) and connected new ports (`spm_req_o` -> `spm_cpu_req`, `dma_req_o` -> `dma_ctrl_req`, etc.).

### 7. Instantiated scratchpad (cpu_top.sv, line 265-274)
- **What**: `scratchpad #(.DWidth(DWidth), .Depth(16384)) u_spm` connected to arbitrated SPM port.
- **How**: `spm_req/write/addr/wdata` from arbiter, `spm_rdata` shared back.

### 8. Instantiated DMA controller (cpu_top.sv, line 279-301)
- **What**: `dma_controller u_dma` with parameterized address ranges.
- **How**: Control port from MCU, DMEM port to 3-way arbiter, SPM port to SPM arbiter. `DMEM_END_BYTE` computed as `((DMEM_START_W + DMEM_DEPTH_W) << 2) - 1`.

### 9. Updated run_vcs.sh (sim/run_vcs.sh, line 68-71)
- **What**: Added `scratchpad.sv` and `dma_controller.sv` to RTL_LIST.
- **Why**: VCS needs to compile the new modules.

## Verify
- In simulation, `DUT.u_spm.req_i` should toggle when CPU or DMA accesses SPM.
- `DUT.u_dma.state_q` should transition through FSM states during a DMA transfer.
- External DMEM arbiter should correctly prioritize D-cache > DMA > MCU.
