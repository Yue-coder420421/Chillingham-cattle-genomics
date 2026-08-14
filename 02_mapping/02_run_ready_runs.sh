#!/usr/bin/env bash
set -euo pipefail

layout="${1:-ALL}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

tail -n +2 "$MAPPING_MANIFEST" |
    sort -t $'\t' -k9,9n -k10,10n |
    while IFS=$'\t' read -r run biological_sample row_layout read1_rel read2_rel rest; do
        if [[ "$layout" != "ALL" && "$layout" != "$row_layout" ]]; then
            continue
        fi
        if [[ ! -s "$PROJECT_ROOT/$read1_rel" ]]; then
            continue
        fi
        if [[ "$row_layout" == "PE" && ! -s "$PROJECT_ROOT/$read2_rel" ]]; then
            continue
        fi
        if [[ -s "$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv" ]]; then
            continue
        fi
        "$script_dir/01_map_one_run.sh" "$run"
    done
