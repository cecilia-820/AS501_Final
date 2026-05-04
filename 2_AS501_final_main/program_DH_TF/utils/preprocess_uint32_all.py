##################################################################################
## AS501/AS603                                                                                                                                     ##
##################################################################################
## Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       ##
## All rights reserved.                                                         ##
##                                                                              ##
##                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) ##
##                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)##
##################################################################################

import re
import struct
from collections import Counter
from pathlib import Path

# -----------------------
# Config
# -----------------------
BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "dataset"

SRC_LANG = "de"
TGT_LANG = "en"

TRAIN_SRC = DATA_DIR / f"train.lc.norm.tok.{SRC_LANG}"
TRAIN_TGT = DATA_DIR / f"train.lc.norm.tok.{TGT_LANG}"

VAL_SRC = DATA_DIR / f"val.lc.norm.tok.{SRC_LANG}"
VAL_TGT = DATA_DIR / f"val.lc.norm.tok.{TGT_LANG}"

MIN_FREQ = 2
MAX_VOCAB_SIZE = 20000
MAX_TOKENS = 100

OUT_DIR = BASE_DIR / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

SPECIALS = ["<pad>", "<unk>", "<bos>", "<eos>"]

# -----------------------
# Tokenizer
# -----------------------
word_re = re.compile(r"\w+|[^\w\s]", re.UNICODE)


def tokenize(s: str):
    return word_re.findall(s.strip().lower())


def read_txt_lines(path: Path):
    if not path.exists():
        raise FileNotFoundError(f"Missing: {path}")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return [ln.strip() for ln in f if ln.strip()]


def load_parallel(src_path: Path, tgt_path: Path):
    src_lines = read_txt_lines(src_path)
    tgt_lines = read_txt_lines(tgt_path)

    if len(src_lines) != len(tgt_lines):
        raise ValueError(
            f"Line count mismatch: {src_path.name}={len(src_lines)} vs "
            f"{tgt_path.name}={len(tgt_lines)}"
        )

    return src_lines, tgt_lines


def build_vocab(sentences):
    counter = Counter()
    for sent in sentences:
        counter.update(tokenize(sent))

    words = [w for w, c in counter.items() if c >= MIN_FREQ]
    words = sorted(words, key=lambda x: (-counter[x], x))

    if MAX_VOCAB_SIZE:
        words = words[: MAX_VOCAB_SIZE - len(SPECIALS)]

    itos = SPECIALS + words
    stoi = {w: i for i, w in enumerate(itos)}
    return stoi, itos


def encode_sentence(sent, stoi):
    bos = stoi["<bos>"]
    eos = stoi["<eos>"]
    unk = stoi["<unk>"]

    toks = tokenize(sent)
    if len(toks) > MAX_TOKENS:
        return None, "len"

    ids = [bos] + [stoi.get(t, unk) for t in toks] + [eos]

    if max(ids) > 0xFFFFFFFF:
        return None, "oor"

    return ids, None


def write_ids_and_u32bin(ids_list, out_txt_path: Path, out_bin_path: Path):
    with open(out_txt_path, "w", encoding="utf-8") as ft, open(out_bin_path, "wb") as fb:
        for ids in ids_list:
            ft.write(" ".join(map(str, ids)) + "\n")
            fb.write(struct.pack("<I", len(ids)))
            fb.write(struct.pack("<" + "I" * len(ids), *ids))


