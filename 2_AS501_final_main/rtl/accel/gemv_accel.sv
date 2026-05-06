// Copyright (c) 2026 AS501 Final Project - GEMV Accelerator
//
// GEMV (General Matrix-Vector Multiply) hardware accelerator.
// Offloads the dominant matmul kernel from LSTM lstm_step().
// Data type: int32 Q12 fixed-point, matching int_model_q12.c.
//
// FSM: IDLE -> LOAD_VEC -> LOAD_ROW -> COMPUTE -> STORE -> DONE
// DMA interface shares the existing DMEM port via an arbiter in cpu_top.

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

  // Internal vector buffer (stores input vector for reuse across rows)
  logic [DWidth-1:0] vec_buf [MAX_DIM];

  // Row element latch (one element at a time from DMA)
  logic [DWidth-1:0] row_elem_q;

  // MAC accumulator
  logic signed [63:0] acc_q, acc_d;

  // DMA request control
  logic              dma_req_d;
  logic              dma_write_d;
  logic [DWidth-1:0] dma_addr_d;
  logic [DWidth-1:0] dma_wdata_d;

  // ---------------------------------------------------------------------------
  // Control register read/write
  // ---------------------------------------------------------------------------
  // Register writes (1-cycle ready, combinational path)
  assign accel_ready_o = accel_req_i;  // always ready in 1 cycle

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
          default: ;  // ignore writes to STATUS or unknown offsets
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
    // Default assignments
    state_d    = state_q;
    col_cnt_d  = col_cnt_q;
    row_cnt_d  = row_cnt_q;
    acc_d      = acc_q;
    dma_req_d  = 1'b0;
    dma_write_d = 1'b0;
    dma_addr_d = '0;
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
        dma_req_d  = 1'b1;
        dma_write_d = 1'b0;
        dma_addr_d = vec_addr_q + {col_cnt_q, 2'b00};  // byte address
        if (dma_ready_i) begin
          if (col_cnt_q == cols_q[$clog2(MAX_DIM)-1:0] - 1) begin
            state_d   = StLoadRow;
            col_cnt_d = '0;
          end else begin
            col_cnt_d = col_cnt_q + 1;
          end
        end
      end

      // StLoadRow: DMA read K elements of current row
      StLoadRow: begin
        dma_req_d  = 1'b1;
        dma_write_d = 1'b0;
        // mat_addr + (row_cnt * cols + col_cnt) * 4
        dma_addr_d = mat_addr_q
                     + ({row_cnt_q, 2'b00} * cols_q)
                     + {col_cnt_q, 2'b00};
        if (dma_ready_i) begin
          if (col_cnt_q == cols_q[$clog2(MAX_DIM)-1:0] - 1) begin
            state_d   = StCompute;
            col_cnt_d = '0;
          end else begin
            col_cnt_d = col_cnt_q + 1;
          end
        end
      end

      // StCompute: MAC over buffered row and vector (sequential MAC)
      StCompute: begin
        if (col_cnt_q == cols_q[$clog2(MAX_DIM)-1:0]) begin
          state_d   = StStore;
          col_cnt_d = '0;
          // Pre-load write/addr/wdata one cycle before req goes high so that
          // D_MEMORY's hold-time check (50 ps after posedge dmem_req_i) is met.
          dma_write_d = 1'b1;
          dma_addr_d  = out_addr_q + {row_cnt_q, 2'b00};
          dma_wdata_d = acc_q[DWidth-1+Q_BITS:Q_BITS];
        end else begin
          col_cnt_d = col_cnt_q + 1;
        end
      end

      // StStore: DMA write result to output
      // req goes high here; write/addr/wdata were pre-loaded in StCompute's
      // last cycle so they are already stable at the posedge of dma_req_o.
      StStore: begin
        dma_req_d   = 1'b1;
        dma_write_d = 1'b1;
        dma_addr_d  = out_addr_q + {row_cnt_q, 2'b00};
        dma_wdata_d = acc_q[DWidth-1+Q_BITS:Q_BITS];
        if (dma_ready_i) begin
          if (row_cnt_q == rows_q[$clog2(MAX_DIM)-1:0] - 1) begin
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
  // Row buffer for current row elements
  // ---------------------------------------------------------------------------
  logic [DWidth-1:0] row_buf [MAX_DIM];

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

      // DMA output registers
      dma_req_o   <= dma_req_d;
      dma_write_o <= dma_write_d;
      dma_addr_o  <= dma_addr_d;
      dma_wdata_o <= dma_wdata_d;

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

      // MAC accumulation during COMPUTE (late Q12 shift: accumulate full
      // 64-bit products, apply >>> Q_BITS only at store to match software's
      // dot_shift_q which shifts the final sum rather than each product)
      if (state_q == StCompute) begin
        if (col_cnt_q == '0) begin
          acc_q <= signed'(row_buf[0]) * signed'(vec_buf[0]);
        end else if (col_cnt_q < cols_q[$clog2(MAX_DIM)-1:0]) begin
          acc_q <= acc_q
                   + (signed'(row_buf[col_cnt_q]) * signed'(vec_buf[col_cnt_q]));
        end
      end

      // Reset accumulator before each new row
      if (state_q == StStore && dma_ready_i
          && row_cnt_q != rows_q[$clog2(MAX_DIM)-1:0] - 1) begin
        acc_q <= '0;
      end
    end
  end

endmodule