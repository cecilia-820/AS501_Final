# D-Cache 구현 요약

## 1. 추가 목적

GEMV 가속기가 행렬 가중치를 DMA로 읽을 때 매 행마다 같은 주소를 반복 접근한다.  
D_MEMORY의 40ns(= 4클럭) 레이턴시가 매 원소마다 발생하면 성능이 크게 저하되므로,  
ACCEL DMA 포트와 D_MEMORY 사이에 **직접 매핑(direct-mapped) 데이터 캐시**를 삽입하여  
가중치를 캐시에 올려두고 재사용한다.

---

## 2. 구조 개요

```
GEMV_ACCEL (dma_req/addr/wdata/rdata/ready)
       │
       ▼
  DATA_CACHE          ← 신규 추가 (rtl/cache/data_cache.sv)
  ┌─────────────────────────────────────────┐
  │  direct-mapped, 512 entry, 1-word line  │
  │  SRAM: TS5N28HPCPHVTA512X54M4F (54-bit) │
  │  write-through, no-allocate            │
  │  FSM: Reset→Idle→Check→Fetch→Fill      │
  │              └─→WritePre→WriteWait      │
  └─────────────────────────────────────────┘
       │  (mem_req/write/addr/wdata/rdata)
       ▼
  DMEM 아비터 (cpu_top 내부)
       │
       ▼
  D_MEMORY  (40ns latency)
```

---

## 3. D-Cache 상세 설계 (rtl/cache/data_cache.sv)

### 3-1. 파라미터

| 파라미터 | 값 | 설명 |
|---|---|---|
| `DWidth` | 32 | 데이터 비트 폭 |
| `Depth` | 512 | 캐시 엔트리 수 |
| `Index` | 9 (=$clog2(512)) | 인덱스 비트 |
| `Tag` | 21 (=32−2−9) | 태그 비트 |
| `LineW` | 54 (=1+21+32) | SRAM 라인 폭: valid(1)+tag(21)+data(32) |
| `LATENCY` | 4 | D_MEMORY 응답 대기 클럭 수 |

### 3-2. 캐시 라인 구조

```
bit[53]      bit[52:32]   bit[31:0]
  valid(1)    tag(21)      data(32)
```

### 3-3. 주소 분해

```
byte address [31:0]
  [31:11]  → tag   (21비트)
  [10:2]   → index (9비트, 엔트리 선택)
  [1:0]    → 무시  (word-aligned)
```

### 3-4. FSM 상태

| 상태 | 동작 |
|---|---|
| `StReset` | 리셋 시 모든 512 엔트리 valid=0 초기화 (512사이클 소요) |
| `StIdle` | DMA 요청 대기. read → StCheck, write → StWritePre |
| `StCheck` | SRAM 출력 확인. Hit → dma_ready=1 즉시 반환. Miss → mem_req 펄스 → StFetch |
| `StFetch` | lat_cnt 0→3 카운트 (4클럭 대기, D_MEMORY 처리 시간) |
| `StFill` | mem_rdata를 캐시 SRAM에 기록 + dma_rdata_o 반환 + dma_ready=1 |
| `StWritePre` | mem_req=1, mem_write=1 동시 어설트 (wdata는 StIdle에서 선행 라우팅) |
| `StWriteWait` | 4클럭 대기 후 dma_ready=1 (no-allocate: 캐시 갱신 없음) |

### 3-5. 쓰기 정책

- **Write-through, no-allocate**: write hit/miss 모두 D_MEMORY에 직접 기록, 캐시 라인은 갱신하지 않음
- `$hold` 위반 방지: StIdle에서 `mem_write_o=1`로 wdata를 선행 라우팅 → StWritePre에서 `mem_req_o` 상승 시 wdata가 이미 안정

### 3-6. Hit/Miss 판단

```systemverilog
wire hit = sram_rdata[LineW-1]                         // valid bit
        && (sram_rdata[LineW-2:DWidth] == req_tag);    // tag 일치
```

### 3-7. SRAM 인스턴스

I-cache와 동일한 물리 SRAM(`ICACHE_SRAM`)을 재사용.  
시뮬레이션(`+define+SIM`)에서는 SRAM 입력에 수십 ps 지연선을 삽입하여 타이밍 경고를 방지.

```systemverilog
`ifdef SIM
  wire #0.038  cen_d   = cen;
  wire #0.095  wen_d   = wen;
  wire #0.0932 addr_d  = sram_addr;
  wire #0.1371 wdata_d = sram_wdata;
  ICACHE_SRAM ... DCACHE_SRAM ( .ceb_i(!cen_d), ... );
`else
  ICACHE_SRAM ... DCACHE_SRAM ( .ceb_i(!cen),  ... );
`endif
```

---

## 4. 변경된 파일 목록

### 4-1. 신규 생성: `rtl/cache/data_cache.sv`

전체 파일 신규 작성. 위 3절 내용 전부 포함.

---

### 4-2. 수정: `rtl/cpu_top.sv`

**변경 내용:** ACCEL DMA 포트와 D_MEMORY 아비터 사이에 DATA_CACHE 삽입

#### 추가된 내부 신호

```systemverilog
// D-cache memory-side signals (DMEM 아비터 구동)
logic                 dcache_mem_req;
logic                 dcache_mem_write;
logic [DWidth-1:0]    dcache_mem_addr;
logic [DWidth-1:0]    dcache_mem_wdata;
```

#### 아비터 변경 (ACCEL DMA → D-cache → DMEM)

```systemverilog
// 변경 전: dma_req가 직접 DMEM 아비터를 구동
assign dmem_req_o   = dma_req ? 1'b1      : mcu_ext_dmem_req;
assign dmem_addr_o  = dma_req ? (dma_addr - (DMEM_START_W << 2)) : mcu_ext_dmem_addr;
assign dma_rdata    = dmem_rdata_i;
assign dma_ready    = dma_req ? 1'b1 : 1'b0;

