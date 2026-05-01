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
#python3 utils/update_tb_pc_addrs.py 




import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple


THIS_DIR = Path(__file__).resolve().parent
PROGRAM_DIR = THIS_DIR.parent
AS501_DIR = PROGRAM_DIR.parent

DEFAULT_DIS = PROGRAM_DIR / "out" / "eval_int_riscv.dis"
DEFAULT_MAP = PROGRAM_DIR / "out" / "mem.map"
DEFAULT_TB = AS501_DIR / "sim" / "tb" / "lstm_tb.sv"

# TB localparam name -> disassembly symbol
PC_SYMBOL_MAP: List[Tuple[str, str]] = [
    ("PC_MAIN", "main"),
    ("PC_RESET_RESULT_BUFFER", "reset_result_buffer"),
    ("PC_APPEND_RESULT_SEQUENCE", "append_result_sequence"),
    ("PC_INIT_STATIC_BUFFERS", "init_static_buffers"),
    ("PC_GREEDY_DECODE_INT", "greedy_decode_int"),
    ("PC_LSTM_STEP_INT", "lstm_step_int"),
    ("PC_LINEAR_OUT_ARGMAX", "linear_out_argmax"),
    ("PC_EMBEDDING_LOOKUP", "embedding_lookup"),
    ("PC_ARENA_RESET", "arena_reset"),
    ("PC_ARENA_ALLOC", "arena_alloc"),
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Update PC_* function entry addresses and ResultStart in sim/tb/lstm_tb.sv"
    )
    p.add_argument("--dis", type=Path, default=DEFAULT_DIS, help=f"Disassembly file (default: {DEFAULT_DIS})")
    p.add_argument("--map", type=Path, default=DEFAULT_MAP, help=f"Linker map file (default: {DEFAULT_MAP})")
    p.add_argument("--tb", type=Path, default=DEFAULT_TB, help=f"Testbench file (default: {DEFAULT_TB})")
    p.add_argument("--dry-run", action="store_true", help="Print changes only, do not modify files")
    return p.parse_args()


def format_sv_addr(addr: int) -> str:
    s = f"{addr:08x}"
    return f"{s[:4]}_{s[4:]}"


def read_result_start_word(map_path: Path) -> int:
    text = map_path.read_text(encoding="utf-8", errors="ignore")
    input_m = re.search(r"^\s*0x([0-9a-fA-F]+)\s+_sinput\s*=\s*\.$", text, re.MULTILINE)
    result_m = re.search(r"^\s*0x([0-9a-fA-F]+)\s+_sresult\s*=\s*\.$", text, re.MULTILINE)
    if not input_m or not result_m:
        raise ValueError(f"Failed to find _sinput/_sresult in map file: {map_path}")

    input_addr = int(input_m.group(1), 16)
    result_addr = int(result_m.group(1), 16)
    if result_addr < input_addr:
        raise ValueError(
            f"Invalid section order in map file: _sresult(0x{result_addr:08x}) < _sinput(0x{input_addr:08x})"
        )
    delta = result_addr - input_addr
    if (delta % 4) != 0:
        raise ValueError(
            f"ResultStart is not word-aligned: _sinput=0x{input_addr:08x}, _sresult=0x{result_addr:08x}"
        )
    return delta // 4


def read_symbol_addrs(dis_path: Path) -> Dict[str, int]:
    text = dis_path.read_text(encoding="utf-8", errors="ignore")
    # Example: 0000165c <main>:
    pat = re.compile(r"^([0-9a-fA-F]+)\s+<([A-Za-z0-9_.$@]+)>:$", re.MULTILINE)
    sym2addr: Dict[str, int] = {}
    for m in pat.finditer(text):
        addr_hex, sym = m.group(1), m.group(2)
        if sym not in sym2addr:
            sym2addr[sym] = int(addr_hex, 16)
    return sym2addr


def update_tb(tb_path: Path, sym2addr: Dict[str, int], result_start_w: int, dry_run: bool) -> int:
    lines = tb_path.read_text(encoding="utf-8").splitlines(keepends=True)
    changed = 0

    for i, line in enumerate(lines):
        result_pat = re.compile(
            r"^(\s*localparam\s+ResultStart\s*=\s*32'h)([0-9a-fA-F_]+)(;\s*.*)$"
        )
        result_m = result_pat.match(line)
        if result_m:
            new_addr = format_sv_addr(result_start_w)
            old_addr = result_m.group(2).lower()
            if old_addr != new_addr:
                new_line = (
                    f"{result_m.group(1)}{new_addr}{result_m.group(3)}\n"
                    if not result_m.group(3).endswith("\n")
                    else f"{result_m.group(1)}{new_addr}{result_m.group(3)}"
                )
                if dry_run:
                    print(f"[DRY] {tb_path}:{i+1} ResultStart: 32'h{old_addr} -> 32'h{new_addr}")
                lines[i] = new_line
                changed += 1
            continue

        for pc_name, sym in PC_SYMBOL_MAP:
            if sym not in sym2addr:
                continue
            pat = re.compile(
                rf"^(\s*localparam\s+logic\s+\[31:0\]\s+{re.escape(pc_name)}\s*=\s*32'h)([0-9a-fA-F_]+)(;\s*.*)$"
            )
            m = pat.match(line)
            if not m:
                continue
            new_addr = format_sv_addr(sym2addr[sym])
            old_addr = m.group(2).lower()
            if old_addr != new_addr:
                new_line = f"{m.group(1)}{new_addr}{m.group(3)}\n" if not m.group(3).endswith("\n") else f"{m.group(1)}{new_addr}{m.group(3)}"
                if dry_run:
                    print(f"[DRY] {tb_path}:{i+1} {pc_name}: 32'h{old_addr} -> 32'h{new_addr}")
                lines[i] = new_line
                changed += 1
            break

    if changed > 0 and not dry_run:
        tb_path.write_text("".join(lines), encoding="utf-8")

    return changed


def main() -> int:
    args = parse_args()
    dis_path = args.dis.resolve()
    map_path = args.map.resolve()
    tb_path = args.tb.resolve()

    if not dis_path.exists():
        print(f"[ERROR] Disassembly file not found: {dis_path}", file=sys.stderr)
        return 1
    if not map_path.exists():
        print(f"[ERROR] Map file not found: {map_path}", file=sys.stderr)
        return 1
    if not tb_path.exists():
        print(f"[ERROR] Testbench file not found: {tb_path}", file=sys.stderr)
        return 1

    sym2addr = read_symbol_addrs(dis_path)
    result_start_w = read_result_start_word(map_path)
    missing = [sym for _, sym in PC_SYMBOL_MAP if sym not in sym2addr]
    if missing:
        print("[ERROR] Missing symbols in disassembly:", ", ".join(missing), file=sys.stderr)
        return 1

    changed = update_tb(tb_path, sym2addr, result_start_w, args.dry_run)
    mode = "DRY-RUN" if args.dry_run else "UPDATED"
    print(f"[{mode}] {tb_path}")
    print(f"[{mode}] changed PC entries: {changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
