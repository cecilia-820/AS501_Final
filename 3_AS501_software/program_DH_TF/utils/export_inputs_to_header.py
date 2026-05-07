##################################################################################
## AS501/AS603                                                                                                                                     ##
##################################################################################
## Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST       ##
## All rights reserved.                                                         ##
##                                                                              ##
##                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) ##
##                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)##
##################################################################################

#!/usr/bin/env python3
import argparse
import struct
from pathlib import Path
from typing import List, Tuple


THIS_FILE = Path(__file__).resolve()
AS501_ROOT = THIS_FILE.parents[1]          # .../AS501_final/program
PROJECT_ROOT = THIS_FILE.parents[2]        # .../AS501_final
DEFAULT_PROCESSED = PROJECT_ROOT / "processed"
DEFAULT_OUT_H = AS501_ROOT / "test_code" / "input_data.h"
DEFAULT_OUT_C = AS501_ROOT / "test_code" / "input_data.c"


def read_u32_dataset(path: Path) -> List[List[int]]:
    seqs: List[List[int]] = []
    with open(path, "rb") as f:
        while True:
            nbuf = f.read(4)
            if not nbuf:
                break
            (L,) = struct.unpack("<I", nbuf)
            data = f.read(4 * L)
            if len(data) != 4 * L:
                raise RuntimeError(f"Truncated u32 dataset: {path}")
            seqs.append(list(struct.unpack("<" + "I" * L, data)))
    return seqs


def flatten_with_offsets(seqs: List[List[int]]) -> Tuple[List[int], List[int], int]:
    offsets = [0]
    flat: List[int] = []
    max_len = 0
    for s in seqs:
        flat.extend(s)
        offsets.append(len(flat))
        if len(s) > max_len:
            max_len = len(s)
    return flat, offsets, max_len


def load_vocab(path: Path) -> Tuple[List[str], int, int, int]:
    toks: List[str] = []
    bos = -1
    eos = -1
    unk = -1
    with open(path, "r", encoding="utf-8") as f:
        for i, line in enumerate(f):
            tok = line.rstrip("\n")
            if not tok:
                continue
            toks.append(tok)
            if tok == "<bos>":
                bos = i
            if tok == "<eos>":
                eos = i
            if tok == "<unk>":
                unk = i
    if bos < 0 or eos < 0:
        raise RuntimeError(f"Missing <bos>/<eos> in vocab: {path}")
    if unk < 0:
        unk = 1
    return toks, bos, eos, unk


def write_u32_array_def(
    f, name: str, arr: List[int], per_line: int = 12, prefix: str = ""
) -> None:
    f.write(f"{prefix}const uint32_t {name}[{len(arr)}] = {{\n")
    for i in range(0, len(arr), per_line):
        chunk = arr[i : i + per_line]
        line = ", ".join(str(int(x)) for x in chunk)
        if i + per_line < len(arr):
            f.write(f"    {line},\n")
        else:
            f.write(f"    {line}\n")
    f.write("};\n\n")


def main() -> None:
    ap = argparse.ArgumentParser(description="Export processed datasets/vocab to one C header")
    ap.add_argument("--processed", type=str, default=str(DEFAULT_PROCESSED))
    ap.add_argument("--split", type=str, choices=["val", "test"], default="val")
    ap.add_argument("--out-h", type=str, default=str(DEFAULT_OUT_H))
    ap.add_argument("--out-c", type=str, default=str(DEFAULT_OUT_C))
    args = ap.parse_args()

    processed = Path(args.processed)
    split = args.split
    out_h_path = Path(args.out_h)
    out_c_path = Path(args.out_c)

    src_path = processed / f"{split}.src.u32bin"
    ref_path = processed / f"{split}.tgt.u32bin"
    vocab_src_path = processed / "vocab_src.txt"
    vocab_tgt_path = processed / "vocab_tgt.txt"

    src_seqs = read_u32_dataset(src_path)
    ref_seqs = read_u32_dataset(ref_path)

    n = min(len(src_seqs), len(ref_seqs))
    src_seqs = src_seqs[:n]
    ref_seqs = ref_seqs[:n]

    src_flat, src_off, src_max_len = flatten_with_offsets(src_seqs)
    ref_flat, ref_off, ref_max_len = flatten_with_offsets(ref_seqs)

    src_vocab, src_bos, src_eos, src_unk = load_vocab(vocab_src_path)
    tgt_vocab, tgt_bos, tgt_eos, tgt_unk = load_vocab(vocab_tgt_path)

    out_h_path.parent.mkdir(parents=True, exist_ok=True)
    out_c_path.parent.mkdir(parents=True, exist_ok=True)
    guard = f"INPUT_DATA_{split.upper()}_H"

    with open(out_h_path, "w", encoding="utf-8") as f:
        f.write(f"#ifndef {guard}\n")
        f.write(f"#define {guard}\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("/* Auto-generated input header */\n")
        f.write(f"#define INPUT_SPLIT_{split.upper()} 1\n")
        f.write(f"#define INPUT_SENT_COUNT {n}\n")
        f.write(f"#define INPUT_SRC_MAX_LEN {src_max_len}\n")
        f.write(f"#define INPUT_REF_MAX_LEN {ref_max_len}\n")
        f.write(f"#define INPUT_SRC_VOCAB {len(src_vocab)}\n")
        f.write(f"#define INPUT_TGT_VOCAB {len(tgt_vocab)}\n")
        f.write(f"#define INPUT_SRC_BOS {src_bos}\n")
        f.write(f"#define INPUT_SRC_EOS {src_eos}\n")
        f.write(f"#define INPUT_SRC_UNK {src_unk}\n")
        f.write(f"#define INPUT_TGT_BOS {tgt_bos}\n")
        f.write(f"#define INPUT_TGT_EOS {tgt_eos}\n")
        f.write(f"#define INPUT_TGT_UNK {tgt_unk}\n\n")

        f.write(f"extern const uint32_t input_src_offsets[{len(src_off)}];\n")
        f.write(f"extern const uint32_t input_src_data[{len(src_flat)}];\n")
        f.write(f"extern const uint32_t input_ref_offsets[{len(ref_off)}];\n")
        f.write(f"extern const uint32_t input_ref_data[{len(ref_flat)}];\n\n")

        f.write(f"#endif /* {guard} */\n")

    with open(out_c_path, "w", encoding="utf-8") as f:
        f.write(f'#include "{out_h_path.name}"\n\n')
        f.write("#define PLACE_IN_INPUT __attribute__((section(\".input\"), used))\n\n")
        place = "PLACE_IN_INPUT "
        write_u32_array_def(f, "input_src_offsets", src_off, prefix=place)
        write_u32_array_def(f, "input_src_data", src_flat, prefix=place)
        write_u32_array_def(f, "input_ref_offsets", ref_off, prefix=place)
        write_u32_array_def(f, "input_ref_data", ref_flat, prefix=place)

    print(f"[Save] header: {out_h_path}")
    print(f"[Save] source: {out_c_path}")
    print(f"[Data] split={split} n={n} src_max={src_max_len} ref_max={ref_max_len}")


if __name__ == "__main__":
    main()
