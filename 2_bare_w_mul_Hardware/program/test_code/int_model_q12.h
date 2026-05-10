/////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                        //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
////////////////////////////////////////////////////////////////////////////////*/


#ifndef INT_MODEL_Q12_H
#define INT_MODEL_Q12_H

#include <stdint.h>

/* Auto-generated from integer checkpoint (.pt) */
#define MODEL_Q_BITS 12
#define MODEL_NUM_LAYERS 2
#define MODEL_HID_SIZE 128
#define MODEL_X_MAX_Q 32768
#define MODEL_ENC_EMB_DIM 128
#define MODEL_DEC_EMB_DIM 128
#define MODEL_SRC_VOCAB 7876
#define MODEL_TGT_VOCAB 5897
#define MODEL_LUT_SIZE 4097

extern const int32_t enc_layer_in_dims[2];
extern const int32_t dec_layer_in_dims[2];
extern const int32_t enc_emb_q[1008128];
extern const int32_t dec_emb_q[754816];
extern const int32_t enc_w_ih_offsets[3];
extern const int32_t enc_w_hh_offsets[3];
extern const int32_t enc_b_offsets[3];
extern const int32_t dec_w_ih_offsets[3];
extern const int32_t dec_w_hh_offsets[3];
extern const int32_t dec_b_offsets[3];
extern const int32_t enc_w_ih_q[131072];
extern const int32_t enc_w_hh_q[131072];
extern const int32_t enc_b_q[1024];
extern const int32_t dec_w_ih_q[131072];
extern const int32_t dec_w_hh_q[131072];
extern const int32_t dec_b_q[1024];
extern const int32_t out_w_q[754816];
extern const int32_t out_b_q[5897];
extern const int32_t sigmoid_lut_q[4097];
extern const int32_t tanh_lut_q[4097];

#endif /* INT_MODEL_Q12_H */
