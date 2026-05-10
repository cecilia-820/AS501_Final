/////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                        //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
////////////////////////////////////////////////////////////////////////////////*/


#include "arena.h"

uint8_t g_arena_buf[ARENA_SIZE_BYTES]; //256*1024bit
uint32_t g_arena_off = 0u;

void arena_reset(void) {
    g_arena_off = 0u;
}

void *arena_alloc(uint32_t size, uint32_t align_pow2) {
    if (align_pow2 == 0u) align_pow2 = 1u;
    uint32_t mask = align_pow2 - 1u;
    uint32_t off = (g_arena_off + mask) & (~mask);
    uint32_t next = off + size;
    if (next < off) return 0;
    if (next > ARENA_SIZE_BYTES) return 0;
    g_arena_off = next;
    return (void *)(g_arena_buf + off);
}
