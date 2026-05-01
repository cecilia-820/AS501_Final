//////////////////////////////////////////////////////////////////////////////////
// AS603                                                                        //
// INSTRUCTION MEMORY                                                           //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                                       Minyoung Choi    (myconejo@kaist.ac.kr)//
//                                       JeongSeop Park   (eddie020@kaist.ac.kr)//
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
//////////////////////////////////////////////////////////////////////////////////


module I_MEMORY #(
    parameter int unsigned DWidth      = 32,
    parameter IMEM_START_W  = 32'h0000_0000,
    parameter IMEM_DEPTH_W  = 32'h0008_0000,
    parameter IMEMHexFile   = ""
)(
    input  logic                   clk_i,       // unused  
    input  logic                   rst_ni,

    input  logic                   imem_req_i,
    input  logic  [DWidth-1:0]     imem_addr_i,

    output logic  [DWidth-1:0]     imem_rdata_o
);
    // Behavioral memory array
    logic  [DWidth-1:0]            mem[0:IMEM_DEPTH_W-1];

    logic [63:0] access_cnt;

    logic [DWidth-1:0]  addr_snap;


//////////////////////////////////////////////////////////////////////////////////
// timing violation notifiers
//////////////////////////////////////////////////////////////////////////////////
    parameter time TSETUP_DATA_P = 0.1ns;
    parameter time THOLD_DATA_P  = 0.05ns;
    parameter time TSETUP_CTL_P  = 0.1ns;
    parameter time THOLD_CTL_P   = 0ns;
    logic notifier_addr, notifier_data, notifier_web;
      // timing checks for setup/hold violations
      specify
      specparam TSETUP_ADDR = 0.1ns,
                THOLD_ADDR  = 0.05ns,
                TSETUP_DATA = 0.1ns,
                THOLD_DATA  = 0.05ns,
                TSETUP_CTL  = 0.1ns,
                THOLD_CTL   = 0ns;



    
        $setuphold(posedge imem_req_i, imem_addr_i,  TSETUP_ADDR, THOLD_ADDR, notifier_addr);
      endspecify

      // hard fail
      always @(notifier_addr) $fatal("[%0t] imem_addr_i setup/hold violation", $time);
//////////////////////////////////////////////////////////////////////////////////

    typedef enum logic [1:0] {MEMORY_IDLE, MEMORY_BUSY} state_m;
    state_m memory_state;

    localparam time MEMORY_DELAY_COST   = 20ns; 

    always @(negedge rst_ni) begin        
        if (!rst_ni) begin
            access_cnt   <= 64'h0;
            imem_rdata_o <= 32'h0;
            addr_snap   <= 32'h0;
            memory_state <= MEMORY_IDLE;
        end 
    end

    always @(posedge imem_req_i) begin

        addr_snap   = imem_addr_i;
        unique case (memory_state)
            MEMORY_IDLE: begin
                memory_state <= MEMORY_BUSY;
                access_cnt   <= access_cnt + 1;
                fork
                    begin : Imem_worker
                        // Apply delay
                        #MEMORY_DELAY_COST;
                                    // reject unknown addr
                        if ($isunknown(addr_snap)) $fatal("[%0t] Imem_addr_i unknown", $time);
                        // reject out-of-range addr
                        if (addr_snap>= {IMEM_DEPTH_W, 2'b00}) begin
                            $fatal("[%0t] I_memory address out of range: %h", $time, imem_addr_i); 
                        end

                        // Read instruction data
                        imem_rdata_o = mem[addr_snap[DWidth-1:2]];

                        // Lastly check if the address/data has been X/Z or change
                        if ($isunknown(addr_snap)) $fatal("[%0t] Imem addr became X/Z", $time);

                        // Free memory state
                        memory_state <= MEMORY_IDLE;
                    end
                join 
            end

            MEMORY_BUSY: begin
                // when busy, drop request and print error
                $fatal("[%0t] INST request while IMEM busy", $time);
            end
        endcase
    end

`ifdef SIM
    initial begin
        // Initialize imem from hex file
        $readmemh(IMEMHexFile, mem, 0);
    end
`endif

endmodule