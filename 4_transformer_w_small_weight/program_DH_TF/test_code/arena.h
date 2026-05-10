/////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                        //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
////////////////////////////////////////////////////////////////////////////////*/


#ifndef STATIC_ARENA_H
#define STATIC_ARENA_H

#include <stdint.h>

#ifndef ARENA_SIZE_BYTES
#define ARENA_SIZE_BYTES (256u * 1024u)
#endif

extern uint8_t g_arena_buf[ARENA_SIZE_BYTES];
extern uint32_t g_arena_off;

void arena_reset(void);
void *arena_alloc(uint32_t size, uint32_t align_pow2);

#endif
