# Changelog Part 1: Create SPM Module

## Files Created
- `rtl/memory/scratchpad.sv` — 64KB on-chip scratchpad memory

## Changes

### 1. Created scratchpad.sv
- **What**: New single-port SRAM module, 16384 words x 32-bit = 64KB, with 1-cycle read latency.
- **Why**: External DMEM has 4-cycle (40ns) latency. SPM provides 1-cycle access for frequently used data (weight rows, vectors) that the DMA pre-loads.
- **How**:
  - Interface: `req_i`, `write_i`, `addr_i` (byte offset), `wdata_i`, `rdata_o`
  - `addr_i` is a byte offset relative to SPM base — cpu_top subtracts `SPM_START_W << 2` before passing
  - Word index extracted as `addr_i[AddrBits+1:2]` (drop 2 LSBs for word alignment)
  - Read: on `req_i && !write_i`, output appears on `rdata_o` at next posedge (registered read = 1-cycle latency)
  - Write: on `req_i && write_i`, data written at posedge
  - `ifdef SIM`: behavioral `logic [31:0] mem[0:16383]` array
  - `else` (synthesis): TSMC 28nm `ts1n28hpcphvtb32768x32m16s` macro (32768x32, only lower 16384 used)
- **Verify**: In simulation, CPU store to SPM byte address `0x2080_0000` followed by load should return in 1 cycle (D_WAIT with latency counter starting at `LATENCY_CYCLES-2`). Check `DUT.u_spm.mem[0]` in waveform.
