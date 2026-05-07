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
    parameter ACCEL_DEPTH_W = 32'h0000_0010,

    // SPM
    parameter SPM_START_W   = 32'h0820_0000,
    parameter SPM_DEPTH_W   = 32'h0000_4000,   // 16384 words = 64KB

    // DMA controller
    parameter DMA_START_W   = 32'h0824_0000,
    parameter DMA_DEPTH_W   = 32'h0000_0010

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

    // ACCEL DMA signals (GEMV accel -> data cache -> DMEM arbiter)
    logic                 accel_dma_req;
    logic                 accel_dma_write;
    logic [DWidth-1:0]    accel_dma_addr;
    logic [DWidth-1:0]    accel_dma_wdata;
    logic [DWidth-1:0]    accel_dma_rdata;
    logic                 accel_dma_ready;

    //for cpi counting
    assign icache_read_o = icache_read;

    // MCU's external DMEM output (arbiter input)
    logic                 mcu_ext_dmem_req;
    logic                 mcu_ext_dmem_write;
    logic [DWidth-1:0]    mcu_ext_dmem_addr;
    logic [DWidth-1:0]    mcu_ext_dmem_wdata;

    // D-cache memory-side signals (drive the DMEM arbiter)
    logic                 dcache_mem_req;
    logic                 dcache_mem_write;
    logic [DWidth-1:0]    dcache_mem_addr;
    logic [DWidth-1:0]    dcache_mem_wdata;

    // MCU <-> SPM (CPU access path)
    logic                 spm_cpu_req;
    logic                 spm_cpu_write;
    logic [DWidth-1:0]    spm_cpu_addr;
    logic [DWidth-1:0]    spm_cpu_wdata;
    logic [DWidth-1:0]    spm_cpu_rdata;

    // MCU <-> DMA control
    logic                 dma_ctrl_req;
    logic                 dma_ctrl_write;
    logic [DWidth-1:0]    dma_ctrl_addr;
    logic [DWidth-1:0]    dma_ctrl_wdata;
    logic [DWidth-1:0]    dma_ctrl_rdata;
    logic                 dma_ctrl_ready;

    // DMA controller <-> external DMEM port
    logic                 dma_mem_req;
    logic                 dma_mem_write;
    logic [DWidth-1:0]    dma_mem_addr;
    logic [DWidth-1:0]    dma_mem_wdata;

    // DMA controller <-> SPM port
    logic                 dma_spm_req;
    logic                 dma_spm_write;
    logic [DWidth-1:0]    dma_spm_addr;
    logic [DWidth-1:0]    dma_spm_wdata;
    logic [DWidth-1:0]    dma_spm_rdata;

    // Merged SPM port (CPU + DMA arbitrated)
    logic                 spm_req;
    logic                 spm_write;
    logic [DWidth-1:0]    spm_addr;
    logic [DWidth-1:0]    spm_wdata;
    logic [DWidth-1:0]    spm_rdata;

    // =========================================================================
    // SPM port arbiter (DMA controller has priority over CPU)
    // =========================================================================
    assign spm_req   = dma_spm_req   ? 1'b1           : spm_cpu_req;
    assign spm_write = dma_spm_req   ? dma_spm_write  : spm_cpu_write;
    assign spm_addr  = dma_spm_req   ? dma_spm_addr   : spm_cpu_addr;
    assign spm_wdata = dma_spm_req   ? dma_spm_wdata  : spm_cpu_wdata;
    assign spm_cpu_rdata = spm_rdata;
    assign dma_spm_rdata = spm_rdata;

    // =========================================================================
    // 3-way priority arbiter for external DMEM bus
    // Priority: D-cache (GEMV DMA) > DMA controller > MCU (CPU)
    // =========================================================================
    assign dmem_req_o   = dcache_mem_req ? 1'b1              :
                          dma_mem_req    ? 1'b1              :
                                           mcu_ext_dmem_req;

    assign dmem_write_o = dcache_mem_req ? dcache_mem_write  :
                          dma_mem_req    ? dma_mem_write     :
                                           mcu_ext_dmem_write;

    // DMA controller outputs full byte addresses; subtract DMEM base
    // to match the relative-offset format used by D-cache and MCU.
    assign dmem_addr_o  = dcache_mem_req ? dcache_mem_addr                      :
                          dma_mem_req    ? (dma_mem_addr - (DMEM_START_W << 2)) :
                                           mcu_ext_dmem_addr;

    // wdata MUX: dcache_mem_write pre-asserted 1 cycle before dcache_mem_req
    // to meet D_MEMORY hold-time constraints.
    assign dmem_wdata_o = dcache_mem_write ? dcache_mem_wdata :
                          dma_mem_write    ? dma_mem_wdata    :
                                             mcu_ext_dmem_wdata;


    // =========================================================================
    // Module instances
    // =========================================================================

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
        .ACCEL_DEPTH_W (ACCEL_DEPTH_W),
        .SPM_START_W   (SPM_START_W),
        .SPM_DEPTH_W   (SPM_DEPTH_W),
        .DMA_START_W   (DMA_START_W),
        .DMA_DEPTH_W   (DMA_DEPTH_W)
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
        .dmem_req_o    (mcu_ext_dmem_req),
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
        .accel_ready_i (accel_ready),

        // SPM port (CPU access path)
        .spm_req_o     (spm_cpu_req),
        .spm_write_o   (spm_cpu_write),
        .spm_addr_o    (spm_cpu_addr),
        .spm_wdata_o   (spm_cpu_wdata),
        .spm_rdata_i   (spm_cpu_rdata),

        // DMA control port
        .dma_req_o     (dma_ctrl_req),
        .dma_write_o   (dma_ctrl_write),
        .dma_addr_o    (dma_ctrl_addr),
        .dma_wdata_o   (dma_ctrl_wdata),
        .dma_rdata_i   (dma_ctrl_rdata),
        .dma_ready_i   (dma_ctrl_ready)
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
        .dma_req_o     (accel_dma_req),
        .dma_write_o   (accel_dma_write),
        .dma_addr_o    (accel_dma_addr),
        .dma_wdata_o   (accel_dma_wdata),
        .dma_rdata_i   (accel_dma_rdata),
        .dma_ready_i   (accel_dma_ready)
    );

    DATA_CACHE #(
        .DWidth(DWidth)
    ) u_data_cache (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .dma_req_i   (accel_dma_req),
        .dma_write_i (accel_dma_write),
        .dma_addr_i  (accel_dma_addr - (DMEM_START_W << 2)),
        .dma_wdata_i (accel_dma_wdata),
        .dma_rdata_o (accel_dma_rdata),
        .dma_ready_o (accel_dma_ready),
        .mem_req_o   (dcache_mem_req),
        .mem_write_o (dcache_mem_write),
        .mem_addr_o  (dcache_mem_addr),
        .mem_wdata_o (dcache_mem_wdata),
        .mem_rdata_i (dmem_rdata_i)
    );

    // =========================================================================
    // Scratchpad Memory (64KB, 1-cycle access)
    // =========================================================================
    scratchpad #(
        .DWidth(DWidth),
        .Depth(16384)
    ) u_spm (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .req_i   (spm_req),
        .write_i (spm_write),
        .addr_i  (spm_addr),
        .wdata_i (spm_wdata),
        .rdata_o (spm_rdata)
    );

    // =========================================================================
    // DMA Controller (DMEM <-> SPM bulk transfer)
    // =========================================================================
    dma_controller #(
        .DWidth        (DWidth),
        .DMEM_START_BYTE(DMEM_START_W << 2),
        .DMEM_END_BYTE (((DMEM_START_W + DMEM_DEPTH_W) << 2) - 1),
        .SPM_START_BYTE(SPM_START_W << 2),
        .SPM_END_BYTE  (((SPM_START_W + SPM_DEPTH_W) << 2) - 1)
    ) u_dma (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        // Control port (from MCU)
        .ctrl_req_i     (dma_ctrl_req),
        .ctrl_write_i   (dma_ctrl_write),
        .ctrl_addr_i    (dma_ctrl_addr),
        .ctrl_wdata_i   (dma_ctrl_wdata),
        .ctrl_rdata_o   (dma_ctrl_rdata),
        .ctrl_ready_o   (dma_ctrl_ready),
        // DMEM port (to external DMEM via 3-way arbiter)
        .mem_req_o      (dma_mem_req),
        .mem_write_o    (dma_mem_write),
        .mem_addr_o     (dma_mem_addr),
        .mem_wdata_o    (dma_mem_wdata),
        .mem_rdata_i    (dmem_rdata_i),
        // SPM port (to SPM arbiter)
        .spm_req_o      (dma_spm_req),
        .spm_write_o    (dma_spm_write),
        .spm_addr_o     (dma_spm_addr),
        .spm_wdata_o    (dma_spm_wdata),
        .spm_rdata_i    (dma_spm_rdata)
    );


endmodule
