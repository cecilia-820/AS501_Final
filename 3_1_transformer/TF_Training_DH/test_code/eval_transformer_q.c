////////////////////////////////////////////////////////////////////////////////
// AS501/AS603
// Final Project — Seq2Seq Transformer Inference (Q12 Fixed-Point)
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by [Your Name]
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
////////////////////////////////////////////////////////////////////////////////
// Architecture: Encoder-Decoder Transformer (Pre-LayerNorm variant)
//   Encoder: TF_N_ENC_LAYERS × (Self-Attention + FFN)
//   Decoder: TF_N_DEC_LAYERS × (Causal Self-Attention + Cross-Attention + FFN)
//   Decoding: Greedy (argmax, softmax omitted at output — same as LSTM)
//
// Key difference from LSTM (eval_int_c.c):
//   [NEW]  softmax_q12()     — required for attention weights (cannot be skipped)
//   [NEW]  layer_norm_q12()  — Pre-LN normalization
//   [NEW]  matmul_q12()      — sequence-level matrix multiply
//   [NEW]  scaled_dot_product_attention()
//   [NEW]  multi_head_attention()
//   [NEW]  feed_forward()
//   [SAME] embedding_lookup(), linear_out_argmax() — greedy: no softmax needed
//   [SAME] arena allocator, result buffer, main() structure
//
// Memory budget (ARENA_SIZE_BYTES must be >= 256 KB):
//   See init_static_buffers() for full breakdown (~230 KB)
////////////////////////////////////////////////////////////////////////////////

#include <stdint.h>
#include <stddef.h>

#ifdef SERVER
#  include <stdio.h>
#  include <stdlib.h>
#  include <string.h>
#endif

#include "int_model_transformer_q12.h"
#include "input_data.h"
#include "arena.h"
#include "result.h"

#if !defined(SERVER) && !defined(RISCV)
#  define SERVER
#endif

////////////////////////////////////////////////////////////////////////////////
// Compile-time constants
////////////////////////////////////////////////////////////////////////////////
#define MAX_LEN                 TF_MAX_TGT_LEN   /* max generated tokens = 40  */

#ifndef MAX_SENTENCES_OVERRIDE
#  define MAX_SENTENCES_OVERRIDE 0
#endif

/* Output paths (SERVER mode) */
#define DEFAULT_OUT_HYP             "./processed/val.hyp.tf_q.u32bin"
#define DEFAULT_OUT_RESULT_TXT      "./processed/val.result_mem.tf_q.txt"
#define DEFAULT_OUT_RESULT_SUMMARY  "./processed/val.result_summary.tf_q.txt"

/* head_scratch size: holds Q_h/K_h/V_h/A_h per head
 * = 4 × max_seq_len × TF_D_HEAD int32s
 * = 4 × 40 × 32 = 5120 int32 = 20 KB                                        */
#define HEAD_SCRATCH_WORDS      (4 * TF_MAX_SRC_LEN * TF_D_HEAD)

////////////////////////////////////////////////////////////////////////////////
// Types
////////////////////////////////////////////////////////////////////////////////
typedef struct { uint32_t lo; uint32_t hi; } I64Pair;

#ifdef SERVER
typedef struct {
    const char *out_hyp;
    const char *out_result_txt;
    const char *out_result_summary;
    int         max_sentences;
} Args;
#endif

////////////////////////////////////////////////////////////////////////////////
// Arena-allocated runtime buffers
////////////////////////////////////////////////////////////////////////////////
/* Encoder */
static int32_t *g_enc_out;       /* [TF_MAX_SRC_LEN × TF_D_MODEL]          */
/* Decoder */
static int32_t *g_dec_buf;       /* [TF_MAX_TGT_LEN × TF_D_MODEL]          */
/* Projection scratch (Q / K / V) */
static int32_t *g_q_buf;         /* [TF_MAX_SRC_LEN × TF_D_MODEL]          */
static int32_t *g_k_buf;         /* [TF_MAX_SRC_LEN × TF_D_MODEL]          */
static int32_t *g_v_buf;         /* [TF_MAX_SRC_LEN × TF_D_MODEL]          */
/* Attention output / FFN output (shared, not live simultaneously) */
static int32_t *g_attn_out;      /* [TF_MAX_SRC_LEN × TF_D_MODEL]          */
/* Attention scores */
static int32_t *g_score_buf;     /* [TF_MAX_SRC_LEN × TF_MAX_SRC_LEN]      */
/* FFN intermediate */
static int32_t *g_ffn_mid;       /* [TF_MAX_SRC_LEN × TF_D_FF]             */
/* Layer norm scratch */
static int32_t *g_norm_buf;      /* [TF_MAX_SRC_LEN × TF_D_MODEL]          */
/* Per-head scratch: Q_h, K_h, V_h, A_h stacked */
static int32_t *g_head_scratch;  /* [HEAD_SCRATCH_WORDS]                    */
/* Output token buffer */
static uint32_t *g_out_ids;      /* [TF_MAX_TGT_LEN]                        */

/* Causal mask — small enough for BSS (not arena) */
static uint8_t g_causal_mask[TF_MAX_TGT_LEN * TF_MAX_TGT_LEN]; /* 1600 B  */

/* Counters */
static uint32_t g_result_used_cursor = 0u;
static uint32_t g_tf_dec_steps       = 0u;

////////////////////////////////////////////////////////////////////////////////
// Trace event IDs (matched to lstm_tb.sv TRACE_FUNC monitoring)
////////////////////////////////////////////////////////////////////////////////
enum {
    TRACE_EV_MAIN_ENTER     = 1,
    TRACE_EV_INIT_OK        = 2,
    TRACE_EV_SENTENCE_BEGIN = 3,
    TRACE_EV_ENC_DONE       = 4,
    TRACE_EV_DEC_STEP       = 5,
    TRACE_EV_SENTENCE_DONE  = 6,
    TRACE_EV_MAIN_EXIT      = 7
};

