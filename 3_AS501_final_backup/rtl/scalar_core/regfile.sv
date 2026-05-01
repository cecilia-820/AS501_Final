////////////////////////////////////////////////////////////////////////////////
// AS501/603
// Register File
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2024 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by Hyungjoon Bae (jo_on@kaist.ac.kr)
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
////////////////////////////////////////////////////////////////////////////////

module REGFILE #(
    parameter DWidth   = 32,
    parameter NumofReg = 32,
    localparam AWidth  = $clog2(NumofReg)
)(
    // Basic signals
    input   logic                   clk_i,
    input   logic                   rst_ni,
    // Read and Write signals
    input   logic   [AWidth-1:0]    read1_addr_i,
    input   logic   [AWidth-1:0]    read2_addr_i,
    input   logic   [AWidth-1:0]    write_addr_i,
    input   logic   [DWidth-1:0]    write_data_i,
    input   logic                   write_en_i,
    // Read data
    output  logic   [DWidth-1:0]    read1_data_o,
    output  logic   [DWidth-1:0]    read2_data_o
);

    // Register array
    logic   [DWidth-1:0]            GPR[0:NumofReg-1];

    // Read Operation
    assign  read1_data_o = GPR[read1_addr_i];
    assign  read2_data_o = GPR[read2_addr_i];
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int unsigned i = 0; i < NumofReg; i = i + 1) begin
                GPR[i] <= '0;
            end
        end else if (write_en_i && (write_addr_i != 0)) begin
            GPR[write_addr_i] <= write_data_i;
        end
    end

endmodule