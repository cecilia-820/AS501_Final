# GEMV 가속기 + D-Cache 구현 세션 로그

## 세션 개요

- **브랜치**: `gemv-accel-program` → `my-final-version`
- **목표**: GEMV 하드웨어 가속기 구현 후 시뮬레이션 hang 디버깅, D-Cache 추가

---

## 1. 시뮬레이션 멈춤 현상 최초 확인

**증상**:
```
[TB][func] cycle=900599 time=9006015000 pc=0x00000038 gemv_hw count=1
```
이후 아무 출력 없이 시뮬레이션 정지.

**원인 가설**: `gemv_hw` 내부의 폴링 루프에서 탈출 못 함
```c
while (!(ACCEL_STATUS & 1u)) {}
```
→ `ACCEL_STATUS bit[0]` (done)이 절대 1이 되지 않음

---

## 2. D-Cache 추가 (rtl/cache/data_cache.sv 신규 생성)

GEMV 가속기가 행렬 가중치를 DMA로 읽을 때 매 원소마다 D_MEMORY(40ns = 4클럭) 레이턴시가 발생하는 문제를 해결하기 위해 ACCEL DMA 포트와 D_MEMORY 사이에 데이터 캐시를 삽입.

### 구조

```
GEMV_ACCEL
    │
    ▼
DATA_CACHE  (직접 매핑, 512 엔트리, 1-word 라인)
    │ Hit  → dma_ready=1, 2클럭
    │ Miss → D_MEMORY → StFill → dma_ready=1, 7클럭
    ▼
DMEM 아비터 (cpu_top)
    │
    ▼
D_MEMORY (40ns)
```

### 캐시 파라미터

| 항목 | 값 |
|---|---|
| 엔트리 수 | 512 |
| 라인 크기 | 1 word (32bit) |
| 태그 | 21bit |
| 인덱스 | 9bit (addr[10:2]) |
| SRAM | ICACHE_SRAM 재사용 (54bit: valid+tag+data) |
| 쓰기 정책 | Write-through, no-allocate |
| 레이턴시 카운터 | 4클럭 (D_MEMORY 40ns 대응) |

### FSM

```
StReset → StIdle → StCheck --Hit-→ dma_ready=1 → StIdle
                        └--Miss→ StFetch(4클럭) → StFill → StIdle
          StIdle --write→ StWritePre → StWriteWait(4클럭) → StIdle
```

### $hold 위반 방지

D_MEMORY는 `always @(posedge dmem_req_i)`로 동작하며 write 시 `dmem_wdata`에 대한 `$setuphold` 검사가 있음.  
→ `StIdle`에서 `mem_write_o=1`로 wdata를 **1클럭 선행 라우팅**한 뒤 `StWritePre`에서 `mem_req_o=1` 어설트.  
→ `cpu_top` 아비터도 `dcache_mem_write` 기준으로 `dmem_wdata_o`를 라우팅:
```systemverilog
assign dmem_wdata_o = dcache_mem_write ? dcache_mem_wdata : mcu_ext_dmem_wdata;
```

---

## 3. cpu_top.sv 수정

### 변경 전: ACCEL DMA → DMEM 직접 연결

```systemverilog
assign dmem_req_o   = dma_req ? 1'b1      : mcu_ext_dmem_req;
assign dmem_addr_o  = dma_req ? (dma_addr - (DMEM_START_W << 2)) : mcu_ext_dmem_addr;
assign dma_rdata    = dmem_rdata_i;
assign dma_ready    = dma_req ? 1'b1 : 1'b0;
```

### 변경 후: ACCEL DMA → DATA_CACHE → DMEM

```systemverilog
// D-cache memory-side 신호
logic dcache_mem_req, dcache_mem_write;
logic [DWidth-1:0] dcache_mem_addr, dcache_mem_wdata;

assign dmem_req_o   = dcache_mem_req   ? 1'b1             : mcu_ext_dmem_req;
assign dmem_write_o = dcache_mem_req   ? dcache_mem_write : mcu_ext_dmem_write;
assign dmem_addr_o  = dcache_mem_req   ? dcache_mem_addr  : mcu_ext_dmem_addr;
assign dmem_wdata_o = dcache_mem_write ? dcache_mem_wdata : mcu_ext_dmem_wdata;

DATA_CACHE u_data_cache (
    .dma_addr_i  (dma_addr - (DMEM_START_W << 2)),  // 절대 주소 → 상대 오프셋
    ...
);
```

---

## 4. 핵심 버그 발견 및 수정

