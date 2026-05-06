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
    parameter IOMEM_DEPTH_W = 32'h0010_0000,

    //accelerator
    parameter ACCEL_START_W = 32'h0810_0000,
    parameter ACCEL_DEPTH_W = 32'h0000_0010
    
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

    // MCU <-> ACCEL control bus
    logic                 accel_req;
    logic                 accel_write;
    logic [DWidth-1:0]    accel_addr;
    logic [DWidth-1:0]    accel_wdata;
    logic [DWidth-1:0]    accel_rdata;
    logic                 accel_ready;

    // ACCEL DMA signals
    logic                 dma_req;
    logic                 dma_write;
    logic [DWidth-1:0]    dma_addr;
    logic [DWidth-1:0]    dma_wdata;
    logic [DWidth-1:0]    dma_rdata;
    logic                 dma_ready;

    // Arbitrated DMEM signals (output side toward external DMEM)
    logic                 arb_dmem_req;
    logic                 arb_dmem_write;
    logic [DWidth-1:0]    arb_dmem_addr;
    logic [DWidth-1:0]    arb_dmem_wdata;
    logic [DWidth-1:0]    arb_dmem_rdata;

    //for cpi counting
    assign icache_read_o = icache_read;


    // MCU의 외부 DMEM 출력 (아비터 입력)
    logic                 mcu_ext_dmem_req;
    logic                 mcu_ext_dmem_write;
    logic [DWidth-1:0]    mcu_ext_dmem_addr;
    logic [DWidth-1:0]    mcu_ext_dmem_wdata;

    // D-cache memory-side signals (drive the DMEM arbiter)
    logic                 dcache_mem_req;
    logic                 dcache_mem_write;
    logic [DWidth-1:0]    dcache_mem_addr;
    logic [DWidth-1:0]    dcache_mem_wdata;

    // Arbiter: D-cache (DMA path) has priority over MCU (CPU path) on DMEM bus.
    // During ACCEL operation, CPU polls STATUS via ACCEL control port (separate
    // path), so no DMEM contention arises in normal operation.
    assign dmem_req_o   = dcache_mem_req   ? 1'b1             : mcu_ext_dmem_req;
    assign dmem_write_o = dcache_mem_req   ? dcache_mem_write : mcu_ext_dmem_write;
    assign dmem_addr_o  = dcache_mem_req   ? dcache_mem_addr  : mcu_ext_dmem_addr;
    // dcache_mem_write pre-asserted 1 cycle before dcache_mem_req (DATA_CACHE
    // StIdle write path) keeps dmem_wdata_o stable at the posedge of dmem_req_i.
    assign dmem_wdata_o = dcache_mem_write ? dcache_mem_wdata : mcu_ext_dmem_wdata;


    
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
        .IOMEM_DEPTH_W (IOMEM_DEPTH_W),
        .ACCEL_START_W (ACCEL_START_W),       
        .ACCEL_DEPTH_W (ACCEL_DEPTH_W)        
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
        .dmem_req_o    (mcu_ext_dmem_req),    //(dmem_req_o → mcu_ext_dmem_req)
        .dmem_write_o  (mcu_ext_dmem_write),
        .dmem_addr_o   (mcu_ext_dmem_addr),
        .dmem_wdata_o  (mcu_ext_dmem_wdata),
        .dmem_rdata_i  (dmem_rdata_i),

        // IOMEM <-> MCU
        .iomem_req_o   (iomem_req_o),
        .iomem_write_o (iomem_write_o),
        .iomem_addr_o  (iomem_addr_o),
        .iomem_wdata_o (iomem_wdata_o),
        .iomem_rdata_i (iomem_rdata_i),

        // ACCEL control port
        .accel_req_o   (accel_req),           
        .accel_write_o (accel_write),
        .accel_addr_o  (accel_addr),
        .accel_wdata_o (accel_wdata),
        .accel_rdata_i (accel_rdata),
        .accel_ready_i (accel_ready)
    );

    gemv_accel #(
        .DWidth(DWidth)
    ) u_gemv_accel (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .accel_req_i   (accel_req),
        .accel_write_i (accel_write),
        .accel_addr_i  (accel_addr),
        .accel_wdata_i (accel_wdata),
        .accel_rdata_o (accel_rdata),
        .accel_ready_o (accel_ready),
        .dma_req_o     (dma_req),
        .dma_write_o   (dma_write),
        .dma_addr_o    (dma_addr),
        .dma_wdata_o   (dma_wdata),
        .dma_rdata_i   (dma_rdata),
        .dma_ready_i   (dma_ready)
    );

    DATA_CACHE #(
        .DWidth(DWidth)
    ) u_data_cache (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .dma_req_i   (dma_req),
        .dma_write_i (dma_write),
        .dma_addr_i  (dma_addr - (DMEM_START_W << 2)),
        .dma_wdata_i (dma_wdata),
        .dma_rdata_o (dma_rdata),
        .dma_ready_o (dma_ready),
        .mem_req_o   (dcache_mem_req),
        .mem_write_o (dcache_mem_write),
        .mem_addr_o  (dcache_mem_addr),
        .mem_wdata_o (dcache_mem_wdata),
        .mem_rdata_i (dmem_rdata_i)
    );


endmodule