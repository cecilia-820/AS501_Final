//////////////////////////////////////////////////////////////////////////////////
// AS501/AS603
// Data Cache (for GEMV DMA reads)
//////////////////////////////////////////////////////////////////////////////////
// Direct-mapped, 512-entry, 1-word line cache.
// Sits between the ACCEL DMA port and D_MEMORY in cpu_top.
// Line format: valid(1) + tag(21) + data(32) = 54 bits  (same as ICACHE_SRAM).
//
// FSM:
//   StReset    : invalidate all 512 lines at startup
//   StIdle     : wait for DMA request; for writes, pre-assert mem_write_o
//   StCheck    : SRAM output available (1 cycle after SRAM read in StIdle)
//   StFetch    : count 4 cycles after mem_req pulse (read miss path)
//   StFill     : fill cache line, return data to ACCEL
//   StWritePre : assert mem_req_o=1 (wdata was pre-routed in StIdle); count
//   StWriteWait: count remaining 4-cycle D_MEMORY latency, then ack ACCEL
//
// Write policy: write-through, no-allocate.
// The wdata MUX in cpu_top must use dcache_mem_write (not mem_req_o) to
// pre-route dmem_wdata_o one cycle before the req posedge, avoiding D_MEMORY
// $hold violations.
//////////////////////////////////////////////////////////////////////////////////

