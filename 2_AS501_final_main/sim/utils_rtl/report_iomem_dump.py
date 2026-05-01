import argparse
import math
import random
import re
import struct
import sys
from pathlib import Path
from typing import Dict, List, Tuple

THIS_DIR = Path(__file__).resolve().parent
AS501_DIR = THIS_DIR.parents[1]
PROC_DIR = AS501_DIR / "program" / "processed"

DEFAULT_DUMP = AS501_DIR / "sim" / "out" / "lstm_iomem_dump.txt"
DEFAULT_REF = PROC_DIR / "val.tgt.u32bin"
DEFAULT_SRC = PROC_DIR / "val.src.u32bin"
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


def read_u32_dataset(path: Path) -> List[List[int]]:
    seqs: List[List[int]] = []
    with open(path, "rb") as f:
        while True:
            nbuf = f.read(4)
            if not nbuf:
                break
            (length,) = struct.unpack("<I", nbuf)
            data = f.read(4 * length)
            if len(data) != 4 * length:
                raise RuntimeError(f"Truncated u32 dataset: {path}")
            ids = list(struct.unpack("<" + "I" * length, data))
            seqs.append(ids)
    return seqs


def read_summary_dataset(path: Path) -> Tuple[List[List[int]], Dict[str, int]]:
    sent_re = re.compile(r"^sent\[(\d+)\]\.tok=(.*)$")
    kv_re = re.compile(r"^(status|sentence_count|used)=(.+)$")
    seqs: Dict[int, List[int]] = {}
    meta: Dict[str, int] = {
        "status": 0,
        "sentence_count": 0,
        "used_u32": 0,
        "available_words": 0,
        "parsed_sentences": 0,
        "decode_mode": "summary_text",
    }

    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            m_kv = kv_re.match(line)
            if m_kv:
                key = m_kv.group(1)
                val = int(m_kv.group(2))
                if key == "status":
                    meta["status"] = val
                elif key == "sentence_count":
                    meta["sentence_count"] = val
                elif key == "used":
                    meta["used_u32"] = val
                continue
            m_sent = sent_re.match(line)
            if m_sent:
                idx = int(m_sent.group(1))
                tail = m_sent.group(2).strip()
                seqs[idx] = [] if tail == "" else [int(tok) for tok in tail.split()]

    ordered = [seqs[i] for i in sorted(seqs.keys())]
    meta["parsed_sentences"] = len(ordered)
    meta["available_words"] = meta["used_u32"] + 3
    if meta["sentence_count"] == 0:
        meta["sentence_count"] = len(ordered)
    return ordered, meta


