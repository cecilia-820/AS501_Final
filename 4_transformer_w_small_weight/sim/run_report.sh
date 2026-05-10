#!/bin/bash
################################################################################
## AS501/AS603
## Final Project
## Run RTL Result Report Script
################################################################################

set -e

THIS_SCRIPT_DIR="$(realpath "$(dirname "$BASH_SOURCE")")"
REPORT_PY="$THIS_SCRIPT_DIR/utils_rtl/report_iomem_dump.py"
DUMP_TXT="$THIS_SCRIPT_DIR/out/lstm_iomem_dump.txt"
PYTHON_BIN="${PYTHON:-python3}"

if [ ! -f "$REPORT_PY" ]; then
    echo "Error: report script not found: $REPORT_PY"
    exit 1
fi

if [ ! -f "$DUMP_TXT" ]; then
    echo "Error: dump file not found: $DUMP_TXT"
    echo "Run ./run_vcs.sh first."
    exit 1
fi

echo "[report] python=$PYTHON_BIN"
echo "[report] dump=$DUMP_TXT"
"$PYTHON_BIN" "$REPORT_PY" --iomem-dump "$DUMP_TXT" "$@"