static void trace_push(uint32_t ev, uint32_t a, uint32_t b, uint32_t c) {
#ifdef SERVER
    (void)b; (void)c;
    switch (ev) {
        case TRACE_EV_MAIN_ENTER:
            printf("[TF][trace] main enter  (sentences=%u)\n", a);   break;
        case TRACE_EV_INIT_OK:
            printf("[TF][trace] buffers OK\n");                       break;
        case TRACE_EV_SENTENCE_BEGIN:
            printf("[TF][trace] sentence %u begin\n", a);             break;
        case TRACE_EV_ENC_DONE:
            printf("[TF][trace] encoder done (src_len=%u)\n", a);     break;
        case TRACE_EV_DEC_STEP:
            printf("[TF][trace] decoder step %u\n", a);               break;
        case TRACE_EV_SENTENCE_DONE:
            printf("[TF][trace] sentence done (out_len=%u)\n", a);    break;
        case TRACE_EV_MAIN_EXIT:
            printf("[TF][trace] main exit  (decoded=%u)\n", a);       break;
        default: break;
    }
#else
    (void)ev; (void)a; (void)b; (void)c;
#endif
}

////////////////////////////////////////////////////////////////////////////////
// Integer utility (unchanged from eval_int_c.c)
////////////////////////////////////////////////////////////////////////////////

static uint32_t udiv32_sub(uint32_t num, uint32_t den) {
    if (den == 0u) return 0xffffffffu;
    uint32_t q = 0u, r = 0u;
    for (int i = 31; i >= 0; --i) {
        r = (r << 1) | ((num >> i) & 1u);
        if (r >= den) { r -= den; q |= (1u << i); }
    }
    return q;
}

static I64Pair i64_add(I64Pair a, I64Pair b) {
    I64Pair r;
    r.lo = a.lo + b.lo;
    r.hi = a.hi + b.hi + (r.lo < a.lo ? 1u : 0u);
    return r;
}

static I64Pair i64_neg(I64Pair v) {
    I64Pair r;
    r.lo = ~v.lo + 1u;
    r.hi = ~v.hi + (r.lo == 0u ? 1u : 0u);
    return r;
}

static I64Pair i64_mul_i32(int32_t a, int32_t b) {
    int neg = 0;
    uint32_t ua = (a < 0) ? (neg ^= 1, (~(uint32_t)a) + 1u) : (uint32_t)a;
    uint32_t ub = (b < 0) ? (neg ^= 1, (~(uint32_t)b) + 1u) : (uint32_t)b;
    uint32_t ah = ua >> 16, al = ua & 0xffffu;
    uint32_t bh = ub >> 16, bl = ub & 0xffffu;
    uint32_t p0 = al * bl, p1 = al * bh, p2 = ah * bl, p3 = ah * bh;
    uint32_t lo = p0;
    uint32_t hi = p3 + (p1 >> 16) + (p2 >> 16);
    uint32_t old_lo = lo;
    lo += (p1 << 16);
    if (lo < old_lo) hi++;
    old_lo = lo;
    lo += (p2 << 16);
    if (lo < old_lo) hi++;
    I64Pair r = {lo, hi};
    return neg ? i64_neg(r) : r;
}

static int32_t i64_sar_to_i32(I64Pair v, int bits) {
    if (bits <= 0)  return (int32_t)v.lo;
    if (bits >= 32) return ((int32_t)v.hi) >> (bits - 32);
    return (int32_t)((v.lo >> bits) | (v.hi << (32 - bits)));
}

static int32_t mul_shift_q(int32_t a, int32_t b, int q) {
    return i64_sar_to_i32(i64_mul_i32(a, b), q);
}

static int32_t dot_shift_q(const int32_t *a, const int32_t *b, int len, int q) {
    I64Pair acc = {0u, 0u};
    for (int i = 0; i < len; ++i)
        acc = i64_add(acc, i64_mul_i32(a[i], b[i]));
    return i64_sar_to_i32(acc, q);
}

/* Integer square root (Newton-Raphson) */
static uint32_t isqrt32(uint32_t n) {
    if (n == 0u) return 0u;
    uint32_t x = n, y = (x + 1u) >> 1;
    while (y < x) { x = y; y = (x + udiv32_sub(n, x)) >> 1; }
    return x;
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] pow2_neg_q12 — base-2 exponential for softermax
//
// Computes 2^(x_q / Q_SCALE) in Q12 format, where x_q ≤ 0.
//
// Hardware decomposition (Softermax key idea):
//   x = -n - f   where n = integer part (≥ 0), f = fraction ∈ [0, 1)
//   2^x = 2^(-n) × 2^(-f)
//         └─ barrel shift (free!) └─ linear interpolation
//
// Linear approximation of 2^(-f) for f ∈ [0, 1):
//   f=0 → 2^0  = 1.0  → Q_SCALE       (exact)
//   f=1 → 2^-1 = 0.5  → Q_SCALE/2     (exact)
//   linear: Q_SCALE - frac_q/2
//   Max error ≈ 6% at f=0.5 (2^-0.5 ≈ 0.707, approx = 0.75)
//   → acceptable for attention weight computation
//
// Advantage over exp() LUT:
//   - No large LUT table (4097 entries) required
//   - 2^(-n) = right shift by n bits (1 cycle on any hardware)
//   - 2^(-f) = one subtraction + one right shift
//   - Total: ~5 integer ops vs. LUT + udiv32
////////////////////////////////////////////////////////////////////////////////
static int32_t pow2_neg_q12(int32_t x_q) {
    if (x_q >= 0)                                 return MODEL_Q_SCALE; /* 2^0  = 1.0 */
    if (x_q < -(12 * (int32_t)MODEL_Q_SCALE))    return 0;             /* underflow  */

    /* Split |x_q| into integer part n and Q12-fractional part frac_q */
    uint32_t abs_xq = (uint32_t)(-x_q);
    uint32_t n      = abs_xq >> MODEL_Q_BITS;                          /* n ∈ [0, 12) */
    uint32_t frac_q = abs_xq & (uint32_t)(MODEL_Q_SCALE - 1u);        /* frac ∈ [0, Q) */

    /* 2^(-f) ≈ Q_SCALE - frac_q/2   (linear interp between 1.0 and 0.5) */
    int32_t pow2_neg_frac = (int32_t)MODEL_Q_SCALE - (int32_t)(frac_q >> 1u);

    /* 2^(-n) via barrel shift: pow2_neg_frac >> n */
    return pow2_neg_frac >> (int)n;
}

