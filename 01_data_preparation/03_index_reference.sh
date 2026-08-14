#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

report="$DELIVERY_ROOT/results/reference_vs_ipcc_sq.tsv"
python_exe="python"
if ! command -v "$python_exe" >/dev/null 2>&1; then
    python_exe="python3"
fi
expected_report_lines="$(( $(grep -c '^@SQ' "$IPCC_SQ") + 1 ))"
if [[ ! -s "$report" ]] || [[ "$(wc -l < "$report")" -ne "$expected_report_lines" ]] || grep -q $'\tFALSE$' "$report"; then
    "$python_exe" "$script_dir/02_check_reference_compatibility.py" \
        --fasta "$REFERENCE" --sq "$IPCC_SQ" --report "$report"
fi

samtools faidx "$REFERENCE"
picard CreateSequenceDictionary \
    R="$REFERENCE" \
    O="${REFERENCE%.*}.dict"
bwa-mem2 index "$REFERENCE"
md5sum "$REFERENCE" > "$REFERENCE.md5"
