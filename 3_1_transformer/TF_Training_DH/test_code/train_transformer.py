#!/usr/bin/env python3
"""
train_transformer.py
────────────────────────────────────────────────────────────────────────────────
Seq2Seq Transformer 학습 스크립트 (DE → EN)
변경사항:
  - --val_src / --val_tgt 로 별도 검증 파일 지정 가능
  - Beam Search 디코딩 추가 (BLEU 향상)
  - epoch마다 BLEU 출력 및 최고 BLEU 기준으로 체크포인트 저장

실행 방법:
    python train_transformer.py \
        --src  train_lc_norm_tok.de \
        --tgt  train_lc_norm_tok.en \
        --val_src val_lc_norm_tok.de \
        --val_tgt val_lc_norm_tok.en \
        --out_dir ./output \
        --epochs 30 \
        --batch 256 \
        --beam_size 4
────────────────────────────────────────────────────────────────────────────────
"""

import os, sys, math, time, argparse, collections, random
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader

################################################################################
# 하이퍼파라미터 (C 코드 상수와 반드시 일치)
################################################################################
D_MODEL      = 128
N_HEADS      = 4
D_HEAD       = D_MODEL // N_HEADS
D_FF         = 256
N_ENC_LAYERS = 2
N_DEC_LAYERS = 2
MAX_SRC_LEN  = 40
MAX_TGT_LEN  = 40
BATCH_SIZE   = 128
N_EPOCHS     = 30
WARMUP_STEPS = 4000
DROPOUT      = 0.1
CLIP_GRAD    = 1.0
MIN_FREQ     = 1
Q_BITS       = 12
Q_SCALE      = 1 << Q_BITS
PAD_IDX = 0; BOS_IDX = 1; EOS_IDX = 2; UNK_IDX = 3

################################################################################
# Vocabulary
################################################################################
class Vocab:
    def __init__(self, min_freq=MIN_FREQ):
        self.min_freq = min_freq
        self.tok2idx = {'<pad>':PAD_IDX,'<bos>':BOS_IDX,'<eos>':EOS_IDX,'<unk>':UNK_IDX}
        self.idx2tok = {v:k for k,v in self.tok2idx.items()}

    def build(self, sentences):
        counter = collections.Counter()
        for s in sentences: counter.update(s.strip().split())
        for tok, cnt in sorted(counter.items()):
            if cnt >= self.min_freq and tok not in self.tok2idx:
                idx = len(self.tok2idx)
                self.tok2idx[tok] = idx; self.idx2tok[idx] = tok
        return self

    def encode(self, sentence, max_len=None):
        ids = [self.tok2idx.get(t, UNK_IDX) for t in sentence.strip().split()]
        if max_len: ids = ids[:max_len]
        return [BOS_IDX] + ids + [EOS_IDX]

    def decode(self, ids):
        sp = {PAD_IDX, BOS_IDX, EOS_IDX}
        return ' '.join(self.idx2tok.get(i,'<unk>') for i in ids if i not in sp)

    def save(self, path):
        with open(path,'w') as f:
            for tok,idx in sorted(self.tok2idx.items(), key=lambda x:x[1]):
                f.write(f"{tok}\t{idx}\n")
        print(f"[Vocab] saved -> {path}  (size={len(self)})")

    def __len__(self): return len(self.tok2idx)

################################################################################
# Dataset
################################################################################
class TranslationDataset(Dataset):
    def __init__(self, src_sents, tgt_sents, src_vocab, tgt_vocab):
        self.pairs = []
        for s, t in zip(src_sents, tgt_sents):
            si = src_vocab.encode(s, MAX_SRC_LEN)
            ti = tgt_vocab.encode(t, MAX_TGT_LEN)
            if len(si) <= MAX_SRC_LEN+2 and len(ti) <= MAX_TGT_LEN+2:
                self.pairs.append((si, ti))
    def __len__(self): return len(self.pairs)
    def __getitem__(self, i): return self.pairs[i]

