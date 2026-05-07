//////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                  //
// DMA CONTROLLER                                                               //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//////////////////////////////////////////////////////////////////////////////////
// Bulk data mover between external DMEM and on-chip SPM.
// MMIO register interface (5 registers), CPU polls STATUS for completion.
// Two memory ports: one for DMEM (4-cycle), one for SPM (1-cycle).
// Direction auto-detected from source address range.
//////////////////////////////////////////////////////////////////////////////////

module dma_controller #(
    parameter int unsigned DWidth         = 32,
    parameter int unsigned DMEM_START_BYTE = 32'h0020_0000,
    parameter int unsigned DMEM_END_BYTE   = 32'h011F_FFFF,
    parameter int unsigned SPM_START_BYTE  = 32'h2080_0000,
    parameter int unsigned SPM_END_BYTE    = 32'h2080_FFFF,
    parameter int unsigned LATENCY_CYCLES  = 4
)(
    input  logic              clk_i,
    input  logic              rst_ni,

    // Control port (from MCU — MMIO registers)
    input  logic              ctrl_req_i,
    input  logic              ctrl_write_i,
    input  logic [DWidth-1:0] ctrl_addr_i,    // byte offset from DMA base
    input  logic [DWidth-1:0] ctrl_wdata_i,
    output logic [DWidth-1:0] ctrl_rdata_o,
    output logic              ctrl_ready_o,

    // DMEM port (to external DMEM via arbiter in cpu_top)
    output logic              mem_req_o,
    output logic              mem_write_o,
    output logic [DWidth-1:0] mem_addr_o,
    output logic [DWidth-1:0] mem_wdata_o,
    input  logic [DWidth-1:0] mem_rdata_i,

    // SPM port (direct to SPM arbiter in cpu_top)
    output logic              spm_req_o,
    output logic              spm_write_o,
    output logic [DWidth-1:0] spm_addr_o,
    output logic [DWidth-1:0] spm_wdata_o,
    input  logic [DWidth-1:0] spm_rdata_i
);

    // -------------------------------------------------------------------------
    // Control register offsets (byte)
    // -------------------------------------------------------------------------
    localparam logic [DWidth-1:0] REG_SRC_ADDR = 32'h00;
    localparam logic [DWidth-1:0] REG_DST_ADDR = 32'h04;
    localparam logic [DWidth-1:0] REG_LEN      = 32'h08;
    localparam logic [DWidth-1:0] REG_CTRL     = 32'h0C;
    localparam logic [DWidth-1:0] REG_STATUS   = 32'h10;

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        StIdle,
        StReadReq,
        StReadWait,
        StWriteReq,
        StWriteWait,
        StDone
    } dma_state_e;

    // -------------------------------------------------------------------------
    // Registers
    // -------------------------------------------------------------------------
    logic [DWidth-1:0] src_addr_q;
    logic [DWidth-1:0] dst_addr_q;
    logic [DWidth-1:0] len_q;
    logic              start_pulse;
    logic              done_q;
    logic              busy_q;

    dma_state_e        state_q, state_d;
    logic [DWidth-1:0] cur_src_q, cur_src_d;
    logic [DWidth-1:0] cur_dst_q, cur_dst_d;
    logic [DWidth-1:0] remaining_q, remaining_d;
    logic [DWidth-1:0] data_buf_q, data_buf_d;
    logic [1:0]        lat_cnt_q, lat_cnt_d;

    // Direction flags (latched at start)
    logic              src_is_dmem_q;   // 1 = DMEM->SPM, 0 = SPM->DMEM

    // -------------------------------------------------------------------------
    // Control register read/write (1-cycle ready)
    // -------------------------------------------------------------------------
    assign ctrl_ready_o = ctrl_req_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            src_addr_q  <= '0;
            dst_addr_q  <= '0;
            len_q       <= '0;
            start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (ctrl_req_i && ctrl_write_i) begin
                unique case (ctrl_addr_i)
                    REG_SRC_ADDR: src_addr_q <= ctrl_wdata_i;
                    REG_DST_ADDR: dst_addr_q <= ctrl_wdata_i;
                    REG_LEN:      len_q      <= ctrl_wdata_i;
                    REG_CTRL: begin
                        if (ctrl_wdata_i[0])
                            start_pulse <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        ctrl_rdata_o = '0;
        if (ctrl_req_i && !ctrl_write_i) begin
            unique case (ctrl_addr_i)
                REG_SRC_ADDR: ctrl_rdata_o = src_addr_q;
                REG_DST_ADDR: ctrl_rdata_o = dst_addr_q;
                REG_LEN:      ctrl_rdata_o = len_q;
                REG_CTRL:     ctrl_rdata_o = '0;
                REG_STATUS:   ctrl_rdata_o = {30'd0, busy_q, done_q};
                default:      ctrl_rdata_o = '0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Direction detection helper
    // -------------------------------------------------------------------------
    function automatic logic addr_is_dmem(input logic [DWidth-1:0] addr);
        return (addr >= DMEM_START_BYTE) && (addr <= DMEM_END_BYTE);
    endfunction

    // -------------------------------------------------------------------------
    // FSM: next-state (combinational)
    // -------------------------------------------------------------------------
    always_comb begin
        state_d     = state_q;
        cur_src_d   = cur_src_q;
        cur_dst_d   = cur_dst_q;
        remaining_d = remaining_q;
        data_buf_d  = data_buf_q;
        lat_cnt_d   = lat_cnt_q;

        mem_req_o   = 1'b0;
        mem_write_o = 1'b0;
        mem_addr_o  = '0;
        mem_wdata_o = '0;
        spm_req_o   = 1'b0;
        spm_write_o = 1'b0;
        spm_addr_o  = '0;
        spm_wdata_o = '0;

        unique case (state_q)

            StIdle: begin
                if (start_pulse) begin
                    cur_src_d   = src_addr_q;
                    cur_dst_d   = dst_addr_q;
                    remaining_d = len_q;
                    lat_cnt_d   = '0;
                    if (len_q == '0) begin
                        state_d = StDone;
                    end else begin
                        state_d = StReadReq;
                    end
                end
            end

            // Issue read request
            StReadReq: begin
                if (src_is_dmem_q) begin
                    // Read from DMEM
                    mem_req_o  = 1'b1;
                    mem_addr_o = cur_src_q;
                    lat_cnt_d  = '0;
                    state_d    = StReadWait;
                end else begin
                    // Read from SPM (1-cycle)
                    spm_req_o  = 1'b1;
                    spm_addr_o = cur_src_q - SPM_START_BYTE;
                    lat_cnt_d  = '0;
                    state_d    = StReadWait;
                end
            end

            // Wait for read data
            StReadWait: begin
                if (src_is_dmem_q) begin
                    // DMEM: wait LATENCY_CYCLES
                    if (lat_cnt_q == 2'(LATENCY_CYCLES - 1)) begin
                        data_buf_d = mem_rdata_i;
                        state_d    = StWriteReq;
                    end else begin
                        lat_cnt_d = lat_cnt_q + 1;
                    end
                end else begin
                    // SPM: 1-cycle read latency
                    if (lat_cnt_q == 2'd0) begin
                        lat_cnt_d = lat_cnt_q + 1;
                    end else begin
                        data_buf_d = spm_rdata_i;
                        state_d    = StWriteReq;
                    end
                end
            end

            // Issue write request
            StWriteReq: begin
                if (src_is_dmem_q) begin
                    // Write to SPM (1-cycle)
                    spm_req_o   = 1'b1;
                    spm_write_o = 1'b1;
                    spm_addr_o  = cur_dst_q - SPM_START_BYTE;
                    spm_wdata_o = data_buf_q;
                    lat_cnt_d   = '0;
                    state_d     = StWriteWait;
                end else begin
                    // Write to DMEM — pre-assert write signals
                    mem_write_o = 1'b1;
                    mem_addr_o  = cur_dst_q;
                    mem_wdata_o = data_buf_q;
                    lat_cnt_d   = '0;
                    state_d     = StWriteWait;
                end
            end

            // Wait for write completion
            StWriteWait: begin
                if (src_is_dmem_q) begin
                    // SPM write: 1-cycle (done immediately)
                    cur_src_d   = cur_src_q + 32'd4;
                    cur_dst_d   = cur_dst_q + 32'd4;
                    remaining_d = remaining_q - 32'd1;
                    if (remaining_q == 32'd1) begin
                        state_d = StDone;
                    end else begin
                        state_d = StReadReq;
                    end
                end else begin
                    // DMEM write: need to pulse mem_req_o and wait LATENCY_CYCLES
                    mem_write_o = 1'b1;
                    mem_addr_o  = cur_dst_q;
                    mem_wdata_o = data_buf_q;
                    if (lat_cnt_q == '0) begin
                        mem_req_o = 1'b1;
                        lat_cnt_d = lat_cnt_q + 1;
                    end else if (lat_cnt_q == 2'(LATENCY_CYCLES - 1)) begin
                        cur_src_d   = cur_src_q + 32'd4;
                        cur_dst_d   = cur_dst_q + 32'd4;
                        remaining_d = remaining_q - 32'd1;
                        if (remaining_q == 32'd1) begin
                            state_d = StDone;
                        end else begin
                            state_d = StReadReq;
                        end
                    end else begin
                        lat_cnt_d = lat_cnt_q + 1;
                    end
                end
            end

            StDone: begin
                state_d = StIdle;
            end

            default: state_d = StIdle;

        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q       <= StIdle;
            cur_src_q     <= '0;
            cur_dst_q     <= '0;
            remaining_q   <= '0;
            data_buf_q    <= '0;
            lat_cnt_q     <= '0;
            done_q        <= 1'b0;
            busy_q        <= 1'b0;
            src_is_dmem_q <= 1'b0;
        end else begin
            state_q     <= state_d;
            cur_src_q   <= cur_src_d;
            cur_dst_q   <= cur_dst_d;
            remaining_q <= remaining_d;
            data_buf_q  <= data_buf_d;
            lat_cnt_q   <= lat_cnt_d;

            // Latch direction at start
            if (start_pulse) begin
                src_is_dmem_q <= addr_is_dmem(src_addr_q);
                done_q        <= 1'b0;
                busy_q        <= 1'b1;
            end

            // Status flags
            if (state_d == StDone) begin
                done_q <= 1'b1;
                busy_q <= 1'b0;
            end else if (state_d == StIdle && !start_pulse) begin
                busy_q <= 1'b0;
            end
        end
    end

endmodule
