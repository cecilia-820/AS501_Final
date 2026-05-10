/////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                        //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
////////////////////////////////////////////////////////////////////////////////*/


#include "result.h"

__attribute__((section(".result"), aligned(4)))
uint32_t result_status = 0u;

__attribute__((section(".result"), aligned(4)))
uint32_t result_sentence_count = 0u;

__attribute__((section(".result"), aligned(4)))
uint32_t result_used_u32 = 0u;

__attribute__((section(".result"), aligned(4)))
uint32_t result_data[RESULT_U32_CAP];