def collate_fn(batch):
    sl, tl = zip(*batch)
    sm, tm = max(len(s) for s in sl), max(len(t) for t in tl)
    sp = [s+[PAD_IDX]*(sm-len(s)) for s in sl]
    tp = [t+[PAD_IDX]*(tm-len(t)) for t in tl]
    return torch.tensor(sp,dtype=torch.long), torch.tensor(tp,dtype=torch.long)

################################################################################
# Model
################################################################################
class Seq2SeqTransformer(nn.Module):
    def __init__(self, sv, tv):
        super().__init__()
        self.src_emb = nn.Embedding(sv, D_MODEL, padding_idx=PAD_IDX)
        self.tgt_emb = nn.Embedding(tv, D_MODEL, padding_idx=PAD_IDX)
        self.register_buffer('pe', self._make_pe(200, D_MODEL))
        el = nn.TransformerEncoderLayer(D_MODEL, N_HEADS, D_FF, DROPOUT,
                                        batch_first=True, norm_first=True)
        self.encoder = nn.TransformerEncoder(el, N_ENC_LAYERS, nn.LayerNorm(D_MODEL))
        dl = nn.TransformerDecoderLayer(D_MODEL, N_HEADS, D_FF, DROPOUT,
                                        batch_first=True, norm_first=True)
        self.decoder = nn.TransformerDecoder(dl, N_DEC_LAYERS, nn.LayerNorm(D_MODEL))
        self.out_proj = nn.Linear(D_MODEL, tv)
        for p in self.parameters():
            if p.dim() > 1: nn.init.xavier_uniform_(p)

    @staticmethod
    def _make_pe(L, D):
        pe = torch.zeros(L, D)
        pos = torch.arange(L).unsqueeze(1).float()
        div = torch.exp(torch.arange(0,D,2).float()*(-math.log(10000.)/D))
        pe[:,0::2]=torch.sin(pos*div); pe[:,1::2]=torch.cos(pos*div)
        return pe.unsqueeze(0)

    def _pe(self, x): return x + self.pe[:,:x.size(1)]

    def encode(self, src, mask):
        return self.encoder(self._pe(self.src_emb(src)), src_key_padding_mask=mask)

    def decode(self, tgt, mem, tm, tpm, smm):
        return self.decoder(self._pe(self.tgt_emb(tgt)), mem,
                            tgt_mask=tm, tgt_key_padding_mask=tpm,
                            memory_key_padding_mask=smm)

    def forward(self, src, tgt):
        sp = (src==PAD_IDX); tp = (tgt==PAD_IDX)
        tm = nn.Transformer.generate_square_subsequent_mask(tgt.size(1)).to(src.device)
        mem = self.encode(src, sp)
        out = self.decode(tgt, mem, tm, tp, sp)
        return self.out_proj(out)

################################################################################
# Warmup Scheduler
################################################################################
class WarmupScheduler:
    def __init__(self, opt, d, w):
        self.opt=opt; self.d=d; self.w=w; self.n=0
    def step(self):
        self.n += 1
        lr = self.d**(-0.5)*min(self.n**(-0.5), self.n*self.w**(-1.5))
        for g in self.opt.param_groups: g['lr']=lr
        self.opt.step()
    @property
    def lr(self): return self.opt.param_groups[0]['lr']

################################################################################
# BLEU 계산
################################################################################
def compute_bleu(hyps, refs, max_n=4):
    clip_c = [0]*max_n; tot_c = [0]*max_n
    hlen = rlen = 0
    for h, r in zip(hyps, refs):
        hlen += len(h); rlen += len(r)
        for n in range(1, max_n+1):
            hng = collections.Counter(tuple(h[i:i+n]) for i in range(len(h)-n+1))
            rng = collections.Counter(tuple(r[i:i+n]) for i in range(len(r)-n+1))
            for ng, cnt in hng.items():
                clip_c[n-1] += min(cnt, rng.get(ng,0))
                tot_c[n-1]  += cnt
    precs = []
    for c,t in zip(clip_c, tot_c):
        precs.append(math.log(c/t) if c>0 and t>0 else -float('inf'))
    if any(math.isinf(p) for p in precs): return 0.0
    bp = min(1., math.exp(1-rlen/hlen)) if hlen>0 else 0.
    return bp * math.exp(sum(precs)/max_n) * 100