module DATA_CACHE #(
    parameter int unsigned DWidth = 32,
    parameter int unsigned Depth  = 512
)(
    input  logic              clk_i,
    input  logic              rst_ni,

    // DMA side — receives relative DMEM byte offset (cpu_top subtracts base)
    input  logic              dma_req_i,
    input  logic              dma_write_i,
    input  logic [DWidth-1:0] dma_addr_i,
    input  logic [DWidth-1:0] dma_wdata_i,
    output logic [DWidth-1:0] dma_rdata_o,
    output logic              dma_ready_o,

    // Memory side — drives the DMEM arbiter in cpu_top
    output logic              mem_req_o,
    output logic              mem_write_o,
    output logic [DWidth-1:0] mem_addr_o,
    output logic [DWidth-1:0] mem_wdata_o,
    input  logic [DWidth-1:0] mem_rdata_i
);

    localparam int unsigned Index   = $clog2(Depth);       // 9
    localparam int unsigned Tag     = DWidth - 2 - Index;  // 21
    localparam int unsigned LineW   = 1 + Tag + DWidth;    // 54
    localparam int unsigned LATENCY = 4;                   // D_MEMORY cycles

    typedef enum logic [2:0] {
        StReset, StIdle, StCheck, StFetch, StFill, StWritePre, StWriteWait
    } state_e;

    state_e            state_q, state_d;
    logic [Index-1:0]  rst_cnt_q;
    logic [1:0]        lat_cnt_q, lat_cnt_d;
    logic [DWidth-1:0] req_addr_q, req_wdata_q;

    // Address decode from latched request
    wire [Index-1:0] req_index = req_addr_q[Index+1:2];
    wire [Tag-1:0]   req_tag   = req_addr_q[DWidth-1:Index+2];

    // SRAM interface
    logic             cen, wen;
    logic [Index-1:0] sram_addr;
    logic [LineW-1:0] sram_wdata, sram_rdata;

    wire hit = sram_rdata[LineW-1] && (sram_rdata[LineW-2:DWidth] == req_tag);

    // -------------------------------------------------------------------------
    // FSM combinational
    // -------------------------------------------------------------------------
    always_comb begin
        state_d     = state_q;
        lat_cnt_d   = lat_cnt_q;
        cen         = 1'b0;
        wen         = 1'b0;
        sram_addr   = req_index;
        sram_wdata  = '0;
        dma_rdata_o = '0;
        dma_ready_o = 1'b0;
        mem_req_o   = 1'b0;
        mem_write_o = 1'b0;
        mem_addr_o  = req_addr_q;
        mem_wdata_o = req_wdata_q;

        unique case (state_q)

            // Write valid=0 to every SRAM entry before first use
            StReset: begin
                cen       = 1'b1;
                wen       = 1'b1;
                sram_addr = rst_cnt_q;
                state_d   = (&rst_cnt_q) ? StIdle : StReset;
            end

            StIdle: begin
                if (dma_req_i) begin
                    if (!dma_write_i) begin
                        // Read: kick off SRAM lookup (result in StCheck)
                        cen       = 1'b1;
                        sram_addr = dma_addr_i[Index+1:2];
                        state_d   = StCheck;
                    end else begin
                        // Write: pre-route wdata so dmem_wdata_o is stable
                        // before mem_req_o rises in StWritePre (avoids $hold).
                        mem_write_o = 1'b1;
                        mem_addr_o  = dma_addr_i;
                        mem_wdata_o = dma_wdata_i;
                        state_d     = StWritePre;
                    end
                end
            end

            // SRAM output valid — check hit/miss
            StCheck: begin
                if (hit) begin
                    dma_rdata_o = sram_rdata[DWidth-1:0];
                    dma_ready_o = 1'b1;
                    state_d     = StIdle;
                end else begin
                    // Miss: pulse mem_req for 1 cycle, then count latency
                    mem_req_o = 1'b1;
                    lat_cnt_d = '0;
                    state_d   = StFetch;
                end
            end

            // Count 4 cycles while D_MEMORY processes the read
            StFetch: begin
                if (lat_cnt_q == 2'(LATENCY - 1)) begin
                    state_d = StFill;
                end else begin
                    lat_cnt_d = lat_cnt_q + 1;
                end
            end

            // Fill cache line and return data to ACCEL
            StFill: begin
                cen        = 1'b1;
                wen        = 1'b1;
                sram_addr  = req_index;
                sram_wdata = {1'b1, req_tag, mem_rdata_i};
                dma_rdata_o = mem_rdata_i;
                dma_ready_o = 1'b1;
                state_d     = StIdle;
            end

            // Assert mem_req_o (wdata was pre-routed in StIdle, so it is
            // already stable on dmem_wdata_o — no $hold violation)
            StWritePre: begin
                mem_write_o = 1'b1;
                mem_req_o   = 1'b1;
                lat_cnt_d   = '0;
                state_d     = StWriteWait;
            end

            // Count 4 cycles while D_MEMORY processes the write
            StWriteWait: begin
                if (lat_cnt_q == 2'(LATENCY - 1)) begin
                    dma_ready_o = 1'b1;
                    state_d     = StIdle;
                end else begin
                    lat_cnt_d = lat_cnt_q + 1;
                end
            end

            default: state_d = StIdle;

        endcase
    end

    // -------------------------------------------------------------------------
    // Stuck detector (simulation only)
    // -------------------------------------------------------------------------
`ifdef SIM
    logic [15:0] stuck_cnt_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            stuck_cnt_q <= '0;
        end else begin
            if (state_q inside {StFetch, StFill, StWritePre, StWriteWait})
                stuck_cnt_q <= stuck_cnt_q + 1;
            else
                stuck_cnt_q <= '0;
            if (stuck_cnt_q == 16'd200)
                $display("[DCACHE] %0t: STUCK in state %0s for >200 cycles, addr=%0h",
                         $time, state_q.name(), req_addr_q);
        end
    end
`endif

    // -------------------------------------------------------------------------
    // Sequential
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q     <= StReset;
            rst_cnt_q   <= '0;
            lat_cnt_q   <= '0;
            req_addr_q  <= '0;
            req_wdata_q <= '0;
        end else begin
            state_q   <= state_d;
            lat_cnt_q <= lat_cnt_d;

            // Latch address/data when a new request is accepted in StIdle
            if (state_q == StIdle && dma_req_i) begin
                req_addr_q  <= dma_addr_i;
                req_wdata_q <= dma_wdata_i;
            end

            // Reset counter: increment until all-ones (511), then hold
            if (state_q == StReset && !(&rst_cnt_q)) begin
                rst_cnt_q <= rst_cnt_q + 1;
            end else if (state_q != StReset) begin
                rst_cnt_q <= '0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // SRAM instance (same physical SRAM used by I-cache)
    // -------------------------------------------------------------------------
`ifdef SIM
    wire             #0.038  cen_d   = cen;
    wire             #0.095  wen_d   = wen;
    wire [Index-1:0] #0.0932 addr_d  = sram_addr;
    wire [LineW-1:0] #0.1371 wdata_d = sram_wdata;

    ICACHE_SRAM #(.Depth(Depth), .DWidth(LineW)) DCACHE_SRAM (
        .clk_i  (clk_i),
        .ceb_i  (!cen_d),
        .web_i  (!wen_d),
        .addr_i (addr_d),
        .data_i (wdata_d),
        .data_o (sram_rdata)
    );
`else
    ICACHE_SRAM #(.Depth(Depth), .DWidth(LineW)) DCACHE_SRAM (
        .clk_i  (clk_i),
        .ceb_i  (!cen),
        .web_i  (!wen),
        .addr_i (sram_addr),
        .data_i (sram_wdata),
        .data_o (sram_rdata)
    );
`endif

endmodule
