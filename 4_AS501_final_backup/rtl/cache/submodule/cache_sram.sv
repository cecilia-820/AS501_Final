//////////////////////////////////////////////////////////////////////////////////
// AS603                                                                        //
// Cache SRAM                                                                   //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                                       Minyoung Choi    (myconejo@kaist.ac.kr)//
//                                       JeongSeop Park   (eddie020@kaist.ac.kr)//
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
//////////////////////////////////////////////////////////////////////////////////

module ICACHE_SRAM #(
    parameter Depth     = 512,
    parameter DWidth    = 54,  
    localparam Index    = $clog2(Depth)
)(
    input   logic                   clk_i,
    input   logic                   ceb_i,
    input   logic                   web_i,
    input   logic   [Index-1:0]     addr_i,
    input   logic   [DWidth-1:0]    data_i,
    output  logic   [DWidth-1:0]    data_o
);
    TS5N28HPCPHVTA512X54M4F SRAM(
        .CLK                        (clk_i),
        .CEB                        (ceb_i),
        .WEB                        (web_i),
        .A                          (addr_i),
        .D                          (data_i),
        .Q                          (data_o)
    );

endmodule