////////////////////////////////////////////////////////////////////////////////
// q12_ceil_to_int — integer exponent used by streaming softermax
//
// The online Softermax structure updates the denominator with
//   d <- (d >> (m_j - m_{j-1})) + 2^(x_j - m_j)
// so m_j must be an integer exponent. Scores are Q12, therefore we use
// ceil(score / Q_SCALE). This guarantees x_j - m_j <= 0.
////////////////////////////////////////////////////////////////////////////////
static int32_t q12_ceil_to_int(int32_t x_q) {
    if (x_q >= 0)
        return (int32_t)(((uint32_t)x_q +
                          (uint32_t)MODEL_Q_SCALE - 1u) >> MODEL_Q_BITS);

    /* For negative values: ceil(-a / Q) = -(a >> MODEL_Q_BITS). */
    uint32_t abs_xq = (~(uint32_t)x_q) + 1u;
    return -(int32_t)(abs_xq >> MODEL_Q_BITS);
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] softermax_q12  (Streaming / hardware-friendly Softermax)
////////////////////////////////////////////////////////////////////////////////
static void softermax_q12(const int32_t *scores, int32_t *weights, int len) {
    if (len <= 0) return;

    /* Attention row length is bounded by TF_MAX_SRC_LEN / TF_MAX_TGT_LEN (=40). */
    int32_t m_hist[TF_MAX_SRC_LEN];

    uint32_t d = 0u;          /* denominator in Q12 scale */
    int32_t  m = 0;           /* running integer max exponent */
    int      m_valid = 0;

    /* Pass 1: online max + denominator update + unnormalized y_i storage. */
    for (int i = 0; i < len; ++i) {
        int32_t x_int = q12_ceil_to_int(scores[i]);
        int32_t m_new = (!m_valid || x_int > m) ? x_int : m;

        if (m_valid && m_new > m) {
            int32_t delta = m_new - m;
            d = (delta >= 32) ? 0u : (d >> delta);
        }

        m = m_new;
        m_valid = 1;

        int32_t m_q   = m << MODEL_Q_BITS;
        int32_t y_q12 = pow2_neg_q12(scores[i] - m_q);

        weights[i] = y_q12;
        m_hist[i]  = m;
        d         += (uint32_t)y_q12;
    }

    if (d == 0u) d = 1u;

    /* Pass 2: correct each y_i to final max m_V, then normalize. */
    for (int i = 0; i < len; ++i) {
        int32_t delta = m - m_hist[i];
        uint32_t corrected = (delta >= 32) ? 0u
                             : ((uint32_t)weights[i] >> delta);

        weights[i] = (int32_t)udiv32_sub(
            corrected * (uint32_t)MODEL_Q_SCALE, d);
    }
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] layer_norm_q12 (Pre-LayerNorm variant)
//
// Computes: out = gamma * (x - mean) / std + beta
// All values in Q12 format.
////////////////////////////////////////////////////////////////////////////////
static void layer_norm_q12(const int32_t *x,  int32_t *out,
                            const int32_t *gamma, const int32_t *beta,
                            int dim) {
    /* Mean */
    I64Pair sum_acc = {0u, 0u};
    for (int i = 0; i < dim; ++i)
        sum_acc = i64_add(sum_acc, i64_mul_i32(x[i], 1));
    int32_t raw_sum = i64_sar_to_i32(sum_acc, 0);
    int     neg_sum = (raw_sum < 0);
    uint32_t u_sum  = neg_sum ? (~(uint32_t)raw_sum + 1u) : (uint32_t)raw_sum;
    u_sum           = udiv32_sub(u_sum, (uint32_t)dim);
    int32_t mean    = neg_sum ? -(int32_t)u_sum : (int32_t)u_sum;

    /* Variance: E[(x - mean)^2]  →  result is Q24 (x is Q12, diff^2 is Q24) */
    I64Pair var_acc = {0u, 0u};
    for (int i = 0; i < dim; ++i) {
        int32_t d = x[i] - mean;
        var_acc   = i64_add(var_acc, i64_mul_i32(d, d));
    }
    /* var_acc in Q24; shift right 12 to get Q12, then divide by dim */
    int32_t  var_q12  = i64_sar_to_i32(var_acc, 12);
    uint32_t uvar     = (var_q12 < 0) ? 0u : (uint32_t)var_q12;
    uvar              = udiv32_sub(uvar, (uint32_t)dim);

    /* std = sqrt(var) in Q12; add epsilon to avoid divide-by-zero
     * uvar is Q12: variance_real = uvar / Q_SCALE.
     * We need std_q12 = sqrt(variance_real) * Q_SCALE
     *                  = sqrt(uvar / Q_SCALE) * Q_SCALE
     *                  = sqrt(uvar * Q_SCALE)
     *                  = isqrt32(uvar << MODEL_Q_BITS)                       */
    uint32_t std_q12  = isqrt32(uvar << MODEL_Q_BITS) + (uint32_t)TF_LN_EPS_Q;
    if (std_q12 == 0u) std_q12 = 1u;

    /* Normalize and affine transform */
    for (int i = 0; i < dim; ++i) {
        int32_t  d     = x[i] - mean;
        int      neg_d = (d < 0);
        uint32_t ud    = neg_d ? (~(uint32_t)d + 1u) : (uint32_t)d;
        /* (d << 12) / std to keep Q12 precision */
        uint32_t norm_u = udiv32_sub(ud << 12, std_q12);
        int32_t  norm   = neg_d ? -(int32_t)norm_u : (int32_t)norm_u;
        out[i]          = mul_shift_q(gamma[i], norm, MODEL_Q_BITS) + beta[i];
    }
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] Matrix multiply: C[M×N] = A[M×K] × B^T[N×K]   (Q12)
// B stored row-major as [N×K]: each row is an output neuron's weight vector.
////////////////////////////////////////////////////////////////////////////////
static void matmul_q12(const int32_t *A, const int32_t *Bt,
                        int32_t *C,
                        int M, int K, int N) {
    for (int m = 0; m < M; ++m)
        for (int n = 0; n < N; ++n)
            C[m * N + n] = dot_shift_q(A + m * K, Bt + n * K, K, MODEL_Q_BITS);
}

