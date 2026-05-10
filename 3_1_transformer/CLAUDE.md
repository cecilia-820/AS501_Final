# AS501 Final Project — GEMV 가속기 구현 가이드

## 작업 디렉토리

```
/home/AS501_G3/2_AS501_final_main/
```

사용 폴더: `program/`, `rtl/`, `sim/`, `syn/` 만 사용. 그 외 폴더(`program_DH_TF`, `TF_Training_DH` 등)는 건드리지 않는다.

---

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

---

## 현재 아키텍처 요약

```
cpu_top
  ├── INSTR_CACHE
  ├── SCALAR_CORE  (RISC-V, non-pipelined)
  │     ├── DECODER / REGFILE / ALU / CSR
  │     └── dmem 포트 → MCU
  └── MCU  (메모리 컨트롤러, 4-cycle latency)
        ├── 주소 → IMEM  : 0x0000_0000 ~ (word)
        ├── 주소 → DMEM  : 0x0008_0000 ~ (word)  ← 가중치/활성화 저장
        └── 주소 → IOMEM : 0x0800_0000 ~ (word)  ← 입력/결과 버퍼
```

### 메모리 맵 (word 주소 기준, cpu_top.sv 파라미터)

| 영역 | START_W | DEPTH_W | 바이트 주소 |
|------|---------|---------|------------|
| IMEM | `0x0000_0000` | `0x0008_0000` | `0x0000_0000 ~` |
| DMEM | `0x0008_0000` | `0x07f8_0000` | `0x0020_0000 ~` |
| IOMEM | `0x0800_0000` | `0x0010_0000` | `0x2000_0000 ~` |

### ALU 연산 코드 (`core_package.sv`)

```
ADD=0x00, SUB=0x10, SLL=0x01, SLT=0x02, SLTU=0x03
XOR=0x04, SRL=0x05, SRA=0x15, OR=0x06,  AND=0x07
MUL=0x08, MULH=0x09, MULHSU=0x0A, MULHU=0x0B
```

---

## 목표: GEMV 가속기 추가

LSTM `lstm_step` 내의 행렬-벡터 곱(GEMV)을 하드웨어로 오프로드한다.

### 설계 원칙

- ACCEL은 `cpu_top` **내부**에 완전히 숨는다 (새 외부 포트 없음).
- ACCEL 제어 레지스터는 **새 주소 범위**를 MCU가 내부적으로 디코딩한다 (외부 `iomem_req_o`로 나가지 않음).
- ACCEL의 DMA는 **기존 DMEM 포트를 공유**한다. `cpu_top` 내부에 아비터를 두어 SCALAR_CORE와 ACCEL이 경쟁한다.
- ACCEL 동작 중 CPU는 STATUS 레지스터를 폴링하며 자연스럽게 stall.

### 추가할 ACCEL 주소 범위

MCU가 내부 디코딩 (외부 iomem_req_o로 나가지 않음):

```
ACCEL_START_W = 32'h0810_0000   (바이트: 0x2040_0000)
ACCEL_DEPTH_W = 32'h0000_0010   (레지스터 16개면 충분)
```

### ACCEL 제어 레지스터 맵 (word offset)

| Offset | 이름 | 방향 | 설명 |
|--------|------|------|------|
| 0 | `MAT_ADDR` | W | DMEM 내 행렬 베이스 주소 (바이트) |
| 1 | `VEC_ADDR` | W | DMEM 내 입력 벡터 베이스 주소 (바이트) |
| 2 | `OUT_ADDR` | W | DMEM 내 출력 베이스 주소 (바이트) |
| 3 | `ROWS` | W | 행렬 행 수 (M) |
| 4 | `COLS` | W | 행렬 열 수 / 벡터 길이 (K) |
| 5 | `CTRL` | W | bit[0]=start (write 1 to launch) |
| 6 | `STATUS` | R | bit[0]=done, bit[1]=busy |

---

## 구현할 파일 목록

### 1. 신규 생성

#### `rtl/accel/gemv_accel.sv`

인터페이스:
```systemverilog
module GEMV_ACCEL #(parameter DWidth = 32)(
    input  logic                 clk_i,
    input  logic                 rst_ni,
    // MCU → ACCEL: 제어 레지스터 포트
    input  logic                 accel_req_i,
    input  logic                 accel_write_i,
    input  logic [DWidth-1:0]    accel_addr_i,   // word offset
    input  logic [DWidth-1:0]    accel_wdata_i,
    output logic [DWidth-1:0]    accel_rdata_o,
    output logic                 accel_ready_o,
    // ACCEL → 아비터: DMEM DMA 포트
    output logic                 dma_req_o,
    output logic                 dma_write_o,
    output logic [DWidth-1:0]    dma_addr_o,
    output logic [DWidth-1:0]    dma_wdata_o,
    input  logic [DWidth-1:0]    dma_rdata_i,
    input  logic                 dma_ready_i
);
```

