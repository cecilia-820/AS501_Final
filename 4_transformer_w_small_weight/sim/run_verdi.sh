#!/bin/bash
################################################################################
## AS501/AS603
## Final Project
## Run Verdi Debug Script
################################################################################

set -e

THIS_SCRIPT_DIR="$(realpath "$(dirname "$BASH_SOURCE")")"
OUT_DIR="$THIS_SCRIPT_DIR/out"

if [ ! -d "$OUT_DIR" ]; then
    echo "Error: $OUT_DIR does not exist. Run ./run_vcs.sh first."
    exit 1
fi

cd "$OUT_DIR"

if [ ! -d "simv.daidir" ]; then
    echo "Error: simv.daidir not found in $OUT_DIR. Run ./run_vcs.sh first."
    exit 1
fi

FSDB_FILE="$(ls -t *.fsdb 2>/dev/null | head -n 1 || true)"
if [ -n "$FSDB_FILE" ]; then
    echo "[verdi] opening dbdir=simv.daidir, fsdb=$FSDB_FILE"
    verdi -dbdir simv.daidir -ssf "$FSDB_FILE" &
else
    echo "[verdi] no .fsdb found, opening dbdir=simv.daidir only"
    verdi -dbdir simv.daidir &
fi
