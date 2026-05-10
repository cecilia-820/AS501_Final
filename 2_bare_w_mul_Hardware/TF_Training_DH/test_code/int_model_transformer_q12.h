////////////////////////////////////////////////////////////////////////////////
// AS501/AS603
// Final Project — Transformer Weight Declarations (Q12 Fixed-Point)
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by [Your Name]
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
////////////////////////////////////////////////////////////////////////////////
// Auto-generated from transformer checkpoint (.pt) via make export
// Quantization: Q12 (scaling factor Q = 2^12 = 4096)
////////////////////////////////////////////////////////////////////////////////

#ifndef INT_MODEL_TRANSFORMER_Q12_H
#define INT_MODEL_TRANSFORMER_Q12_H

#include <stdint.h>

////////////////////////////////////////////////////////////////////////////////
// Quantization parameters
////////////////////////////////////////////////////////////////////////////////
#define MODEL_Q_BITS        12
#define MODEL_Q_SCALE       (1 << MODEL_Q_BITS)   /* 4096 */

////////////////////////////////////////////////////////////////////////////////
// Model hyper-parameters
////////////////////////////////////////////////////////////////////////////////
#define TF_D_MODEL          128
#define TF_N_HEADS          4
#define TF_D_HEAD           (TF_D_MODEL / TF_N_HEADS)  /* 32 */
#define TF_D_FF             256
#define TF_N_ENC_LAYERS     2
#define TF_N_DEC_LAYERS     2
#define TF_MAX_SRC_LEN      40
#define TF_MAX_TGT_LEN      40

/* 1/sqrt(d_head) = 1/sqrt(32) ≈ 0.1768; in Q12: 0.1768 * 4096 ≈ 724 */
#define TF_ATTN_SCALE_Q     724

/* Layer norm epsilon: 1e-5 represented in Q12 units (use 1 as floor) */
#define TF_LN_EPS_Q         1

////////////////////////////////////////////////////////////////////////////////
// Vocabulary sizes (shared with LSTM version)
////////////////////////////////////////////////////////////////////////////////
#define MODEL_SRC_VOCAB     7876
#define MODEL_TGT_VOCAB     5897

////////////////////////////////////////////////////////////////////////////////
// Softermax constants (replaces exp LUT — no large table needed)
// Base-2 exponential: 2^x decomposed as barrel_shift + linear_interp
// See eval_transformer_q.c: pow2_neg_q12()
////////////////////////////////////////////////////////////////////////////////
/* Maximum negative shift before underflow (2^-12 < 1 in Q12) */
#define TF_POW2_MIN_SHIFT   12

////////////////////////////////////////////////////////////////////////////////
// Positional encoding table (pre-computed sinusoidal, Q12)
// Layout: [TF_MAX_SRC_LEN × TF_D_MODEL]
////////////////////////////////////////////////////////////////////////////////
extern const int32_t pos_enc_q[TF_MAX_SRC_LEN * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Token embedding tables (shared format with LSTM version)
////////////////////////////////////////////////////////////////////////////////
extern const int32_t enc_emb_q[MODEL_SRC_VOCAB * TF_D_MODEL]; /* 7876 × 128 */
extern const int32_t dec_emb_q[MODEL_TGT_VOCAB * TF_D_MODEL]; /* 5897 × 128 */

////////////////////////////////////////////////////////////////////////////////
// Output projection (shared format with LSTM version)
////////////////////////////////////////////////////////////////////////////////
extern const int32_t out_w_q[MODEL_TGT_VOCAB * TF_D_MODEL];   /* 5897 × 128 */
extern const int32_t out_b_q[MODEL_TGT_VOCAB];                 /* 5897        */

////////////////////////////////////////////////////////////////////////////////
// Encoder — Self-Attention weights
// Layout per layer: [TF_D_MODEL × TF_D_MODEL]
// Total: TF_N_ENC_LAYERS × TF_D_MODEL × TF_D_MODEL = 2 × 128 × 128 = 32768
////////////////////////////////////////////////////////////////////////////////
extern const int32_t enc_attn_Wq_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bq_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_attn_Wk_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bk_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_attn_Wv_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bv_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_attn_Wo_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bo_q[TF_N_ENC_LAYERS * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Encoder — Feed-Forward Network weights
// W1: [TF_D_FF × TF_D_MODEL], W2: [TF_D_MODEL × TF_D_FF]
////////////////////////////////////////////////////////////////////////////////
extern const int32_t enc_ff1_W_q[TF_N_ENC_LAYERS * TF_D_FF    * TF_D_MODEL];
extern const int32_t enc_ff1_b_q[TF_N_ENC_LAYERS * TF_D_FF];
extern const int32_t enc_ff2_W_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_FF];
extern const int32_t enc_ff2_b_q[TF_N_ENC_LAYERS * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Encoder — Layer Norm parameters (Pre-LN, 2 norms per layer)
////////////////////////////////////////////////////////////////////////////////
extern const int32_t enc_ln1_gamma_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ln1_beta_q [TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ln2_gamma_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ln2_beta_q [TF_N_ENC_LAYERS * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Encoder — Final Layer Norm (applied after all encoder layers)
////////////////////////////////////////////////////////////////////////////////
extern const int32_t enc_final_ln_gamma_q[TF_D_MODEL];
extern const int32_t enc_final_ln_beta_q [TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Decoder — Causal Self-Attention weights
////////////////////////////////////////////////////////////////////////////////
extern const int32_t dec_self_Wq_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bq_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_self_Wk_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bk_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_self_Wv_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bv_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_self_Wo_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bo_q[TF_N_DEC_LAYERS * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Decoder — Cross-Attention weights (query=decoder, key/value=encoder)
////////////////////////////////////////////////////////////////////////////////
extern const int32_t dec_cross_Wq_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bq_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_cross_Wk_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bk_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_cross_Wv_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bv_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_cross_Wo_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bo_q[TF_N_DEC_LAYERS * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Decoder — Feed-Forward Network weights
////////////////////////////////////////////////////////////////////////////////
extern const int32_t dec_ff1_W_q[TF_N_DEC_LAYERS * TF_D_FF    * TF_D_MODEL];
extern const int32_t dec_ff1_b_q[TF_N_DEC_LAYERS * TF_D_FF];
extern const int32_t dec_ff2_W_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_FF];
extern const int32_t dec_ff2_b_q[TF_N_DEC_LAYERS * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Decoder — Layer Norm parameters (Pre-LN, 3 norms per layer)
////////////////////////////////////////////////////////////////////////////////
extern const int32_t dec_ln1_gamma_q[TF_N_DEC_LAYERS * TF_D_MODEL]; /* self-attn  */
extern const int32_t dec_ln1_beta_q [TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln2_gamma_q[TF_N_DEC_LAYERS * TF_D_MODEL]; /* cross-attn */
extern const int32_t dec_ln2_beta_q [TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln3_gamma_q[TF_N_DEC_LAYERS * TF_D_MODEL]; /* ffn        */
extern const int32_t dec_ln3_beta_q [TF_N_DEC_LAYERS * TF_D_MODEL];

////////////////////////////////////////////////////////////////////////////////
// Decoder — Final Layer Norm
////////////////////////////////////////////////////////////////////////////////
extern const int32_t dec_final_ln_gamma_q[TF_D_MODEL];
extern const int32_t dec_final_ln_beta_q [TF_D_MODEL];

#endif /* INT_MODEL_TRANSFORMER_Q12_H */
