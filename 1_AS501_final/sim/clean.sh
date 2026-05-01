#!/bin/bash
set -e

THIS_SCRIPT_DIR="$(realpath "$(dirname "$BASH_SOURCE")")"
OUT_DIR="$THIS_SCRIPT_DIR/out"

# Only remove simulation output directory. Keep helper scripts (e.g., run_verdi.sh).
rm -rf "$OUT_DIR"

echo "[clean] removed: $OUT_DIR"
