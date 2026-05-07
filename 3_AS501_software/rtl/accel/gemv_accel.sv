// Copyright (c) 2026 AS501 Final Project - GEMV Accelerator
//
// GEMV (General Matrix-Vector Multiply) hardware accelerator.
// Offloads the dominant matmul kernel from LSTM lstm_step().
// Data type: int32 Q12 fixed-point, matching int_model_q12.c.
//
// FSM: IDLE -> LOAD_VEC -> LOAD_ROW -> COMPUTE -> STORE -> DONE
// DMA interface shares the existing DMEM port via an arbiter in cpu_top.
//
// 8-way parallel MAC in StCompute: processes 8 elements per cycle
// with an adder tree, giving ~8x speedup over the sequential version.

module gemv_accel #(
  parameter int unsigned DWidth = 32
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // MCU -> ACCEL: control register port
  input  logic                 accel_req_i,
  input  logic                 accel_write_i,
  input  logic [DWidth-1:0]    accel_addr_i,   // word offset
  input  logic [DWidth-1:0]    accel_wdata_i,
  output logic [DWidth-1:0]    accel_rdata_o,
  output logic                 accel_ready_o,

  // ACCEL -> arbiter: DMEM DMA port
  output logic                 dma_req_o,
  output logic                 dma_write_o,
  output logic [DWidth-1:0]    dma_addr_o,
  output logic [DWidth-1:0]    dma_wdata_o,
  input  logic [DWidth-1:0]    dma_rdata_i,
  input  logic                 dma_ready_i
);

  // ---------------------------------------------------------------------------
  // Local parameters
  // ---------------------------------------------------------------------------
  localparam int unsigned MAX_DIM    = 512;   // max rows or cols supported
  localparam int unsigned Q_BITS     = 12;    // Q12 fixed-point shift
  localparam int unsigned N_PE       = 8;     // number of parallel MAC units

  // Control register word offsets
  localparam logic [DWidth-1:0] REG_MAT_ADDR = 32'd0;
  localparam logic [DWidth-1:0] REG_VEC_ADDR = 32'd1;
  localparam logic [DWidth-1:0] REG_OUT_ADDR = 32'd2;
  localparam logic [DWidth-1:0] REG_ROWS     = 32'd3;
  localparam logic [DWidth-1:0] REG_COLS     = 32'd4;
  localparam logic [DWidth-1:0] REG_CTRL     = 32'd5;
  localparam logic [DWidth-1:0] REG_STATUS   = 32'd6;

  // FSM states
  typedef enum logic [2:0] {
    StIdle,
    StLoadVec,
    StLoadRow,
    StCompute,
    StStore,
    StDone
  } gemv_state_e;

  // ---------------------------------------------------------------------------
  // Control registers
  // ---------------------------------------------------------------------------
  logic [DWidth-1:0] mat_addr_q;
  logic [DWidth-1:0] vec_addr_q;
  logic [DWidth-1:0] out_addr_q;
  logic [DWidth-1:0] rows_q;
  logic [DWidth-1:0] cols_q;
  logic              start_pulse;
  logic              done_q;
  logic              busy_q;

  // ---------------------------------------------------------------------------
  // FSM signals
  // ---------------------------------------------------------------------------
  gemv_state_e state_q, state_d;

  // Counters
  logic [$clog2(MAX_DIM)-1:0] col_cnt_q, col_cnt_d;
  logic [$clog2(MAX_DIM)-1:0] row_cnt_q, row_cnt_d;

  // Internal buffers
  logic [DWidth-1:0] vec_buf [MAX_DIM];
  logic [DWidth-1:0] row_buf [MAX_DIM];

  // MAC accumulator (64-bit to preserve precision)
  logic signed [63:0] acc_q, acc_d;

  // DMA request control
  logic              dma_req_d;
  logic              dma_write_d;
  logic [DWidth-1:0] dma_addr_d;
  logic [DWidth-1:0] dma_wdata_d;

  // ---------------------------------------------------------------------------
  // 8-way parallel MAC: combinational products and adder tree
  // ---------------------------------------------------------------------------
  logic signed [63:0] product [N_PE];
  logic signed [63:0] sum_s1 [4];
  logic signed [63:0] sum_s2 [2];
  logic signed [63:0] sum_s3;

  // Remaining columns for this compute step
  logic [$clog2(MAX_DIM)-1:0] cols_trunc;
  assign cols_trunc = cols_q[$clog2(MAX_DIM)-1:0];

  always_comb begin
    // Compute products with masking for out-of-range elements
    for (int i = 0; i < N_PE; i++) begin
      if ((col_cnt_q + i[$clog2(MAX_DIM)-1:0]) < cols_trunc) begin
        product[i] = signed'(row_buf[col_cnt_q + i[$clog2(MAX_DIM)-1:0]])
                   * signed'(vec_buf[col_cnt_q + i[$clog2(MAX_DIM)-1:0]]);
      end else begin
        product[i] = 64'sd0;
      end
    end

    // 3-stage adder tree
    sum_s1[0] = product[0] + product[1];
    sum_s1[1] = product[2] + product[3];
    sum_s1[2] = product[4] + product[5];
    sum_s1[3] = product[6] + product[7];

    sum_s2[0] = sum_s1[0] + sum_s1[1];
    sum_s2[1] = sum_s1[2] + sum_s1[3];

    sum_s3    = sum_s2[0] + sum_s2[1];
  end

  // ---------------------------------------------------------------------------
  // Control register read/write
  // ---------------------------------------------------------------------------
  assign accel_ready_o = accel_req_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mat_addr_q  <= '0;
      vec_addr_q  <= '0;
      out_addr_q  <= '0;
      rows_q      <= '0;
      cols_q      <= '0;
      start_pulse <= 1'b0;
    end else begin
      start_pulse <= 1'b0;
      if (accel_req_i && accel_write_i) begin
        unique case (accel_addr_i)
          REG_MAT_ADDR: mat_addr_q <= accel_wdata_i;
          REG_VEC_ADDR: vec_addr_q <= accel_wdata_i;
          REG_OUT_ADDR: out_addr_q <= accel_wdata_i;
          REG_ROWS:     rows_q     <= accel_wdata_i;
          REG_COLS:     cols_q     <= accel_wdata_i;
          REG_CTRL: begin
            if (accel_wdata_i[0]) begin
              start_pulse <= 1'b1;
            end
          end
          default: ;
        endcase
      end
    end
  end

  // Register reads (combinational)
  always_comb begin
    accel_rdata_o = '0;
    if (accel_req_i && !accel_write_i) begin
      unique case (accel_addr_i)
        REG_MAT_ADDR: accel_rdata_o = mat_addr_q;
        REG_VEC_ADDR: accel_rdata_o = vec_addr_q;
        REG_OUT_ADDR: accel_rdata_o = out_addr_q;
        REG_ROWS:     accel_rdata_o = rows_q;
        REG_COLS:     accel_rdata_o = cols_q;
        REG_CTRL:     accel_rdata_o = '0;
        REG_STATUS:   accel_rdata_o = {30'd0, busy_q, done_q};
        default:      accel_rdata_o = '0;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // FSM: next-state logic (combinational)
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    col_cnt_d   = col_cnt_q;
    row_cnt_d   = row_cnt_q;
    acc_d       = acc_q;
    dma_req_d   = 1'b0;
    dma_write_d = 1'b0;
    dma_addr_d  = '0;
    dma_wdata_d = '0;

    unique case (state_q)
      // StIdle: wait for start pulse
      StIdle: begin
        if (start_pulse) begin
          state_d   = StLoadVec;
          col_cnt_d = '0;
          row_cnt_d = '0;
        end
      end

      // StLoadVec: DMA read K elements of input vector
      StLoadVec: begin
        dma_req_d   = 1'b1;
        dma_write_d = 1'b0;
        dma_addr_d  = vec_addr_q + {col_cnt_q, 2'b00};
        if (dma_ready_i) begin
          if (col_cnt_q + 1'b1 == cols_trunc) begin
            state_d   = StLoadRow;
            col_cnt_d = '0;
          end else begin
            col_cnt_d = col_cnt_q + 1;
          end
        end
      end

      // StLoadRow: DMA read K elements of current row
      StLoadRow: begin
        dma_req_d   = 1'b1;
        dma_write_d = 1'b0;
        dma_addr_d  = mat_addr_q
                      + ({row_cnt_q, 2'b00} * cols_q)
                      + {col_cnt_q, 2'b00};
        if (dma_ready_i) begin
          if (col_cnt_q + 1'b1 == cols_trunc) begin
            state_d   = StCompute;
            col_cnt_d = '0;
          end else begin
            col_cnt_d = col_cnt_q + 1;
          end
        end
      end

      // StCompute: 8-way parallel MAC over buffered row and vector
      StCompute: begin
        if (col_cnt_q >= cols_trunc) begin
          // All columns processed, go to store
          state_d   = StStore;
          col_cnt_d = '0;
          // Pre-load write signals for D_MEMORY hold-time
          dma_write_d = 1'b1;
          dma_addr_d  = out_addr_q + {row_cnt_q, 2'b00};
          dma_wdata_d = acc_q[DWidth-1+Q_BITS:Q_BITS];
        end else begin
          // Process N_PE elements this cycle
          if (col_cnt_q == '0) begin
            acc_d = sum_s3;
          end else begin
            acc_d = acc_q + sum_s3;
          end
          // Advance by N_PE, capped at cols
          if ((col_cnt_q + N_PE[$clog2(MAX_DIM)-1:0]) >= cols_trunc) begin
            col_cnt_d = cols_trunc;  // will trigger store on next cycle
          end else begin
            col_cnt_d = col_cnt_q + N_PE[$clog2(MAX_DIM)-1:0];
          end
        end
      end

      // StStore: DMA write result to output
      StStore: begin
        dma_req_d   = 1'b1;
        dma_write_d = 1'b1;
        dma_addr_d  = out_addr_q + {row_cnt_q, 2'b00};
        dma_wdata_d = acc_q[DWidth-1+Q_BITS:Q_BITS];
        if (dma_ready_i) begin
          if (row_cnt_q + 1'b1 == rows_q[$clog2(MAX_DIM)-1:0]) begin
            state_d = StDone;
          end else begin
            row_cnt_d = row_cnt_q + 1;
            state_d   = StLoadRow;
            col_cnt_d = '0;
          end
        end
      end

      // StDone: signal completion, return to idle
      StDone: begin
        state_d = StIdle;
      end

      default: state_d = StIdle;
    endcase
  end

  // ---------------------------------------------------------------------------
  // FSM: state register + datapath (sequential)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= StIdle;
      col_cnt_q <= '0;
      row_cnt_q <= '0;
      acc_q     <= '0;
      done_q    <= 1'b0;
      busy_q    <= 1'b0;
      dma_req_o   <= 1'b0;
      dma_write_o <= 1'b0;
      dma_addr_o  <= '0;
      dma_wdata_o <= '0;
    end else begin
      state_q   <= state_d;
      col_cnt_q <= col_cnt_d;
      row_cnt_q <= row_cnt_d;
      acc_q     <= acc_d;

      // DMA output registers
      dma_req_o   <= dma_req_d;
      dma_write_o <= dma_write_d;
      dma_addr_o  <= dma_addr_d;
      dma_wdata_o <= dma_wdata_d;

      // Debug: trace FSM milestones
      if (start_pulse)
        $display("[ACCEL] %0t: START rows=%0d cols=%0d mat=%0h vec=%0h out=%0h",
                 $time, rows_q, cols_q, mat_addr_q, vec_addr_q, out_addr_q);
      if (state_q == StLoadVec && state_d == StLoadRow)
        $display("[ACCEL] %0t: LOAD_VEC done -> LOAD_ROW row=0", $time);
      if (state_q == StStore && dma_ready_i) begin
        if (row_cnt_q[6:0] == 7'd0)
          $display("[ACCEL] %0t: STORE row=%0d done", $time, row_cnt_q);
      end
      if (state_d == StDone && state_q != StDone)
        $display("[ACCEL] %0t: DONE! (all %0d rows)", $time, rows_q);

      // Status flags
      unique case (state_d)
        StIdle: begin
          busy_q <= 1'b0;
        end
        StDone: begin
          done_q <= 1'b1;
          busy_q <= 1'b0;
        end
        default: begin
          busy_q <= 1'b1;
          if (start_pulse) begin
            done_q <= 1'b0;
          end
        end
      endcase

      // Clear done on new start
      if (start_pulse) begin
        done_q <= 1'b0;
        acc_q  <= '0;
      end

      // Vector buffer write during LOAD_VEC
      if (state_q == StLoadVec && dma_ready_i) begin
        vec_buf[col_cnt_q] <= dma_rdata_i;
      end

      // Row buffer write during LOAD_ROW
      if (state_q == StLoadRow && dma_ready_i) begin
        row_buf[col_cnt_q] <= dma_rdata_i;
      end

      // Reset accumulator before each new row
      if (state_q == StStore && dma_ready_i
          && (row_cnt_q + 1'b1) != rows_q[$clog2(MAX_DIM)-1:0]) begin
        acc_q <= '0;
      end
    end
  end

endmodule
