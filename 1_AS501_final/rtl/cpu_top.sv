//////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                        //
// CPU TOP                                                                      //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                                       Minyoung Choi    (myconejo@kaist.ac.kr)//
//                                       JeongSeop Park   (eddie020@kaist.ac.kr)//
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
//////////////////////////////////////////////////////////////////////////////////

module CPU_TOP #(
    parameter DWidth = 32,

    parameter IMEM_START_W  = 32'h0000_0000,
    parameter IMEM_DEPTH_W  = 32'h0008_0000,
    
    parameter DMEM_START_W  = 32'h0008_0000,
    parameter DMEM_DEPTH_W  = 32'h07f8_0000,

    parameter IOMEM_START_W = 32'h0800_0000,
    parameter IOMEM_DEPTH_W = 32'h0010_0000
    
)(
    // Basic signals
    input  logic                   clk_i,
    input  logic                   rst_ni,

    // Instruction interface (to physical IMEM)
    input  logic  [DWidth-1:0]     imem_rdata_i,
    output logic  [DWidth-1:0]     imem_addr_o,
    output logic                   imem_req_o,
    
    // Data interface (to physical DMEM)
    input  logic  [DWidth-1:0]     dmem_rdata_i,
    output logic  [DWidth-1:0]     dmem_wdata_o,
    output logic  [DWidth-1:0]     dmem_addr_o,
    output logic                   dmem_req_o,
    output logic                   dmem_write_o,

    // IO interface (to physical IOMEM)
    input  logic  [DWidth-1:0]     iomem_rdata_i,
    output logic  [DWidth-1:0]     iomem_wdata_o,
    output logic  [DWidth-1:0]     iomem_addr_o,
    output logic                   iomem_req_o,
    output logic                   iomem_write_o,

    // expose for CPI counting in TB
    output logic               icache_read_o
);

    // Core <-> ICache
    logic                   icache_read;
    logic  [DWidth-1:0]     icache_addr;
    logic  [DWidth-1:0]     icache_rdata;
    logic                   icache_hit;

    // Core <-> MCU (Data Path)
    logic                   core_dmem_req;
    logic                   core_dmem_write;
    logic  [DWidth-1:0]     core_dmem_addr;
    logic  [DWidth-1:0]     core_dmem_wdata;
    logic                   mcu_dmem_ready;
    logic  [DWidth-1:0]     mcu_dmem_rdata;

    // ICache <-> MCU (Instruction Path for instr misses)
    logic                   icache_miss_req;
    logic  [DWidth-1:0]     icache_miss_addr;
    logic                   mcu_imem_ready;
    logic  [DWidth-1:0]     mcu_imem_rdata;

    //for cpi counting
    assign icache_read_o = icache_read;
    
    INSTR_CACHE #(.DWidth(DWidth)) ICACHE(
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .read_i        (icache_read),
        .addr_i        (icache_addr),
        .imem_rdata_i  (mcu_imem_rdata),
        .imem_ready_i  (mcu_imem_ready),
        .imem_addr_o   (icache_miss_addr),
        .imem_req_o    (icache_miss_req),
        .instr_o       (icache_rdata),
        .hit_o         (icache_hit)
    );

    SCALAR_CORE #(.DWidth(DWidth)) SCORE(
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .imem_ready_i  (icache_hit),
        .imem_rdata_i  (icache_rdata),
        .imem_addr_o   (icache_addr),
        .imem_req_o    (icache_read),
        .dmem_ready_i  (mcu_dmem_ready),
        .dmem_rdata_i  (mcu_dmem_rdata),
        .dmem_wdata_o  (core_dmem_wdata),
        .dmem_addr_o   (core_dmem_addr),
        .dmem_req_o    (core_dmem_req),
        .dmem_write_o  (core_dmem_write)
    );

    MCU #(
        .IMEM_START_W  (IMEM_START_W),
        .IMEM_DEPTH_W  (IMEM_DEPTH_W),
        .DMEM_START_W  (DMEM_START_W),
        .DMEM_DEPTH_W  (DMEM_DEPTH_W),
        .IOMEM_START_W (IOMEM_START_W),
        .IOMEM_DEPTH_W (IOMEM_DEPTH_W)
    ) MCU_INST (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        
        // MCU <-> Core (data path)
        .dmem_req_i    (core_dmem_req),
        .dmem_write_i  (core_dmem_write),
        .dmem_addr_i   (core_dmem_addr),
        .dmem_wdata_i  (core_dmem_wdata),
        .dmem_ready_o  (mcu_dmem_ready),
        .dmem_rdata_o  (mcu_dmem_rdata),

        // MCU <-> ICache (instr path)
        .imem_req_i    (icache_miss_req),
        .imem_addr_i   (icache_miss_addr),
        .imem_ready_o  (mcu_imem_ready),
        .imem_rdata_o  (mcu_imem_rdata),

        // IMEM <-> MCU
        .imem_req_o    (imem_req_o),
        .imem_addr_o   (imem_addr_o),
        .imem_rdata_i  (imem_rdata_i),
        
        // DMEM <-> MCU
        .dmem_req_o    (dmem_req_o),
        .dmem_write_o  (dmem_write_o),
        .dmem_addr_o   (dmem_addr_o),
        .dmem_wdata_o  (dmem_wdata_o),
        .dmem_rdata_i  (dmem_rdata_i),

        // IOMEM <-> MCU
        .iomem_req_o   (iomem_req_o),
        .iomem_write_o (iomem_write_o),
        .iomem_addr_o  (iomem_addr_o),
        .iomem_wdata_o (iomem_wdata_o),
        .iomem_rdata_i (iomem_rdata_i)
    );


endmodule