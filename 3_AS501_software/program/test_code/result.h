/////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                        //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
////////////////////////////////////////////////////////////////////////////////*/


#ifndef AS501_RESULT_H
#define AS501_RESULT_H

#include <stdint.h>
#include "input_data.h"

#define RISCV_MAX_LEN 80
#define RESULT_U32_CAP (INPUT_SENT_COUNT * (RISCV_MAX_LEN + 1))

extern uint32_t result_status;
extern uint32_t result_sentence_count;
extern uint32_t result_used_u32;
extern uint32_t result_data[RESULT_U32_CAP];

#endif
