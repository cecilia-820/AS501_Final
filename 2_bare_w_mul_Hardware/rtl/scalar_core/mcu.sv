//////////////////////////////////////////////////////////////////////////////////
// AS603                                                                        //
// MEMORY CONTROLLER UNIT                                                       //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                                       Minyoung Choi    (myconejo@kaist.ac.kr)//
//                                       JeongSeop Park   (eddie020@kaist.ac.kr)//
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
//////////////////////////////////////////////////////////////////////////////////

module MCU #(
    parameter int unsigned DWidth      = 32,

    parameter IMEM_START_W  = 32'h0000_0000,
    parameter IMEM_DEPTH_W  = 32'h0008_0000,
    
    parameter DMEM_START_W  = 32'h0008_0000,
    parameter DMEM_DEPTH_W  = 32'h07f8_0000,

    parameter IOMEM_START_W = 32'h0800_0000,
    parameter IOMEM_DEPTH_W = 32'h0010_0000,

    parameter int unsigned ACCEL_START_W = 32'h0810_0000,
    parameter int unsigned ACCEL_DEPTH_W = 32'h0000_0010
)(
    // Clock & reset
    input  logic                   clk_i,
    input  logic                   rst_ni,
    
    // MCU <-> Core (dmem ports)
    input  logic                   dmem_req_i,
    input  logic                   dmem_write_i,
    input  logic[DWidth-1:0]       dmem_addr_i,
    input  logic[DWidth-1:0]       dmem_wdata_i,
    
    output logic                   dmem_ready_o,
    output logic[DWidth-1:0]       dmem_rdata_o,

    // MCU <-> Icache (imem ports)
    input  logic                   imem_req_i,
    input  logic[DWidth-1:0]       imem_addr_i,

    output logic                   imem_ready_o,
    output logic[DWidth-1:0]       imem_rdata_o,

    // IMEM <-> MCU 
    output logic                   imem_req_o,
    output logic[DWidth-1:0]       imem_addr_o,
    
    input  logic[DWidth-1:0]       imem_rdata_i,
    
    // DMEM <-> MCU 
    output logic                   dmem_req_o,
    output logic                   dmem_write_o,
    output logic[DWidth-1:0]       dmem_addr_o,
    output logic[DWidth-1:0]       dmem_wdata_o,

    input  logic[DWidth-1:0]       dmem_rdata_i,

    // IOMEM <-> MCU 
    output logic                   iomem_req_o,
    output logic                   iomem_write_o,
    output logic[DWidth-1:0]       iomem_addr_o,
    output logic[DWidth-1:0]       iomem_wdata_o,

    input  logic[DWidth-1:0]       iomem_rdata_i,

    // ACCEL control port
    output logic                 accel_req_o,
    output logic                 accel_write_o,
    output logic [DWidth-1:0]    accel_addr_o,
    output logic [DWidth-1:0]    accel_wdata_o,
    input  logic [DWidth-1:0]    accel_rdata_i,
    input  logic                 accel_ready_i

);

    // Latency for memory access
    localparam int LATENCY_CYCLES = 4;
    
    // FSM for DMEM/IOMEM 
    typedef enum logic [1:0] {
        D_IDLE, // free to access
        D_WAIT  // blocks if either IOMEM or DMEM is being read/written (block parallel accesses)
    } d_state_e;

    d_state_e d_state_q, d_state_d;
    logic [1:0] d_latency_cnt_q, d_latency_cnt_d;

    // remembers if the target was IOMEM
    logic is_iomem_q; 

    // read-phase tracking
    logic is_accel_q;

    // states for IMEM
    logic imem_busy_q, imem_busy_d;
    logic [1:0] i_latency_cnt_q, i_latency_cnt_d;

    // dmem or iomem (for muxing at data read)
    logic dmem_addr_is_io;
    assign dmem_addr_is_io =
        (dmem_addr_i >= (IOMEM_START_W << 2)) &&
        (dmem_addr_i <  ((IOMEM_START_W + IOMEM_DEPTH_W) << 2));

    //ACCEL address decode logic
    logic dmem_addr_is_accel;
    assign dmem_addr_is_accel =
        (dmem_addr_i >= (ACCEL_START_W << 2)) &&
        (dmem_addr_i <  ((ACCEL_START_W + ACCEL_DEPTH_W) << 2));    
        
    // DMEM & IOMEM state logic
    // [NOTE] Parallel access to DMEM and IOMEM is prohibited, as we assume these two are single external memory. 
    always_comb begin
        // Default assignments
        d_state_d       = d_state_q;
        d_latency_cnt_d = d_latency_cnt_q;
        dmem_req_o      = 1'b0;
        iomem_req_o     = 1'b0;
        dmem_ready_o    = 1'b0;
        accel_req_o     = 1'b0;
        accel_write_o   = 1'b0;
        accel_addr_o    = '0;
        accel_wdata_o   = '0;

        case (d_state_q)
            // D_IDLE: free to access 
            D_IDLE: begin
                // check for a request
                if (dmem_req_i) begin
                    if (dmem_addr_is_accel) begin
                        accel_req_o   = 1'b1;
                        accel_write_o = dmem_write_i;
                        accel_addr_o  = (dmem_addr_i - (ACCEL_START_W << 2)) >> 2;
                        accel_wdata_o = dmem_wdata_i;
                        dmem_ready_o  = 1'b1;
                    end else if (dmem_addr_is_io) begin
                        d_state_d       = D_WAIT;
                        d_latency_cnt_d = '0;
                        iomem_req_o     = 1'b1;
                    end else begin
                        d_state_d       = D_WAIT;
                        d_latency_cnt_d = '0;
                        dmem_req_o      = 1'b1;
                    end
                end
            end
            
            // D_WAIT: memory currently being read/written
            // [WARNING] If memory request(s) arrive in this stage, memory request will be DISCARDED. 
            D_WAIT: begin
                // wait for 2 clk cycles
                if (d_latency_cnt_q == LATENCY_CYCLES - 1) begin
                    d_state_d       = D_IDLE;
                    dmem_ready_o    = 1'b1; // Send ACK to core
                end else begin
                    d_latency_cnt_d = d_latency_cnt_q + 1;
                end
            end
        endcase
    end

    // Data/IO memory path registers
    always_ff @(posedge clk_i or negedge rst_ni) begin
        // initialize state
        if (!rst_ni) begin
            d_state_q       <= D_IDLE;
            d_latency_cnt_q <= '0;
            is_iomem_q      <= 1'b0;
            is_accel_q      <= 1'b0;
        // update state every clk cycle
        end else begin
            d_state_q       <= d_state_d;
            d_latency_cnt_q <= d_latency_cnt_d;

            // Latch the destination when a request is accepted during IDLE state. 
            if (d_state_q == D_IDLE && dmem_req_i) begin
                // destination determined by address 
                is_iomem_q <= dmem_addr_is_io;
                is_accel_q <= dmem_addr_is_accel;
            end
        end
    end

    // IMEM logic
    always_comb begin
        
        // Default assignments
        imem_busy_d     = imem_busy_q;
        i_latency_cnt_d = i_latency_cnt_q;
        imem_req_o      = 1'b0;
        imem_ready_o    = 1'b0;

        // IDLE: if there is an incoming request, send it to IMEM
        if (!imem_busy_q) begin
            if (imem_req_i) begin
                imem_busy_d     = 1'b1;
                i_latency_cnt_d = '0;
                imem_req_o      = 1'b1;
            end
        // WAIT: wait for 2 clock cycles
        // [WARNING] If memory request(s) arrive in this stage, memory request will be DISCARDED. 
        end else begin
            if (i_latency_cnt_q == LATENCY_CYCLES - 1) begin
                imem_busy_d  = 1'b0;
                imem_ready_o = 1'b1; // Send ACK to core/icache
            end else begin
                i_latency_cnt_d = i_latency_cnt_q + 1;
            end
        end
    end
    
    // Instruction memory path registers
    always_ff @(posedge clk_i or negedge rst_ni) begin
        // initialize
        if (!rst_ni) begin
            imem_busy_q     <= 1'b0;
            i_latency_cnt_q <= '0;
        // update state every clock cycle
        end else begin
            imem_busy_q     <= imem_busy_d;
            i_latency_cnt_q <= i_latency_cnt_d;
        end
    end
    
    // Instruction Path
    assign imem_addr_o  = imem_addr_i - (IMEM_START_W << 2);  // [NOTE] _W is word address. 
    assign imem_rdata_o = imem_rdata_i;

    // data Path
    assign dmem_addr_o   = dmem_addr_i - (DMEM_START_W << 2);
    assign dmem_wdata_o = dmem_wdata_i;
    assign dmem_write_o = dmem_write_i;
    assign iomem_addr_o = dmem_addr_i - (IOMEM_START_W << 2);
    assign iomem_wdata_o= dmem_wdata_i;
    assign iomem_write_o= dmem_write_i;

    // mux read data based on the latched request type
    assign dmem_rdata_o = is_iomem_q ? iomem_rdata_i : is_accel_q ? accel_rdata_i : dmem_rdata_i;

endmodule