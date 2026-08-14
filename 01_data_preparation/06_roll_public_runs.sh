#!/usr/bin/env bash
set -euo pipefail

layout="${1:-PE}"
if [[ "$layout" != "SE" && "$layout" != "PE" ]]; then
    printf 'Usage: %s SE|PE\n' "$0" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env
python_exe="python"
if ! command -v "$python_exe" >/dev/null 2>&1; then
    python_exe="python3"
fi

max_runs="${MAX_RUNS:-0}"
completed=0
awk -F '\t' -v layout="$layout" 'NR > 1 && $3 == layout && $6 == "public_fastq" {printf "%.0f\t%s\n", ($9 + $10), $1}' "$MAPPING_MANIFEST" |
    sort -n |
    while IFS=$'\t' read -r input_bytes run; do
        if [[ "$max_runs" -gt 0 && "$completed" -ge "$max_runs" ]]; then
            break
        fi
        if [[ -s "$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv" ]]; then
            continue
        fi
        "$python_exe" "$script_dir/04_download_public_fastq.py" \
            --manifest "$DELIVERY_ROOT/manifests/ena_download_manifest.tsv" \
            --root "$PROJECT_ROOT" \
            --layout "$layout" \
            --sample "$run" \
            --workers 1 \
            --min-free-gb "$MIN_FREE_GB"
        REMOVE_INPUT_AFTER_SUCCESS=1 "$script_dir/../02_illumina_mapping/01_map_one_run.sh" "$run"
        completed=$((completed + 1))
    done
