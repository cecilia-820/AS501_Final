/////////////////////////////////////////////////////////////////////////////////
// AS501/AS603                                                                        //
//////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       //
// All rights reserved.                                                         //
//                                                                              //
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) //
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)//
////////////////////////////////////////////////////////////////////////////////*/


#include <stdint.h>
#include <stddef.h>

#ifdef SERVER
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#endif

#include "int_model_q12.h"
#include "input_data.h"
#include "arena.h"
#include "result.h"

#if !defined(SERVER) && !defined(RISCV)
#define SERVER
#endif

#define MAX_LEN 80
#ifndef MAX_SENTENCES_OVERRIDE
#define MAX_SENTENCES_OVERRIDE 0
#endif

#if defined(INPUT_SPLIT_TEST)
#define DEFAULT_OUT_HYP "./processed/test.hyp.int_c.u32bin"
#define DEFAULT_OUT_RESULT_TXT "./processed/test.result_mem.int_c.txt"
#define DEFAULT_OUT_RESULT_SUMMARY "./processed/test.result_summary.int_c.txt"
#else
#define DEFAULT_OUT_HYP "./processed/val.hyp.int_c.u32bin"
#define DEFAULT_OUT_RESULT_TXT "./processed/val.result_mem.int_c.txt"
#define DEFAULT_OUT_RESULT_SUMMARY "./processed/val.result_summary.int_c.txt"
#endif

typedef struct {
    const char *out_hyp;
    const char *out_result_txt;
    const char *out_result_summary;
    int max_sentences;
} Args;

typedef struct {
    uint32_t lo;
    uint32_t hi;
} I64Pair;

static int32_t *g_h_state = NULL;
static int32_t *g_c_state = NULL;
static int32_t *g_layer_in = NULL;
static int32_t *g_h_new = NULL;
static int32_t *g_c_new = NULL;
static int32_t *g_gates = NULL;
static uint32_t *g_out_ids = NULL;

static uint32_t result_used_cursor = 0u;
static uint32_t g_lstm_trace_emitted = 0u;
static uint32_t g_lstm_step_call_count = 0u;
#define SERVER_RESULT_DUMP_WORDS 64u
#define SERVER_RESULT_BASE_ADDR 0x20010fa0u

enum {
    TRACE_EV_MAIN_ENTER = 1,
    TRACE_EV_INIT_BUFFERS_OK = 2,
    TRACE_EV_SENTENCE_BEGIN = 3,
    TRACE_EV_LSTM_STEP_ENTER = 4,
    TRACE_EV_LSTM_STEP_DONE = 5,
    TRACE_EV_SENTENCE_DONE = 6,
    TRACE_EV_MAIN_EXIT = 7,
    TRACE_EV_LSTM_CALL_COUNT = 8,
    TRACE_EV_LSTM_GATES_BEGIN = 9,
    TRACE_EV_LSTM_GATES_DONE = 10,
    TRACE_EV_LSTM_STATE_DONE = 11
};

#ifdef SERVER
static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [--out-hyp PATH] [--out-result-txt PATH] [--out-result-summary PATH] [--max-sentences N]\n",
            prog);
}

static int parse_int(const char *s, int *out) {
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0') return -1;
    if (v < -2147483648L || v > 2147483647L) return -1;
    *out = (int)v;
    return 0;
}

static int parse_args(int argc, char **argv, Args *args) {
    args->out_hyp = DEFAULT_OUT_HYP;
    args->out_result_txt = DEFAULT_OUT_RESULT_TXT;
    args->out_result_summary = DEFAULT_OUT_RESULT_SUMMARY;
    args->max_sentences = 0;

    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (strcmp(a, "--out-hyp") == 0) {
            if (i + 1 >= argc) return -1;
            args->out_hyp = argv[++i];
        } else if (strcmp(a, "--out-result-txt") == 0) {
            if (i + 1 >= argc) return -1;
            args->out_result_txt = argv[++i];
        } else if (strcmp(a, "--out-result-summary") == 0) {
            if (i + 1 >= argc) return -1;
            args->out_result_summary = argv[++i];
        } else if (strcmp(a, "--max-sentences") == 0) {
            if (i + 1 >= argc) return -1;
            if (parse_int(argv[++i], &args->max_sentences) != 0) return -1;
        } else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
            usage(argv[0]);
            return 1;
        } else {
            return -1;
        }
    }
    return 0;
}
#endif

