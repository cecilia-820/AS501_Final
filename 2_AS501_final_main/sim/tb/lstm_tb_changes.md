# lstm_tb.sv 수정 내역

기준 파일: `sim/tb/lstm_tb.sv`
기준 바이너리: `program/out/eval_int_riscv.dis` (GEMV 가속기 포함 빌드, 2026-05-06)

---

## 1. PC localparam 주소 갱신 (10개 전체)

GEMV 가속기(`gemv_hw`) 함수가 `.text` 섹션에 추가되면서 기존 함수들의 주소가 이동했다.
아래 표는 이전 값 → 현재 값 변경 내역이다.

| localparam | 이전 값 | 현재 값 |
|---|---|---|
| `PC_MAIN` | `0x0000_1600` | `0x0000_1694` |
| `PC_RESET_RESULT_BUFFER` | `0x0000_1498` | `0x0000_152c` |
| `PC_APPEND_RESULT_SEQUENCE` | `0x0000_14e4` | `0x0000_1578` |
| `PC_INIT_STATIC_BUFFERS` | `0x0000_0ca4` | `0x0000_0d38` |
| `PC_GREEDY_DECODE_INT` | `0x0000_0f74` | `0x0000_1008` |
| `PC_LSTM_STEP_INT` | `0x0000_0844` | `0x0000_08ec` |
| `PC_LINEAR_OUT_ARGMAX` | `0x0000_0bcc` | `0x0000_0c60` |
| `PC_EMBEDDING_LOOKUP` | `0x0000_079c` | `0x0000_0844` |
| `PC_ARENA_RESET` | `0x0000_1860` | `0x0000_18f4` |
| `PC_ARENA_ALLOC` | `0x0000_1884` | `0x0000_1918` |

변경되지 않은 값: `HANG_PC = 0x0000_0034`, `ResultStart = 0x0000_7fe1`

---

## 2. 신규 PC localparam 추가 (2개)

GEMV 가속기 도입으로 새로 추가된 함수 및 기존에 누락됐던 함수를 추가했다.

```systemverilog
localparam logic [31:0] PC_GEMV_HW                         = 32'h0000_0038;
localparam logic [31:0] PC_PUBLISH_PARTIAL_RESULT_SEQUENCE = 32'h0000_0ee8;
```

| localparam | 주소 | 설명 |
|---|---|---|
| `PC_GEMV_HW` | `0x0000_0038` | GEMV 하드웨어 가속기 진입점. `lstm_step_int` 1회당 2번 호출됨 (w_ih용, w_hh용) |
| `PC_PUBLISH_PARTIAL_RESULT_SEQUENCE` | `0x0000_0ee8` | `greedy_decode_int` 내에서 매 decoding step마다 부분 결과를 IOMEM에 저장하는 함수 |

---

## 3. gemv_hw 호출 횟수 카운터 추가

`lstm_step_hit_cnt`와 동일한 방식으로 `gemv_hw_hit_cnt`를 추가했다.

**선언:**
```systemverilog
longint unsigned gemv_hw_hit_cnt;
```

**초기화 (`initial` 블록):**
```systemverilog
gemv_hw_hit_cnt = 0;
```

**TRACE_FUNC case 분기:**
```systemverilog
PC_GEMV_HW: begin
    gemv_hw_hit_cnt <= gemv_hw_hit_cnt + 1;
    if ((gemv_hw_hit_cnt < 40) || ((gemv_hw_hit_cnt % LSTM_STEP_LOG_EVERY) == 0))
        $display("[TB][func] cycle=%0d time=%0t pc=0x%08h gemv_hw count=%0d",
                 total_cycles, $time, imem_addr, gemv_hw_hit_cnt + 1);
end
PC_PUBLISH_PARTIAL_RESULT_SEQUENCE:
    $display("[TB][func] time=%0t pc=0x%08h publish_partial_result_sequence", $time, imem_addr);
```

---

## 4. 시뮬레이션 종료 보고에 gemv_hw 통계 추가

```systemverilog
$display(" * Total gemv_hw      entries (PC-based) = %0d", gemv_hw_hit_cnt);
$display(" *   (expected: lstm_step_int x2 = %0d)", lstm_step_hit_cnt * 2);
```

LSTM step당 `gemv_hw`는 정확히 2회 호출되어야 한다.  
시뮬레이션 종료 시 `gemv_hw_hit_cnt == lstm_step_hit_cnt * 2`이면 GEMV 가속기가 정상 동작한 것이다.

---

## 변경 파일 요약

| 파일 | 변경 내용 |
|---|---|
| `sim/tb/lstm_tb.sv` | PC 주소 갱신 10개, PC 신규 추가 2개, `gemv_hw_hit_cnt` 카운터 추가, 종료 보고 2줄 추가 |
