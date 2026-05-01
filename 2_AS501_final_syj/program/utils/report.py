##################################################################################
## AS501/AS603                                                                                                                                     ##
##################################################################################
## Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       ##
## All rights reserved.                                                         ##
##                                                                              ##
##                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) ##
##                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)##
##################################################################################

import argparse
import math
import random
import re
import struct
import sys
from pathlib import Path
from typing import Dict, List, Tuple

THIS_DIR = Path(__file__).resolve().parent
PROGRAM_DIR = THIS_DIR.parent
PROC_DIR = PROGRAM_DIR / "processed"
DEFAULT_HYP = PROC_DIR / "val.hyp.int_c.u32bin"
DEFAULT_REF = PROC_DIR / "val.tgt.u32bin"
DEFAULT_SRC = PROC_DIR / "val.src.u32bin"
TEST_HYP = PROC_DIR / "test.hyp.int_c.u32bin"
TEST_REF = PROC_DIR / "test.tgt.u32bin"
TEST_SRC = PROC_DIR / "test.src.u32bin"
VOCAB_SRC = PROC_DIR / "vocab_src.txt"
VOCAB_TGT = PROC_DIR / "vocab_tgt.txt"

BLEU_N = 4
SMOOTH_K = 1.0
SPECIAL_PAD = "<pad>"
SPECIAL_BOS = "<bos>"
SPECIAL_EOS = "<eos>"


def load_vocab_txt(path: Path) -> Tuple[List[str], Dict[str, int]]:
    itos: List[str] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            w = line.rstrip("\n")
            if w:
                itos.append(w)
    stoi = {w: i for i, w in enumerate(itos)}
    return itos, stoi


def read_dataset(path: Path) -> List[List[int]]:
    if path.suffix == ".txt":
        return read_summary_dataset(path)
    if path.suffixes[-2:] == [".u32bin", ".bin"]:
        len_fmt = "<I"
        elem_fmt = "I"
        item_bytes = 4
    elif path.name.endswith(".u32bin"):
        len_fmt = "<I"
        elem_fmt = "I"
        item_bytes = 4
    else:
        len_fmt = "<H"
        elem_fmt = "H"
        item_bytes = 2

    seqs: List[List[int]] = []
    with open(path, "rb") as f:
        while True:
            nbuf = f.read(item_bytes)
            if not nbuf:
                break
            (L,) = struct.unpack(len_fmt, nbuf)
            data = f.read(item_bytes * L)
            if len(data) != item_bytes * L:
                raise RuntimeError(f"Truncated dataset: {path}")
            ids = list(struct.unpack("<" + (elem_fmt * L), data))
            seqs.append(ids)
    return seqs


def read_summary_dataset(path: Path) -> List[List[int]]:
    sent_re = re.compile(r"^sent\[(\d+)\]\.tok=(.*)$")
    seqs: Dict[int, List[int]] = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = sent_re.match(line.strip())
            if not m:
                continue
            idx = int(m.group(1))
            tail = m.group(2).strip()
            seqs[idx] = [] if tail == "" else [int(tok) for tok in tail.split()]
    return [seqs[i] for i in sorted(seqs.keys())]


def detokenize(tokens: List[str]) -> str:
    out = ""
    punct = set([".", ",", "!", "?", ";", ":", ")"])
    for i, tok in enumerate(tokens):
        if i == 0:
            out = tok
            continue
        if tok in punct:
            out += tok
        elif tok == "'":
            out += tok
        elif out.endswith("'"):
            out += tok
        elif tok == "(":
            out += " " + tok
        else:
            out += " " + tok
    return out


def safe_console_text(s: str) -> str:
    return s.encode("ascii", "backslashreplace").decode("ascii")


def ids_to_tokens(ids: List[int], itos: List[str], bos: int, eos: int, pad: int) -> List[str]:
    out: List[str] = []
    for x in ids:
        if x == bos or x == pad:
            continue
        if x == eos:
            break
        if 0 <= x < len(itos):
            out.append(itos[x])
        else:
            out.append("<unk>")
    return out


def strip_special(ids: List[int], bos: int, eos: int, pad: int) -> List[int]:
    out: List[int] = []
    for x in ids:
        if x == bos or x == pad:
            continue
        if x == eos:
            break
        out.append(int(x))
    return out


def count_ngrams(tokens: List[int], n: int) -> Dict[str, int]:
    d: Dict[str, int] = {}
    L = len(tokens)
    if L < n:
        return d
    for i in range(L - n + 1):
        key = ""
        for j in range(n):
            if j > 0:
                key += ","
            key += str(tokens[i + j])
        d[key] = d.get(key, 0) + 1
    return d