static void trace_push(uint32_t event, uint32_t a, uint32_t b, uint32_t c) {
#ifdef SERVER
    (void)a; (void)b; (void)c;
    switch (event) {
        case TRACE_EV_MAIN_ENTER:
            printf("[TRACE][func] enter main\n");
            break;
        case TRACE_EV_INIT_BUFFERS_OK:
            printf("[TRACE][func] init_static_buffers done\n");
            break;
        case TRACE_EV_SENTENCE_BEGIN:
            printf("[TRACE][func] enter greedy_decode_int\n");
            break;
        case TRACE_EV_LSTM_STEP_ENTER:
            printf("[TRACE][func] enter lstm_step_int (count=%u)\n",
                   (unsigned)g_lstm_step_call_count);
            break;
        case TRACE_EV_SENTENCE_DONE:
            printf("[TRACE][func] leave greedy_decode_int\n");
            break;
        case TRACE_EV_MAIN_EXIT:
            printf("[TRACE][func] leave main\n");
            break;
        case TRACE_EV_LSTM_CALL_COUNT:
            printf("[TRACE][func] lstm_step_int total_calls=%u\n",
                   (unsigned)g_lstm_step_call_count);
            break;
        default:
            break;
    }
#else
    (void)event;
    (void)a;
    (void)b;
    (void)c;
#endif
}

static void i32_memcpy(int32_t *dst, const int32_t *src, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        dst[i] = src[i];
    }
}

static void i32_memset_zero(int32_t *dst, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        dst[i] = 0;
    }
}

