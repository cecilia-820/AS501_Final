//////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                  //
// SCRATCHPAD MEMORY (SPM)                                                      //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//////////////////////////////////////////////////////////////////////////////////
// 64KB on-chip SRAM, single-port, 1-cycle read latency.
// Addr input is a byte offset relative to SPM base (cpu_top subtracts base).
// Behavioral SRAM for simulation, TSMC 28nm macro for synthesis.
//////////////////////////////////////////////////////////////////////////////////

module scratchpad #(
    parameter int unsigned DWidth = 32,
    parameter int unsigned Depth  = 16384   // 16384 words = 64KB
)(
    input  logic              clk_i,
    input  logic              rst_ni,

    input  logic              req_i,
    input  logic              write_i,
    input  logic [DWidth-1:0] addr_i,     // byte offset relative to SPM base
    input  logic [DWidth-1:0] wdata_i,
    output logic [DWidth-1:0] rdata_o
);

    localparam int unsigned AddrBits = $clog2(Depth);  // 14

    // Convert byte address to word index
    wire [AddrBits-1:0] word_idx = addr_i[AddrBits+1:2];

`ifdef SIM
    // Behavioral SRAM for simulation
    logic [DWidth-1:0] mem [0:Depth-1];

    always_ff @(posedge clk_i) begin
        if (req_i) begin
            if (write_i) begin
                mem[word_idx] <= wdata_i;
            end else begin
                rdata_o <= mem[word_idx];
            end
        end
    end
`else
    // Synthesis: use TSMC 28nm SRAM macro
    // ts1n28hpcphvtb32768x32m16s — 32768x32 (128KB), use lower 16384 addresses
    logic              sram_ceb;
    logic              sram_web;
    logic [14:0]       sram_a;     // 15-bit addr for 32768 depth
    logic [DWidth-1:0] sram_d;
    logic [DWidth-1:0] sram_q;

    assign sram_ceb = ~req_i;
    assign sram_web = ~write_i;
    assign sram_a   = {1'b0, word_idx};  // pad MSB to 0, using lower 16384
    assign sram_d   = wdata_i;
    assign rdata_o  = sram_q;

    ts1n28hpcphvtb32768x32m16s u_sram (
        .CLK  (clk_i),
        .CEB  (sram_ceb),
        .WEB  (sram_web),
        .A    (sram_a),
        .D    (sram_d),
        .Q    (sram_q),
        .RTSEL(2'b01),
        .WTSEL(2'b00)
    );
`endif

endmodule
