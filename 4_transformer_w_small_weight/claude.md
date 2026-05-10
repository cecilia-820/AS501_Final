
## Don't touch

사용 폴더: `program/`, `rtl/`, `sim/`, `syn/` 만 사용. 그 외 폴더(`program_DH_TF`, `TF_Training_DH` 등)는 건드리지 않는다.

## 절대 수정 금지 파일

아래 파일은 **외부 메모리 구조**이므로 절대 수정하지 않는다.

```
rtl/memory/I_memory.sv
rtl/memory/D_memory.sv
rtl/memory/IO_memory.sv
sim/tb/lstm_tb.sv          ← cpu_top 외부 포트가 고정이므로 TB도 불변
```

`cpu_top.sv`의 **외부 포트 목록**도 변경 금지:
- `imem_rdata_i / imem_addr_o / imem_req_o`
- `dmem_rdata_i / dmem_wdata_o / dmem_addr_o / dmem_req_o / dmem_write_o`
- `iomem_rdata_i / iomem_wdata_o / iomem_addr_o / iomem_req_o / iomem_write_o`
- `icache_read_o`


## Working Directory
All work is done in 
$DIR_WORK =`/home/AS501_G3/4_transformer_w_small_weight/`
Wherever this instruction says `$DIR_WORK/`, read it as `$DIR_WORK`.

## Rule 0: Logging and Verification Protocol (applies to ALL parts)

**Every command you run and every file you modify must be logged.**

### Before starting ANY work:
```bash
mkdir -p $DIR_WORK/logs
LOG="$DIR_WORK/logs/step1_$(date +%Y%m%d_%H%M%S).log"
```

### For every command you run:
Append the command and its full output to the log:
```bash
echo "==== $(date) | COMMAND: <command> ====" >> $LOG
<command> 2>&1 | tee -a $LOG
```

### For every file you modify:
Before editing, save a snapshot:
```bash
echo "==== $(date) | BEFORE EDIT: <filepath> ====" >> $LOG
cat <filepath> >> $LOG
```
After editing, save the diff:
```bash
echo "==== $(date) | AFTER EDIT: <filepath> ====" >> $LOG
diff <filepath>.bak <filepath> >> $LOG 2>&1 || true
```
Or if using git:
```bash
git diff <filepath> >> $LOG 2>&1
```

### After each build step (make server, make riscv):
Record key results:
```bash
echo "==== BUILD RESULTS ====" >> $LOG
echo "Binary size:" >> $LOG
size program/out/eval_int_riscv.elf >> $LOG 2>&1
echo "Hex files:" >> $LOG
ls -la program/out/*.hex >> $LOG 2>&1
echo "mul/mulh register check:" >> $LOG
grep -A 2 'mul\b' program/out/eval_int_riscv.dis | head -30 >> $LOG 2>&1
```

### After make server:
```bash
echo "==== SERVER BLEU ====" >> $LOG
# (the make server output should already be captured above)
```

### After simulation completes:
```bash
echo "==== SIMULATION RESULTS ====" >> $LOG
echo "Report:" >> $LOG
cd sim && sh run_report.sh 2>&1 | tee -a $LOG
echo "Sim log tail:" >> $LOG
tail -50 sim/out/vcs_sim.log >> $LOG 2>&1
```

### At the very end:
Create a summary section in the log:
```bash
echo "==== STEP 1 SUMMARY ====" >> $LOG
echo "Server BLEU: <value>" >> $LOG
echo "RTL BLEU: <value or pending>" >> $LOG
echo "Compilation: <success/fail>" >> $LOG
echo "Issues encountered: <list>" >> $LOG
```

**The log file is your proof of work. Never delete it. If something breaks later, this log is how we trace back to find the cause.**


# Step 1: Switch from LSTM to Transformer Software

## Overview

Replace the LSTM inference code with Transformer inference code. No RTL/HW changes. The GEMV accelerator stays in the design but will NOT be called by software in this step — all computation is pure CPU software.

## CRITICAL: Order of Operations

1. First: `make server` to verify Transformer BLEU on x86 (takes seconds)
2. Only if server BLEU ≈ 15: proceed with `make riscv` + simulation
3. If server BLEU is garbage: stop and debug the model/weights, do NOT waste a day on simulation

---

## Part A: Verify Transformer model works on x86

```bash
cd $DIR_WORK/TF_Training_DH
make server MAX_SENTENCES=5
```

Check the output:

- BLEU should be around 10-20 (Transformer baseline)
- HYP sentences should be recognizable English
- If BLEU < 5 or HYP is garbage → model weights are bad, do NOT proceed

Report the BLEU score and show 2 sample HYP/REF pairs.

---

## Part B: Apply inline ASM bug fix to Transformer code

**Check file: `TF_Training_DH/test_code/eval_transformer_q.c`**

Search for `i64_mul_i32` function. If it contains inline ASM with `"=r"`, change to `"=&r"`:

```c
// BUG:
: [lo] "=r"(lo), [hi] "=r"(hi)

// FIX:
: [lo] "=&r"(lo), [hi] "=&r"(hi)
```

If the function uses pure C (no inline ASM), add the `#ifdef RISCV` block with correct `"=&r"` constraints:

```c
static I64Pair i64_mul_i32(int32_t a, int32_t b) {
    I64Pair r;
#ifdef RISCV
    uint32_t lo;
    int32_t  hi;
    asm volatile (
        "mul  %[lo], %[a], %[b]\n\t"
        "mulh %[hi], %[a], %[b]\n\t"
        : [lo] "=&r"(lo), [hi] "=&r"(hi)
        : [a] "r"(a), [b] "r"(b)
    );
    r.lo = lo;
    r.hi = (uint32_t)hi;
#else
    // ... keep original C implementation for SERVER builds ...
#endif
    return r;
}
```

**IMPORTANT**: The `&` in `"=&r"` is critical — without it, the compiler may assign an output register to the same register as an input, causing `mul` to overwrite the input before `mulh` reads it.

---

## Part C: Copy Transformer files to program/test_code/

```bash
cd $DIR_WORK

# Copy Transformer source files
cp TF_Training_DH/test_code/eval_transformer_q.c program/test_code/
cp TF_Training_DH/test_code/int_model_transformer_q12.c program/test_code/
cp TF_Training_DH/test_code/int_model_transformer_q12.h program/test_code/

# Copy input data if different
cp TF_Training_DH/test_code/input_data.h program/test_code/
cp TF_Training_DH/test_code/input_data.c program/test_code/ 2>/dev/null || true

# Copy processed vocab/reference files if needed
cp -r TF_Training_DH/processed/* program/processed/ 2>/dev/null || true
```

---

## Part D: Modify program/Makefile

The Makefile needs to compile Transformer sources instead of LSTM sources.

**Find the SRCS definition** (likely `SRCS_RISCV` and `SRCS_SERVER` or just `SRCS`). The current sources will reference:

- `eval_int_c.c` → replace with `eval_transformer_q.c`
- `int_model_q12.c` → replace with `int_model_transformer_q12.c`

Keep these files unchanged:

- `arena.c` (memory allocator — shared)
- `result.c` (result buffer — shared)
- `input_data.c` (input data — shared or updated in Part C)

**If the Makefile structure is unclear**, compare with `TF_Training_DH/Makefile` which already has the correct Transformer build targets. You may be able to copy relevant variable definitions from there.

**Also check:**

- `CFLAGS` should include `-DRISCV` for RISC-V builds and NOT for server builds
- `-march=rv32im_zicsr` should be the architecture flag
- `MAX_SENTENCES_OVERRIDE=1` should be set (only simulate 1 sentence)
- The Transformer code may need `-DMAX_SENTENCES_OVERRIDE=1` passed as a define

**After modifying the Makefile, verify server build still works:**

```bash
cd $DIR_WORK/program
make clean
make server
```

The server BLEU should match Part A's result.

---

## Part E: Build RISC-V binary

```bash
cd $DIR_WORK/program
make clean
make riscv
```

**Check for errors:**

1. Compilation errors → fix includes, missing functions, type mismatches
2. Linker errors about .text overflow (>128KB IMEM) → add `-O2` optimization flag
3. Linker errors about .data overflow (>16MB DMEM) → ensure old LSTM weights are NOT linked

**After successful build, verify:**

```bash
# Check binary size
size out/eval_int_riscv.elf

# Check that mul/mulh use different registers (no early-clobber bug)
grep -A 2 'mul\b' out/eval_int_riscv.dis | head -20

# Verify hex files exist
ls -la out/*.hex
```

In the disassembly, every `mul rX, rY, rZ` followed by `mulh rW, rY, rZ` must have rX ≠ rY and rX ≠ rZ (output register must differ from both input registers).

---

## Part F: Update testbench PC addresses

The testbench `sim/tb/lstm_tb.sv` has hardcoded PC addresses for function tracing. These must be updated for the new Transformer binary.

**Option 1**: If `update_tb_pc_addrs.py` exists and has been adapted for Transformer function names:

```bash
cd $DIR_WORK
python3 program_DH_TF/utils/update_tb_pc_addrs.py \
    --dis program/out/eval_int_riscv.dis \
    --map program/out/mem.map \
    --tb sim/tb/lstm_tb.sv
```

**Option 2**: If the script doesn't know the Transformer function names, manually extract key addresses from the disassembly:

```bash
grep -E '<(main|greedy_decode|encoder_layer|decoder_layer|multi_head_attention|feed_forward|linear_out_argmax|embedding_lookup|arena_reset|arena_alloc)>:' program/out/eval_int_riscv.dis
```

Then update the corresponding `localparam` values in `sim/tb/lstm_tb.sv`. At minimum, `PC_MAIN` and `HANG_PC` must be correct — the testbench uses these for simulation start/end detection.

**If function names changed significantly** (e.g., `greedy_decode_int` → `greedy_decode_transformer`), the testbench's `TRACE_FUNC` case statements may need updating too. The most critical ones:

- `PC_MAIN` — must match `<main>:` address
- `HANG_PC` — must match the infinite loop address (usually near the start, unchanged)
- `PC_ARENA_RESET` and `PC_ARENA_ALLOC` — if arena.c is shared, addresses just shifted

