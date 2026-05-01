//////////////////////////////////////////////////////////////////////////////////
// AS603                                                                        //
// Instruction Cache                                                            //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                                       Minyoung Choi    (myconejo@kaist.ac.kr)//
//                                       JeongSeop Park   (eddie020@kaist.ac.kr)//
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
//////////////////////////////////////////////////////////////////////////////////

module INSTR_CACHE #(
    parameter DWidth = 32,
    parameter Depth  = 512,
    localparam Tag   = DWidth - 2 - $clog2(Depth),
    localparam Index = $clog2(Depth),
    localparam Valid = 1
)(
    // Basic signals
    input   logic                   clk_i,
    input   logic                   rst_ni,
    // From scalar core
    input   logic                   read_i,
    input   logic   [DWidth-1:0]    addr_i,
    // From instruction memory
    input   logic   [DWidth-1:0]    imem_rdata_i,
    input   logic                   imem_ready_i,
    // To instruction memory
    output  logic   [DWidth-1:0]    imem_addr_o,
    output  logic                   imem_req_o,
    // To scalar core
    output  logic   [DWidth-1:0]    instr_o,
    output  logic                   hit_o
);
    import pkg_bool::*;

////////////////////////////////////////////////////////////////////////////////
// Latched data
    logic   [DWidth-1:0]            latched_instr;

    D_FF #(.DWidth(DWidth), .RValue('0)) FF_INSTR(
        .clk_i                      (clk_i),
        .rst_ni                     (rst_ni),
        .write_en_i                 (hit_o),
        .write_data_i               (instr_o),
        .read_data_o                (latched_instr)
    );

////////////////////////////////////////////////////////////////////////////////
// Reset counter
    logic   [DWidth-3:0]            cnt_value;
    logic                           cnt_done;

    COUNTER #(.DWidth(DWidth-2), .RValue('0), .FValue(Depth-1)) COUNTER_ICACHE(
        .clk_i                      (clk_i),
        .rst_ni                     (rst_ni),
        .cnt_en_i                   (!cnt_done),
        .cnt_done_o                 (cnt_done),
        .cnt_data_o                 (cnt_value)
    );

////////////////////////////////////////////////////////////////////////////////
// Mealy machine
    // FSM states
    typedef enum logic [1:0] { // A 2-bit enumerated type
        StIdle, StRead, StWrite, StReset
    } cache_state_e;

    cache_state_e                   cache_state_d, cache_state_q;

    logic                           cen;
    logic                           wen;
    logic   [DWidth-1:0]            addr;
    logic                           valid;
    logic   [DWidth-1:0]            wdata;
    logic                           hit;
    logic   [Valid+Tag+DWidth-1:0]  cache_line;

    always_comb begin
        unique case (cache_state_q)
            StIdle: begin
                // If request is read, go to read
                // else stay in idle
                cache_state_d = (read_i) ? StRead : StIdle;
                cen           = cache_state_d inside {StRead};
                wen           = FALSE;
                addr          = addr_i;
                valid         = FALSE;
                wdata         = imem_rdata_i;
                hit_o         = FALSE;
                imem_req_o    = FALSE;
                instr_o       = latched_instr;
            end
            StRead: begin
                cache_state_d = (hit) ? (read_i) ? StRead : StIdle : (imem_ready_i) ? StWrite : StRead;
                cen           = cache_state_d inside {StRead, StWrite};
                wen           = cache_state_d inside {StWrite};
                addr          = addr_i;
                valid         = cache_state_d inside {StWrite};
                wdata         = imem_rdata_i;
                hit_o         = hit;
                imem_req_o    = !hit;
                instr_o       = (hit) ? cache_line[DWidth-1:0] : latched_instr;
            end
            StWrite: begin
                // If request is read, go to read
                // else go to idle
                cache_state_d = (read_i) ? StRead : StIdle;
                cen           = cache_state_d inside {StRead};
                wen           = FALSE;
                addr          = addr_i;
                valid         = FALSE;
                wdata         = imem_rdata_i;
                hit_o         = TRUE;
                imem_req_o    = FALSE;
                instr_o       = imem_rdata_i;
            end
            // StReset
            default: begin
                // If all rows are initialized, go to idle
                // else stay in reset
                cache_state_d = (cnt_done) ? StIdle : StReset;
                cen           = cache_state_d inside {StReset};
                wen           = cache_state_d inside {StReset};
                addr          = {cnt_value, 2'b0};
                valid         = FALSE;
                wdata         = '0;
                hit_o         = FALSE;
                imem_req_o    = FALSE;
                instr_o       = '0;
            end
        endcase
    end

    assign  imem_addr_o = addr_i;

    // FSM register
    D_FF #(.DWidth(2), .RValue(StReset)) FF_CACHE_STATE(
        .clk_i                      (clk_i),
        .rst_ni                     (rst_ni),
        .write_en_i                 (1'b1),
        .write_data_i               (cache_state_d[1:0]),
        .read_data_o                (cache_state_q[1:0])
    );

////////////////////////////////////////////////////////////////////////////////
// Cache logic
    wire    [Index+1-2:0]           index = addr[Index+1:2];

    // hit = valid && (tag == address)
    assign  hit = cache_line[Valid+Tag+DWidth-1] &&
                  (cache_line[Valid+Tag+DWidth-2:DWidth] == addr[DWidth-1:($clog2(Depth)+2)]);

`ifdef SIM
    // Hold time delay
    wire                            #0.038  cen_d  = cen;
    wire                            #0.095  wen_d  = wen;
    wire    [Index+1-2:0]           #0.0932 addr_d = index;
    wire    [Valid+Tag+DWidth-1:0]  #0.1371 wdata_d = {valid, addr[DWidth-1:($clog2(Depth)+2)], wdata};

    ICACHE_SRAM #(.Depth(Depth), .DWidth(Valid+Tag+DWidth)) ICACHE_SRAM(
        .clk_i                      (clk_i),
        .ceb_i                      (!cen_d),
        .web_i                      (!wen_d),
        .addr_i                     (addr_d),
        .data_i                     (wdata_d),
        .data_o                     (cache_line)
    );
`else
    ICACHE_SRAM #(.Depth(Depth), .DWidth(Valid+Tag+DWidth)) ICACHE_SRAM(
        .clk_i                      (clk_i),
        .ceb_i                      (!cen),
        .web_i                      (!wen),
        .addr_i                     (index),
        .data_i                     ({valid, addr[DWidth-1:($clog2(Depth)+2)], wdata}),
        .data_o                     (cache_line)
    );
`endif

////////////////////////////////////////////////////////////////////////////////

endmodule