/* Add bias[N] to each of M rows in X[M×N] */
static void add_bias_rows(int32_t *X, const int32_t *bias, int M, int N) {
    for (int m = 0; m < M; ++m)
        for (int n = 0; n < N; ++n)
            X[m * N + n] += bias[n];
}

/* dst[i] += src[i] for len elements (residual connection) */
static void add_residual(int32_t *dst, const int32_t *src, int len) {
    for (int i = 0; i < len; ++i) dst[i] += src[i];
}

static void i32_copy(int32_t *dst, const int32_t *src, int len) {
    for (int i = 0; i < len; ++i) dst[i] = src[i];
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] Positional encoding — add pre-computed Q12 sinusoidal table
////////////////////////////////////////////////////////////////////////////////
static void add_positional_encoding(int32_t *x, int seq_len, int d_model) {
    for (int t = 0; t < seq_len; ++t)
        for (int d = 0; d < d_model; ++d)
            x[t * d_model + d] += pos_enc_q[t * d_model + d];
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] ReLU in Q12
////////////////////////////////////////////////////////////////////////////////
static int32_t relu_q12(int32_t x) { return (x > 0) ? x : 0; }

////////////////////////////////////////////////////////////////////////////////
// [SAME] Embedding lookup (identical to eval_int_c.c)
////////////////////////////////////////////////////////////////////////////////
static const int32_t *embedding_lookup(const int32_t *tbl, int vsz,
                                        int dim, int idx) {
    if (idx < 0 || idx >= vsz) idx = 1;
    return tbl + (size_t)idx * (size_t)dim;
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] Scaled Dot-Product Attention
//
//   Attention(Q, K, V) = softmax( Q·K^T / sqrt(d_head) ) · V
//
// Why softmax cannot be skipped here:
//   The output is a weighted average of V rows.
//   Without normalization the weights are unbounded and the average is
//   meaningless. Argmax would pick exactly one V row (hard attention),
//   losing all multi-position context.
//
// mask: uint8_t [q_len × k_len]; mask[i][j]=1 sets score[i][j] = -INF
//       Used for causal (autoregressive) masking in decoder self-attention.
//
// Q_mat  [q_len × TF_D_HEAD]
// K_mat  [k_len × TF_D_HEAD]
// V_mat  [k_len × TF_D_HEAD]
// out    [q_len × TF_D_HEAD]
// score_row_buf [k_len]: temp row buffer for softmax (caller provides)
////////////////////////////////////////////////////////////////////////////////
static void scaled_dot_product_attention(
    const int32_t *Q_mat, int q_len,
    const int32_t *K_mat, int k_len,
    const int32_t *V_mat,
    const uint8_t *mask,
    int32_t       *out,
    int32_t       *score_row_buf   /* scratch [k_len] */
) {
    int dh = TF_D_HEAD;

    for (int i = 0; i < q_len; ++i) {
        /* Compute scaled scores: s[j] = (Q[i] · K[j]) * attn_scale / Q_SCALE */
        for (int j = 0; j < k_len; ++j) {
            int32_t raw = dot_shift_q(Q_mat + i * dh, K_mat + j * dh,
                                       dh, MODEL_Q_BITS);
            int32_t s   = mul_shift_q(raw, TF_ATTN_SCALE_Q, MODEL_Q_BITS);
            /* Apply causal mask: masked positions get -8.0 (≈ -∞ in Q12) */
            score_row_buf[j] = (mask != NULL && mask[i * k_len + j])
                               ? TF_EXP_X_MIN_Q : s;
        }

        /* softermax over k_len scores → attention weights in [0, 1] (Q12)
         * Uses 2^x base (barrel shift) instead of exp(x) LUT             */
        softermax_q12(score_row_buf, score_row_buf, k_len);

        /* Weighted sum: out[i] = sum_j( weight[j] * V[j] ) */
        for (int d = 0; d < dh; ++d) {
            I64Pair acc = {0u, 0u};
            for (int j = 0; j < k_len; ++j)
                acc = i64_add(acc,
                              i64_mul_i32(score_row_buf[j], V_mat[j * dh + d]));
            out[i * dh + d] = i64_sar_to_i32(acc, MODEL_Q_BITS);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] Multi-Head Attention
//
// Splits D_MODEL into TF_N_HEADS independent heads of size TF_D_HEAD,
// runs scaled_dot_product_attention per head, concatenates results,
// then applies the output projection Wo.
//
// x_q  [q_len × D_MODEL]: query source
// x_kv [k_len × D_MODEL]: key/value source (equals x_q for self-attention)
// Wq/Wk/Wv/Wo: [D_MODEL × D_MODEL] weights (row-major: [out_dim × in_dim])
// out  [q_len × D_MODEL]
//
// Scratch buffers supplied by caller (all arena-allocated):
//   Q_mat, K_mat, V_mat: [max_len × D_MODEL]
//   head_scratch        : [HEAD_SCRATCH_WORDS]  — holds Q_h/K_h/V_h/A_h
//   score_row_buf       : [max_len]             — per-row softmax scratch
////////////////////////////////////////////////////////////////////////////////
static void multi_head_attention(
    const int32_t *x_q,  int q_len,
    const int32_t *x_kv, int k_len,
    const int32_t *Wq, const int32_t *bq,
    const int32_t *Wk, const int32_t *bk,
    const int32_t *Wv, const int32_t *bv,
    const int32_t *Wo, const int32_t *bo,
    const uint8_t *mask,
    int32_t       *out,
    int32_t       *Q_mat,
    int32_t       *K_mat,
    int32_t       *V_mat,
    int32_t       *head_scratch,   /* [HEAD_SCRATCH_WORDS]  */
    int32_t       *score_row_buf   /* [max(q_len, k_len)]   */
) {
    int dm = TF_D_MODEL;
    int dh = TF_D_HEAD;
    int nh = TF_N_HEADS;

    /* Project inputs to Q, K, V spaces: [len × D_MODEL] */
    matmul_q12(x_q,  Wq, Q_mat, q_len, dm, dm);
    add_bias_rows(Q_mat, bq, q_len, dm);
    matmul_q12(x_kv, Wk, K_mat, k_len, dm, dm);
    add_bias_rows(K_mat, bk, k_len, dm);
    matmul_q12(x_kv, Wv, V_mat, k_len, dm, dm);
    add_bias_rows(V_mat, bv, k_len, dm);

    /* Process each head; results interleaved into out[t * dm + h*dh .. +dh] */
    for (int h = 0; h < nh; ++h) {
        /* Pointers into head_scratch: Q_h, K_h, V_h, A_h each [len × dh] */
        int32_t *Q_h = head_scratch;
        int32_t *K_h = Q_h + q_len * dh;
        int32_t *V_h = K_h + k_len * dh;
        int32_t *A_h = V_h + k_len * dh;

        /* Extract head h slice from full projections */
        for (int t = 0; t < q_len; ++t)
            for (int d = 0; d < dh; ++d)
                Q_h[t * dh + d] = Q_mat[t * dm + h * dh + d];
        for (int t = 0; t < k_len; ++t)
            for (int d = 0; d < dh; ++d) {
                K_h[t * dh + d] = K_mat[t * dm + h * dh + d];
                V_h[t * dh + d] = V_mat[t * dm + h * dh + d];
            }

        scaled_dot_product_attention(Q_h, q_len, K_h, k_len, V_h,
                                     mask, A_h, score_row_buf);

        /* Write head result back: out[t][h*dh .. (h+1)*dh] = A_h[t] */
        for (int t = 0; t < q_len; ++t)
            for (int d = 0; d < dh; ++d)
                out[t * dm + h * dh + d] = A_h[t * dh + d];
    }

    /* Output projection: out = out × Wo + bo
     * Reuse Q_mat as temporary for the projected result              */
    matmul_q12(out, Wo, Q_mat, q_len, dm, dm);
    add_bias_rows(Q_mat, bo, q_len, dm);
    i32_copy(out, Q_mat, q_len * dm);
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] Position-wise Feed-Forward Network
//
//   FFN(x) = ReLU( x·W1 + b1 ) · W2 + b2
//
// W1: [D_FF    × D_MODEL]  (expand)
// W2: [D_MODEL × D_FF]     (project back)
// mid: scratch [seq_len × D_FF]
////////////////////////////////////////////////////////////////////////////////
static void feed_forward(
    const int32_t *x, int seq_len,
    const int32_t *W1, const int32_t *b1,
    const int32_t *W2, const int32_t *b2,
    int32_t       *out,
    int32_t       *mid            /* scratch [seq_len × TF_D_FF] */
) {
    int dm = TF_D_MODEL, df = TF_D_FF;

    /* Expand: mid = ReLU(x × W1 + b1) */
    matmul_q12(x, W1, mid, seq_len, dm, df);
    add_bias_rows(mid, b1, seq_len, df);
    for (int i = 0; i < seq_len * df; ++i)
        mid[i] = relu_q12(mid[i]);

    /* Project back: out = mid × W2 + b2 */
    matmul_q12(mid, W2, out, seq_len, df, dm);
    add_bias_rows(out, b2, seq_len, dm);
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] One Encoder Layer (Pre-LayerNorm)
//
//   x' = x + MHA( LN(x), LN(x), LN(x) )
//   x  = x' + FFN( LN(x') )
////////////////////////////////////////////////////////////////////////////////
static void encoder_layer(
    int32_t *x, int seq_len, int layer,
    int32_t *Q_mat, int32_t *K_mat, int32_t *V_mat,
    int32_t *attn_out, int32_t *head_scratch,
    int32_t *score_row_buf, int32_t *ffn_mid, int32_t *norm_buf
) {
    int dm = TF_D_MODEL;
    int sz = seq_len * dm;

    /* ── Self-Attention block ── */
    /* LN(x) → norm_buf */
    for (int t = 0; t < seq_len; ++t)
        layer_norm_q12(x + t*dm, norm_buf + t*dm,
                       enc_ln1_gamma_q + layer*dm,
                       enc_ln1_beta_q  + layer*dm, dm);

    /* Multi-head self-attention (no mask in encoder) */
    multi_head_attention(
        norm_buf, seq_len, norm_buf, seq_len,
        enc_attn_Wq_q + layer*dm*dm, enc_attn_bq_q + layer*dm,
        enc_attn_Wk_q + layer*dm*dm, enc_attn_bk_q + layer*dm,
        enc_attn_Wv_q + layer*dm*dm, enc_attn_bv_q + layer*dm,
        enc_attn_Wo_q + layer*dm*dm, enc_attn_bo_q + layer*dm,
        /*mask=*/NULL,
        attn_out, Q_mat, K_mat, V_mat, head_scratch, score_row_buf
    );

    /* Residual: x += attn_out */
    add_residual(x, attn_out, sz);

    /* ── Feed-Forward block ── */
    /* LN(x) → norm_buf */
    for (int t = 0; t < seq_len; ++t)
        layer_norm_q12(x + t*dm, norm_buf + t*dm,
                       enc_ln2_gamma_q + layer*dm,
                       enc_ln2_beta_q  + layer*dm, dm);

    /* FFN */
    feed_forward(norm_buf, seq_len,
                 enc_ff1_W_q + layer*dm*TF_D_FF, enc_ff1_b_q + layer*TF_D_FF,
                 enc_ff2_W_q + layer*TF_D_FF*dm, enc_ff2_b_q + layer*dm,
                 attn_out, ffn_mid);

    /* Residual: x += FFN_out */
    add_residual(x, attn_out, sz);
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] One Decoder Layer (Pre-LayerNorm)
//
//   x' = x   + CausalMHA( LN(x),   LN(x),   LN(x)   )  ← self-attention
//   x''= x'  + CrossMHA ( LN(x'),  enc_out, enc_out  )  ← cross-attention
//   x  = x'' + FFN( LN(x'') )
////////////////////////////////////////////////////////////////////////////////
static void decoder_layer(
    int32_t       *x, int tgt_len,
    const int32_t *enc_out, int src_len,
    int            layer,
    const uint8_t *causal_mask,
    int32_t *Q_mat, int32_t *K_mat, int32_t *V_mat,
    int32_t *attn_out, int32_t *head_scratch,
    int32_t *score_row_buf, int32_t *ffn_mid, int32_t *norm_buf
) {
    int dm = TF_D_MODEL;
    int sz = tgt_len * dm;

    /* ── Causal Self-Attention ── */
    for (int t = 0; t < tgt_len; ++t)
        layer_norm_q12(x + t*dm, norm_buf + t*dm,
                       dec_ln1_gamma_q + layer*dm,
                       dec_ln1_beta_q  + layer*dm, dm);

    multi_head_attention(
        norm_buf, tgt_len, norm_buf, tgt_len,
        dec_self_Wq_q + layer*dm*dm, dec_self_bq_q + layer*dm,
        dec_self_Wk_q + layer*dm*dm, dec_self_bk_q + layer*dm,
        dec_self_Wv_q + layer*dm*dm, dec_self_bv_q + layer*dm,
        dec_self_Wo_q + layer*dm*dm, dec_self_bo_q + layer*dm,
        causal_mask,   /* mask[i][j]=1 if j>i (future tokens) */
        attn_out, Q_mat, K_mat, V_mat, head_scratch, score_row_buf
    );
    add_residual(x, attn_out, sz);

    /* ── Cross-Attention (query = decoder, key/value = encoder output) ── */
    for (int t = 0; t < tgt_len; ++t)
        layer_norm_q12(x + t*dm, norm_buf + t*dm,
                       dec_ln2_gamma_q + layer*dm,
                       dec_ln2_beta_q  + layer*dm, dm);

    multi_head_attention(
        norm_buf, tgt_len,
        enc_out,  src_len,   /* encoder output: fixed key/value */
        dec_cross_Wq_q + layer*dm*dm, dec_cross_bq_q + layer*dm,
        dec_cross_Wk_q + layer*dm*dm, dec_cross_bk_q + layer*dm,
        dec_cross_Wv_q + layer*dm*dm, dec_cross_bv_q + layer*dm,
        dec_cross_Wo_q + layer*dm*dm, dec_cross_bo_q + layer*dm,
        /*mask=*/NULL,   /* no mask: decoder attends to all encoder positions */
        attn_out, Q_mat, K_mat, V_mat, head_scratch, score_row_buf
    );
    add_residual(x, attn_out, sz);

    /* ── Feed-Forward ── */
    for (int t = 0; t < tgt_len; ++t)
        layer_norm_q12(x + t*dm, norm_buf + t*dm,
                       dec_ln3_gamma_q + layer*dm,
                       dec_ln3_beta_q  + layer*dm, dm);

    feed_forward(norm_buf, tgt_len,
                 dec_ff1_W_q + layer*dm*TF_D_FF, dec_ff1_b_q + layer*TF_D_FF,
                 dec_ff2_W_q + layer*TF_D_FF*dm, dec_ff2_b_q + layer*dm,
                 attn_out, ffn_mid);
    add_residual(x, attn_out, sz);
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] Full Encoder Pass
// Produces enc_out[src_len × D_MODEL] from source token IDs.
////////////////////////////////////////////////////////////////////////////////
static void transformer_encode(
    const uint32_t *src_ids, int src_len,
    int32_t *enc_out,
    int32_t *Q_mat, int32_t *K_mat, int32_t *V_mat,
    int32_t *attn_out, int32_t *head_scratch,
    int32_t *score_row_buf, int32_t *ffn_mid, int32_t *norm_buf
) {
    int dm = TF_D_MODEL;

    /* Embedding + positional encoding */
    for (int t = 0; t < src_len; ++t) {
        const int32_t *emb = embedding_lookup(enc_emb_q, MODEL_SRC_VOCAB,
                                               dm, (int)src_ids[t]);
        for (int d = 0; d < dm; ++d) enc_out[t*dm + d] = emb[d];
    }
    add_positional_encoding(enc_out, src_len, dm);

    /* Stack of encoder layers */
    for (int l = 0; l < TF_N_ENC_LAYERS; ++l)
        encoder_layer(enc_out, src_len, l,
                      Q_mat, K_mat, V_mat, attn_out,
                      head_scratch, score_row_buf, ffn_mid, norm_buf);

    /* Final layer norm */
    for (int t = 0; t < src_len; ++t)
        layer_norm_q12(enc_out + t*dm, enc_out + t*dm,
                       enc_final_ln_gamma_q, enc_final_ln_beta_q, dm);
}

////////////////////////////////////////////////////////////////////////////////
// [SAME] linear_out_argmax — greedy output: softmax NOT needed
//
// Reason: argmax(softmax(logits)) == argmax(logits) because softmax is
// monotone. Only the index of the maximum matters, not its probability.
// This saves exp() and division at every decoding step.
////////////////////////////////////////////////////////////////////////////////
static int linear_out_argmax(const int32_t *h_last) {
    int     best_idx = 0;
    int32_t best_val = 0;
    int     inited   = 0;
    for (int v = 0; v < MODEL_TGT_VOCAB; ++v) {
        const int32_t *row = out_w_q + (size_t)v * TF_D_MODEL;
        int32_t val = dot_shift_q(row, h_last, TF_D_MODEL, MODEL_Q_BITS)
                    + out_b_q[v];
        if (!inited || val > best_val) { best_val = val; best_idx = v; inited = 1; }
    }
    return best_idx;
}

////////////////////////////////////////////////////////////////////////////////
// [SAME] publish_partial_result_sequence (unchanged from eval_int_c.c)
////////////////////////////////////////////////////////////////////////////////
static int publish_partial_result_sequence(
    uint32_t base_cursor, uint32_t visible_sent_count,
    const uint32_t *out_ids, int out_len
) {
    if (out_len <= 0 || out_len > MAX_LEN) { result_status = 4u; return -1; }
    uint32_t used = base_cursor + 1u + (uint32_t)out_len;
    if (used > (uint32_t)RESULT_U32_CAP)  { result_status = 3u; return -1; }
    result_data[base_cursor] = (uint32_t)out_len;
    for (int j = 0; j < out_len; ++j)
        result_data[base_cursor + 1u + (uint32_t)j] = out_ids[j];
    result_sentence_count = visible_sent_count;
    result_used_u32       = used;
    return 0;
}

////////////////////////////////////////////////////////////////////////////////
// [NEW] Greedy Decode — Transformer
//
// Step-by-step decoding (re-runs full decoder each step).
// A KV-cache can be added later to avoid re-computing past token attention.
////////////////////////////////////////////////////////////////////////////////
static int greedy_decode_transformer(
    const uint32_t *src_ids, int src_len,
    int bos_id, int eos_id,
    uint32_t *out_ids,
    uint32_t base_cursor, uint32_t visible_sent_count
) {
    int dm = TF_D_MODEL;

    /* ① Encode: run source through encoder once */
    transformer_encode(src_ids, src_len, g_enc_out,
                       g_q_buf, g_k_buf, g_v_buf,
                       g_attn_out, g_head_scratch,
                       g_score_buf, g_ffn_mid, g_norm_buf);
    trace_push(TRACE_EV_ENC_DONE, (uint32_t)src_len, 0u, 0u);

    /* ② Decode: greedy token-by-token */
    int out_len = 0;
    out_ids[out_len++] = (uint32_t)bos_id;
    if (publish_partial_result_sequence(base_cursor, visible_sent_count,
                                        out_ids, out_len) != 0) return -1;

    for (int step = 0; step < MAX_LEN - 1; ++step) {
        int tgt_len = step + 1;
        trace_push(TRACE_EV_DEC_STEP, (uint32_t)step, 0u, 0u);
        g_tf_dec_steps++;

        /* Embed all generated tokens + positional encoding */
        for (int t = 0; t < tgt_len; ++t) {
            const int32_t *emb = embedding_lookup(dec_emb_q, MODEL_TGT_VOCAB,
                                                   dm, (int)out_ids[t]);
            for (int d = 0; d < dm; ++d) g_dec_buf[t*dm + d] = emb[d];
        }
        add_positional_encoding(g_dec_buf, tgt_len, dm);

        /* Build causal mask: mask[i][j] = 1 if j > i (can't attend to future) */
        for (int i = 0; i < tgt_len; ++i)
            for (int j = 0; j < tgt_len; ++j)
                g_causal_mask[i * tgt_len + j] = (uint8_t)(j > i);

        /* Stack of decoder layers */
        for (int l = 0; l < TF_N_DEC_LAYERS; ++l)
            decoder_layer(g_dec_buf, tgt_len, g_enc_out, src_len, l,
                          g_causal_mask,
                          g_q_buf, g_k_buf, g_v_buf,
                          g_attn_out, g_head_scratch,
                          g_score_buf, g_ffn_mid, g_norm_buf);

        /* Final layer norm on last generated position only */
        int32_t norm_last[TF_D_MODEL];
        layer_norm_q12(g_dec_buf + step * dm, norm_last,
                       dec_final_ln_gamma_q, dec_final_ln_beta_q, dm);

        /* Greedy: argmax over vocabulary (no softmax — see comment above) */
        int next_id = linear_out_argmax(norm_last);
        out_ids[out_len++] = (uint32_t)next_id;
        if (publish_partial_result_sequence(base_cursor, visible_sent_count,
                                            out_ids, out_len) != 0) return -1;
        if (next_id == eos_id) break;
    }

    return out_len;
}

////////////////////////////////////////////////////////////////////////////////
// Arena buffer allocation
//
// Memory budget per buffer:
//   g_enc_out     : 40 × 128 × 4 =  20 KB
//   g_dec_buf     : 40 × 128 × 4 =  20 KB
//   g_q_buf       : 40 × 128 × 4 =  20 KB
//   g_k_buf       : 40 × 128 × 4 =  20 KB
//   g_v_buf       : 40 × 128 × 4 =  20 KB
//   g_attn_out    : 40 × 128 × 4 =  20 KB
//   g_score_buf   : 40 ×  40 × 4 =   6 KB
//   g_ffn_mid     : 40 × 256 × 4 =  40 KB
//   g_norm_buf    : 40 × 128 × 4 =  20 KB
//   g_head_scratch: HEAD_SCRATCH_WORDS × 4 = 5120 × 4 = 20 KB
//   g_out_ids     : 40 × 4        =   0.2 KB
//   Total                         ≈ 206 KB  (fits in 256 KB arena)
//   g_causal_mask : 40 × 40       =  1.6 KB (BSS, not arena)
////////////////////////////////////////////////////////////////////////////////
static int init_static_buffers(void) {
    arena_reset();

#define SEQ_ALLOC(seq, dim) \
    (int32_t *)arena_alloc((uint32_t)((seq) * (dim) * sizeof(int32_t)), 8u)

    g_enc_out      = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_D_MODEL);
    g_dec_buf      = SEQ_ALLOC(TF_MAX_TGT_LEN, TF_D_MODEL);
    g_q_buf        = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_D_MODEL);
    g_k_buf        = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_D_MODEL);
    g_v_buf        = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_D_MODEL);
    g_attn_out     = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_D_MODEL);
    g_score_buf    = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_MAX_SRC_LEN);
    g_ffn_mid      = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_D_FF);
    g_norm_buf     = SEQ_ALLOC(TF_MAX_SRC_LEN, TF_D_MODEL);
    g_head_scratch = (int32_t *)arena_alloc(
                         HEAD_SCRATCH_WORDS * sizeof(int32_t), 8u);
    g_out_ids      = (uint32_t *)arena_alloc(
                         MAX_LEN * sizeof(uint32_t), 8u);