static uint32_t udiv32_sub(uint32_t num, uint32_t den) {
    if (den == 0u) return 0xffffffffu;
    uint32_t q = 0u;
    uint32_t r = 0u;
    for (int i = 31; i >= 0; --i) {
        r = (r << 1) | ((num >> i) & 1u);
        if (r >= den) {
            r -= den;
            q |= (1u << i);
        }
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
    uint32_t ua;
    uint32_t ub;

    if (a < 0) {
        neg ^= 1;
        ua = (uint32_t)(~(uint32_t)a) + 1u;
    } else {
        ua = (uint32_t)a;
    }
    if (b < 0) {
        neg ^= 1;
        ub = (uint32_t)(~(uint32_t)b) + 1u;
    } else {
        ub = (uint32_t)b;
    }

    uint32_t ah = ua >> 16;
    uint32_t al = ua & 0xffffu;
    uint32_t bh = ub >> 16;
    uint32_t bl = ub & 0xffffu;

    uint32_t p0 = al * bl;
    uint32_t p1 = al * bh;
    uint32_t p2 = ah * bl;
    uint32_t p3 = ah * bh;

    uint32_t lo = p0;
    uint32_t hi = p3 + (p1 >> 16) + (p2 >> 16);

    uint32_t add1 = p1 << 16;
    uint32_t old = lo;
    lo += add1;
    if (lo < old) hi += 1u;

    uint32_t add2 = p2 << 16;
    old = lo;
    lo += add2;
    if (lo < old) hi += 1u;

    I64Pair r;
    r.lo = lo;
    r.hi = hi;
    if (neg) {
        r = i64_neg(r);
    }
    return r;
}

static int32_t i64_sar_to_i32(I64Pair v, int bits) {
    if (bits <= 0) return (int32_t)v.lo;
    if (bits >= 32) {
        int s = bits - 32;
        return ((int32_t)v.hi) >> s;
    }
    uint32_t out = (v.lo >> bits) | (v.hi << (32 - bits));
    return (int32_t)out;
}

static int32_t mul_shift_q(int32_t a, int32_t b, int q_bits) {
    I64Pair p = i64_mul_i32(a, b);
    return i64_sar_to_i32(p, q_bits);
}

static int32_t dot_shift_q(const int32_t *a, const int32_t *b, int len, int q_bits) {
    I64Pair acc;
    acc.lo = 0u;
    acc.hi = 0u;
    for (int i = 0; i < len; ++i) {
        I64Pair p = i64_mul_i32(a[i], b[i]);
        acc = i64_add(acc, p);
    }
    return i64_sar_to_i32(acc, q_bits);
}

static int32_t lut_lookup_scalar(int32_t x_q, const int32_t *lut_q, int x_max_q, int lut_size) {
    if (x_q < -x_max_q) x_q = -x_max_q;
    if (x_q > x_max_q) x_q = x_max_q;

    uint32_t n = (uint32_t)(lut_size - 1);
    uint32_t shifted = (uint32_t)(x_q + x_max_q);
    uint32_t num = shifted * n;
    uint32_t den = (uint32_t)(x_max_q + x_max_q);
    uint32_t idx = udiv32_sub(num, den);
    return lut_q[idx];
}

static const int32_t *embedding_lookup(const int32_t *emb_table, int vocab_size, int emb_dim, int idx) {
    if (idx < 0 || idx >= vocab_size) idx = 1;
    return emb_table + (size_t)idx * (size_t)emb_dim;
}

static const int32_t *layer_ptr(const int32_t *flat, const int32_t *offsets, int layer) {
    return flat + offsets[layer];
}

static int lstm_step_int(
    const int32_t *x,
    const int32_t *h,
    const int32_t *c,
    const int32_t *w_ih,
    const int32_t *w_hh,
    const int32_t *b,
    int in_dim,
    int32_t *h_new,
    int32_t *c_new
) {
    int hid = MODEL_HID_SIZE;
    int gate_dim = 4 * hid;
    g_lstm_step_call_count += 1u;
    trace_push(TRACE_EV_LSTM_STEP_ENTER, (uint32_t)in_dim, (uint32_t)hid, (uint32_t)gate_dim);

    for (int g = 0; g < gate_dim; ++g) {
        const int32_t *wih_row = w_ih + (size_t)g * (size_t)in_dim;
        const int32_t *whh_row = w_hh + (size_t)g * (size_t)hid;
        int32_t s = b[g];
        s += dot_shift_q(wih_row, x, in_dim, MODEL_Q_BITS);
        s += dot_shift_q(whh_row, h, hid, MODEL_Q_BITS);
        g_gates[g] = s;
    }

    for (int i = 0; i < hid; ++i) {
        int32_t i_q = lut_lookup_scalar(g_gates[i], sigmoid_lut_q, MODEL_X_MAX_Q, MODEL_LUT_SIZE);
        int32_t f_q = lut_lookup_scalar(g_gates[hid + i], sigmoid_lut_q, MODEL_X_MAX_Q, MODEL_LUT_SIZE);
        int32_t g_q = lut_lookup_scalar(g_gates[2 * hid + i], tanh_lut_q, MODEL_X_MAX_Q, MODEL_LUT_SIZE);
        int32_t o_q = lut_lookup_scalar(g_gates[3 * hid + i], sigmoid_lut_q, MODEL_X_MAX_Q, MODEL_LUT_SIZE);

        int32_t c_val = mul_shift_q(f_q, c[i], MODEL_Q_BITS) + mul_shift_q(i_q, g_q, MODEL_Q_BITS);
        int32_t c_tanh = lut_lookup_scalar(c_val, tanh_lut_q, MODEL_X_MAX_Q, MODEL_LUT_SIZE);
        c_new[i] = c_val;
        h_new[i] = mul_shift_q(o_q, c_tanh, MODEL_Q_BITS);
    }
    if (g_lstm_trace_emitted < 32u) {
        trace_push(TRACE_EV_LSTM_STEP_DONE, (uint32_t)h_new[0], (uint32_t)c_new[0], (uint32_t)g_lstm_trace_emitted);
        g_lstm_trace_emitted += 1u;
    }
    return 0;
}

static int linear_out_argmax(const int32_t *h_last) {
    int best_idx = 0;
    int32_t best_val = 0;
    int inited = 0;
    for (int v = 0; v < MODEL_TGT_VOCAB; ++v) {
        const int32_t *row = out_w_q + (size_t)v * (size_t)MODEL_HID_SIZE;
        int32_t val = dot_shift_q(row, h_last, MODEL_HID_SIZE, MODEL_Q_BITS) + out_b_q[v];
        if (!inited || val > best_val) {
            best_val = val;
            best_idx = v;
            inited = 1;
        }
    }
    return best_idx;
}

static int init_static_buffers(void) {
    int num_layers = MODEL_NUM_LAYERS;
    int hid = MODEL_HID_SIZE;
    int max_dim = MODEL_ENC_EMB_DIM;
    if (MODEL_DEC_EMB_DIM > max_dim) max_dim = MODEL_DEC_EMB_DIM;
    if (hid > max_dim) max_dim = hid;

    arena_reset();

    g_h_state = (int32_t *)arena_alloc((uint32_t)(num_layers * hid * (int)sizeof(int32_t)), 8u);
    g_c_state = (int32_t *)arena_alloc((uint32_t)(num_layers * hid * (int)sizeof(int32_t)), 8u);
    g_layer_in = (int32_t *)arena_alloc((uint32_t)(max_dim * (int)sizeof(int32_t)), 8u);
    g_h_new = (int32_t *)arena_alloc((uint32_t)(hid * (int)sizeof(int32_t)), 8u);
    g_c_new = (int32_t *)arena_alloc((uint32_t)(hid * (int)sizeof(int32_t)), 8u);
    g_gates = (int32_t *)arena_alloc((uint32_t)((4 * hid) * (int)sizeof(int32_t)), 8u);
    g_out_ids = (uint32_t *)arena_alloc((uint32_t)(MAX_LEN * (int)sizeof(uint32_t)), 8u);

    if (!g_h_state || !g_c_state || !g_layer_in || !g_h_new || !g_c_new || !g_gates || !g_out_ids) {
        return -1;
    }
    return 0;
}

static int publish_partial_result_sequence(
    uint32_t base_cursor,
    uint32_t visible_sent_count,
    const uint32_t *out_ids,
    int out_len
) {
    uint32_t used = 0u;

    if (out_len <= 0 || out_len > MAX_LEN) {
        result_status = 4u;
        return -1;
    }

    used = base_cursor + 1u + (uint32_t)out_len;
    if (used > (uint32_t)RESULT_U32_CAP) {
        result_status = 3u;
        return -1;
    }

    result_data[base_cursor] = (uint32_t)out_len;
    for (int j = 0; j < out_len; ++j) {
        result_data[base_cursor + 1u + (uint32_t)j] = out_ids[j];
    }

    // Publish the header last so TB sees a committed prefix.
    result_sentence_count = visible_sent_count;
    result_used_u32 = used;
    return 0;
}

static int greedy_decode_int(
    const uint32_t *src_ids,
    int src_len,
    int bos_id,
    int eos_id,
    uint32_t *out_ids,
    uint32_t base_cursor,
    uint32_t visible_sent_count
) {
    int num_layers = MODEL_NUM_LAYERS;
    int hid = MODEL_HID_SIZE;

    i32_memset_zero(g_h_state, (size_t)(num_layers * hid));
    i32_memset_zero(g_c_state, (size_t)(num_layers * hid));

    for (int t = 0; t < src_len; ++t) {
        const int32_t *x0 = embedding_lookup(enc_emb_q, MODEL_SRC_VOCAB, MODEL_ENC_EMB_DIM, (int)src_ids[t]);
        i32_memcpy(g_layer_in, x0, (size_t)MODEL_ENC_EMB_DIM);
        int in_dim = MODEL_ENC_EMB_DIM;

        for (int l = 0; l < num_layers; ++l) {
            const int32_t *w_ih = layer_ptr(enc_w_ih_q, enc_w_ih_offsets, l);
            const int32_t *w_hh = layer_ptr(enc_w_hh_q, enc_w_hh_offsets, l);
            const int32_t *b = layer_ptr(enc_b_q, enc_b_offsets, l);
            int32_t *h_l = g_h_state + (size_t)l * (size_t)hid;
            int32_t *c_l = g_c_state + (size_t)l * (size_t)hid;

            if (lstm_step_int(g_layer_in, h_l, c_l, w_ih, w_hh, b, in_dim, g_h_new, g_c_new) != 0) {
                return -1;
            }
            i32_memcpy(h_l, g_h_new, (size_t)hid);
            i32_memcpy(c_l, g_c_new, (size_t)hid);
            i32_memcpy(g_layer_in, g_h_new, (size_t)hid);
            in_dim = hid;
        }
    }

    int out_len = 0;
    out_ids[out_len++] = (uint32_t)bos_id;
    if (publish_partial_result_sequence(base_cursor, visible_sent_count, out_ids, out_len) != 0) {
        return -1;
    }

    for (int step = 0; step < MAX_LEN - 1; ++step) {
        const int32_t *x0 = embedding_lookup(dec_emb_q, MODEL_TGT_VOCAB, MODEL_DEC_EMB_DIM, (int)out_ids[out_len - 1]);
        i32_memcpy(g_layer_in, x0, (size_t)MODEL_DEC_EMB_DIM);
        int in_dim = MODEL_DEC_EMB_DIM;

        for (int l = 0; l < num_layers; ++l) {
            const int32_t *w_ih = layer_ptr(dec_w_ih_q, dec_w_ih_offsets, l);
            const int32_t *w_hh = layer_ptr(dec_w_hh_q, dec_w_hh_offsets, l);
            const int32_t *b = layer_ptr(dec_b_q, dec_b_offsets, l);
            int32_t *h_l = g_h_state + (size_t)l * (size_t)hid;
            int32_t *c_l = g_c_state + (size_t)l * (size_t)hid;

            if (lstm_step_int(g_layer_in, h_l, c_l, w_ih, w_hh, b, in_dim, g_h_new, g_c_new) != 0) {
                return -1;
            }
            i32_memcpy(h_l, g_h_new, (size_t)hid);
            i32_memcpy(c_l, g_c_new, (size_t)hid);
            i32_memcpy(g_layer_in, g_h_new, (size_t)hid);
            in_dim = hid;
        }

        int32_t *h_last = g_h_state + (size_t)(num_layers - 1) * (size_t)hid;
        int next_id = linear_out_argmax(h_last);
        out_ids[out_len++] = (uint32_t)next_id;
        if (publish_partial_result_sequence(base_cursor, visible_sent_count, out_ids, out_len) != 0) {
            return -1;
        }
        if (next_id == eos_id) break;
    }

    return out_len;
}

static void reset_result_buffer(void) {
    result_status = 0u;
    result_sentence_count = 0u;
    result_used_u32 = 0u;
    result_used_cursor = 0u;
    g_lstm_trace_emitted = 0u;
    g_lstm_step_call_count = 0u;
}

static int append_result_sequence(const uint32_t *out_ids, int out_len) {
    if (out_len <= 0 || out_len > MAX_LEN) {
        result_status = 4u;
        return -1;
    }
    if (result_used_cursor + (uint32_t)out_len + 1u > (uint32_t)RESULT_U32_CAP) {
        result_status = 3u;
        return -1;
    }

    result_data[result_used_cursor++] = (uint32_t)out_len;
    for (int j = 0; j < out_len; ++j) {
        result_data[result_used_cursor++] = out_ids[j];
    }
    result_used_u32 = result_used_cursor;
    return 0;
}

#ifdef SERVER
static int dump_result_memory_words(const char *out_path, uint32_t max_words) {
    uint32_t limit = max_words;
    FILE *fout = NULL;

    fout = fopen(out_path, "w");
    if (!fout) {
        fprintf(stderr, "Failed to open result dump file: %s\n", out_path);
        return -1;
    }

    for (uint32_t i = 0; i < limit; ++i) {
        uint32_t addr = SERVER_RESULT_BASE_ADDR + (4u * i);
        uint32_t val = 0u;

        if (i == 0u) {
            val = result_status;
        } else if (i == 1u) {
            val = result_sentence_count;
        } else if (i == 2u) {
            val = result_used_u32;
        } else {
            uint32_t data_idx = i - 3u;
            if (data_idx < (uint32_t)RESULT_U32_CAP) {
                val = result_data[data_idx];
            }
        }

        fprintf(fout, "ADDR[0x%08x]: 0x%08x ,dec=%u\n",
                (unsigned)addr,
                (unsigned)val,
                (unsigned)val);
    }
    fclose(fout);
    printf("[ResultMem] iomem-format dump written: %s (words=%u)\n",
           out_path,
           (unsigned)limit);
    return 0;
}

static int dump_result_summary(const char *out_path) {
    FILE *fout = fopen(out_path, "w");
    uint32_t cursor = 0u;
    if (!fout) {
        fprintf(stderr, "Failed to open result summary file: %s\n", out_path);
        return -1;
    }

    fprintf(fout, "status=%u\n", (unsigned)result_status);
    fprintf(fout, "sentence_count=%u\n", (unsigned)result_sentence_count);
    fprintf(fout, "used=%u\n", (unsigned)result_used_u32);

    for (uint32_t s = 0u; s < result_sentence_count; ++s) {
        uint32_t seq_len = 0u;
        if (cursor >= result_used_u32) {
            fprintf(fout, "sent[%u].len=<truncated>\n", (unsigned)s);
            break;
        }
        seq_len = result_data[cursor++];
        fprintf(fout, "sent[%u].len=%u\n", (unsigned)s, (unsigned)seq_len);
        fprintf(fout, "sent[%u].tok=", (unsigned)s);
        for (uint32_t k = 0u; k < seq_len; ++k) {
            if (cursor >= result_used_u32) {
                break;
            }
            if (k != 0u) {
                fputc(' ', fout);
            }
            fprintf(fout, "%u", (unsigned)result_data[cursor++]);
        }
        fputc('\n', fout);
    }

    fclose(fout);
    printf("[ResultMem] summary written: %s\n", out_path);
    return 0;
}
#endif

#ifdef SERVER
int main(int argc, char **argv) {
    Args args;
    int pr = parse_args(argc, argv, &args);
    if (pr == 1) return 0;
    if (pr != 0) {
        usage(argv[0]);
        return 1;
    }

    reset_result_buffer();
    trace_push(TRACE_EV_MAIN_ENTER, INPUT_SENT_COUNT, 0u, 0u);

    if (init_static_buffers() != 0) {
        result_status = 1u;
        fprintf(stderr, "Arena init failed (increase ARENA_SIZE_BYTES)\n");
        return 1;
    }
    trace_push(TRACE_EV_INIT_BUFFERS_OK, 0u, 0u, 0u);

    FILE *fout = fopen(args.out_hyp, "wb");
    if (!fout) {
        result_status = 5u;
        fprintf(stderr, "Failed to open output file: %s\n", args.out_hyp);
        return 1;
    }

    uint32_t limit = INPUT_SENT_COUNT;
    if (args.max_sentences > 0 && (uint32_t)args.max_sentences < limit) {
        limit = (uint32_t)args.max_sentences;
    }

    uint32_t decoded = 0u;
    for (uint32_t i = 0; i < limit; ++i) {
        trace_push(TRACE_EV_SENTENCE_BEGIN, i, limit, 0u);
        uint32_t s0 = input_src_offsets[i];
        uint32_t s1 = input_src_offsets[i + 1u];
        if (s1 < s0) {
            fclose(fout);
            result_status = 2u;
            fprintf(stderr, "Invalid input_src_offsets at i=%u\n", (unsigned)i);
            return 1;
        }
        int src_len = (int)(s1 - s0);
        const uint32_t *src_ids = input_src_data + s0;
        uint32_t sentence_cursor = result_used_cursor;

        int out_len = greedy_decode_int(
            src_ids, src_len, INPUT_TGT_BOS, INPUT_TGT_EOS, g_out_ids, sentence_cursor, i + 1u
        );
        if (out_len <= 0 || out_len > MAX_LEN) {
            fclose(fout);
            result_status = 4u;
            fprintf(stderr, "Decoding failed at sentence %u\n", (unsigned)i);
            return 1;
        }
        result_used_cursor = sentence_cursor + 1u + (uint32_t)out_len;
        result_used_u32 = result_used_cursor;
        trace_push(TRACE_EV_SENTENCE_DONE, i, (uint32_t)out_len, result_used_u32);
        trace_push(TRACE_EV_LSTM_CALL_COUNT, i, g_lstm_step_call_count, 0u);
        result_sentence_count = i + 1u;

        uint32_t out_len_u32 = (uint32_t)out_len;
        if (fwrite(&out_len_u32, sizeof(uint32_t), 1, fout) != 1) {
            fclose(fout);
            result_status = 6u;
            fprintf(stderr, "Failed to write output length\n");
            return 1;
        }
        if (fwrite(g_out_ids, sizeof(uint32_t), (size_t)out_len_u32, fout) != (size_t)out_len_u32) {
            fclose(fout);
            result_status = 7u;
            fprintf(stderr, "Failed to write output ids\n");
            return 1;
        }

        if (dump_result_memory_words(args.out_result_txt, SERVER_RESULT_DUMP_WORDS) != 0) {
            fclose(fout);
            result_status = 8u;
            return 1;
        }
        if (dump_result_summary(args.out_result_summary) != 0) {
            fclose(fout);
            result_status = 9u;
            return 1;
        }

        decoded += 1u;
        if ((decoded % 50u) == 0u || decoded == limit) {
            printf("[Decode] %u/%u (lstm_step_int_calls=%u)\n",
                   (unsigned)decoded, (unsigned)limit, (unsigned)g_lstm_step_call_count);
            fflush(stdout);
        }
    }

    fclose(fout);
    trace_push(TRACE_EV_MAIN_EXIT, decoded, result_sentence_count, result_used_u32);
    trace_push(TRACE_EV_LSTM_CALL_COUNT, decoded, g_lstm_step_call_count, 1u);
    printf("[TraceSummary] lstm_step_int total calls=%u\n", (unsigned)g_lstm_step_call_count);
    printf("[Save] hypothesis written: %s (n=%u)\n", args.out_hyp, (unsigned)decoded);
    printf("[Save] result memory text written: %s\n", args.out_result_txt);
    printf("[Save] result summary written: %s\n", args.out_result_summary);
    return 0;
}
#else
int main(void) {
    reset_result_buffer();
    trace_push(TRACE_EV_MAIN_ENTER, INPUT_SENT_COUNT, (uint32_t)MAX_SENTENCES_OVERRIDE, 0u);

    if (init_static_buffers() != 0) {
        result_status = 1u;
        return 1;
    }
    trace_push(TRACE_EV_INIT_BUFFERS_OK, 0u, 0u, 0u);

    uint32_t limit = INPUT_SENT_COUNT;
    if (MAX_SENTENCES_OVERRIDE > 0 && (uint32_t)MAX_SENTENCES_OVERRIDE < limit) {
        limit = (uint32_t)MAX_SENTENCES_OVERRIDE;
    }

    for (uint32_t i = 0; i < limit; ++i) {
        trace_push(TRACE_EV_SENTENCE_BEGIN, i, limit, 0u);
        uint32_t s0 = input_src_offsets[i];
        uint32_t s1 = input_src_offsets[i + 1u];
        if (s1 < s0) {
            result_status = 2u;
            return 1;
        }

        {
            int src_len = (int)(s1 - s0);
            const uint32_t *src_ids = input_src_data + s0;
            uint32_t sentence_cursor = result_used_cursor;
            int out_len = greedy_decode_int(
                src_ids, src_len, INPUT_TGT_BOS, INPUT_TGT_EOS, g_out_ids, sentence_cursor, i + 1u
            );
            if (out_len <= 0 || out_len > MAX_LEN) {
                result_status = 4u;
                return 1;
            }
            result_used_cursor = sentence_cursor + 1u + (uint32_t)out_len;
            result_used_u32 = result_used_cursor;
            trace_push(TRACE_EV_SENTENCE_DONE, i, (uint32_t)out_len, result_used_u32);
            trace_push(TRACE_EV_LSTM_CALL_COUNT, i, g_lstm_step_call_count, 0u);
        }
        result_sentence_count = i + 1u;
    }

    trace_push(TRACE_EV_MAIN_EXIT, limit, result_sentence_count, result_used_u32);
    trace_push(TRACE_EV_LSTM_CALL_COUNT, limit, g_lstm_step_call_count, 1u);
    return 0;
}
#endif