// 변경 후: D-cache의 mem 포트가 DMEM 아비터를 구동
assign dmem_req_o   = dcache_mem_req   ? 1'b1             : mcu_ext_dmem_req;
assign dmem_write_o = dcache_mem_req   ? dcache_mem_write : mcu_ext_dmem_write;
assign dmem_addr_o  = dcache_mem_req   ? dcache_mem_addr  : mcu_ext_dmem_addr;
assign dmem_wdata_o = dcache_mem_write ? dcache_mem_wdata : mcu_ext_dmem_wdata;
```

#### DATA_CACHE 인스턴스 추가

```systemverilog
DATA_CACHE #(.DWidth(DWidth)) u_data_cache (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .dma_req_i   (dma_req),
    .dma_write_i (dma_write),
    .dma_addr_i  (dma_addr - (DMEM_START_W << 2)),  // DMEM 상대 byte 오프셋
    .dma_wdata_i (dma_wdata),
    .dma_rdata_o (dma_rdata),
    .dma_ready_o (dma_ready),
    .mem_req_o   (dcache_mem_req),
    .mem_write_o (dcache_mem_write),
    .mem_addr_o  (dcache_mem_addr),
    .mem_wdata_o (dcache_mem_wdata),
    .mem_rdata_i (dmem_rdata_i)
);
```

> `dma_addr - (DMEM_START_W << 2)`: ACCEL이 넘기는 절대 byte 주소에서  
> DMEM 베이스(0x0020_0000)를 빼서 캐시 인덱스 계산에 사용.

---

### 4-3. 수정: `rtl/accel/gemv_accel.sv`

**버그 수정:** row/col 종료 조건의 32비트 산술 오버플로우

#### 원인

```systemverilog
// rows_q = 32'd512 일 때:
// rows_q[$clog2(MAX_DIM)-1:0] = 9'd0
// 9'd0 - 1 → 32비트 문맥에서 32'hFFFF_FFFF
// row_cnt_q(9비트 최대 511) == 32'hFFFF_FFFF → 항상 FALSE → 무한루프
row_cnt_q == rows_q[$clog2(MAX_DIM)-1:0] - 1   // ← 버그
```

#### 수정

```systemverilog
// +1'b1 로 비교: 9비트 산술 → 511+1 = 0 (mod 512), 0 == 0 → TRUE
row_cnt_q + 1'b1 == rows_q[$clog2(MAX_DIM)-1:0]   // ← 수정
```

수정된 위치 4곳:

| 위치 | 변경 |
|---|---|
| StLoadVec 종료 | `col_cnt_q + 1'b1 == cols_q[...]` |
| StLoadRow 종료 | `col_cnt_q + 1'b1 == cols_q[...]` |
| StStore 종료   | `row_cnt_q + 1'b1 == rows_q[...]` |
| acc_q 리셋 조건 | `(row_cnt_q + 1'b1) != rows_q[...]` |

**디버그용 `$display` 추가** (시뮬레이션 FSM 추적용):

```systemverilog
if (start_pulse)
  $display("[ACCEL] %0t: START rows=%0d cols=%0d ...", $time, ...);
if (state_q == StLoadVec && state_d == StLoadRow)
  $display("[ACCEL] %0t: LOAD_VEC done -> LOAD_ROW row=0", $time);
if (state_q == StStore && dma_ready_i && row_cnt_q[6:0] == 7'd0)
  $display("[ACCEL] %0t: STORE row=%0d done", $time, row_cnt_q);
if (state_d == StDone && state_q != StDone)
  $display("[ACCEL] %0t: DONE! (all %0d rows)", $time, rows_q);
```

---

### 4-4. 수정: `sim/run_vcs.sh`

RTL 파일 목록에 한 줄 추가:

```bash
$RTL_DIR/cache/data_cache.sv                     \
```

---

## 5. 신호 흐름 요약

```
GEMV_ACCEL
  dma_req_o / dma_addr_o / dma_wdata_o
          │
          ▼
     DATA_CACHE
      ├─ Hit : SRAM → dma_rdata_o, dma_ready_o=1  (2 클럭)
      └─ Miss: mem_req_o=1 → D_MEMORY → StFill → dma_ready_o=1  (7 클럭)
          │
          ▼  (mem_req/write/addr/wdata)
     cpu_top 아비터
      ├─ dcache_mem_req=1 → D_MEMORY (ACCEL DMA 우선)
      └─ dcache_mem_req=0 → MCU (CPU 접근)
          │
          ▼
     D_MEMORY  (40ns = 4클럭 레이턴시)
```

---

## 6. 시뮬레이션 검증 결과

수정 전:
```
[ACCEL] STORE row=0 done  (반복 무한루프, DONE 미출력)
```

수정 후:
```
[ACCEL] 14296285000: DONE! (all 512 rows)
[TB][func] cycle=4249232 ... lstm_step_int count=2   ← 다음 스텝으로 진행
```