def convert_parallel_split(
    src_sentences,
    tgt_sentences,
    src_stoi,
    tgt_stoi,
    split_name: str,
):
    if len(src_sentences) != len(tgt_sentences):
        raise ValueError(f"{split_name}: src/tgt line counts must match")

    src_ids_list = []
    tgt_ids_list = []

    dropped_src_len = 0
    dropped_tgt_len = 0
    dropped_src_oor = 0
    dropped_tgt_oor = 0

    for idx, (src, tgt) in enumerate(zip(src_sentences, tgt_sentences)):
        src_ids, src_err = encode_sentence(src, src_stoi)
        tgt_ids, tgt_err = encode_sentence(tgt, tgt_stoi)

        if src_err == "len":
            dropped_src_len += 1
            continue
        if tgt_err == "len":
            dropped_tgt_len += 1
            continue
        if src_err == "oor":
            dropped_src_oor += 1
            continue
        if tgt_err == "oor":
            dropped_tgt_oor += 1
            continue

        src_ids_list.append(src_ids)
        tgt_ids_list.append(tgt_ids)

        if (idx + 1) % 100000 == 0:
            print(f"  ... processed {idx + 1} pairs, kept={len(src_ids_list)}")

    write_ids_and_u32bin(
        src_ids_list,
        OUT_DIR / f"{split_name}.src.ids",
        OUT_DIR / f"{split_name}.src.u32bin",
    )
    write_ids_and_u32bin(
        tgt_ids_list,
        OUT_DIR / f"{split_name}.tgt.ids",
        OUT_DIR / f"{split_name}.tgt.u32bin",
    )

    print(
        f"[OK] {split_name}: kept_pairs={len(src_ids_list)}, "
        f"dropped_src_len={dropped_src_len}, dropped_tgt_len={dropped_tgt_len}, "
        f"dropped_src_oor={dropped_src_oor}, dropped_tgt_oor={dropped_tgt_oor}"
    )


def save_vocab(itos, out_path: Path):
    with open(out_path, "w", encoding="utf-8") as f:
        for w in itos:
            f.write(w + "\n")


def resolve_test_paths():
    canonical_src = DATA_DIR / f"test.lc.norm.tok.{SRC_LANG}"
    canonical_tgt = DATA_DIR / f"test.lc.norm.tok.{TGT_LANG}"
    if canonical_src.exists() and canonical_tgt.exists():
        return canonical_src, canonical_tgt

    src_candidates = sorted(DATA_DIR.glob(f"test*.{SRC_LANG}"))
    if not src_candidates:
        return None, None

    for src_path in src_candidates:
        stem_prefix = src_path.name[: -(len(SRC_LANG) + 1)]
        tgt_path = DATA_DIR / f"{stem_prefix}.{TGT_LANG}"
        if tgt_path.exists():
            return src_path, tgt_path

    return None, None


def maybe_convert_test(src_stoi, tgt_stoi):
    test_src, test_tgt = resolve_test_paths()
    if test_src is not None and test_tgt is not None:
        print("Loading test split...")
        print(f"  files         = {test_src.name} | {test_tgt.name}")
        test_src_lines, test_tgt_lines = load_parallel(test_src, test_tgt)
        print(f"  test src/tgt  = {len(test_src_lines)}/{len(test_tgt_lines)}")

        print("Converting test (pair-aligned txt + u32bin)...")
        convert_parallel_split(
            test_src_lines, test_tgt_lines, src_stoi, tgt_stoi, split_name="test"
        )
    else:
        print("[INFO] Test files not found. Skipping test conversion.")
        print(f"  expected pattern src: test*.{SRC_LANG}")
        print(f"  expected pattern tgt: test*.{TGT_LANG}")


def main():
    print("Loading train split...")
    train_src_lines, train_tgt_lines = load_parallel(TRAIN_SRC, TRAIN_TGT)
    print(f"  train src/tgt = {len(train_src_lines)}/{len(train_tgt_lines)}")

    print("Loading val split...")
    val_src_lines, val_tgt_lines = load_parallel(VAL_SRC, VAL_TGT)
    print(f"  val src/tgt   = {len(val_src_lines)}/{len(val_tgt_lines)}")

    print("Building vocab from train split...")
    src_stoi, src_itos = build_vocab(train_src_lines)
    tgt_stoi, tgt_itos = build_vocab(train_tgt_lines)
    print(f"  SRC vocab={len(src_itos)} | TGT vocab={len(tgt_itos)}")

    print("Saving vocab...")
    save_vocab(src_itos, OUT_DIR / "vocab_src.txt")
    save_vocab(tgt_itos, OUT_DIR / "vocab_tgt.txt")

    print("Converting train (pair-aligned txt + u32bin)...")
    convert_parallel_split(
        train_src_lines, train_tgt_lines, src_stoi, tgt_stoi, split_name="train"
    )

    print("Converting val (pair-aligned txt + u32bin)...")
    convert_parallel_split(
        val_src_lines, val_tgt_lines, src_stoi, tgt_stoi, split_name="val"
    )

    maybe_convert_test(src_stoi, tgt_stoi)

    print("Done.")


if __name__ == "__main__":
    main()