def read_iomem_dump_dataset(path: Path) -> Tuple[List[List[int]], Dict[str, int]]:
    if path.suffix == ".txt":
        with open(path, "r", encoding="utf-8") as f:
            first_nonempty = ""
            for raw in f:
                if raw.strip():
                    first_nonempty = raw.strip()
                    break
        if first_nonempty.startswith("status="):
            return read_summary_dataset(path)

    addr_val_re = re.compile(
        r"^\s*ADDR\[0x([0-9a-fA-F]+)\]\s*:\s*0x([0-9a-fA-F]+)(?:\s*,\s*dec=\d+)?\s*$"
    )
    words_by_addr: Dict[int, int] = {}

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = addr_val_re.match(line)
            if not m:
                continue
            addr = int(m.group(1), 16)
            val = int(m.group(2), 16)
            words_by_addr[addr] = val

    if not words_by_addr:
        raise RuntimeError(f"No ADDR lines found in IOMEM dump: {path}")

    addrs = sorted(words_by_addr.keys())
    words = [words_by_addr[a] for a in addrs]
    if len(words) < 3:
        raise RuntimeError(f"IOMEM dump is too short (need >=3 words): {path}")

    status = int(words[0])
    sentence_count = int(words[1])
    used_u32 = int(words[2])

    data_words = words[3:]

    def parse_sequences(payload: List[int]) -> List[List[int]]:
        seqs_local: List[List[int]] = []
        idx_local = 0
        while idx_local < len(payload):
            out_len = int(payload[idx_local])
            idx_local += 1
            if idx_local + out_len > len(payload):
                break
            seqs_local.append(payload[idx_local : idx_local + out_len])
            idx_local += out_len
        return seqs_local

    def parse_single_flat_sentence(payload: List[int]) -> List[List[int]]:
        if sentence_count != 1:
            return []
        seq = list(payload)
        while seq and seq[-1] == 0:
            seq.pop()
        if not seq:
            return []
        return [seq]

    payload = data_words[: min(used_u32, len(data_words))]
    seqs = parse_sequences(payload)
    mode = "word_u32"
    available_u32 = len(data_words)

    if not seqs:
        flat_word = parse_single_flat_sentence(payload)
        if flat_word:
            mode = "word_u32_flat_single_sentence"
            seqs = flat_word

    if used_u32 > available_u32:
        print(
            f"[Warn] IOMEM dump truncated for mode={mode}: used_u32={used_u32}, "
            f"available_u32={available_u32}"
        )

    if sentence_count != len(seqs):
        print(f"[Warn] sentence_count mismatch: header={sentence_count}, parsed={len(seqs)} (mode={mode})")

    meta = {
        "status": status,
        "sentence_count": sentence_count,
        "used_u32": min(used_u32, available_u32),
        "available_words": len(words),
        "parsed_sentences": len(seqs),
        "decode_mode": mode,
    }
    return seqs, meta


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
    length = len(tokens)
    if length < n:
        return d
    for i in range(length - n + 1):
        key = ",".join(str(tokens[i + j]) for j in range(n))
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

    p = [(match[k] + smooth_k) / (total[k] + smooth_k) for k in range(n)]
    geo_mean = math.exp(sum((1.0 / n) * math.log(pk) for pk in p))

    if hyp_len_sum == 0:
        return 0.0
    bp = 1.0 if hyp_len_sum > ref_len_sum else math.exp(1.0 - (ref_len_sum / hyp_len_sum))
    return 100.0 * bp * geo_mean


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="BLEU/report from TB IOMEM dump")
    p.add_argument("--iomem-dump", type=str, default=str(DEFAULT_DUMP))
    p.add_argument("--ref-bin", type=str, default=str(DEFAULT_REF))
    p.add_argument("--src-bin", type=str, default=str(DEFAULT_SRC))
    p.add_argument("--test", action="store_true", help="Use test split defaults")
    p.add_argument("--vocab-src", type=str, default=str(VOCAB_SRC))
    p.add_argument("--vocab-tgt", type=str, default=str(VOCAB_TGT))
    p.add_argument("--samples", type=int, default=10)
    return p.parse_args()


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    args = parse_args()
    ref_bin = args.ref_bin
    src_bin = args.src_bin
    split_name = "val"
    if args.test:
        split_name = "test"
        ref_bin = str(TEST_REF)
        src_bin = str(TEST_SRC)

    src_itos, src_stoi = load_vocab_txt(Path(args.vocab_src))
    tgt_itos, tgt_stoi = load_vocab_txt(Path(args.vocab_tgt))
    src_pad, src_bos, src_eos = src_stoi[SPECIAL_PAD], src_stoi[SPECIAL_BOS], src_stoi[SPECIAL_EOS]
    tgt_pad, tgt_bos, tgt_eos = tgt_stoi[SPECIAL_PAD], tgt_stoi[SPECIAL_BOS], tgt_stoi[SPECIAL_EOS]

    print(f"[Data] split={split_name} iomem_dump={args.iomem_dump}")
    print(f"[Data] split={split_name} ref={ref_bin}")
    print(f"[Data] split={split_name} src={src_bin}")

    hyp_ids_all, meta = read_iomem_dump_dataset(Path(args.iomem_dump))
    print(
        "[IOMEM] "
        f"status=0x{meta['status']:08x} "
        f"sentence_count={meta['sentence_count']} "
        f"used_u32={meta['used_u32']} "
        f"parsed_sentences={meta['parsed_sentences']} "
        f"dump_words={meta['available_words']} "
        f"mode={meta['decode_mode']}"
    )

    ref_ids_all = read_u32_dataset(Path(ref_bin))
    src_ids_all = read_u32_dataset(Path(src_bin))

    n = min(len(hyp_ids_all), len(ref_ids_all), len(src_ids_all))
    if n <= 0:
        raise RuntimeError("No comparable sentences.")

    hyps_for_bleu = [strip_special(hyp_ids_all[i], tgt_bos, tgt_eos, tgt_pad) for i in range(n)]
    refs_for_bleu = [strip_special(ref_ids_all[i], tgt_bos, tgt_eos, tgt_pad) for i in range(n)]

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