내부 구성:
- 제어 레지스터 7개 (위 맵)
- FSM: `IDLE → LOAD_VEC → LOAD_ROW → COMPUTE → STORE → DONE`
- 각 행마다 dot product: K번 MAC 후 결과 저장
- 데이터 타입: int32 (q12 고정소수점, `int_model_q12.c`와 동일)

#### `rtl/accel/gemv_accel.sv` FSM 동작

```
IDLE     : STATUS=done(이전), busy=0. CTRL[0]=1 write 감지 시 LOAD_VEC 진입
LOAD_VEC : VEC_ADDR에서 K개 word DMA read → 내부 벡터 버퍼에 저장
LOAD_ROW : 현재 행 i의 MAT_ADDR+i*K 위치에서 K개 word DMA read
COMPUTE  : 버퍼 내 MAC 계산 (조합논리 or 순차). 결과 = Σ mat[j]*vec[j]
STORE    : OUT_ADDR+i*4 에 result DMA write
           i < ROWS 이면 LOAD_ROW로 루프
DONE     : STATUS[0]=1, busy=0
```

---

### 2. 수정: `rtl/scalar_core/mcu.sv`

추가할 내용:

```systemverilog
// (1) 파라미터 추가 (cpu_top에서 내려받음)
parameter ACCEL_START_W = 32'h0810_0000,
parameter ACCEL_DEPTH_W = 32'h0000_0010

// (2) 포트 추가 (cpu_top → MCU → ACCEL 연결용)
output logic                 accel_req_o,
output logic                 accel_write_o,
output logic [DWidth-1:0]    accel_addr_o,
output logic [DWidth-1:0]    accel_wdata_o,
input  logic [DWidth-1:0]    accel_rdata_i,
input  logic                 accel_ready_i

// (3) 주소 디코딩 추가 (dmem_addr_is_io 옆에)
logic dmem_addr_is_accel;
assign dmem_addr_is_accel =
    (dmem_addr_i >= (ACCEL_START_W << 2)) &&
    (dmem_addr_i <  ((ACCEL_START_W + ACCEL_DEPTH_W) << 2));

// (4) D_IDLE case: accel 주소면 accel_req_o 구동, iomem/dmem_req_o는 0
// (5) dmem_rdata_o mux에 accel 분기 추가
assign dmem_rdata_o = is_iomem_q  ? iomem_rdata_i  :
                      is_accel_q  ? accel_rdata_i   :
                                    dmem_rdata_i;
```

ACCEL 요청은 1 사이클 ready (레지스터 접근이므로 latency 없음) → `accel_ready_i`를 받는 즉시 `dmem_ready_o` 구동.

---

### 3. 수정: `rtl/cpu_top.sv`

추가할 내용:

```systemverilog
// (1) 파라미터 추가
parameter ACCEL_START_W = 32'h0810_0000,
parameter ACCEL_DEPTH_W = 32'h0000_0010

// (2) 내부 신호: MCU ↔ ACCEL 제어 버스
logic                 accel_req, accel_write, accel_ready;
logic [DWidth-1:0]    accel_addr, accel_wdata, accel_rdata;

// (3) 내부 신호: DMEM 아비터 (CPU vs ACCEL DMA)
// - ACCEL DMA 요청이 있으면 우선순위에 따라 MCU에 전달
// - CPU 요청과 ACCEL DMA 요청은 동시에 발생하지 않도록
//   (ACCEL 동작 중 CPU는 STATUS 폴링 → ACCEL 제어 포트 사용,
//    DMA 포트와 CPU dmem 포트는 아비터가 분리)
logic                 arb_dmem_req, arb_dmem_write, arb_dmem_ready;
logic [DWidth-1:0]    arb_dmem_addr, arb_dmem_wdata, arb_dmem_rdata;
logic                 dma_req, dma_write, dma_ready;
logic [DWidth-1:0]    dma_addr, dma_wdata, dma_rdata;

// 아비터: DMA 요청이 없으면 CPU, 있으면 ACCEL
assign arb_dmem_req   = dma_req   ? dma_req   : core_dmem_req;
assign arb_dmem_write = dma_req   ? dma_write  : core_dmem_write;
assign arb_dmem_addr  = dma_req   ? dma_addr   : core_dmem_addr;
assign arb_dmem_wdata = dma_req   ? dma_wdata  : core_dmem_wdata;
// ready/rdata 분기
assign mcu_dmem_ready = dma_req   ? 1'b0        : arb_dmem_ready;
assign dma_ready      = dma_req   ? arb_dmem_ready : 1'b0;
assign arb_dmem_rdata → MCU dmem_rdata_o;
assign dma_rdata      = arb_dmem_rdata;

// (4) MCU 인스턴스: 파라미터/포트 추가
MCU #(
    ...기존 파라미터...,
    .ACCEL_START_W (ACCEL_START_W),
    .ACCEL_DEPTH_W (ACCEL_DEPTH_W)
) MCU_INST (
    ...기존 포트...,
    // 아비터 출력을 MCU dmem 입력으로
    .dmem_req_i   (arb_dmem_req),
    .dmem_write_i (arb_dmem_write),
    .dmem_addr_i  (arb_dmem_addr),
    .dmem_wdata_i (arb_dmem_wdata),
    // ACCEL 제어 포트
    .accel_req_o   (accel_req),
    .accel_write_o (accel_write),
    .accel_addr_o  (accel_addr),
    .accel_wdata_o (accel_wdata),
    .accel_rdata_i (accel_rdata),
    .accel_ready_i (accel_ready)
);

// (5) GEMV_ACCEL 인스턴스
GEMV_ACCEL #(.DWidth(DWidth)) ACCEL (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .accel_req_i   (accel_req),
    .accel_write_i (accel_write),
    .accel_addr_i  (accel_addr),
    .accel_wdata_i (accel_wdata),
    .accel_rdata_o (accel_rdata),
    .accel_ready_o (accel_ready),
    .dma_req_o     (dma_req),
    .dma_write_o   (dma_write),
    .dma_addr_o    (dma_addr),
    .dma_wdata_o   (dma_wdata),
    .dma_rdata_i   (dma_rdata),
    .dma_ready_i   (dma_ready)
);
```

