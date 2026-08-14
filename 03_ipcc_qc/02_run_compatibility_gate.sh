#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

mkdir -p "$PROJECT_ROOT/logs"
exec 9>"$PROJECT_ROOT/logs/ipcc_partial_audit.lock"
flock 9

python "$script_dir/../01_data_preparation/02_check_reference_compatibility.py" \
    --fasta "$REFERENCE" \
    --sq "$IPCC_SQ" \
    --report "$DELIVERY_ROOT/results/reference_vs_ipcc_sq.tsv"

python "$script_dir/01_audit_ipcc_bams.py" \
    --ipcc-dir "$PROJECT_ROOT/ipcc" \
    --expected-sq "$IPCC_SQ" \
    --expected-md5 "$IPCC_MD5" \
    --output "$DELIVERY_ROOT/results/ipcc_compatibility_audit.tsv"

flock -u 9
exec 9>&-
"$script_dir/05_build_ipcc_qc.sh"
