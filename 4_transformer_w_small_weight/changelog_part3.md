# Changelog Part 3: Modify MCU — Add SPM and DMA Address Decode

## Files Modified
- `rtl/scalar_core/mcu.sv` — Added SPM and DMA address decoding, ports, and data paths

## Changes

### 1. Added SPM and DMA parameters (mcu.sv, line 29-33)
- **What**: Added `SPM_START_W`, `SPM_DEPTH_W`, `DMA_START_W`, `DMA_DEPTH_W` parameters.
- **Why**: MCU needs address ranges to distinguish SPM/DMA from DMEM/IOMEM/ACCEL.
- **How**: Same pattern as existing `ACCEL_START_W`/`ACCEL_DEPTH_W`.

### 2. Added SPM and DMA ports (mcu.sv, line 85-98)
- **What**: Added `spm_req_o/write_o/addr_o/wdata_o`, `spm_rdata_i` for SPM; `dma_req_o/write_o/addr_o/wdata_o`, `dma_rdata_i/ready_i` for DMA.
- **Why**: MCU routes CPU data requests to the appropriate target. SPM and DMA each need dedicated ports.
- **How**: SPM port carries byte-offset address (base subtracted). DMA port carries byte offset from DMA base.

### 3. Added address decode logic (mcu.sv, line 145-155)
- **What**: Added `dmem_addr_is_spm` and `dmem_addr_is_dma` combinational comparators.
- **Why**: Determines which target a CPU data request should be routed to.
- **How**: Same pattern as `dmem_addr_is_accel` — compare `dmem_addr_i` against `(START_W << 2)` range.

### 4. Added SPM/DMA paths in D_IDLE FSM case (mcu.sv, line 189-202)
- **What**: When `dmem_addr_is_dma`, drive DMA control port (1-cycle ready like ACCEL). When `dmem_addr_is_spm`, drive SPM port with 1-cycle latency.
- **Why**: SPM should be faster than DMEM (1 cycle vs 4). DMA registers are instant access.
- **How**:
  - DMA: `d_latency_cnt_d = LATENCY_CYCLES - 1` (counter starts at 3, reaches 3 immediately → 1-cycle)
  - SPM: `d_latency_cnt_d = LATENCY_CYCLES - 2` (counter starts at 2, increments to 3 → 1-cycle wait for registered read)
  - Priority order: ACCEL > DMA > SPM > IOMEM > DMEM

### 5. Added `is_spm_q`, `is_dma_q` latching and `dma_rdata_q` capture (mcu.sv, line 237-265)
- **What**: Latch target flags in D_IDLE, capture DMA read data while `dma_req_o` is valid.
- **Why**: By D_WAIT, the req signals are deasserted, so we need latched flags for read-data mux, and latched rdata for DMA reads.

### 6. Updated `dmem_rdata_o` mux (mcu.sv, line 331-335)
- **What**: Added `is_spm_q ? spm_rdata_i` and `is_dma_q ? dma_rdata_q` to the read data mux chain.
- **Why**: CPU needs to receive data from whichever target was accessed.
- **How**: Priority chain: SPM > DMA > IOMEM > ACCEL > DMEM. SPM uses live `spm_rdata_i` (registered read output is stable by D_WAIT completion). DMA uses latched `dma_rdata_q`.

### 7. Added SPM/DMA continuous address assigns (mcu.sv, line 322-328)
- **What**: `spm_addr_o = dmem_addr_i - (SPM_START_W << 2)`, `dma_addr_o = dmem_addr_i - (DMA_START_W << 2)`, and wdata pass-through.
- **Why**: These are always-valid address translations; the req signal gates actual access.

## Verify
- CPU load from `0x2080_0000` (SPM) should complete in 2 cycles total (D_IDLE→D_WAIT→ready), not 5 cycles like DMEM.
- CPU store to `0x2090_000C` (DMA CTRL register) should trigger DMA start.
- CPU load from `0x2090_0010` (DMA STATUS) should return done/busy bits.
