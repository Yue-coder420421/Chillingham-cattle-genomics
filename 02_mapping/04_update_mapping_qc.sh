#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

mkdir -p "$PROJECT_ROOT/logs" "$DELIVERY_ROOT/results"
exec 9>"$PROJECT_ROOT/logs/mapping_qc.lock"
flock 9

python_exe="python"
if ! command -v "$python_exe" >/dev/null 2>&1; then
    python_exe="python3"
fi
output="$DELIVERY_ROOT/results/mapping_qc_summary.tsv"
temporary="$output.part.$$"
trap 'rm -f -- "$temporary"' EXIT
"$python_exe" "$script_dir/03_build_mapping_qc.py" \
    --manifest "$MAPPING_MANIFEST" \
    --mapping-root "$PROJECT_ROOT/results/02_mapping" \
    --output "$temporary"
mv "$temporary" "$output"