### 디버그 $display 추가 (gemv_accel.sv)

```systemverilog
if (start_pulse)
  $display("[ACCEL] %0t: START rows=%0d cols=%0d ...", ...);
if (state_d == StDone && state_q != StDone)
  $display("[ACCEL] %0t: DONE! (all %0d rows)", ...);
```

### 시뮬레이션 5분 실행 결과

```
[ACCEL] 9008635000: START rows=512 cols=128
[ACCEL] 9027875000: STORE row=0 done
[ACCEL] 10347555000: STORE row=128 done
[ACCEL] 11667235000: STORE row=256 done
[ACCEL] 12986915000: STORE row=384 done
[ACCEL] 14306595000: STORE row=0 done   ← 다시 row=0부터!
...                                      ← DONE! 출력 없음 → 무한루프
```

→ **ACCEL이 512 rows를 완료했음에도 StDone에 진입하지 못하고 row=0부터 반복**

### 버그 원인: 32비트 산술 오버플로우

```systemverilog
// rows_q = 32'd512 일 때:
// rows_q[$clog2(MAX_DIM)-1:0] = rows_q[8:0] = 9'd0
// 9'd0 - 1  →  32비트 문맥에서 32'hFFFF_FFFF
// row_cnt_q (9비트 최대값 511) == 32'hFFFF_FFFF → 항상 FALSE
row_cnt_q == rows_q[$clog2(MAX_DIM)-1:0] - 1   // ← 버그
```

`rows=512`이면 하위 9비트가 0이므로, `0 - 1`이 **32비트 문맥**에서 `0xFFFF_FFFF`가 되어 비교가 영원히 실패.

### 수정: `+1'b1` 비교로 변경

```systemverilog
// 9비트 산술: 511 + 1'b1 = 9'd0 (mod 512), 0 == rows_q[8:0](=0) → TRUE
row_cnt_q + 1'b1 == rows_q[$clog2(MAX_DIM)-1:0]
```

수정 위치 4곳:

| 위치 | 수정 |
|---|---|
| StLoadVec 종료 | `col_cnt_q + 1'b1 == cols_q[8:0]` |
| StLoadRow 종료 | `col_cnt_q + 1'b1 == cols_q[8:0]` |
| StStore 종료   | `row_cnt_q + 1'b1 == rows_q[8:0]` |
| acc_q 리셋 조건 | `(row_cnt_q + 1'b1) != rows_q[8:0]` |

### 수정 후 시뮬레이션 결과

```
[ACCEL] 14296285000: DONE! (all 512 rows)   ← 정상 종료
[TB][func] cycle=4249232 ... lstm_step_int count=2   ← 다음 스텝 진행
```

---

## 5. 변경 파일 목록

| 파일 | 변경 내용 |
|---|---|
| `rtl/cache/data_cache.sv` | **신규** — D-Cache FSM, SRAM, stuck 디텍터 |
| `rtl/cpu_top.sv` | D-Cache 삽입, 아비터 수정, DATA_CACHE 인스턴스 추가 |
| `rtl/accel/gemv_accel.sv` | 종료 조건 버그 수정 (`-1` → `+1'b1`), $display 추가 |
| `sim/run_vcs.sh` | `data_cache.sv` 파일 목록 추가 |
| `dcache_summary.md` | D-Cache 구조 설명 문서 |

---

## 6. linear_out_argmax 현황

`linear_out_argmax`는 현재 **소프트웨어 `dot_shift_q`** 사용 중:

```c
// eval_int_c.c:365
for (int v = 0; v < MODEL_TGT_VOCAB; ++v) {   // 5897회 반복
    val = dot_shift_q(out_w_q + v*MODEL_HID_SIZE, h_last, MODEL_HID_SIZE, Q);
}
```

실질적으로 **5897 × 128 GEMV**이며 `gemv_hw` 미사용 상태.  
→ 하드웨어 가속 대상으로 추가 가능.

---

## 7. 커밋 이력

```
a10b6f5 Add D-cache implementation summary document
882119f gemv & dcache
0adc2b7 Fix GEMV accel infinite loop and add D-cache for weight reuse
be06b05 Fix DMA address base subtraction and wdata hold violation in cpu_top arbiter
6938f9e Fix Q12 shift mismatch and RISCV include guard in GEMV path
8868c4f Fix GEMV accel simulation hang and D_MEMORY hold violation
e29d1ca Fix segfault in make server: guard gemv_hw calls with RISCV
9262b91 Add HW GEMV offload to eval_int_c.c and gemv_accel.h
```