---

### 4. 수정: `sim/run_vcs.sh`

RTL_LIST에 한 줄 추가:

```bash
$RTL_DIR/accel/gemv_accel.sv           \
```

기존 `$RTL_DIR/scalar_core/mcu.sv` 줄 바로 앞에 넣는다.

---

### 5. 수정: `program/test_code/int_model_q12.c`

GEMV 소프트웨어 루프를 MMIO 호출로 교체한다.

ACCEL 바이트 주소 (ACCEL_START_W << 2 = 0x2040_0000):

```c
#define ACCEL_BASE      0x2040_0000UL
#define ACCEL_MAT_ADDR  (*(volatile uint32_t*)(ACCEL_BASE + 0x00))
#define ACCEL_VEC_ADDR  (*(volatile uint32_t*)(ACCEL_BASE + 0x04))
#define ACCEL_OUT_ADDR  (*(volatile uint32_t*)(ACCEL_BASE + 0x08))
#define ACCEL_ROWS      (*(volatile uint32_t*)(ACCEL_BASE + 0x0C))
#define ACCEL_COLS      (*(volatile uint32_t*)(ACCEL_BASE + 0x10))
#define ACCEL_CTRL      (*(volatile uint32_t*)(ACCEL_BASE + 0x14))
#define ACCEL_STATUS    (*(volatile uint32_t*)(ACCEL_BASE + 0x18))

static inline void gemv_hw(const int32_t *mat, const int32_t *vec,
                            int32_t *out, int rows, int cols) {
    ACCEL_MAT_ADDR = (uint32_t)(uintptr_t)mat;
    ACCEL_VEC_ADDR = (uint32_t)(uintptr_t)vec;
    ACCEL_OUT_ADDR = (uint32_t)(uintptr_t)out;
    ACCEL_ROWS     = (uint32_t)rows;
    ACCEL_COLS     = (uint32_t)cols;
    ACCEL_CTRL     = 1;                        // start
    while (!(ACCEL_STATUS & 1));               // poll done
}
```

기존 소프트웨어 GEMV 함수 호출을 `gemv_hw()`로 교체.

---

### 6. 수정: `syn/script/dc.tcl`

기존 RTL 파일 목록에 추가:

```tcl
../rtl/accel/gemv_accel.sv
```

---

## Makefile — 하드웨어 Multiplier 활성화

RISC-V 빌드 시 M extension 사용 (소프트웨어 곱셈 에뮬레이션 제거):

```makefile
# Makefile line 215: -march= 수정
-march=rv32im_zicsr    # i → im
```

---

## 구현 순서

1. `rtl/accel/gemv_accel.sv` 작성 (인터페이스 → FSM → MAC)
2. `rtl/scalar_core/mcu.sv` 수정 (ACCEL 주소 디코딩)
3. `rtl/cpu_top.sv` 수정 (아비터 + 인스턴스)
4. `sim/run_vcs.sh` 수정 (파일리스트)
5. `make riscv` 빌드 후 `make sim` 검증
6. `program/test_code/int_model_q12.c` 수정 (MMIO 교체)
7. `syn/script/dc.tcl` 수정

---

## 주의사항

- `int_model_q12.c`의 데이터 타입은 **int32, q12 고정소수점**. ACCEL MAC도 동일 타입 사용.
- DMEM 아비터는 ACCEL DMA 동작 중 CPU의 DMEM 접근을 차단한다. CPU는 ACCEL 제어 레지스터(별도 경로)만 접근 가능하므로 deadlock 없음.
- ACCEL 레지스터 포트의 latency = 1 사이클 (조합 논리). MCU의 `D_WAIT` latency 카운터를 ACCEL 요청 시에는 우회한다.
