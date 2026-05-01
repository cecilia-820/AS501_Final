##################################################################################
## AS501/AS603                                                                        ##
## START ASM                                                                    ##
##################################################################################
## Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       ##
## All rights reserved.                                                         ##
##                                                                              ##
##                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) ##
##                                       Minyoung Choi    (myconejo@kaist.ac.kr)##
##                                       JeongSeop Park   (eddie020@kaist.ac.kr)##
##                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)##
##################################################################################

    .section .text
    .global _start
    .extern main

_start:
  # ---------------------------------------------------
  # Set stack pointer (top of DATARAM)
  # ---------------------------------------------------
  lui x2, %hi(_estack)
  addi x2, x2, %lo(_estack)

  # ---------------------------------------------------
  # Set global pointer (RISC-V small data model)
  # ---------------------------------------------------
  lui gp, %hi(__global_pointer$)
  addi gp, gp, %lo(__global_pointer$)

  # ---------------------------------------------------
  # Zero .bss
  # ---------------------------------------------------
  lui a0, %hi(_sbss)
  addi a0, a0, %lo(_sbss)
  lui a1, %hi(_ebss)
  addi a1, a1, %lo(_ebss)
  li  t1, 0

clear_bss:
  bge a0, a1, clear_bss_done
  sw  t1, 0(a0)
  addi a0, a0, 4
  j   clear_bss
clear_bss_done:

  # ---------------------------------------------------
  # Call main
  # ---------------------------------------------------
  call main

  # If main returns, loop forever
hang:
  j hang