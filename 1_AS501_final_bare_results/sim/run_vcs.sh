#!/bin/bash
################################################################################
## AS501/AS603
## Final Project
## Run VCS Simulation Script
##################################################################################
## Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       ##
## All rights reserved.                                                         ##
##                                                                              ##
##                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) ##
##                                       Minyoung Choi    (myconejo@kaist.ac.kr)##
##                                       JeongSeop Park   (eddie020@kaist.ac.kr)##
##                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)##
##################################################################################

################################################################################
## Don't touch
##
    THIS_SCRIPT_DIR="$(realpath "$(dirname "$BASH_SOURCE")")"
    RTL_DIR="$THIS_SCRIPT_DIR/../rtl"
    TB_DIR="$THIS_SCRIPT_DIR/tb"
    OUT_DIR="./out"

    if [ -n "$OUT_DIR" ]; then
        if [ -d "$OUT_DIR" ]; then
            # Clean the output directory
            rm -rf $OUT_DIR/*
        else
            # Make an output directory
            mkdir -p $OUT_DIR
        fi
    else
        echo "set OUT_DIR variable"
    fi

    # Make log file
    cd $OUT_DIR
    TIME=$(date +%Y-%m-%d_%H:%M)
    touch $TIME.txt
##
################################################################################

################################################################################
## Modify to fit your source file names
##
    # Simulated rtl list
    RTL_LIST="$TB_DIR/lstm_tb.sv                               \
              $RTL_DIR/common/core_package.sv                  \
              $RTL_DIR/common/d_flip_flop.sv                   \
              $RTL_DIR/common/mux2to1.sv                       \
              $RTL_DIR/common/mux3to1.sv                       \
              $RTL_DIR/common/mux4to1.sv                       \
              $RTL_DIR/common/mux5to1.sv                       \
              $RTL_DIR/common/counter.sv                       \
              $RTL_DIR/memory/I_memory.sv                     \
              $RTL_DIR/memory/D_memory.sv                     \
              $RTL_DIR/memory/IO_memory.sv                     \
              /technology/TSMC_28nm_HPC_RF/SRAM/tsn28hpcpd127spsram_20120200_180a/TSMCHOME/sram/Output/ts5n28hpcphvta512x54m4f_tt1v25c/ts5n28hpcphvta512x54m4f_tt1v25c.v \
              $RTL_DIR/cache/submodule/cache_sram.sv           \
              $RTL_DIR/cache/instr_cache.sv                    \
              $RTL_DIR/scalar_core/alu.sv                      \
              $RTL_DIR/scalar_core/csr.sv                      \
              $RTL_DIR/scalar_core/decoder.sv                  \
              $RTL_DIR/scalar_core/regfile.sv                  \
              $RTL_DIR/scalar_core/mcu.sv              \
              $RTL_DIR/scalar_core/scalar_core.sv              \
              $RTL_DIR/cpu_top.sv"

    # Timescale
    TIMESCALE="1ns/1ps"
##
################################################################################

################################################################################
## Modify as needed
##
#Run vcs
    vcs -fgp                    \
        -full64                 \
        -sverilog $RTL_LIST     \
        -timescale=$TIMESCALE   \
        +incdir+$DC/dw/sim_ver  \
        +define+SIM             \
        -debug_access+all       \
        -kdb                    \
        -pcmakeprof        \
        -l vcs.log
    ./simv -fgp=num_threads:16 -fgp=num_fsdb_threads:16 -fgp=fsdb_adjust_cores | tee vcs_sim.log
##
################################################################################
