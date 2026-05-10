//////////////////////////////////////////////////////////////////////////////////
// AS603                                                                        //
// DATA MEMORY                                                                  //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                                       Minyoung Choi    (myconejo@kaist.ac.kr)//
//                                       JeongSeop Park   (eddie020@kaist.ac.kr)//
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
//////////////////////////////////////////////////////////////////////////////////


module D_MEMORY #(
    parameter int unsigned DWidth      = 32,
    parameter DMEM_START_W  = 32'h0008_0000,
    parameter DMEM_DEPTH_W  = 32'h07f8_0000,
    parameter DMEMHexFile   = ""
)(
    input  logic                   clk_i,       // unused
    input  logic                   rst_ni,

    input  logic                   dmem_req_i,
    input  logic                   dmem_write_i,
    input  logic  [DWidth-1:0]     dmem_wdata_i,
    input  logic  [DWidth-1:0]     dmem_addr_i,

    output logic  [DWidth-1:0]     dmem_rdata_o
);
    // Behavioral memory array
    logic  [DWidth-1:0]            mem[0:DMEM_DEPTH_W-1];

    logic [63:0] access_cnt;

    typedef enum logic [1:0] {MEMORY_IDLE, MEMORY_BUSY} state_m;
    state_m memory_state;

    localparam time MEMORY_DELAY_COST   = 40ns; // DO NOT CHANGE




    logic [DWidth-1:0]  a_snap;
    logic [DWidth-1:0]  wdata_snap;
    logic               we_snap;

//////////////////////////////////////////////////////////////////////////////////
// timing violation notifiers
//////////////////////////////////////////////////////////////////////////////////
    parameter time TSETUP_DATA_P = 0.1ns;
    parameter time THOLD_DATA_P  = 0.05ns;
    parameter time TSETUP_CTL_P  = 0.1ns;
    parameter time THOLD_CTL_P   = 0.05ns;
    logic notifier_addr, notifier_data, notifier_web;
    
    // timing checks for setup/hold violations
    specify
    specparam TSETUP_ADDR = 0.1ns,
                THOLD_ADDR  = 0.05ns,
                TSETUP_DATA = 0.1ns,
                THOLD_DATA  = 0.05ns,
                TSETUP_CTL  = 0.1ns,
                THOLD_CTL   = 0ns;


    
        $setuphold(posedge dmem_req_i, addr_delayed ,  TSETUP_ADDR, THOLD_ADDR, notifier_addr);
        $setuphold(posedge dmem_req_i &&& dmem_write_i, dmem_wdata_i, TSETUP_DATA, THOLD_DATA, notifier_data);
        $setuphold(posedge dmem_req_i &&& dmem_write_i, dmem_write_i, TSETUP_CTL,  THOLD_CTL,  notifier_web);
    endspecify

    // hard fail
    always @(notifier_addr) $fatal("[%0t] mem_addr_i setup/hold violation", $time);
    always @(notifier_data) $fatal("[%0t] mem_data_i setup/hold violation", $time);
    always @(notifier_web)  $fatal("[%0t] mem_web_i setup/hold violation", $time);
//////////////////////////////////////////////////////////////////////////////////


    // initialize
    always @(negedge rst_ni) begin        
        if (!rst_ni) begin
            a_snap   = 32'h0;
            wdata_snap = 32'h0;
            we_snap  = 1'b0;
            dmem_rdata_o <= 32'h0;
            memory_state <= MEMORY_IDLE;
            access_cnt   <= 64'h0;
        end 
    end



    always @(posedge dmem_req_i) begin
        
        a_snap   = dmem_addr_i;
        wdata_snap = dmem_wdata_i;
        we_snap  = dmem_write_i;


        unique case (memory_state)
            MEMORY_IDLE: begin
                memory_state <= MEMORY_BUSY;
                access_cnt   <= access_cnt + 1;

                fork
                    begin : Imem_worker
                        
                        // Apply delay
                        #MEMORY_DELAY_COST;
                        if ($isunknown(a_snap)) $fatal("[%0t] Dmem_addr_i unknown", $time);

                        // reject out-of-range addr
                        if (a_snap >= {DMEM_DEPTH_W, 2'b00}) begin
                            $fatal("[%0t] D_memory address out of range: %h", $time,a_snap);
                        end

                        // Lastly check if the address/data has been X/Z or changed
                        if ($isunknown(a_snap)) $fatal("[%0t] Dmem addr became X/Z", $time);

                        // W or R? 
                        if (we_snap) begin
                            if ($isunknown(wdata_snap)) $fatal("[%0t] Dmem wdata became X/Z", $time);
                            mem[a_snap[DWidth-1:2]] = wdata_snap;            
                        end else begin
                            dmem_rdata_o = mem[a_snap[DWidth-1:2]];
                        end

                        // Free memory state
                        memory_state <= MEMORY_IDLE;
                    end
                join
            end

            MEMORY_BUSY: begin
                // when busy, drop request and print error
                $fatal("[%0t] Data request while DMEM busy", $time);
            end
        endcase
    end

`ifdef SIM
    initial begin
        // Initialize dmem from hex file
        $readmemh(DMEMHexFile, mem, 0);
    end
`endif

endmodule