def bleu_corpus(hyps: List[List[int]], refs: List[List[int]], n: int = 4, smooth_k: float = 1.0) -> float:
    hyp_len_sum = 0
    ref_len_sum = 0

    match = [0.0] * n
    total = [0.0] * n

    for hyp, ref in zip(hyps, refs):
        hyp_len_sum += len(hyp)
        ref_len_sum += len(ref)

        for k in range(1, n + 1):
            hyp_ng = count_ngrams(hyp, k)
            ref_ng = count_ngrams(ref, k)

            m = 0
            t = 0
            for key, cnt in hyp_ng.items():
                t += cnt
                r_cnt = ref_ng.get(key, 0)
                m += cnt if cnt < r_cnt else r_cnt

            match[k - 1] += m
            total[k - 1] += t

    p = []
    for k in range(n):
        p_k = (match[k] + smooth_k) / (total[k] + smooth_k)
        p.append(p_k)

    log_sum = 0.0
    for k in range(n):
        log_sum += (1.0 / n) * math.log(p[k])
    geo_mean = math.exp(log_sum)

    if hyp_len_sum == 0:
        return 0.0
    if hyp_len_sum > ref_len_sum:
        bp = 1.0
    else:
        bp = math.exp(1.0 - (ref_len_sum / hyp_len_sum))

    return 100.0 * bp * geo_mean


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="BLEU/report from hypothesis dataset")
    p.add_argument("--hyp-bin", type=str, default=str(DEFAULT_HYP))
    p.add_argument("--ref-bin", type=str, default=str(DEFAULT_REF))
    p.add_argument("--src-bin", type=str, default=str(DEFAULT_SRC))
    p.add_argument("--test", action="store_true", help="Use test split defaults")
    p.add_argument("--vocab-src", type=str, default=str(VOCAB_SRC))
    p.add_argument("--vocab-tgt", type=str, default=str(VOCAB_TGT))
    p.add_argument("--samples", type=int, default=10)
    return p.parse_args()


def main() -> None:
    args = parse_args()
    argv = sys.argv[1:]

    hyp_bin = args.hyp_bin
    ref_bin = args.ref_bin
    src_bin = args.src_bin
    split_name = "val"

    if args.test:
        split_name = "test"
        if "--hyp-bin" not in argv:
            hyp_bin = str(TEST_HYP)
        if "--ref-bin" not in argv:
            ref_bin = str(TEST_REF)
        if "--src-bin" not in argv:
            src_bin = str(TEST_SRC)
    elif "--hyp-bin" in argv and "--ref-bin" not in argv and "--src-bin" not in argv:
        # Keep CLI short: infer split from hypothesis filename when only hyp is provided.
        hyp_name = Path(hyp_bin).name
        if hyp_name.startswith("test."):
            split_name = "test"
            ref_bin = str(TEST_REF)
            src_bin = str(TEST_SRC)

    src_itos, src_stoi = load_vocab_txt(Path(args.vocab_src))
    tgt_itos, tgt_stoi = load_vocab_txt(Path(args.vocab_tgt))

    src_pad = src_stoi[SPECIAL_PAD]
    src_bos = src_stoi[SPECIAL_BOS]
    src_eos = src_stoi[SPECIAL_EOS]

    tgt_pad = tgt_stoi[SPECIAL_PAD]
    tgt_bos = tgt_stoi[SPECIAL_BOS]
    tgt_eos = tgt_stoi[SPECIAL_EOS]

    print(f"[Data] split={split_name} hyp={hyp_bin}")
    print(f"[Data] split={split_name} ref={ref_bin}")
    print(f"[Data] split={split_name} src={src_bin}")

    hyp_ids_all = read_dataset(Path(hyp_bin))
    ref_ids_all = read_dataset(Path(ref_bin))
    src_ids_all = read_dataset(Path(src_bin))

    n = min(len(hyp_ids_all), len(ref_ids_all), len(src_ids_all))
    if n <= 0:
        raise RuntimeError("No comparable sentences.")

    hyps_for_bleu: List[List[int]] = []
    refs_for_bleu: List[List[int]] = []
    for i in range(n):
        hyps_for_bleu.append(strip_special(hyp_ids_all[i], tgt_bos, tgt_eos, tgt_pad))
        refs_for_bleu.append(strip_special(ref_ids_all[i], tgt_bos, tgt_eos, tgt_pad))

    bleu = bleu_corpus(hyps_for_bleu, refs_for_bleu, n=BLEU_N, smooth_k=SMOOTH_K)
    avg_len = sum(len(x) for x in hyps_for_bleu) / max(1, len(hyps_for_bleu))

    print(f"[Result] BLEU-{BLEU_N} ({split_name}, n={n}) = {bleu:.2f} | avg_hyp_len={avg_len:.2f}")

    k = min(args.samples, n)
    if k > 0:
        print(f"\n[Samples] random {k}")
        rnd = random.Random(0)
        idxs = rnd.sample(range(n), k=k)
        for sidx, i in enumerate(idxs, start=1):
            src_toks = ids_to_tokens(src_ids_all[i], src_itos, src_bos, src_eos, src_pad)
            ref_toks = ids_to_tokens(ref_ids_all[i], tgt_itos, tgt_bos, tgt_eos, tgt_pad)
            hyp_toks = ids_to_tokens(hyp_ids_all[i], tgt_itos, tgt_bos, tgt_eos, tgt_pad)

            print(f"\n--- Sample {sidx} (idx={i}) ---")
            print("DE :", safe_console_text(detokenize(src_toks)))
            print("REF:", safe_console_text(detokenize(ref_toks)))
            print("HYP:", safe_console_text(detokenize(hyp_toks)))


if __name__ == "__main__":
    main()