#undef SEQ_ALLOC

    if (!g_enc_out || !g_dec_buf || !g_q_buf  || !g_k_buf  ||
        !g_v_buf   || !g_attn_out|| !g_score_buf||!g_ffn_mid||
        !g_norm_buf|| !g_head_scratch || !g_out_ids)
        return -1;
    return 0;
}

static void reset_result_buffer(void) {
    result_status         = 0u;
    result_sentence_count = 0u;
    result_used_u32       = 0u;
    g_result_used_cursor  = 0u;
    g_tf_dec_steps        = 0u;
}

////////////////////////////////////////////////////////////////////////////////
// [SAME structure] main() — RISCV build (runs on hardware, writes to IOMEM)
////////////////////////////////////////////////////////////////////////////////
#ifndef SERVER
int main(void) {
    reset_result_buffer();
    trace_push(TRACE_EV_MAIN_ENTER, INPUT_SENT_COUNT, 0u, 0u);

    if (init_static_buffers() != 0) { result_status = 1u; return 1; }
    trace_push(TRACE_EV_INIT_OK, 0u, 0u, 0u);

    uint32_t limit = INPUT_SENT_COUNT;
    if (MAX_SENTENCES_OVERRIDE > 0 &&
        (uint32_t)MAX_SENTENCES_OVERRIDE < limit)
        limit = (uint32_t)MAX_SENTENCES_OVERRIDE;

    for (uint32_t i = 0; i < limit; ++i) {
        trace_push(TRACE_EV_SENTENCE_BEGIN, i, 0u, 0u);

        uint32_t s0 = input_src_offsets[i];
        uint32_t s1 = input_src_offsets[i + 1u];
        if (s1 < s0) { result_status = 2u; return 1; }

        const uint32_t *src_ids = input_src_data + s0;
        int             src_len = (int)(s1 - s0);
        uint32_t sentence_cursor = g_result_used_cursor;

        int out_len = greedy_decode_transformer(
            src_ids, src_len,
            INPUT_TGT_BOS, INPUT_TGT_EOS,
            g_out_ids, sentence_cursor, i + 1u
        );
        if (out_len <= 0 || out_len > MAX_LEN) { result_status = 4u; return 1; }

        g_result_used_cursor  = sentence_cursor + 1u + (uint32_t)out_len;
        result_used_u32       = g_result_used_cursor;
        result_sentence_count = i + 1u;
        trace_push(TRACE_EV_SENTENCE_DONE, (uint32_t)out_len, i, 0u);
    }

    trace_push(TRACE_EV_MAIN_EXIT, limit, result_sentence_count, 0u);
    return 0;
}