################################################################################
# Beam Search (BLEU 향상 핵심)
################################################################################
@torch.no_grad()
def beam_search(model, src_sent, sv, tv, device, beam=4, max_len=MAX_TGT_LEN, alpha=0.6):
    model.eval()
    src = torch.tensor([sv.encode(src_sent, MAX_SRC_LEN)], dtype=torch.long, device=device)
    sp  = (src==PAD_IDX)
    mem = model.encode(src, sp)
    beams, done = [(0., [BOS_IDX])], []
    for _ in range(max_len):
        nb = []
        for score, ids in beams:
            t   = torch.tensor([ids], dtype=torch.long, device=device)
            tm  = nn.Transformer.generate_square_subsequent_mask(len(ids)).to(device)
            out = model.decode(t, mem, tm, t==PAD_IDX, sp)
            lp  = F.log_softmax(model.out_proj(out[:,-1]), dim=-1)
            tk_lp, tk_id = lp[0].topk(beam)
            for l, i in zip(tk_lp.tolist(), tk_id.tolist()):
                ni = ids+[i]; ns = score+l
                if i==EOS_IDX:
                    norm = ((5+len(ni))/6)**alpha
                    done.append((ns/norm, ni))
                else: nb.append((ns, ni))
        nb.sort(key=lambda x:x[0], reverse=True)
        beams = nb[:beam]
        if len(done) >= beam: break
    if done: done.sort(key=lambda x:x[0], reverse=True); best=done[0][1]
    elif beams: best=beams[0][1]
    else: best=[BOS_IDX, EOS_IDX]
    return tv.decode(best)

################################################################################
# 학습/평가 루프
################################################################################
def train_epoch(model, loader, crit, opt, sched, device):
    model.train()
    tot, n = 0., 0
    for src, tgt in loader:
        src, tgt = src.to(device), tgt.to(device)
        ti, to = tgt[:,:-1], tgt[:,1:]
        loss = crit(model(src,ti).reshape(-1, model.out_proj.out_features), to.reshape(-1))
        opt.zero_grad(); loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), CLIP_GRAD)
        sched.step()
        np_ = (to!=PAD_IDX).sum().item()
        tot += loss.item()*np_; n += np_
    return tot/max(n,1)

@torch.no_grad()
def eval_epoch(model, loader, crit, device):
    model.eval()
    tot, n = 0., 0
    for src, tgt in loader:
        src, tgt = src.to(device), tgt.to(device)
        ti, to = tgt[:,:-1], tgt[:,1:]
        loss = crit(model(src,ti).reshape(-1, model.out_proj.out_features), to.reshape(-1))
        np_ = (to!=PAD_IDX).sum().item()
        tot += loss.item()*np_; n += np_
    return tot/max(n,1)

@torch.no_grad()
def eval_bleu(model, src_sents, tgt_sents, sv, tv, device, beam=4, n=200):
    model.eval()
    pairs = list(zip(src_sents, tgt_sents))
    if n and len(pairs)>n:
        random.seed(42); pairs = random.sample(pairs, n)
    hyps = [beam_search(model, s, sv, tv, device, beam).split() for s,_ in pairs]
    refs = [t.strip().split() for _,t in pairs]
    return compute_bleu(hyps, refs)

################################################################################
# Export (Q12 C 배열)
################################################################################
def q12(t):
    return np.clip(np.round(t.detach().float().cpu().numpy()*Q_SCALE), -(2**31), 2**31-1).astype(np.int32)

def wca(f, name, data):
    flat = data.flatten()
    f.write(f"const int32_t {name}[{len(flat)}] = {{\n")
    for i in range(0,len(flat),8):
        chunk = flat[i:i+8]
        f.write("    " + ", ".join(f"{int(v):8d}" for v in chunk)
                + ("," if i+8<len(flat) else "") + "\n")
    f.write("};\n\n")