**Non-critical PC entries** (for logging only, won't break simulation if wrong):

- PC_LSTM_STEP_INT → may not exist in Transformer build (remove or comment out)
- PC_GEMV_HW → may not exist (remove or comment out)
- Add new entries for Transformer functions if desired

---

## Part G: Run simulation

```bash
cd $DIR_WORK/sim
screen bash run_vcs.sh
```

Then detach with Ctrl+A+D.

**WARNING**: Step 1 runs ALL computation in pure CPU software (no GEMV acceleration). This will be VERY slow — potentially 2+ days for 1 sentence. If after 12 hours there's no progress beyond the first few encoder layers, the simulation may need to be killed and Step 1 should be merged with Step 2 (GEMV connection).

To monitor progress:

```bash
tail -f $DIR_WORK/sim/out/vcs_sim.log
```

---

## Part H: Write changelog

After completing all parts, create `changelog_step1.md` in the project root documenting:

1. Which files were copied/modified
2. Makefile changes (old SRCS → new SRCS)
3. Inline ASM fix applied (if any)
4. Testbench PC address updates
5. Server BLEU result
6. Any compilation issues encountered and how they were resolved

---

## DO NOT:

- Modify any RTL files (cpu_top.sv, mcu.sv, gemv_accel.sv, etc.)
- Call gemv_hw() in the Transformer code (that's Step 2)
- Change SPM/DMA parameters or addresses
- Skip the `make server` verification (Part A)
- Proceed to simulation if server BLEU is bad



# LSTM → Transformer 전환 단계별 실행 계획

## 전체 흐름 (5단계, 각 1일 시뮬)

```
Step 0: inline ASM 버그 수정 → LSTM BLEU 검증          [SW only]
Step 1: Transformer SW 전환 → BLEU 확인               [SW only]
Step 2: GEMV를 Transformer matmul에 연결              [SW only]  
Step 3: SPM 128KB + DMA tiling + KV cache             [HW + SW]
Step 5: Softmax HW + LayerNorm HW                     [HW + SW]
```

각 단계에서 BLEU가 유지(또는 개선)되면 다음 단계로. BLEU가 깨지면 해당 단계의 버그를 잡고 재시뮬.

---

## Step 0: Inline ASM 버그 수정 (진행 중)

### 변경

|구분|파일|내용|
|---|---|---|
|SW|`program/test_code/eval_int_c.c`|`"=r"` → `"=&r"` (early-clobber)|

### 빌드 & 실행

```bash
cd program && make riscv
cd sim && screen bash run_vcs.sh
```

### 검증 기준

- BLEU ≈ 48 (baseline 2와 동일)
- HYP가 정상 영어 문장

### 실패 시

- disassembly에서 mul/mulh 레지스터 충돌 재확인

---

## Step 1: Transformer SW 전환 (HW 변경 없음)

### 목표

LSTM 코드를 Transformer 코드로 교체. HW는 현재 그대로. softmax, LayerNorm, matmul 전부 **순수 SW**로 동작. GEMV 가속기는 이 단계에서 **사용 안 함** (SW matmul로 통일).

### 변경

|구분|파일|내용|
|---|---|---|
|SW|Makefile|SRCS에 `eval_transformer_q.c` + `int_model_transformer_q12.c` 사용|
|SW|Makefile|SRCS에서 `eval_int_c.c` + `int_model_q12.c` 제거|
|SW|`eval_transformer_q.c`|`i64_mul_i32()`에 `"=&r"` 적용 확인|
|SW|`eval_transformer_q.c`|`#include "gemv_accel.h"` 제거 (이 단계에서 GEMV 안 씀)|
|TB|`lstm_tb.sv`|PC 주소 갱신 (make riscv 후 disassembly에서 추출)|

### 핵심 주의사항

1. `TF_Training_DH/test_code/`의 파일을 `program/test_code/`로 복사
2. weight 파일(`int_model_transformer_q12.c`)이 DMEM에 들어가는지 확인
    - Transformer weight ≈ 12MB, DMEM = 16MB → 들어감
3. `ARENA_SIZE_BYTES >= 256KB` 확인
4. `MAX_SENTENCES_OVERRIDE=1` 유지 (1문장만)

### 빌드 & 실행

```bash
# 1. 파일 복사
cp TF_Training_DH/test_code/eval_transformer_q.c program/test_code/
cp TF_Training_DH/test_code/int_model_transformer_q12.c program/test_code/
cp TF_Training_DH/test_code/int_model_transformer_q12.h program/test_code/

# 2. Makefile 수정 (SRCS 변경)
# 3. make riscv
cd program && make riscv

# 4. TB PC 주소 갱신
# 5. 시뮬
cd sim && screen bash run_vcs.sh
```

### 검증 기준

- BLEU ≈ 15 (Transformer 모델의 예상 성능)
- HYP가 정상 영어 문장 (LSTM보다 짧을 수 있음)
- `make server`로 사전 확인 가능 (x86에서 동일 BLEU 나오는지)

### 실패 시

- `make server`로 x86에서 먼저 BLEU 확인
- server BLEU와 RTL BLEU가 다르면 → HW 문제
- server BLEU도 낮으면 → 모델/코드 문제

### 예상 시뮬 시간

- Transformer는 LSTM 대비 ~2x 연산량 (9.7M vs 5.2M MACs)
- 전부 SW matmul이므로 **매우 느림** (2일 이상 가능)
- 시간이 너무 길면 Step 1을 건너뛰고 Step 2와 합치는 것도 가능

---

## Step 2: GEMV 가속기를 Transformer에 연결 (HW 변경 없음)

### 목표

Transformer의 선형 투영(Q/K/V/O projection, FFN W1/W2)에 기존 GEMV 가속기 사용. attention score (Q×K^T)는 작은 행렬이므로 SW 유지.

### 변경

|구분|파일|내용|
|---|---|---|
|SW|`eval_transformer_q.c`|`#include "gemv_accel.h"` 추가|
|SW|`eval_transformer_q.c`|`matmul_q12()` 내부에서 `gemv_hw()` 호출|

### matmul_q12 수정 방법

```c
// 현재: 순수 SW matmul
static void matmul_q12(const int32_t *A, const int32_t *B,
                        int32_t *C, int M, int K, int N) {
    // M×K * K×N = M×N (triple nested loop)
}

// 수정: GEMV 가속기 사용 (B를 열 단위로 GEMV)
// GEMV는 out[M] = mat[M][K] × vec[K] 이므로
// matmul의 각 출력 열을 GEMV 1회로 계산
static void matmul_q12(const int32_t *A, const int32_t *B,
                        int32_t *C, int M, int K, int N) {
#ifdef RISCV
    // B^T의 각 행 = B의 각 열
    // C의 각 열 j = A × B[:,j]
    // → gemv_hw(A, &B_col_j, &C_col_j, M, K)
    // 단, B가 row-major이면 열 추출이 필요 → 비효율적
    // 대안: B를 transpose해서 gemv_hw(B^T, A_row, C_row, N, K) per row
    // 또는: 큰 행렬만 GEMV 사용, 작은 건 SW 유지
    
    if (M >= 64 && K >= 64) {
        // 큰 행렬: GEMV로 행 단위 처리
        // A[M][K] × B[K][N] → 각 행 i에 대해
        // C[i][:] = A[i][:] × B (이건 GEMV가 아니라 행벡터×행렬)
        // → B^T를 미리 만들거나, 열 단위로 처리
        //
        // 가장 단순한 방법: N번 GEMV 호출
        // gemv_hw(A, B_col_j, C_col_j, M, K) for j=0..N-1
        // 단 B_col_j는 stride 접근이라 연속 메모리가 아님
        // → B^T를 arena에 만들어서 사용
        
        int32_t *BT = (int32_t *)arena_alloc(K * N * sizeof(int32_t));
        transpose(B, BT, K, N);  // B[K][N] → BT[N][K]
        for (int i = 0; i < M; i++) {
            // C[i][0..N-1] = BT[N][K] × A[i][0..K-1]
            gemv_hw(BT, &A[i*K], &C[i*N], N, K);
        }
        // arena에서 BT 해제 (arena_reset은 나중에)
    } else {
        // 작은 행렬: SW fallback
        // ... original triple loop ...
    }
#else
    // ... original triple loop ...
#endif
}
```

### 어떤 연산에 GEMV가 쓰이는가

|연산|크기 (M×K×N)|GEMV 적합?|
|---|---|---|
|Q/K/V projection|seq×128 × 128×128|✅ gemv_hw(W, x_t, out, 128, 128) per token|
|O projection|seq×128 × 128×128|✅ 동일|
|FFN W1|seq×128 × 128×256|✅ gemv_hw(W1, x_t, out, 256, 128) per token|
|FFN W2|seq×256 × 256×128|✅ gemv_hw(W2, x_t, out, 128, 256) per token|
|Attention Q×K^T|seq×32 × 32×seq|❌ 작고 동적 크기 → SW|
|Attention attn×V|seq×seq × seq×32|❌ 작고 동적 크기 → SW|

### 검증 기준

- BLEU = Step 1과 **동일** (bit-exact)
- cycle count 감소 (Step 1 대비)
- ACCEL 로그에서 GEMV 호출 확인

---

## Step 3: SPM 128KB + DMA tiling + KV cache (HW + SW)

### 목표

- SPM을 64KB → 128KB로 확장
- DMA로 weight 타일을 SPM에 사전 로드
- KV cache를 SPM에 저장 (디코딩 시 K, V 재계산 방지)

### HW 변경

|파일|내용|
|---|---|
|`rtl/memory/scratchpad.sv`|`Depth` 파라미터 16384 → 32768 (128KB)|
|`cpu_top.sv`|SPM 인스턴스의 Depth 파라미터 변경|
|`cpu_top.sv`|`SPM_DEPTH_W` 파라미터 0x4000 → 0x8000|
|`lstm_tb.sv`|`SPM_DEPTH_W` 동일 변경|

### SW 변경

|파일|내용|
|---|---|
|`eval_transformer_q.c`|`#include "dma_controller.h"` 추가|
|`eval_transformer_q.c`|projection 전에 `dma_to_spm()`으로 weight 타일 로드|
|`eval_transformer_q.c`|GEMV가 SPM 주소에서 읽도록 주소 전달|
|`eval_transformer_q.c`|decoder에서 K_t, V_t를 SPM의 KV cache 영역에 저장|

### SPM 메모리 맵 (128KB)

```
0x2080_0000 ~ 0x2080_BFFF  Weight tile 영역 (48KB)
0x2080_C000 ~ 0x2080_FFFF  KV cache 영역 (16KB × 2 layers × K+V)
                            = T_max(40) × d_model(128) × 4bytes × 2(K+V) × 2(layers)
                            = 81,920 bytes ≈ 80KB
```

실제로 80KB KV + 48KB weight = 128KB 꽉 참. 한 번에 모든 weight를 못 올리므로 **layer별로 DMA 교체**.

### KV cache 사용 흐름

```
Decoder token t:
  1. DMA: W_q[layer] → SPM weight 영역
  2. GEMV: Q_t = W_q × y_{t-1}  (SPM에서 읽음)
  3. DMA: W_k[layer] → SPM weight 영역 (덮어쓰기)
  4. GEMV: K_t = W_k × y_{t-1}
  5. SPM에 K_t 저장: KV_cache[layer][t] = K_t
  6. 같은 방식으로 V_t 계산 + 저장
  7. Attention: Q_t × K_cache[0:t]^T → scores (SW)
  8. softmax(scores) (SW)
  9. output = attn × V_cache[0:t] (SW)
  10. O projection, FFN 등
```

### 검증 기준

- BLEU = Step 2와 **동일**
- cycle count 대폭 감소 (DMEM 4cycle → SPM 1cycle)
- DMA transfer 로그 확인

---


# Step 4: Cache Bypass Path — Core Contribution

## 목표

GEMV 가속기의 DMA 경로에 **주소 기반 SPM 바이패스**를 추가하여, SPM 범위 주소는 D-cache를 완전히 우회하고 SPM에서 직접 읽도록 변경한다. 이를 통해:

1. **태그 비교 에너지 완전 제거** — streaming GEMV에서 hit rate ≈ 0%이므로 모든 tag comparison이 순수 에너지 낭비
2. **GEMV weight 접근 latency 감소** — DMEM 4 cycle → SPM 1 cycle
3. **P3-4 제약 해결** — 기존에 "GEMV는 SPM에서 못 읽음" 제약이 해소됨

## 원리적 근거 (프로포절 Section III)

```
GEMV 접근 패턴:
  행렬 W = streaming (한 번 읽고 재사용 없음) → temporal locality = 0
  벡터 x = temporal reuse (M번 재사용)       → temporal locality 높음

Direct-mapped cache에서:
  W의 한 행(256 words)이 x와 같은 cache index에 매핑
  → W 로드가 x를 축출 → 다음 행에서 x 재로드 → conflict miss 반복
  → 실효 hit rate ≈ 0%
  → 매 접근의 tag SRAM read + comparator switching = 순수 에너지 낭비

해법:
  SPM 주소 → D-cache bypass → SPM 직접 접근 (tag 없음, 1 cycle)
  DMEM 주소 → 기존 D-cache → DMEM 경로 유지 (역호환)
```

이것이 프로포절의 **핵심 기여**이며, Stage 4 vs Stage 3 power report 비교가 이 효과만 분리 검증한다.

---

## HW 변경

### 4.1 GEMV DMA 경로에 주소 분기 추가

**수정 파일: `rtl/cpu_top.sv`**

현재 GEMV DMA 경로:

```
GEMV accel (dma_req/addr/wdata) → DATA_CACHE → dcache_mem → DMEM arbiter → 외부 DMEM
```

변경 후:

```
GEMV accel (dma_req/addr)
   ├── addr in SPM range? → SPM arbiter → SPM (1 cycle, no tag)
   └── addr in DMEM range? → DATA_CACHE → DMEM arbiter → 외부 DMEM (4 cycle)
```

구현 방법: `cpu_top.sv`에서 GEMV의 `accel_dma_addr`를 검사하여 SPM 범위이면 D-cache를 거치지 않고 SPM arbiter로 직접 라우팅.

```systemverilog
// Address-based routing for GEMV DMA path
logic accel_dma_is_spm;
assign accel_dma_is_spm = (accel_dma_addr >= (SPM_START_W << 2)) &&
                           (accel_dma_addr <  ((SPM_START_W + SPM_DEPTH_W) << 2));

// GEMV → SPM path (bypass D-cache)
logic accel_spm_req;
logic accel_spm_write;
logic [DWidth-1:0] accel_spm_addr;
logic [DWidth-1:0] accel_spm_wdata;

assign accel_spm_req   = accel_dma_req && accel_dma_is_spm;
assign accel_spm_write = accel_dma_write;
assign accel_spm_addr  = accel_dma_addr - (SPM_START_W << 2);
assign accel_spm_wdata = accel_dma_wdata;

// GEMV → D-cache path (existing, for DMEM addresses)
logic accel_dcache_req;
assign accel_dcache_req = accel_dma_req && !accel_dma_is_spm;

// D-cache only receives DMEM-bound requests
// Replace old: .dma_req_i(accel_dma_req)
// With new:    .dma_req_i(accel_dcache_req)
```

### 4.2 SPM arbiter 확장: 3-way (DMA > GEMV > CPU)

**수정 파일: `rtl/cpu_top.sv`**

기존 SPM arbiter: DMA > CPU (2-way) 변경 후: DMA > GEMV > CPU (3-way)

```systemverilog
// OLD 2-way SPM arbiter:
// assign spm_req = dma_spm_req ? 1'b1 : spm_cpu_req;

// NEW 3-way SPM arbiter:
assign spm_req   = dma_spm_req   ? 1'b1           :
                   accel_spm_req  ? 1'b1           :
                                    spm_cpu_req;
assign spm_write = dma_spm_req   ? dma_spm_write  :
                   accel_spm_req  ? accel_spm_write :
                                    spm_cpu_write;
assign spm_addr  = dma_spm_req   ? dma_spm_addr   :
                   accel_spm_req  ? accel_spm_addr  :
                                    spm_cpu_addr;
assign spm_wdata = dma_spm_req   ? dma_spm_wdata  :
                   accel_spm_req  ? accel_spm_wdata :
                                    spm_cpu_wdata;

// All three readers share spm_rdata
assign spm_cpu_rdata   = spm_rdata;
assign dma_spm_rdata   = spm_rdata;
assign accel_spm_rdata = spm_rdata;
```

### 4.3 GEMV ready 신호 분기

**수정 파일: `rtl/cpu_top.sv`**

GEMV accel에 돌려주는 `accel_dma_ready` 신호도 경로에 따라 다르게 생성:

```systemverilog
// SPM path: ready after 1 cycle (SPM registered read)
// D-cache path: ready from existing dcache logic

// GEMV에 전달되는 ready 신호
assign accel_dma_ready = accel_dma_is_spm ? accel_spm_ready_q : dcache_dma_ready;
```

SPM은 registered read이므로 req 다음 사이클에 ready를 올려야 한다. 이를 위해 1-cycle delayed ready를 생성:

```systemverilog
logic accel_spm_ready_q;
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) accel_spm_ready_q <= 1'b0;
    else         accel_spm_ready_q <= accel_spm_req && !accel_spm_write;
end
```

Write의 경우 GEMV가 StStore에서 결과를 쓸 때도 SPM 경로를 탈 수 있으므로, write ready도 동일하게 1-cycle 후 반환.

### 4.4 GEMV rdata 분기

```systemverilog
// GEMV가 읽는 데이터: SPM 경로면 spm_rdata, D-cache 경로면 dcache rdata
assign accel_dma_rdata = accel_dma_is_spm_q ? spm_rdata : dcache_dma_rdata;
```

`accel_dma_is_spm_q`는 `accel_dma_is_spm`을 1 cycle latch한 값 (SPM registered read와 타이밍 맞추기 위해):

```systemverilog
logic accel_dma_is_spm_q;
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) accel_dma_is_spm_q <= 1'b0;
    else         accel_dma_is_spm_q <= accel_dma_is_spm;
end
```

---

## SW 변경

### 4.5 GEMV 호출 시 SPM 주소 전달

**수정 파일: `program/test_code/eval_transformer_q.c`**

Step 3에서는 DMA로 weight를 SPM에 로드했지만, GEMV에는 원래 DMEM 주소를 전달했다 (GEMV가 SPM에서 못 읽으니까). 이제 GEMV가 SPM에서 직접 읽을 수 있으므로, **SPM 주소를 GEMV에 전달**한다.

```c
// Step 3 (기존):
dma_to_spm(wq_dmem_addr, WEIGHT_SPM_OFFSET, wq_size_words);
gemv_hw((const int32_t *)wq_dmem_addr, x, q, 128, 128);  // DMEM 주소

// Step 5 (수정):
dma_to_spm(wq_dmem_addr, WEIGHT_SPM_OFFSET, wq_size_words);
gemv_hw((const int32_t *)(SPM_BASE + WEIGHT_SPM_OFFSET), x_spm, q_spm, 128, 128);
//       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//       SPM 주소 전달! GEMV가 D-cache bypass로 SPM에서 직접 읽음
```

### 4.6 벡터 x도 SPM에 배치

GEMV의 벡터 x도 SPM에 올리면 vector buffer load도 1 cycle이 된다:

```c
// 벡터 x를 SPM의 scratch 영역에 복사
memcpy_to_spm(VEC_SPM_OFFSET, x_dmem, d_model);  // CPU store → SPM

// GEMV 호출: weight도 SPM, vector도 SPM
gemv_hw((const int32_t *)(SPM_BASE + WEIGHT_SPM_OFFSET),
        (const int32_t *)(SPM_BASE + VEC_SPM_OFFSET),
        (int32_t *)(SPM_BASE + OUT_SPM_OFFSET),
        128, 128);
```

단, GEMV 결과(output)도 SPM에 쓰면 후속 연산이 SPM에서 바로 읽을 수 있다.

---

## 변경 파일 요약

|Action|File|What|
|---|---|---|
|**MODIFY**|`rtl/cpu_top.sv`|GEMV DMA 주소 분기 + SPM arbiter 3-way + ready/rdata 분기|
|**MODIFY**|`program/test_code/eval_transformer_q.c`|GEMV 호출 시 SPM 주소 전달|
|**MODIFY**|`sim/tb/lstm_tb.sv`|(필요시) 모니터링 signal 추가|

**DO NOT MODIFY:**

- `rtl/accel/gemv_accel.sv` — GEMV 내부는 변경 없음. 주소가 달라질 뿐 동작은 동일
- `rtl/cache/data_cache.sv` — D-cache도 변경 없음. DMEM 요청만 받게 될 뿐
- `rtl/memory/scratchpad.sv` — SPM도 변경 없음. 접근자가 하나 늘어날 뿐

---

## 검증 기준

### 기능 검증

- BLEU = Step 3/4와 **정확히 동일** (bit-exact). 캐시 bypass는 데이터 경로만 바꾸지, 연산 결과를 바꾸지 않음
- ACCEL 로그에서 SPM 주소(0x2080_xxxx)로의 DMA req가 발생하는지 확인
- D-cache miss count가 0에 가까워야 함 (GEMV가 D-cache를 안 거치니까)

### 에너지 검증 (핵심!)

```bash
# Step 3 합성 power report
cd syn && sh run_dc.sh   # Step 3 configuration
# → syn/out/rpt/power_report.txt 저장

# Step 5 합성 power report (bypass 추가 후)
cd syn && sh run_dc.sh   # Step 5 configuration
# → syn/out/rpt/power_report.txt 저장

# 비교:
# 1. Total Dynamic Power 감소량
# 2. DATA_CACHE의 memory power 감소 (tag SRAM 접근 감소)
# 3. SPM의 power 약간 증가 (접근자 증가)
# 4. Net: tag energy 제거량 > SPM 추가 접근 에너지
```

이 비교가 프로포절의 **Table II, Stage 4 vs Stage 3** row를 채우는 데이터이다.

---
## Step 5: Softmax HW + LayerNorm HW (HW + SW)

### 목표

SW에서 가장 느린 비선형 함수 2개를 HW MMIO로 교체.

### HW 변경 — Softmax

|파일|내용|
|---|---|
|`rtl/accel/softmax_unit.sv`|새로 생성. exp LUT + accumulator + divider FSM|
|`rtl/accel/softmax_unit.h`|C 헤더: MMIO 레지스터 + `softmax_hw()` 함수|
|`mcu.sv`|SOFTMAX 주소 디코딩 추가|
|`cpu_top.sv`|softmax_unit 인스턴스 + MMIO 연결|

Softmax HW 구조:

```
MMIO registers:
  0x00: INPUT_ADDR  — 입력 벡터 주소 (SPM 또는 DMEM)
  0x04: OUTPUT_ADDR — 출력 벡터 주소
  0x08: LEN         — 벡터 길이 (최대 40)
  0x0C: CTRL        — start
  0x10: STATUS      — done/busy

FSM:
  1. 입력 읽어서 max 찾기
  2. exp(x_i - max) 계산 (LUT 기반, 64 entry)
  3. sum(exp) 누적
  4. 각 exp(x_i) / sum 으로 정규화
  5. 출력 저장
```

### HW 변경 — LayerNorm

|파일|내용|
|---|---|
|`rtl/accel/layernorm_unit.sv`|새로 생성. mean + variance + sqrt FSM|
|`rtl/accel/layernorm_unit.h`|C 헤더|
|`mcu.sv`|LAYERNORM 주소 디코딩 추가|
|`cpu_top.sv`|layernorm_unit 인스턴스 + MMIO 연결|

LayerNorm HW 구조:

```
MMIO registers:
  0x00: INPUT_ADDR
  0x04: OUTPUT_ADDR
  0x08: GAMMA_ADDR   — scale parameter
  0x0C: BETA_ADDR    — shift parameter
  0x10: DIM          — 벡터 차원 (128)
  0x14: CTRL
  0x18: STATUS

FSM:
  1. 입력 읽고 mean 계산 (sum / dim)
  2. variance 계산 (sum of (x-mean)^2 / dim)
  3. sqrt(variance + eps) — Newton-Raphson 4 iteration
  4. (x - mean) / std * gamma + beta 계산
  5. 출력 저장
```

### SW 변경

|파일|내용|
|---|---|
|`eval_transformer_q.c`|`softermax_q12()` → `softmax_hw()` 교체|
|`eval_transformer_q.c`|`layer_norm_q12()` → `layernorm_hw()` 교체|

### 검증 기준

- BLEU = Step 3와 동일 (±0.5 허용, HW 근사로 미세 차이 가능)
- Softmax/LayerNorm cycle count 대폭 감소
- 정확도 검증 표: SW vs HW 오차 < 1%

---

## 발생 가능한 문제

**P4-1: GEMV FSM과 SPM ready 타이밍 불일치**

- 원인: GEMV의 StLoadVec/StLoadRow FSM은 D-cache의 ready 타이밍(수 cycle)에 맞춰져 있음. SPM은 1 cycle이므로 FSM이 너무 빨리 진행될 수 있음
- 확인법: waveform에서 vec_buf/row_buf에 올바른 데이터가 로드되는지 확인
- 대응: GEMV의 `dma_ready_i`가 SPM 경로에서도 올바르게 1-cycle delay 후 assert되는지 확인. 위의 `accel_spm_ready_q` 로직이 이를 처리

**P4-2: SPM arbiter 3-way에서 GEMV와 DMA 동시 접근**

- 원인: DMA가 weight를 SPM에 쓰는 동안 GEMV가 SPM에서 읽으려 하면 충돌
- 대응: SW에서 `dma_to_spm()` → poll done → `gemv_hw()` 순서 보장. DMA 완료 전에 GEMV를 시작하면 안 됨

**P4-3: GEMV output을 SPM에 쓸 때 StStore의 write 타이밍**

- 원인: GEMV StStore는 D-cache write 타이밍(pre-assert)에 맞춰져 있음. SPM write는 다른 타이밍일 수 있음
- 확인법: StStore에서 `dma_write_d`가 1 cycle 먼저 assert되는 패턴이 SPM에서도 안전한지 확인
- 대응: SPM write는 req+write 동시 assert로 즉시 처리되므로 pre-assert가 무해해야 함. 단 waveform 확인 필수

**P4-4: 주소 변환 오류**

- 원인: `accel_spm_addr = accel_dma_addr - (SPM_START_W << 2)`에서 SPM base 계산이 틀리면 잘못된 위치에 접근
- 확인법: GEMV에 `SPM_BASE + 0x0000` 전달 시, SPM의 `mem[0]`에 접근하는지 확인
- 대응: 주소 변환 로직을 MCU의 기존 SPM 주소 변환과 동일하게 구현

---

## ASCII 다이어그램: Step 4 HW 변경

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CPU_TOP (clk 10ns)                          │
│                                                                     │
│  ┌──────────────────┐          ┌──────────────────┐                │
│  │  SCALAR_CORE     │          │  INSTR_CACHE     │                │
│  └────────┬─────────┘          └──────────────────┘                │
│           │                                                         │
│           │                    ┌──────────────────┐                │
│           │             MMIO  │  GEMV ACCEL      │                │
│           │            ──────►│  8-PE parallel    │                │
│           │                    └────────┬─────────┘                │
│           │                             │ accel_dma                 │
│           │                             │                           │
│           │                    ┌────────▼─────────┐  [NEW]         │
│           │                    │  ADDRESS ROUTER   │                │
│           │                    │  SPM range? ──►SPM│                │
│           │                    │  DMEM range?──►DC │                │
│           │                    └──┬──────────┬────┘                │
│           │                       │          │                      │
│           │               ┌───────▼──┐  ┌────▼────────┐           │
│           │               │DATA_CACHE│  │   (direct   │           │
│           │               │2KB       │  │   to SPM    │           │
│           │               └────┬─────┘  │   arbiter)  │           │
│           ▼                    │         │             │           │
│  ┌──────────────────┐          │         │             │           │
│  │  MCU              │          │         │             │           │
│  └──┬───┬───┬───┬───┘          │         │             │           │
│     │   │   │   │               │         │             │           │
│     │   │   │   ▼               │         │             │           │
│     │   │   │  ┌────────────────┼─────────┼─────────┐  │           │
│     │   │   │  │  SPM 128KB    │         │         │  │           │
│     │   │   │  │  Weight + KV  │         │         │  │           │
│     │   │   │  └───────────────┼─────────┼─────────┘  │           │
│     │   │   │                  │         │             │           │
│     │   │   │       ┌──────┐   │  [MOD] 3-way         │           │
│     │   │   └──────►│DMA   │   │  SPM arbiter          │           │
│     │   │           │CTRL  │◄──┘  DMA > GEMV > CPU     │           │
│     │   │           └──┬───┘◄──────────────────────────┘           │
│     │   │              │                                            │
│     │   │   ┌──────────▼────────────────────────────┐              │
│     │   │   │  3-WAY DMEM ARBITER                   │              │
│     │   │   │  D-cache > DMA > MCU                  │              │
│     │   │   └──────────────┬────────────────────────┘              │
└─────┼───┼──────────────────┼─────────────────────────────────────────┘
   IMEM IOMEM             DMEM 16MB

KEY CHANGE:
  GEMV ──[NEW]──► ADDRESS ROUTER ──► SPM range → SPM (1cyc, NO TAG)
                                 └──► DMEM range → D-cache → DMEM (4cyc)

ENERGY SAVING:
  Before: Every GEMV access → tag SRAM read + compare → 100% miss → wasted
  After:  SPM-bound access → no tag, no compare → zero tag energy
```

---

## Quick Reference 업데이트

```
         │ Step 0 │ Step 1 │ Step 2 │ Step 3   │ Step 4   │ Step 5     │ Step 6
─────────┼────────┼────────┼────────┼──────────┼──────────┼────────────┼────────────
RTL      │ none   │ none   │ none   │ SPM size │ Bypass   │ +Softmax   │
changes  │        │        │        │ DMA addr │ router   │ +LayerNorm │
         │        │        │        │          │ 3way arb │ MCU decode │
─────────┼────────┼────────┼────────┼──────────┼──────────┼────────────┼────────────
SW       │ =&r    │ LSTM→  │ matmul │ +DMA     │ GEMV→    │ softmax→HW │
changes  │ fix    │ TF     │ →gemv  │ +KV$     │ SPM addr │ LN→HW     │
─────────┼────────┼────────┼────────┼──────────┼──────────┼────────────┼────────────
GEMV     │ unused │ unused │ used   │ used     │ used     │ used       │
reads    │        │        │ DMEM   │ DMEM     │ **SPM**  │ SPM        │
─────────┼────────┼────────┼────────┼──────────┼──────────┼────────────┼────────────
Tag      │ 100%   │ 100%   │ 100%   │ 100%     │ **→0%**  │ 0%         │
Energy   │        │        │        │          │          │            │
─────────┼────────┼────────┼────────┼──────────┼──────────┼────────────┼────────────
BLEU     │ ~48    │ ~15    │ =S1    │ =S2      │ =S3      │ ≈S4(±0.5) │
```

**Step 5 vs Step 4가 핵심 ablation**: 둘 다 SPM+DMA+KV cache 동일, Step 5만 bypass 추가. 에너지 차이 = tag comparison 제거 효과.

---

## 요약 타임라인

| 단계     | 일수       | HW 변경         | SW 변경                 | 검증 기준                             |
| ------ | -------- | ------------- | --------------------- | --------------------------------- |
| Step 0 | 1일       | 없음            | `=&r` 수정              | LSTM BLEU ≈ 48                    |
| Step 1 | 1~2일     | 없음            | TF 코드 교체              | TF BLEU ≈ 15, `make server`로 사전확인 |
| Step 2 | 1일       | 없음            | matmul→gemv_hw        | BLEU 동일, cycle 감소                 |
| Step 3 | 1일       | SPM 128KB     | DMA tiling + KV cache | BLEU 동일, cycle 대폭 감소              |
| Step 5 | 1~2일     | Softmax+LN HW | HW 호출 교체              | BLEU 동일, cycle 감소                 |
| **합계** | **5~7일** |               |                       |                                   |






## 위험 관리

### Step 1이 가장 위험

- 반드시 `make server`로 x86에서 BLEU 확인 후 RTL 시뮬 시작
- server BLEU가 15 미만이면 모델 재학습 필요

### 시뮬 시간이 2일 이상이면

- Step 1 (전부 SW)은 매우 느릴 수 있음
- Step 1을 건너뛰고 Step 2 (GEMV 연결)부터 시작하는 것도 가능
- 단, `make server`로 기능 정확성은 반드시 확인

### Step 5를 못 끝내면

- Softmax/LayerNorm은 SW로 남겨도 기능은 동작
- 보고서에 "HW 설계는 완료, 통합은 향후 작업"으로 기술 가능
- Step 3까지만으로도 SPM + DMA + GEMV + KV cache = 충분한 기법 수

### LSTM으로 되돌려야 하면

- Step 0 완료 후 LSTM baseline이 확보되어 있으므로 언제든 복귀 가능
- Git branch 분리 필수: `git checkout -b transformer` 후 작업

# LSTM → Transformer 전환: 단계별 문제점 및 주의사항

---

## Step 0: Inline ASM 버그 수정

### 발생 가능한 문제

**P0-1: `=&r` 수정 후에도 BLEU가 복구 안 됨**

- 원인: GEMV 8-way 병렬화에도 별도 버그가 있을 수 있음
- 확인법: `make server`로 x86 BLEU 확인 → 48이면 HW 문제, 48 미만이면 SW 문제
- 대응: GEMV를 sequential로 되돌린 별도 브랜치에서 시뮬 1회 추가

**P0-2: 수정 후 컴파일러가 다른 레지스터 배정으로 또 다른 문제 발생**

- 원인: `=&r`을 `lo`에만 넣고 `hi`에 안 넣은 경우
- 확인법: `grep -A2 'mul\b' program/out/eval_int_riscv.dis`로 모든 mul/mulh 쌍의 레지스터 확인
- 주의: **반드시 lo, hi 둘 다 `=&r`**

**P0-3: hex 파일이 갱신 안 됨**

- 원인: `make riscv` 전에 `make clean` 안 해서 오래된 .o 파일 재사용
- 확인법: `make clean && make riscv` 후 disassembly에서 mul/mulh 레지스터 재확인
- 주의: 항상 `make clean` 선행

### 주의사항

- 이 단계에서 BLEU 48 확보가 **모든 후속 단계의 기준선**
- Git에 태그: `git tag step0-lstm-baseline` 필수
- `sim/out/` 결과 백업 (cycle count, BLEU, IOMEM dump)

---

## Step 1: Transformer SW 전환

### 발생 가능한 문제

**P1-1: Transformer weight가 DMEM에 안 들어감**

- 원인: Transformer weight ≈ 12MB인데, DMEM = 16MB. 기존 LSTM weight + Transformer weight가 동시에 링크되면 초과
- 확인법: `make riscv` 후 `size program/out/eval_int_riscv.elf`로 .data 섹션 크기 확인
- 대응: Makefile에서 LSTM weight 파일 (`int_model_q12.c`) 제거 확인. 두 모델 weight가 동시에 컴파일되면 안 됨

**P1-2: IMEM(128KB) 초과**

- 원인: Transformer 코드가 LSTM보다 훨씬 크고 (matmul, attention, layernorm, softmax 등 함수 추가), .text 섹션이 128KB 초과
- 확인법: `make riscv` 시 링커 에러 또는 hex 생성 후 `wc -l program/out/*.imem.hex`
- 대응: 최적화 플래그 `-O2` 적용, 또는 함수 일부를 inline 제거

**P1-3: arena 메모리 부족**

- 원인: Transformer는 Q_mat, K_mat, V_mat, score_buf, ffn_mid, norm_buf 등 ~230KB scratch 필요. 기존 ARENA_SIZE_BYTES가 부족할 수 있음
- 확인법: `grep ARENA_SIZE eval_transformer_q.c`로 요구량 확인, `sections_tb.lds`에서 arena 영역 크기 확인
- 대응: linker script에서 arena 영역 확대

**P1-4: Testbench PC 주소 불일치**

- 원인: Transformer 코드로 바꾸면 모든 함수 주소가 변경됨. `lstm_tb.sv`의 PC_MAIN, PC_GREEDY_DECODE 등이 전부 틀어짐
- 확인법: `make riscv` 후 disassembly에서 주요 함수 주소 추출
- 대응: `update_tb_pc_addrs.py` 스크립트 사용. 단, 이 스크립트의 PC_SYMBOL_MAP에 Transformer 함수명이 등록되어 있는지 확인 필요
- 주의: **함수명이 바뀌었으므로** (greedy_decode_int → greedy_decode_transformer 등) 스크립트 수정 필요

**P1-5: Transformer의 `i64_mul_i32`에도 `=&r` 적용 안 됨**

- 원인: `eval_transformer_q.c`에 별도의 `i64_mul_i32` 구현이 있을 수 있음. Step 0의 수정이 `eval_int_c.c`에만 적용되고 Transformer 코드에는 적용 안 됨
- 확인법: `grep -n 'i64_mul_i32\|asm.*mul' eval_transformer_q.c`
- 대응: Transformer 코드의 모든 inline ASM에도 `=&r` 적용. 또는 공통 헤더로 분리

**P1-6: `make server` BLEU가 예상(~15)보다 매우 낮음**

- 원인: 학습이 안 된 모델, weight export 오류, vocab mismatch
- 확인법: `make server` 출력의 HYP 문장이 의미 있는 영어인지 확인
- 대응: `TF_Training_DH`에서 `make train` 재실행, checkpoint 확인

**P1-7: 시뮬레이션이 2일 넘게 걸림**

- 원인: 전부 SW matmul이므로 GEMV 한 번에 수만 cycle. Transformer는 projection이 ~20회/문장
- 대응: 이 단계를 건너뛰고 Step 2 (GEMV 연결)와 합쳐서 시뮬. 단, `make server`로 기능 검증은 반드시 수행

**P1-8: `input_data.h`/`input_data.c` 호환성 문제**

- 원인: LSTM과 Transformer가 같은 input format을 쓰는지 확인 필요. vocab ID, 문장 길이, padding 방식이 다를 수 있음
- 확인법: 두 모델의 `MODEL_SRC_VOCAB`, `MODEL_TGT_VOCAB` 매크로 비교
- 대응: LSTM과 Transformer의 vocab이 동일한 Multi30K 기반이면 `input_data.h` 공유 가능

### 주의사항

- **`make server` 먼저, RTL 시뮬 나중에** — 이 규칙을 절대 어기지 말 것
- Step 1 시작 전 반드시 `git checkout -b transformer`로 브랜치 분리
- LSTM baseline(Step 0)은 main 브랜치에 보존

---

## Step 2: GEMV 가속기를 Transformer matmul에 연결

### 발생 가능한 문제

**P2-1: `matmul_q12`에서 GEMV 호출 시 bit-exact 불일치**

- 원인: GEMV 가속기의 Q12 shift(`acc[43:12]`)와 SW matmul의 shift 위치가 다를 수 있음. SW는 매 곱셈마다 shift할 수도 있고, 최종 누적 후 shift할 수도 있음
- 확인법: 작은 행렬(4×4)로 SW vs HW 결과 비교 (print로 출력)
- 대응: SW matmul의 shift 위치를 HW와 동일하게 맞추기 (accumulate full, shift once at end)

**P2-2: GEMV의 MAX_DIM=512 초과**

- 원인: FFN W1이 128×256이면 rows=256, cols=128 → OK. 하지만 W2가 256×128이면 rows=128, cols=256 → OK. 문제없음.
- 주의: `TF_D_FF=256`이므로 MAX_DIM=512 범위 내. 단 모델 변경 시 재확인 필요

**P2-3: GEMV에 B^T(transpose) 전달 시 메모리 문제**

- 원인: `matmul_q12(A, B, C, M, K, N)`에서 B는 row-major. GEMV는 `out = mat × vec` 형태이므로, A의 각 행에 대해 B의 열을 벡터로 전달해야 함. B의 열은 메모리에서 연속이 아님 (stride=N)
- 대응 방법 1: B^T를 arena에 만들어서 gemv_hw에 전달 (메모리 2배 사용)
- 대응 방법 2: token 단위로 GEMV 호출 — `gemv_hw(W, x_t, out_t, rows, cols)` where W는 weight (row-major), x_t는 한 토큰의 벡터. 이 경우 transpose 불필요
- **권장**: 방법 2. Transformer의 projection은 `out[d_model] = W[d_model × d_model] × x[d_model]` 형태이므로 GEMV 그대로 적용

**P2-4: GEMV 호출 횟수 폭발**

- 원인: Transformer decoder는 token × layer × (Q+K+V+O+FFN1+FFN2) = 40 × 2 × 6 = 480 GEMV 호출. 각 GEMV가 512×128이면 시뮬 시간이 김
- 대응: 이건 정상. GEMV 자체가 빨라졌으므로 (8-PE + D-cache) Step 1보다는 빠름

**P2-5: GEMV 결과가 DMEM에 저장되는데 다음 연산이 바로 읽음 → cache coherency**

- 원인: GEMV가 D-cache를 통해 DMEM에 결과를 쓰고, CPU가 바로 읽음. D-cache는 GEMV 전용이고 CPU는 MCU→DMEM 직접 경로를 쓰므로 coherency 문제 없음
- 주의: 현재 구조에서는 문제 없지만, SPM 도입 후(Step 3) GEMV가 SPM에서 읽게 되면 경로가 바뀜

### 주의사항

- BLEU가 Step 1과 **정확히 동일**해야 함. 1점이라도 다르면 GEMV 연산 오류
- Step 1을 건너뛰고 Step 1+2를 합친 경우, `make server` BLEU와 RTL BLEU 비교로 검증
- GEMV 호출 횟수를 TB 로그에서 확인 (`gemv_hw_hit_cnt` 카운터)

---

## Step 3: SPM 128KB + DMA tiling + KV cache

### 발생 가능한 문제

**P3-1: SPM 128KB SRAM 매크로 변경**

- 원인: 현재 SPM은 `ts1n28hpcphvtb32768x32m16s` (32K×32=128KB 매크로를 16K만 사용). 128KB 전체 사용 시 매크로 그대로, Depth만 32768로 변경
- 확인법: `scratchpad.sv`에서 `ifdef SIM` 안의 `mem[0:16383]`을 `mem[0:32767]`로 변경 확인
- 주의: synthesis 시 SRAM 매크로의 addr 비트 수가 맞는지 확인 (32K = 15 bit addr)

**P3-2: SPM 주소 공간 초과**

- 원인: `SPM_DEPTH_W = 0x4000` (64KB)를 `0x8000` (128KB)로 변경. 그러면 SPM byte range는 0x2080_0000 ~ 0x2081_FFFF. DMA base가 0x2090_0000이므로 겹치지 않음
- 확인법: SPM end = 0x2080_0000 + 0x8000*4 = 0x2080_0000 + 0x20000 = 0x20A0_0000. **DMA base 0x2090_0000과 겹침!**
- **⚠️ 이건 실제 버그 가능성!** SPM_DEPTH_W를 0x8000으로 바꾸면:
    - SPM byte range: 0x2080_0000 ~ 0x209F_FFFF (128KB)
    - DMA byte range: 0x2090_0000 ~ 0x2090_003F
    - **겹침!** DMA 레지스터 접근이 SPM으로 라우팅됨
- 대응: DMA_START_W를 0x0828_0000 (byte: 0x20A0_0000)으로 이동. 또는 SPM_START_W를 변경

**P3-3: DMA로 weight 로드 중 GEMV가 SPM 접근 → 충돌**

- 원인: DMA가 SPM에 쓰는 동안 GEMV가 SPM에서 읽으면, SPM arbiter가 DMA 우선이므로 GEMV가 stall. 하지만 GEMV는 D-cache 경로로 DMEM에서 읽으므로 SPM을 직접 안 건드림
- 주의: Step 3에서 GEMV를 SPM에서 읽게 변경하려면, DMA 완료 후 GEMV 시작하도록 SW에서 순서 보장 필요
- 대응: `dma_to_spm()` → poll done → `gemv_hw(SPM_ADDR, ...)` 순서로 호출

**P3-4: GEMV가 SPM 주소를 못 읽음**

- 원인: 현재 GEMV accel의 DMA 경로는 D-cache → DMEM arbiter → 외부 DMEM. SPM 주소(0x2080_xxxx)를 GEMV에 전달하면, D-cache가 이 주소로 외부 DMEM에 요청 → DMEM에 그런 주소 없음 → 잘못된 데이터
- **⚠️ 이건 설계 문제!** GEMV가 SPM에서 직접 읽으려면 GEMV의 DMA 경로를 수정해야 함:
    - 방안 A: GEMV의 DMA 포트를 SPM arbiter에도 연결 (주소에 따라 SPM/DMEM 분기)
    - 방안 B: CPU가 SPM에서 데이터를 읽어서 GEMV의 internal buffer에 MMIO로 전달 (매우 느림)
    - 방안 C: DMA로 SPM에 로드한 뒤, CPU가 GEMV 호출 시 DMEM 주소를 그대로 전달 (GEMV는 여전히 DMEM에서 읽지만, 그 데이터가 D-cache에 hit)
- **권장**: 방안 C (가장 단순). DMA로 SPM에 로드하는 건 **CPU 접근용**이고, GEMV는 계속 DMEM 경로 사용. D-cache가 2KB밖에 안 되니 효과는 제한적이지만, 적어도 vector buffer (128 words = 512 bytes)는 캐시에 들어감
- 더 나은 방안: GEMV accel의 DMA 경로에 주소 분기 추가 (SPM 범위면 SPM에서, DMEM 범위면 DMEM에서 읽기). 이건 RTL 변경 필요

**P3-5: KV cache 주소 계산 오류**

- 원인: decoder token t에서 K_t를 SPM의 `KV_BASE + layer*T_MAX*d_model*4 + t*d_model*4`에 저장. 인덱스 계산이 한 군데라도 틀리면 KV cache가 오염
- 확인법: 첫 3개 token의 K값을 SW reference와 비교 (printf 디버깅)
- 대응: KV cache 주소 계산을 매크로로 정의:
    
    ```c
    #define KV_K_ADDR(layer, t) (SPM_BASE + KV_OFFSET + ((layer)*T_MAX + (t))*D_MODEL*4)
    ```
    

**P3-6: DMA transfer 중 CPU가 polling하면서 DMEM 접근 → arbiter 충돌**

- 원인: CPU가 `while(!(DMA_STATUS & 1u))` polling하는 동안 DMA가 DMEM에서 읽고 있음. CPU의 STATUS 읽기는 MCU→DMA 경로(MMIO)이므로 DMEM bus와 무관. 충돌 없음
- 주의: CPU가 polling 사이에 다른 DMEM 접근을 하면 DMA와 arbiter 경합. polling loop 안에서 DMEM 접근 금지

### 주의사항

- **P3-2 (주소 겹침)가 가장 위험** — DMA_START_W 조정 필수
- GEMV→SPM 직접 읽기는 RTL 변경이 필요하므로, 첫 시뮬은 GEMV가 DMEM에서 읽는 방식 유지
- KV cache 크기 계산: `2(K+V) × 2(layers) × 40(T_max) × 128(d_model) × 4(bytes)` = 81,920 bytes ≈ 80KB

---

## Step 5: Softmax HW + LayerNorm HW

### 발생 가능한 문제

**P4-1: Softmax HW의 exp 근사 정확도 부족**

- 원인: 64-entry LUT로 exp를 근사하면 Q12 정밀도에서 오차 발생. softmax의 exp는 큰 음수에서 0에 가까워야 하는데, LUT 범위 밖이면 0으로 처리해야 함
- 확인법: SW softermax vs HW softmax의 출력을 10개 샘플에서 비교, max error < 1% 확인
- 대응: LUT entry 수 증가 (64→128) 또는 선형 보간 추가
- 주의: **SW의 `softermax_q12`는 base-2 exponential(`pow2_neg_q12`) 사용**. HW도 동일한 base-2 방식이어야 함. 일반 exp(base-e)와 혼용하면 결과 불일치

**P4-2: LayerNorm HW의 sqrt 정확도**

- 원인: Newton-Raphson 4 iteration으로 sqrt 근사. 초기값이 나쁘면 수렴 안 함
- 확인법: variance 범위가 Q12에서 얼마인지 확인. 극단값(variance ≈ 0 또는 매우 큰 경우)에서 sqrt 결과 검증
- 대응: 초기값을 bit manipulation으로 추정 (fast inverse sqrt 패턴)

**P4-3: LayerNorm HW의 division 구현**

- 원인: `(x - mean) / std`에서 division이 필요. HW divider는 면적이 크고, iterative divider는 latency가 김
- 대응: `(x - mean) * (1/std)`로 변환. `1/std`를 Newton-Raphson으로 계산 (sqrt와 합칠 수 있음: `1/sqrt(var)` 직접 계산)

**P4-4: MMIO 레지스터 주소 충돌**

- 원인: Softmax, LayerNorm, GEMV, DMA의 MMIO 주소가 겹치면 잘못된 모듈에 접근
- 확인법: 모든 MMIO 주소 범위 표 작성:
    
    ```
    ACCEL (GEMV):  0x2040_0000 ~ 0x2040_003FSPM:           0x2080_0000 ~ 0x209F_FFFF (128KB 시)DMA:           0x20A0_0000 ~ 0x20A0_003F (P3-2 수정 후)SOFTMAX:       0x20A4_0000 ~ 0x20A4_003F (새로 배정)LAYERNORM:     0x20A8_0000 ~ 0x20A8_003F (새로 배정)
    ```
    
- 주의: MCU의 address decode 우선순위에 따라 겹치면 뒤쪽이 무시됨

**P4-5: Softmax HW가 SPM에서 데이터를 읽어야 하는 경우**

- 원인: attention score가 SPM에 있으면 Softmax HW도 SPM 접근 필요. GEMV와 같은 문제
- 대응: Softmax HW의 input/output을 DMEM 주소로 전달하거나, CPU가 SPM에서 읽어서 MMIO로 전달 (작은 벡터이므로 feasible: T_max=40 words = 160 bytes)

**P4-6: Softmax/LayerNorm HW의 FSM과 CPU polling 타이밍**

- 원인: CPU가 CTRL에 start 쓰고 STATUS를 polling. FSM이 1 cycle만에 done을 올리면 CPU가 polling하기 전에 done이 이미 올라가 있어야 함
- 확인법: MCU의 ACCEL 처리 패턴과 동일하게 구현되었는지 확인
- 대응: GEMV accel의 CTRL/STATUS 패턴을 그대로 복사

**P4-7: HW/SW softmax 결과 차이로 BLEU 변동**

- 원인: HW 근사와 SW 근사의 미세한 차이로 attention weight가 달라지고, 이게 누적되어 다른 token 선택 → BLEU 변동
- 허용 범위: ±0.5 BLEU 이내면 정상
- 대응: 보고서에 "HW vs SW 정확도 비교 표" 포함. max error, mean error, BLEU 차이 정량화

**P4-8: 합성 시 critical path**

- 원인: 8-PE GEMM + Softmax + LayerNorm이 추가되면 면적과 critical path 증가
- 확인법: 합성 후 slack 확인. 음수면 clock period 늘리거나 pipeline 추가
- 대응: Softmax/LayerNorm은 FSM 기반(multi-cycle)이므로 critical path에 큰 영향 없음. GEMV의 8-way multiplier가 더 위험

### 주의사항

- Softmax와 LayerNorm을 **동시에** 추가하면 디버깅이 어려움. 가능하면 하나씩 추가하고 각각 시뮬
- 시간 부족 시 **Softmax만 HW로** (호출 빈도가 LayerNorm보다 높고, SW가 더 느림)
- LayerNorm은 SW로 남겨도 보고서에 "HW 설계 완료, 통합은 향후 과제"로 기술 가능

---

## 단계 간 공통 주의사항

### Git 관리

- 매 단계 시뮬 성공 후 `git tag stepN-pass` 태깅
- 문제 발생 시 이전 태그로 즉시 복귀 가능해야 함
- `git stash`로 작업 중 코드 임시 저장 습관

### 시뮬 시간 관리

- `screen bash run_vcs.sh`로 백그라운드 실행 필수
- 시뮬 시작 시각 기록. 24시간 후에도 안 끝나면 문제 있는 것
- `tail -f sim/out/vcs_sim.log`로 진행 상황 모니터링
- TB 로그에서 `sent_cnt`, `lstm_step_hit_cnt` (또는 transformer 대응 카운터) 확인

### BLEU 비교 표

| 단계     | 예상 BLEU         | cycle count | 비고                           |
| ------ | --------------- | ----------- | ---------------------------- |
| Step 0 | ~48             | baseline    | LSTM + GEMV + inline ASM fix |
| Step 1 | ~15             | 매우 많음       | Transformer, 전부 SW           |
| Step 2 | = Step 1        | 감소          | GEMV 연결                      |
| Step 3 | = Step 2        | 대폭 감소       | SPM + DMA + KV cache         |
| Step 5 | ≈ Step 3 (±0.5) | 추가 감소       | Softmax/LN HW                |

### 절대 하면 안 되는 것

1. `make server` 없이 RTL 시뮬부터 시작 (하루 낭비 위험)
2. 두 단계를 한꺼번에 변경 후 시뮬 (버그 원인 특정 불가)
3. LSTM baseline 브랜치를 덮어쓰기 (되돌릴 수 없음)
4. 시뮬 중 같은 서버에서 다른 시뮬 동시 실행 (리소스 경합)
5. weight 파일 생성 없이 코드만 교체 (weight mismatch → 쓰레기 출력)


# Step-by-Step Architecture: HW & SW Block Diagrams

All diagrams below use ASCII blocks. `[NEW]` = newly added, `[MOD]` = modified, unmarked = unchanged.

---

## Step 0: Inline ASM Bug Fix (LSTM Baseline)

### HW Block Diagram (no changes from current)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CPU_TOP (clk 10ns)                          │
│                                                                     │
│  ┌──────────────────┐          ┌──────────────────┐                │
│  │  SCALAR_CORE     │ icache   │  INSTR_CACHE     │                │
│  │  RV32IM          │─ ─ ─ ─ ─│  512 entries      │                │
│  │  ┌────┐ ┌─────┐  │          └──────────────────┘                │
│  │  │ALU │ │REGF │  │                                               │
│  │  │+MUL│ │     │  │          ┌──────────────────┐                │
│  │  └────┘ └─────┘  │  MMIO   │  GEMV ACCEL      │                │
│  └────────┬─────────┘ ───────►│  8-PE parallel    │                │
│           │dmem req             └────────┬─────────┘                │
│           ▼                              │ accel_dma                │
│  ┌──────────────────┐          ┌─────────▼────────┐                │
│  │  MCU              │          │  DATA_CACHE 2KB  │                │
│  │  IMEM/DMEM/IOMEM │          │  GEMV DMA path   │                │
│  │  +SPM/DMA decode  │          └────────┬─────────┘                │
│  └──┬───┬───┬───┬───┘                    │ dcache_mem               │
│     │   │   │   │         ┌──────────────┤                          │
│     │   │   │   │         │   ┌──────────┤                          │
│     │   │   │   │  ┌──────▼───▼──────┐   │                          │
│  ┌──▼─┐ │   │   │  │SPM    │ DMA     │   │                          │
│  │    │ │   │   │  │64KB   │ CTRL    │   │                          │
│  │    │ │   │   │  │1-cyc  │         │   │                          │
│  │    │ │   │   │  └───────┴────┬────┘   │                          │
│  │    │ │   │   │    SPM arbiter│         │                          │
│  │    │ │   │   │               │         │                          │
│  │    │ │   │   │  ┌────────────▼─────────▼──────────┐             │
│  │    │ │   │   │  │  3-WAY DMEM ARBITER             │             │
│  │    │ │   │   │  │  D-cache > DMA > MCU            │             │
│  │    │ │   │   │  └──────────────┬──────────────────┘             │
│  │    │ │   │   │                 │                                  │
└──┼────┼─┼───┼───┼─────────────────┼──────────────────────────────────┘
   │    │ │   │   │                 │
┌──▼──┐ │ │ ┌─▼──┐│          ┌──────▼──────┐
│IMEM │ │ │ │IOEM││          │   DMEM      │
│128KB│ │ │ │512K││          │   16MB 4cyc  │
└─────┘ │ │ └────┘│          └─────────────┘
        │ │       │
        └─┘       │
     (unused SPM/DMA — SW doesn't call them yet)
```

### SW Block Diagram

```
main()
 └─► greedy_decode_int()
      │
      ├─► ENCODER (for t in src_tokens)
      │    ├─► embedding_lookup()
      │    └─► lstm_step_int()
      │         ├─► gemv_hw(W_ih, x, gates, 512, 256)     ← HW GEMV
      │         ├─► gemv_hw(W_hh, h, temp, 512, 128)      ← HW GEMV
      │         ├─► sigmoid_q12() via mul_shift_q()         ← SW (LUT)
      │         ├─► tanh_q12() via mul_shift_q()            ← SW (LUT)
      │         └─► element-wise gate ops                   ← SW
      │
      └─► DECODER (for t in max_tgt_len)
           ├─► embedding_lookup()
           ├─► lstm_step_int()  (same as encoder)
           └─► linear_out_argmax()
                └─► dot_shift_q() loop (5897 × 128)
                     └─► i64_mul_i32()  ← [MOD] "=r" → "=&r" fix
```

**Step 0 change**: Only `eval_int_c.c` line ~219: `"=r"` → `"=&r"` in inline ASM.

---

## Step 1: Transformer SW Switch (no HW change)

### HW Block Diagram

```
(IDENTICAL to Step 0 — no hardware changes)
GEMV accel exists in HW but is NOT called by SW.
SPM/DMA exist in HW but are NOT used by SW.
```

### SW Block Diagram

```
main()                                                        [MOD] new entry
 └─► greedy_decode_transformer()                              [NEW] replaces greedy_decode_int
      │
      ├─► ENCODER (for each src token)
      │    └─► for layer in enc_layers (×2)                   [NEW]
      │         ├─► layer_norm_q12(x, gamma, beta)            [NEW] pure SW
      │         ├─► multi_head_attention()                    [NEW] pure SW
      │         │    ├─► matmul_q12(x, Wq) → Q               [NEW] SW triple-loop
      │         │    ├─► matmul_q12(x, Wk) → K               [NEW] SW triple-loop
      │         │    ├─► matmul_q12(x, Wv) → V               [NEW] SW triple-loop
      │         │    ├─► for each head:
      │         │    │    ├─► scores = Q_h × K_h^T            [NEW] SW small matmul
      │         │    │    ├─► softermax_q12(scores)           [NEW] SW (base-2 exp)
      │         │    │    └─► A_h = weights × V_h             [NEW] SW small matmul
      │         │    └─► matmul_q12(attn_out, Wo) → out      [NEW] SW triple-loop
      │         ├─► residual add                              [NEW]
      │         ├─► layer_norm_q12()                          [NEW]
      │         ├─► feed_forward()                            [NEW]
      │         │    ├─► matmul_q12(x, W1) → mid (128→256)   [NEW] SW triple-loop
      │         │    ├─► relu_q12(mid)                        [NEW] SW
      │         │    └─► matmul_q12(mid, W2) → out (256→128) [NEW] SW triple-loop
      │         └─► residual add                              [NEW]
      │
      └─► DECODER (for t in max_tgt_len)
           ├─► embedding_lookup()
           └─► for layer in dec_layers (×2)                   [NEW]
                ├─► layer_norm → masked_self_attention         [NEW]
                │    └─► (same structure as encoder attn)
                ├─► layer_norm → cross_attention               [NEW]
                │    └─► Q from decoder, K/V from encoder
                ├─► layer_norm → feed_forward                  [NEW]
                └─► linear_out_argmax()
                     └─► dot_shift_q() with i64_mul_i32 (=&r)

REMOVED from Step 0:
  - lstm_step_int()
  - gemv_hw() calls (not called, HW still exists)
  - sigmoid/tanh LUT (replaced by softermax/layernorm)

ALL NEW FUNCTIONS run as pure CPU SW — no HW acceleration.
Expected: VERY SLOW (2+ days sim). Verify BLEU with `make server` first.
```

### Files changed (SW only)

```
program/test_code/eval_transformer_q.c    [NEW] replaces eval_int_c.c
program/test_code/int_model_transformer_q12.c  [NEW] replaces int_model_q12.c
program/test_code/int_model_transformer_q12.h  [NEW] replaces int_model_q12.h
program/Makefile                          [MOD] SRCS swap
sim/tb/lstm_tb.sv                         [MOD] PC addresses updated
```

---

## Step 2: GEMV Connected to Transformer matmul (no HW change)

### HW Block Diagram

```
(IDENTICAL to Step 0/1 — no hardware changes)
GEMV accel is now CALLED by SW for large matrix multiplies.
```

### SW Block Diagram

```
main()
 └─► greedy_decode_transformer()
      │
      ├─► ENCODER (for each src token)
      │    └─► for layer in enc_layers (×2)
      │         ├─► layer_norm_q12()                          SW
      │         ├─► multi_head_attention()
      │         │    ├─► matmul_q12(x, Wq) → Q               [MOD] calls gemv_hw()
      │         │    ├─► matmul_q12(x, Wk) → K               [MOD] calls gemv_hw()
      │         │    ├─► matmul_q12(x, Wv) → V               [MOD] calls gemv_hw()
      │         │    ├─► for each head:
      │         │    │    ├─► scores = Q_h × K_h^T            SW (small, 40×32)
      │         │    │    ├─► softermax_q12(scores)           SW
      │         │    │    └─► A_h = weights × V_h             SW (small, 40×32)
      │         │    └─► matmul_q12(attn_out, Wo)             [MOD] calls gemv_hw()
      │         ├─► feed_forward()
      │         │    ├─► matmul_q12(x, W1, 128→256)           [MOD] calls gemv_hw()
      │         │    ├─► relu_q12()                           SW
      │         │    └─► matmul_q12(mid, W2, 256→128)         [MOD] calls gemv_hw()
      │         └─► residual adds                             SW
      │
      └─► DECODER (for t in max_tgt_len)
           ├─► embedding_lookup()
           └─► for layer (×2)
                ├─► LN → self-attn
                │    ├─► Q/K/V/O projections                  [MOD] gemv_hw()
                │    ├─► Q×K^T, softmax, attn×V               SW (small matrices)
                ├─► LN → cross-attn
                │    ├─► Q/K/V/O projections                  [MOD] gemv_hw()
                │    ├─► Q×K^T, softmax, attn×V               SW
                ├─► LN → FFN
                │    ├─► W1, W2 projections                   [MOD] gemv_hw()
                └─► linear_out_argmax()                       SW dot_shift_q

GEMV ROUTING (inside matmul_q12):
  if (M >= 64 && K >= 64)  →  gemv_hw(W, x_token, out, rows, cols)  per token
  else                      →  SW triple-loop (for small attn matrices)
```

### Files changed (SW only)

```
program/test_code/eval_transformer_q.c    [MOD] matmul_q12() adds gemv_hw() path
                                           Add: #include "gemv_accel.h"
```

---

## Step 3: SPM 128KB + DMA Tiling + KV Cache

### HW Block Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CPU_TOP (clk 10ns)                          │
│                                                                     │
│  ┌──────────────────┐          ┌──────────────────┐                │
│  │  SCALAR_CORE     │          │  INSTR_CACHE     │                │
│  │  RV32IM          │          │  512 entries      │                │
│  └────────┬─────────┘          └──────────────────┘                │
│           │                                                         │
│           │                    ┌──────────────────┐                │
│           │             MMIO  │  GEMV ACCEL      │                │
│           │            ──────►│  8-PE parallel    │                │
│           │                    └────────┬─────────┘                │
│           │                             │accel_dma                  │
│           │                    ┌────────▼─────────┐                │
│           │                    │  DATA_CACHE 2KB  │                │
│           │                    └────────┬─────────┘                │
│           ▼                             │                           │
│  ┌──────────────────┐                   │                           │
│  │  MCU              │                   │                           │
│  │  [MOD] decode:    │                   │                           │
│  │  SPM_DEPTH 0x8000 │                   │                           │
│  │  DMA_START 0x0828 │                   │                           │
│  └──┬───┬───┬───┬───┘                   │                           │
│     │   │   │   │                        │                           │
│     │   │   │   ▼                        │                           │
│     │   │   │  ┌─────────────────────────────────┐                 │
│     │   │   │  │  [MOD] SPM 128KB (was 64KB)     │                 │
│     │   │   │  │  ┌──────────┐  ┌──────────────┐ │                 │
│     │   │   │  │  │Weight    │  │ KV cache     │ │                 │
│     │   │   │  │  │tiles     │  │ ~80KB        │ │                 │
│     │   │   │  │  │~46KB     │  │ [NEW]        │ │                 │
│     │   │   │  │  └──────────┘  └──────────────┘ │                 │
│     │   │   │  └──────────────┬──────────────────┘                 │
│     │   │   │                 │                                     │
│     │   │   │      ┌──────┐  │                                     │
│     │   │   └─────►│[MOD] │  │                                     │
│     │   │   DMA    │DMA   │  │                                     │
│     │   │   MMIO   │CTRL  │  │                                     │
│     │   │          │0x20A0│◄─┘ SPM arbiter                         │
│     │   │          └──┬───┘                                         │
│     │   │             │                                             │
│     │   │  ┌──────────▼──────────────────────────────┐             │
│     │   │  │  3-WAY DMEM ARBITER                     │             │
│     │   │  │  D-cache > DMA > MCU                    │             │
│     │   │  └──────────────┬──────────────────────────┘             │
└─────┼───┼─────────────────┼──────────────────────────────────────────┘
      │   │                 │
   IMEM IOMEM            DMEM 16MB

KEY CONSTRAINT:
  GEMV ──X──► SPM  (CANNOT read from SPM! GEMV only reads DMEM via D-cache)
  CPU  ──✓──► SPM  (1-cycle access via MCU)
  DMA  ──✓──► SPM  (bulk copy DMEM↔SPM)

ADDRESS MAP CHANGE:
  SPM:  0x2080_0000 ~ 0x209F_FFFF  (was ~0x208F_FFFF, now 128KB)
  DMA:  0x20A0_0000 ~ 0x20A0_003F  (was 0x2090, MOVED to avoid overlap!)
```

### SW Block Diagram

```
main()
 └─► greedy_decode_transformer()
      │
      ├─► ENCODER (for each src token)
      │    └─► for layer in enc_layers (×2)
      │         │
      │         ├─► layer_norm_q12()                          SW, operands in DMEM
      │         ├─► multi_head_attention()
      │         │    ├─► gemv_hw(Wq, x, Q, 128, 128)         GEMV reads DMEM (4cyc)
      │         │    ├─► gemv_hw(Wk, x, K, 128, 128)         GEMV reads DMEM
      │         │    ├─► gemv_hw(Wv, x, V, 128, 128)         GEMV reads DMEM
      │         │    ├─► attention scores + softmax            SW
      │         │    └─► gemv_hw(Wo, attn, out, 128, 128)     GEMV reads DMEM
      │         ├─► feed_forward()
      │         │    ├─► gemv_hw(W1, x, mid, 256, 128)        GEMV reads DMEM
      │         │    └─► gemv_hw(W2, mid, out, 128, 256)      GEMV reads DMEM
      │         └─► [NEW] Store encoder K,V to SPM KV cache
      │              └─► CPU load from DMEM → CPU store to SPM (per token)
      │
      └─► DECODER (for t in max_tgt_len)
           ├─► embedding_lookup()
           └─► for layer (×2)
                │
                ├─► LN → self-attn
                │    ├─► gemv_hw() for Q/K/V projections      GEMV reads DMEM
                │    ├─► [NEW] Store K_t, V_t to SPM KV cache
                │    │    └─► SPM[KV_BASE + t*128] = K_t      CPU→SPM 1cyc
                │    ├─► [NEW] Read K_cache, V_cache from SPM
                │    │    └─► K_cache[0..t]: SPM read 1cyc    (was DMEM 4cyc)
                │    ├─► scores = Q × K_cache^T                SW, K from SPM (1cyc)
                │    ├─► softermax_q12(scores)                 SW
                │    └─► out = attn × V_cache                  SW, V from SPM (1cyc)
                │
                ├─► LN → cross-attn
                │    ├─► gemv_hw() for Q projection            GEMV reads DMEM
                │    ├─► [NEW] Read encoder K,V from SPM KV cache
                │    ├─► scores, softmax, attn×V               SW, K/V from SPM (1cyc)
                │
                ├─► LN → FFN
                │    └─► gemv_hw() × 2                         GEMV reads DMEM
                │
                └─► linear_out_argmax()                       SW

SPM DATA LAYOUT (128KB = 0x2080_0000 ~ 0x209F_FFFF):
  0x2080_0000  ┌─────────────────────────┐
               │ Weight tile buffer      │  ~46KB (DMA pre-loads for CPU use)
  0x2080_B800  ├─────────────────────────┤
               │ Encoder KV cache        │  ~40KB
               │  K: 2 layers × 40 × 128 │
               │  V: 2 layers × 40 × 128 │
  0x2081_5800  ├─────────────────────────┤
               │ Decoder KV cache        │  ~40KB
               │  K: 2 layers × 40 × 128 │
               │  V: 2 layers × 40 × 128 │
  0x209F_FFFF  └─────────────────────────┘

WHERE SPM HELPS (1cyc vs 4cyc):
  ✓ KV cache read during attention (⑤⑦ in decoder): 40 tokens × 128 × 2 = 10240 reads saved
  ✓ Encoder output K/V reused by all decoder cross-attention: huge saving
  ✗ GEMV weight access: still DMEM 4cyc (GEMV cannot read SPM)
```

### Files changed

```
rtl/memory/scratchpad.sv       [MOD] Depth: 16384 → 32768 (ifdef SIM: mem[0:32767])
rtl/cpu_top.sv                 [MOD] SPM_DEPTH_W: 0x4000 → 0x8000
                               [MOD] DMA_START_W: 0x0824_0000 → 0x0828_0000
rtl/scalar_core/mcu.sv         [MOD] DMA_START_W default updated
rtl/dma/dma_controller.h       [MOD] DMA_BASE: 0x20900000 → 0x20A00000
sim/tb/lstm_tb.sv              [MOD] SPM_DEPTH_W, DMA_START_W updated

program/test_code/eval_transformer_q.c  [MOD] Add KV cache management:
  - #include "dma_controller.h"
  - KV cache store after each K/V projection
  - KV cache read during attention score computation
  - SPM address macros (KV_K_ADDR, KV_V_ADDR)
```

---

## Step 5: Softmax HW + LayerNorm HW

### HW Block Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CPU_TOP (clk 10ns)                          │
│                                                                     │
│  ┌──────────────────┐          ┌──────────────────┐                │
│  │  SCALAR_CORE     │          │  INSTR_CACHE     │                │
│  │  RV32IM          │          │  512 entries      │                │
│  └────────┬─────────┘          └──────────────────┘                │
│           │                                                         │
│           │         ┌────────────┐ ┌──────────┐ ┌──────────┐      │
│           │  MMIO   │GEMV ACCEL  │ │[NEW]     │ │[NEW]     │      │
│           │ ──────► │8-PE        │ │SOFTMAX   │ │LAYERNORM │      │
│           │         │            │ │HW        │ │HW        │      │
│           │         └─────┬──────┘ │0x20A4    │ │0x20A8    │      │
│           │               │        └──────────┘ └──────────┘      │
│           │         ┌─────▼──────┐                                  │
│           │         │DATA_CACHE  │                                  │
│           │         │2KB         │                                  │
│           │         └─────┬──────┘                                  │
│           ▼               │                                         │
│  ┌──────────────────┐     │                                         │
│  │  MCU              │     │                                         │
│  │  [MOD] +SOFTMAX   │     │                                         │
│  │  +LAYERNORM decode│     │                                         │
│  └──┬───┬───┬───┬───┘     │                                         │
│     │   │   │   │          │                                         │
│     │   │   │   ▼          │                                         │
│     │   │   │  ┌───────────────────────────────┐                    │
│     │   │   │  │SPM 128KB                      │                    │
│     │   │   │  │  Weight tiles │ KV cache       │                    │
│     │   │   │  └───────────────┬───────────────┘                    │
│     │   │   │       ┌─────────┘                                     │
│     │   │   │  ┌────▼───┐                                           │
│     │   │   └─►│DMA CTRL│                                           │
│     │   │      │0x20A0  │                                           │
│     │   │      └────┬───┘                                           │
│     │   │  ┌────────▼────────────────────────────┐                  │
│     │   │  │3-WAY DMEM ARBITER                   │                  │
│     │   │  └──────────────┬──────────────────────┘                  │
└─────┼───┼─────────────────┼──────────────────────────────────────────┘
   IMEM IOMEM            DMEM 16MB

ADDRESS MAP (final):
  ACCEL:     0x2040_0000 ~ 0x2040_003F   GEMV registers
  SPM:       0x2080_0000 ~ 0x209F_FFFF   128KB on-chip SRAM
  DMA:       0x20A0_0000 ~ 0x20A0_003F   DMA control registers
  SOFTMAX:   0x20A4_0000 ~ 0x20A4_003F   [NEW] Softmax registers
  LAYERNORM: 0x20A8_0000 ~ 0x20A8_003F   [NEW] LayerNorm registers
```

### Softmax HW Detail

```
MMIO Registers:
  0x00: INPUT_ADDR   (W) — input vector address (DMEM byte addr)
  0x04: OUTPUT_ADDR  (W) — output vector address (DMEM byte addr)
  0x08: LEN          (W) — vector length (max 40)
  0x0C: CTRL         (W) — bit[0] = start
  0x10: STATUS       (R) — bit[0] = done, bit[1] = busy

FSM: IDLE → FIND_MAX → COMPUTE_EXP → SUM → NORMALIZE → DONE
  - FIND_MAX: read all inputs, find max value (~LEN cycles)
  - COMPUTE_EXP: exp(x_i - max) via 64-entry LUT (~LEN cycles)
  - SUM: accumulate exp values (~LEN cycles)
  - NORMALIZE: exp_i / sum for each element (~LEN cycles)
  Total: ~4 × LEN cycles (vs SW ~500 cycles for LEN=40)

IMPORTANT: Uses base-2 exponential (pow2_neg_q12) to match SW softermax,
           NOT natural exp. Must use same LUT/approximation as SW.
```

### LayerNorm HW Detail

```
MMIO Registers:
  0x00: INPUT_ADDR   (W)
  0x04: OUTPUT_ADDR  (W)
  0x08: GAMMA_ADDR   (W) — scale parameter address
  0x0C: BETA_ADDR    (W) — shift parameter address
  0x10: DIM          (W) — vector dimension (128)
  0x14: CTRL         (W) — bit[0] = start
  0x18: STATUS       (R) — bit[0] = done, bit[1] = busy

FSM: IDLE → MEAN → VARIANCE → SQRT → NORMALIZE → DONE
  - MEAN: sum(x) / dim (~DIM cycles)
  - VARIANCE: sum((x - mean)^2) / dim (~DIM cycles)
  - SQRT: Newton-Raphson 4 iterations (~20 cycles)
  - NORMALIZE: (x - mean) / std * gamma + beta (~DIM cycles)
  Total: ~3×DIM + 20 cycles ≈ 404 cycles for DIM=128
         (vs SW ~800 cycles)
```

### SW Block Diagram

```
main()
 └─► greedy_decode_transformer()
      │
      ├─► ENCODER
      │    └─► for layer (×2)
      │         ├─► [MOD] layernorm_hw(x, gamma, beta, 128)  HW MMIO (~404 cyc)
      │         ├─► multi_head_attention()
      │         │    ├─► gemv_hw() × 4 (Q/K/V/O)             HW GEMV
      │         │    ├─► for each head:
      │         │    │    ├─► Q×K^T                            SW (small)
      │         │    │    ├─► [MOD] softmax_hw(scores, len)   HW MMIO (~160 cyc)
      │         │    │    └─► attn×V                           SW (small)
      │         ├─► residual add                               SW
      │         ├─► [MOD] layernorm_hw()                      HW MMIO
      │         ├─► feed_forward()
      │         │    ├─► gemv_hw() × 2 (W1, W2)               HW GEMV
      │         │    └─► relu_q12()                            SW
      │         ├─► residual add                               SW
      │         └─► Store K,V to SPM KV cache                 CPU→SPM 1cyc
      │
      └─► DECODER (per token t)
           └─► for layer (×2)
                ├─► [MOD] layernorm_hw()                      HW MMIO
                ├─► self-attn
                │    ├─► gemv_hw() × 4                         HW GEMV
                │    ├─► KV cache store to SPM                 CPU→SPM
                │    ├─► KV cache read from SPM                SPM→CPU 1cyc
                │    ├─► Q×K^T                                 SW
                │    ├─► [MOD] softmax_hw()                   HW MMIO
                │    └─► attn×V                                SW
                │
                ├─► [MOD] layernorm_hw()                      HW MMIO
                ├─► cross-attn
                │    ├─► gemv_hw() (Q only)                    HW GEMV
                │    ├─► KV read from SPM (encoder cache)      SPM→CPU 1cyc
                │    ├─► Q×K^T                                 SW
                │    ├─► [MOD] softmax_hw()                   HW MMIO
                │    └─► attn×V                                SW
                │
                ├─► [MOD] layernorm_hw()                      HW MMIO
                ├─► FFN: gemv_hw() × 2 + relu                 HW GEMV + SW
                │
                └─► linear_out_argmax()                       SW

HW CALLS PER DECODER LAYER PER TOKEN:
  layernorm_hw():  3 calls × ~404 cyc = ~1,212 cyc
  softmax_hw():    2 calls × ~160 cyc = ~320 cyc
  gemv_hw():       ~8 calls (varies)
  Total HW calls per layer: 13
  Total HW calls per token (2 layers): 26
```

### Files changed

```
rtl/accel/softmax_unit.sv       [NEW] Softmax MMIO peripheral
rtl/accel/softmax_unit.h        [NEW] C header: softmax_hw()
rtl/accel/layernorm_unit.sv     [NEW] LayerNorm MMIO peripheral
rtl/accel/layernorm_unit.h      [NEW] C header: layernorm_hw()
rtl/scalar_core/mcu.sv          [MOD] Add SOFTMAX/LAYERNORM address decode
                                      SOFTMAX_START_W = 0x0829_0000
                                      LAYERNORM_START_W = 0x082A_0000
rtl/cpu_top.sv                  [MOD] Instantiate softmax_unit, layernorm_unit
                                      Connect to MCU MMIO ports
sim/run_vcs.sh                  [MOD] Add new .sv files to RTL_LIST
sim/tb/lstm_tb.sv               [MOD] Pass new parameters

program/test_code/eval_transformer_q.c  [MOD] Replace:
  - softermax_q12() → softmax_hw()
  - layer_norm_q12() → layernorm_hw()
  - #include "softmax_unit.h"
  - #include "layernorm_unit.h"
```

---

## Quick Reference: What Changes at Each Step

```
         │ Step 0 │ Step 1  │ Step 2  │ Step 3    │ Step 5
─────────┼────────┼─────────┼─────────┼───────────┼────────────
RTL      │  none  │  none   │  none   │ SPM size  │ +Softmax HW
changes  │        │         │         │ DMA addr  │ +LayerNorm HW
         │        │         │         │           │ MCU decode
─────────┼────────┼─────────┼─────────┼───────────┼────────────
SW       │ =&r    │ LSTM→TF │ matmul  │ +DMA tile │ softermax→HW
changes  │ fix    │ full    │ →gemv   │ +KV cache │ layernorm→HW
         │        │ swap    │ _hw()   │ in SPM    │
─────────┼────────┼─────────┼─────────┼───────────┼────────────
GEMV     │ unused │ unused  │ used    │ used      │ used
         │ by TF  │ by TF   │ DMEM    │ DMEM      │ DMEM
─────────┼────────┼─────────┼─────────┼───────────┼────────────
SPM      │ exists │ exists  │ exists  │ 128KB     │ 128KB
         │ unused │ unused  │ unused  │ KV cache  │ KV cache
─────────┼────────┼─────────┼─────────┼───────────┼────────────
Expected │ ~48    │ ~15     │ =Step1  │ =Step2    │ ≈Step3
BLEU     │ (LSTM) │ (TF)   │ same    │ same      │ (±0.5)
─────────┼────────┼─────────┼─────────┼───────────┼────────────
Cycle    │ base   │ very    │ much    │ less      │ less
count    │ line   │ slow    │ faster  │ (KV 1cyc) │ (LN/SM HW)
```