////////////////////////////////////////////////////////////////////////////////
// [SAME structure] main() — SERVER build (host PC, file I/O for validation)
////////////////////////////////////////////////////////////////////////////////
#else
int main(int argc, char **argv) {
    (void)argc; (void)argv;

    Args args = {
        DEFAULT_OUT_HYP,
        DEFAULT_OUT_RESULT_TXT,
        DEFAULT_OUT_RESULT_SUMMARY,
        0
    };

    reset_result_buffer();
    trace_push(TRACE_EV_MAIN_ENTER, INPUT_SENT_COUNT, 0u, 0u);

    if (init_static_buffers() != 0) {
        fprintf(stderr, "[ERROR] Arena alloc failed. "
                        "Increase ARENA_SIZE_BYTES (need ~206 KB).\n");
        result_status = 1u;
        return 1;
    }
    trace_push(TRACE_EV_INIT_OK, 0u, 0u, 0u);

    FILE *fout = fopen(args.out_hyp, "wb");
    if (!fout) { result_status = 5u; return 1; }

    uint32_t limit = INPUT_SENT_COUNT;
    if (args.max_sentences > 0 &&
        (uint32_t)args.max_sentences < limit)
        limit = (uint32_t)args.max_sentences;

    uint32_t decoded = 0u;
    for (uint32_t i = 0; i < limit; ++i) {
        trace_push(TRACE_EV_SENTENCE_BEGIN, i, 0u, 0u);

        uint32_t s0 = input_src_offsets[i];
        uint32_t s1 = input_src_offsets[i + 1u];
        if (s1 < s0) { fclose(fout); result_status = 2u; return 1; }

        const uint32_t *src_ids = input_src_data + s0;
        int             src_len = (int)(s1 - s0);
        uint32_t sentence_cursor = g_result_used_cursor;

        int out_len = greedy_decode_transformer(
            src_ids, src_len,
            INPUT_TGT_BOS, INPUT_TGT_EOS,
            g_out_ids, sentence_cursor, i + 1u
        );
        if (out_len <= 0 || out_len > MAX_LEN) {
            fclose(fout); result_status = 4u; return 1;
        }
        g_result_used_cursor  = sentence_cursor + 1u + (uint32_t)out_len;
        result_used_u32       = g_result_used_cursor;
        result_sentence_count = i + 1u;
        trace_push(TRACE_EV_SENTENCE_DONE, (uint32_t)out_len, i, 0u);

        /* Write output token IDs to binary hypothesis file */
        uint32_t out_len_u32 = (uint32_t)out_len;
        if (fwrite(&out_len_u32, sizeof(uint32_t), 1, fout) != 1 ||
            fwrite(g_out_ids, sizeof(uint32_t), out_len_u32, fout) != out_len_u32) {
            fclose(fout); result_status = 6u; return 1;
        }

        decoded++;
        if ((decoded % 50u == 0u) || (decoded == limit))
            printf("[Decode] %u/%u  (tf_dec_steps_total=%u)\n",
                   decoded, limit, g_tf_dec_steps);
    }

    fclose(fout);
    trace_push(TRACE_EV_MAIN_EXIT, decoded, result_sentence_count, 0u);
    printf("[Save] %s  (n=%u)\n", args.out_hyp, decoded);
    return 0;
}
#endif