def export_weights(model, out_dir, sv, tv):
    dm,ne,nd = D_MODEL, N_ENC_LAYERS, N_DEC_LAYERS
    path = os.path.join(out_dir, "int_model_transformer_q12.c")
    with open(path,'w') as f:
        f.write('// Auto-generated by train_transformer.py\n')
        f.write('#include "int_model_transformer_q12.h"\n#include <stdint.h>\n\n')
        wca(f,"enc_emb_q",q12(model.src_emb.weight))
        wca(f,"dec_emb_q",q12(model.tgt_emb.weight))
        # positional encoding
        pe = np.zeros((max(MAX_SRC_LEN,MAX_TGT_LEN),dm),dtype=np.float32)
        pos = np.arange(len(pe))[:,None]
        div = np.exp(np.arange(0,dm,2)*(-math.log(10000.)/dm))
        pe[:,0::2]=np.sin(pos*div); pe[:,1::2]=np.cos(pos*div)
        wca(f,"pos_enc_q",np.clip(np.round(pe*Q_SCALE),-(2**31),2**31-1).astype(np.int32))
        wca(f,"out_w_q",q12(model.out_proj.weight))
        wca(f,"out_b_q",q12(model.out_proj.bias))

        def ec(fn): return np.concatenate([fn(l) for l in range(ne)],axis=0)
        def dc(fn): return np.concatenate([fn(l) for l in range(nd)],axis=0)

        for pre,n_,attr in [('enc',ne,'self_attn')]:
            wca(f,"enc_attn_Wq_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.in_proj_weight[:dm])))
            wca(f,"enc_attn_Wk_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.in_proj_weight[dm:2*dm])))
            wca(f,"enc_attn_Wv_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.in_proj_weight[2*dm:])))
            wca(f,"enc_attn_Wo_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.out_proj.weight)))
            wca(f,"enc_attn_bq_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.in_proj_bias[:dm])))
            wca(f,"enc_attn_bk_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.in_proj_bias[dm:2*dm])))
            wca(f,"enc_attn_bv_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.in_proj_bias[2*dm:])))
            wca(f,"enc_attn_bo_q",ec(lambda l:q12(model.encoder.layers[l].self_attn.out_proj.bias)))
        wca(f,"enc_ff1_W_q",ec(lambda l:q12(model.encoder.layers[l].linear1.weight)))
        wca(f,"enc_ff1_b_q",ec(lambda l:q12(model.encoder.layers[l].linear1.bias)))
        wca(f,"enc_ff2_W_q",ec(lambda l:q12(model.encoder.layers[l].linear2.weight)))
        wca(f,"enc_ff2_b_q",ec(lambda l:q12(model.encoder.layers[l].linear2.bias)))
        for i,a in [(1,'norm1'),(2,'norm2')]:
            wca(f,f"enc_ln{i}_gamma_q",ec(lambda l,a=a:q12(getattr(model.encoder.layers[l],a).weight)))
            wca(f,f"enc_ln{i}_beta_q", ec(lambda l,a=a:q12(getattr(model.encoder.layers[l],a).bias)))
        wca(f,"enc_final_ln_gamma_q",q12(model.encoder.norm.weight))
        wca(f,"enc_final_ln_beta_q", q12(model.encoder.norm.bias))

        def da(prefix, pytorch_attr):
            ga = lambda l: getattr(model.decoder.layers[l], pytorch_attr)
            wca(f,f"dec_{prefix}_Wq_q",dc(lambda l:q12(ga(l).in_proj_weight[:dm])))
            wca(f,f"dec_{prefix}_Wk_q",dc(lambda l:q12(ga(l).in_proj_weight[dm:2*dm])))
            wca(f,f"dec_{prefix}_Wv_q",dc(lambda l:q12(ga(l).in_proj_weight[2*dm:])))
            wca(f,f"dec_{prefix}_Wo_q",dc(lambda l:q12(ga(l).out_proj.weight)))
            wca(f,f"dec_{prefix}_bq_q",dc(lambda l:q12(ga(l).in_proj_bias[:dm])))
            wca(f,f"dec_{prefix}_bk_q",dc(lambda l:q12(ga(l).in_proj_bias[dm:2*dm])))
            wca(f,f"dec_{prefix}_bv_q",dc(lambda l:q12(ga(l).in_proj_bias[2*dm:])))
            wca(f,f"dec_{prefix}_bo_q",dc(lambda l:q12(ga(l).out_proj.bias)))
        da('self','self_attn'); da('cross','multihead_attn')
        wca(f,"dec_ff1_W_q",dc(lambda l:q12(model.decoder.layers[l].linear1.weight)))
        wca(f,"dec_ff1_b_q",dc(lambda l:q12(model.decoder.layers[l].linear1.bias)))
        wca(f,"dec_ff2_W_q",dc(lambda l:q12(model.decoder.layers[l].linear2.weight)))
        wca(f,"dec_ff2_b_q",dc(lambda l:q12(model.decoder.layers[l].linear2.bias)))
        for i,a in [(1,'norm1'),(2,'norm2'),(3,'norm3')]:
            wca(f,f"dec_ln{i}_gamma_q",dc(lambda l,a=a:q12(getattr(model.decoder.layers[l],a).weight)))
            wca(f,f"dec_ln{i}_beta_q", dc(lambda l,a=a:q12(getattr(model.decoder.layers[l],a).bias)))
        wca(f,"dec_final_ln_gamma_q",q12(model.decoder.norm.weight))
        wca(f,"dec_final_ln_beta_q", q12(model.decoder.norm.bias))
    print(f"[Export] {path}")

def export_header(sv, tv, out_dir):
    s,t = len(sv),len(tv)
    aq  = int(round(1./math.sqrt(D_HEAD)*Q_SCALE))
    ml  = max(MAX_SRC_LEN,MAX_TGT_LEN)
    with open(os.path.join(out_dir,"int_model_transformer_q12.h"),'w') as f:
        f.write(f"""// Auto-generated by train_transformer.py
// Softermax: barrel shift + linear interp (no exp LUT needed)
#ifndef INT_MODEL_TRANSFORMER_Q12_H
#define INT_MODEL_TRANSFORMER_Q12_H
#include <stdint.h>
#define MODEL_Q_BITS        {Q_BITS}
#define MODEL_Q_SCALE       (1 << MODEL_Q_BITS)
#define TF_D_MODEL          {D_MODEL}
#define TF_N_HEADS          {N_HEADS}
#define TF_D_HEAD           (TF_D_MODEL / TF_N_HEADS)
#define TF_D_FF             {D_FF}
#define TF_N_ENC_LAYERS     {N_ENC_LAYERS}
#define TF_N_DEC_LAYERS     {N_DEC_LAYERS}
#define TF_MAX_SRC_LEN      {MAX_SRC_LEN}
#define TF_MAX_TGT_LEN      {MAX_TGT_LEN}
#define TF_ATTN_SCALE_Q     {aq}
#define TF_LN_EPS_Q         1
#define TF_POW2_MIN_SHIFT   12
#define TF_EXP_X_MIN_Q     (-8 * MODEL_Q_SCALE)
#define MODEL_SRC_VOCAB     {s}
#define MODEL_TGT_VOCAB     {t}
extern const int32_t pos_enc_q[{ml} * TF_D_MODEL];
extern const int32_t enc_emb_q[MODEL_SRC_VOCAB * TF_D_MODEL];
extern const int32_t dec_emb_q[MODEL_TGT_VOCAB * TF_D_MODEL];
extern const int32_t out_w_q[MODEL_TGT_VOCAB * TF_D_MODEL];
extern const int32_t out_b_q[MODEL_TGT_VOCAB];
extern const int32_t enc_attn_Wq_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bq_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_attn_Wk_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bk_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_attn_Wv_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bv_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_attn_Wo_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t enc_attn_bo_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ff1_W_q[TF_N_ENC_LAYERS * TF_D_FF    * TF_D_MODEL];
extern const int32_t enc_ff1_b_q[TF_N_ENC_LAYERS * TF_D_FF];
extern const int32_t enc_ff2_W_q[TF_N_ENC_LAYERS * TF_D_MODEL * TF_D_FF];
extern const int32_t enc_ff2_b_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ln1_gamma_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ln1_beta_q [TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ln2_gamma_q[TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_ln2_beta_q [TF_N_ENC_LAYERS * TF_D_MODEL];
extern const int32_t enc_final_ln_gamma_q[TF_D_MODEL];
extern const int32_t enc_final_ln_beta_q [TF_D_MODEL];
extern const int32_t dec_self_Wq_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bq_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_self_Wk_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bk_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_self_Wv_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bv_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_self_Wo_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_self_bo_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_cross_Wq_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bq_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_cross_Wk_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bk_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_cross_Wv_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bv_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_cross_Wo_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_MODEL];
extern const int32_t dec_cross_bo_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ff1_W_q[TF_N_DEC_LAYERS * TF_D_FF    * TF_D_MODEL];
extern const int32_t dec_ff1_b_q[TF_N_DEC_LAYERS * TF_D_FF];
extern const int32_t dec_ff2_W_q[TF_N_DEC_LAYERS * TF_D_MODEL * TF_D_FF];
extern const int32_t dec_ff2_b_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln1_gamma_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln1_beta_q [TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln2_gamma_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln2_beta_q [TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln3_gamma_q[TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_ln3_beta_q [TF_N_DEC_LAYERS * TF_D_MODEL];
extern const int32_t dec_final_ln_gamma_q[TF_D_MODEL];
extern const int32_t dec_final_ln_beta_q [TF_D_MODEL];
#endif
""")
    print(f"[Export] header (src={s}, tgt={t})")

def export_input_data(sv, tv, src_sents, tgt_sents, out_dir, n=1):
    pairs = list(zip(src_sents,tgt_sents))[:n]
    sd, so = [], [0]
    for s,_ in pairs:
        ids = sv.encode(s,MAX_SRC_LEN)
        sd.extend(ids); so.append(len(sd))
    with open(os.path.join(out_dir,"input_data.h"),'w') as f:
        f.write("// Auto-generated\n#ifndef INPUT_DATA_H\n#define INPUT_DATA_H\n")
        f.write("#include <stdint.h>\n")
        f.write(f"#define INPUT_SENT_COUNT  {n}\n")
        f.write(f"#define INPUT_TGT_BOS     {BOS_IDX}\n")
        f.write(f"#define INPUT_TGT_EOS     {EOS_IDX}\n\n")
        f.write(f"static const uint32_t input_src_offsets[{n+1}] = {{")
        f.write(", ".join(str(x) for x in so)+"};\n\n")
        f.write(f"static const uint32_t input_src_data[{len(sd)}] = {{")
        f.write(", ".join(str(x) for x in sd)+"};\n")
        for i,(s,t) in enumerate(pairs):
            f.write(f"// sent[{i}] DE: {s.strip()}\n// sent[{i}] EN: {t.strip()}\n")
        f.write("#endif\n")
    print(f"[Export] input_data.h ({n}문장)")

################################################################################
# Main
################################################################################
def main():
    p = argparse.ArgumentParser()
    p.add_argument('--src',          default='train_lc_norm_tok.de')
    p.add_argument('--tgt',          default='train_lc_norm_tok.en')
    # ── 별도 val 파일 지정 ──────────────────────────────────────────
    p.add_argument('--val_src',      default=None,
                   help='검증 소스 파일 (미지정 시 train의 10%% 사용)')
    p.add_argument('--val_tgt',      default=None,
                   help='검증 타겟 파일 (미지정 시 train의 10%% 사용)')
    # ────────────────────────────────────────────────────────────────
    p.add_argument('--out_dir',      default='./output')
    p.add_argument('--epochs',       type=int, default=N_EPOCHS)
    p.add_argument('--batch',        type=int, default=BATCH_SIZE)
    p.add_argument('--warmup',       type=int, default=WARMUP_STEPS)
    p.add_argument('--min_freq',     type=int, default=MIN_FREQ)
    p.add_argument('--beam_size',    type=int, default=4,
                   help='Beam Search 크기 (클수록 BLEU ↑, 속도 ↓)')
    p.add_argument('--bleu_samples', type=int, default=200,
                   help='BLEU 평가 샘플 수 (0=전체)')
    p.add_argument('--bleu_every',   type=int, default=5,
                   help='몇 epoch마다 BLEU 계산')
    p.add_argument('--n_input',      type=int, default=1)
    p.add_argument('--export_only',  action='store_true')
    p.add_argument('--checkpoint',   default=None)
    # ── 이어서 학습 ──────────────────────────────────────────────────
    p.add_argument('--resume',       action='store_true',
                   help='이전 체크포인트에서 이어서 학습 '
                        '(모델/옵티마이저/스케줄러 모두 복원)')
    # ─────────────────────────────────────────────────────────────────
    args = p.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"[Device] {device}")

    # 데이터 로드
    with open(args.src) as f: src_tr = f.readlines()
    with open(args.tgt) as f: tgt_tr = f.readlines()

    # ── val 파일 분기 ────────────────────────────────────────────────
    if args.val_src and args.val_tgt:
        with open(args.val_src) as f: src_val = f.readlines()
        with open(args.val_tgt) as f: tgt_val = f.readlines()
        print(f"[Data] train={len(src_tr)}  val={len(src_val)} (별도 파일 사용)")
    else:
        nv = int(len(src_tr)*0.1)
        src_val=src_tr[-nv:]; tgt_val=tgt_tr[-nv:]
        src_tr=src_tr[:-nv];  tgt_tr=tgt_tr[:-nv]
        print(f"[Data] train={len(src_tr)}  val={len(src_val)} (train 10%% 분할)")
    # ─────────────────────────────────────────────────────────────────

    # Vocab (train 데이터로만 구축)
    sv = Vocab(args.min_freq).build(src_tr)
    tv = Vocab(args.min_freq).build(tgt_tr)
    print(f"[Vocab] DE={len(sv)}  EN={len(tv)}")
    sv.save(os.path.join(args.out_dir,'vocab_src.txt'))
    tv.save(os.path.join(args.out_dir,'vocab_tgt.txt'))

    model = Seq2SeqTransformer(len(sv), len(tv)).to(device)
    print(f"[Model] params={sum(p.numel() for p in model.parameters() if p.requires_grad):,}")

    if args.export_only:
        ck = args.checkpoint or os.path.join(args.out_dir,'transformer_best.pt')
        model.load_state_dict(torch.load(ck, map_location=device)['model'])
        export_weights(model, args.out_dir, sv, tv)
        export_header(sv, tv, args.out_dir)
        export_input_data(sv, tv, src_val, tgt_val, args.out_dir, args.n_input)
        return

    tr_ds = TranslationDataset(src_tr,  tgt_tr,  sv, tv)
    va_ds = TranslationDataset(src_val, tgt_val, sv, tv)
    tr_ld = DataLoader(tr_ds, args.batch, shuffle=True,  collate_fn=collate_fn,
                       num_workers=2, pin_memory=(device.type=='cuda'))
    va_ld = DataLoader(va_ds, args.batch, shuffle=False, collate_fn=collate_fn, num_workers=2)
    print(f"[Data] 필터 후 train={len(tr_ds)}  val={len(va_ds)}")

    crit  = nn.CrossEntropyLoss(ignore_index=PAD_IDX, label_smoothing=0.1)
    opt   = torch.optim.Adam(model.parameters(), lr=1., betas=(0.9,0.98), eps=1e-9)
    sched = WarmupScheduler(opt, D_MODEL, args.warmup)

    best_bleu = 0.; best_loss = float('inf')
    best_path = os.path.join(args.out_dir,'transformer_best.pt')
    start_epoch = 1   # 기본 시작 epoch

    # ── 이어서 학습: 체크포인트 복원 ────────────────────────────────
    if args.resume:
        ck_path = args.checkpoint or best_path
        if not os.path.exists(ck_path):
            print(f"[Resume] 체크포인트 없음: {ck_path}")
            print(f"[Resume] 처음부터 학습을 시작합니다.")
        else:
            ck = torch.load(ck_path, map_location=device)
            model.load_state_dict(ck['model'])
            if 'optimizer' in ck:
                opt.load_state_dict(ck['optimizer'])
            if 'sched_step' in ck:
                sched.n = ck['sched_step']
            start_epoch = ck.get('epoch', 0) + 1
            best_bleu   = ck.get('bleu',     0.)
            best_loss   = ck.get('val_loss',  float('inf'))
            print(f"[Resume] ✅ 복원 완료: {ck_path}")
            print(f"[Resume]   이전 epoch={start_epoch-1}  "
                  f"BLEU={best_bleu:.2f}  val_loss={best_loss:.4f}")
            print(f"[Resume]   {start_epoch} epoch 부터 이어서 학습합니다.")
    # ─────────────────────────────────────────────────────────────────

    print("\n"+"="*76)
    print(f"{'Ep':>4} {'TrLoss':>8} {'VaLoss':>8} {'PPL':>7} {'BLEU':>7} {'LR':>10} {'Time':>7}")
    print("="*76)

    for ep in range(start_epoch, args.epochs + 1):
        t0    = time.time()
        tl    = train_epoch(model, tr_ld, crit, opt, sched, device)
        vl    = eval_epoch(model, va_ld, crit, device)
        ppl   = math.exp(min(vl,10))
        elapsed = time.time()-t0

        bleu_v, bleu_s = 0., "    -"
        if ep % args.bleu_every == 0 or ep == args.epochs:
            bleu_v = eval_bleu(model, src_val, tgt_val, sv, tv, device,
                               args.beam_size, args.bleu_samples)
            bleu_s = f"{bleu_v:7.2f}"

        print(f"{ep:>4} {tl:>8.4f} {vl:>8.4f} {ppl:>7.2f} {bleu_s} "
              f"{sched.lr:>10.2e} {elapsed:>6.1f}s")

        # 최고 BLEU 또는 최저 loss 기준으로 저장
        save = False
        if bleu_v > best_bleu:   best_bleu = bleu_v; save = True
        if vl     < best_loss:   best_loss = vl;     save = True
        if save:
            torch.save({
                'epoch':     ep,
                'model':     model.state_dict(),
                'optimizer': opt.state_dict(),    # ← 옵티마이저 상태 저장
                'sched_step':sched.n,              # ← 스케줄러 스텝 저장
                'val_loss':  vl,
                'bleu':      bleu_v,
                'sv':        len(sv),
                'tv':        len(tv),
            }, best_path)
            tag = f"BLEU={bleu_v:.2f}" if bleu_v > 0 else f"loss={vl:.4f}"
            print(f"     ✓ checkpoint saved ({tag})")

        # 번역 예시
        if ep % args.bleu_every == 0:
            ex = src_val[0].strip(); ref = tgt_val[0].strip()
            hyp = beam_search(model, ex, sv, tv, device, args.beam_size)
            print(f"     DE : {ex[:72]}")
            print(f"     REF: {ref[:72]}")
            print(f"     HYP: {hyp[:72]}")

    print("="*76)
    if start_epoch > args.epochs:
        print(f"[완료] 이미 {args.epochs} epoch 완료된 체크포인트입니다.")
        print(f"       더 학습하려면 --epochs 를 늘려주세요. (예: --epochs {args.epochs+20})")
    else:
        goal = "✅ 달성!" if best_bleu>=15. else "❌ 미달 (epoch 늘리거나 beam 키우세요)"
        print(f"[완료] 최고 BLEU={best_bleu:.2f}  목표 15.0: {goal}")

    # Export
    model.load_state_dict(torch.load(best_path, map_location=device)['model'])
    export_weights(model, args.out_dir, sv, tv)
    export_header(sv, tv, args.out_dir)
    export_input_data(sv, tv, src_val, tgt_val, args.out_dir, args.n_input)

    print("\n[Done]")
    for fn in sorted(os.listdir(args.out_dir)):
        sz = os.path.getsize(os.path.join(args.out_dir,fn))
        print(f"   {fn:45s}  {sz:>12,} bytes")

if __name__=='__main__': main()
