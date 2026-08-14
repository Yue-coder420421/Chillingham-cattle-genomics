#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

mkdir -p "$PROJECT_ROOT/logs"
current="$DELIVERY_ROOT/results/ipcc_compatibility_audit.current.tsv"
final="$DELIVERY_ROOT/results/ipcc_compatibility_audit.tsv"
temporary="$current.part.$$"
trap 'rm -f -- "$temporary"' EXIT

count_pairs() {
    local count=0
    local number sample bam bai expected_bytes actual_bytes
    for number in 01 02 03 04 05 06; do
        sample="IPCC$number"
        bam="$PROJECT_ROOT/ipcc/$sample.ARS-UCD2.0.bam"
        bai="$bam.bai"
        expected_bytes="$(awk -F '\t' -v sample="$sample" '
            NR == 1 {
                for (field = 1; field <= NF; field++) {
                    if ($field == "sample") sample_field = field
                    if ($field == "bam_bytes") bytes_field = field
                }
                next
            }
            sample_field && bytes_field && $sample_field == sample {print $bytes_field; exit}
        ' "$final" 2>/dev/null || true)"
        actual_bytes="$(stat -c %s "$bam" 2>/dev/null || printf 0)"
        if [[ -s "$bam" && -s "$bai" ]] && \
            [[ -z "$expected_bytes" || "$actual_bytes" == "$expected_bytes" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

count_audited() {
    local audit="$1"
    if [[ ! -s "$audit" ]]; then
        printf '0\n'
        return
    fi
    awk -F '\t' '
        NR == 1 {
            for (field = 1; field <= NF; field++) {
                if ($field == "status") status_field = field
                if ($field == "bam_md5") bam_md5_field = field
                if ($field == "bai_md5") bai_md5_field = field
                if ($field == "md5_match") md5_match_field = field
            }
            next
        }
        status_field && bam_md5_field && bai_md5_field && md5_match_field &&
            $status_field == "PASS" && $bam_md5_field != "." && $bai_md5_field != "." &&
            $md5_match_field == "TRUE" {count++}
        END {print count+0}
    ' "$audit"
}

count_failed() {
    local audit="$1"
    awk -F '\t' '
        NR == 1 {
            for (field = 1; field <= NF; field++) if ($field == "status") status_field = field
            next
        }
        status_field && $status_field == "FAIL" {count++}
        END {print count+0}
    ' "$audit"
}

exec 9>"$PROJECT_ROOT/logs/ipcc_partial_audit.lock"
flock 9

pair_count="$(count_pairs)"
audited_count="$(count_audited "$current")"
if ((pair_count == audited_count)); then
    printf 'IPCC_PARTIAL_AUDIT_SKIP pairs=%s audited=%s\n' "$pair_count" "$audited_count"
    exit 0
fi

rm -f -- "$temporary"
reuse_args=()
if [[ -s "$final" && "$(count_audited "$final")" -eq 6 && "$(count_failed "$final")" -eq 0 ]]; then
    reuse_args=(--reuse-pass-from "$final")
elif [[ -s "$current" && "$audited_count" -le "$pair_count" ]]; then
    reuse_args=(--reuse-pass-from "$current")
fi
python3 "$script_dir/01_audit_ipcc_bams.py" \
    --ipcc-dir "$PROJECT_ROOT/ipcc" \
    --expected-sq "$IPCC_SQ" \
    --expected-md5 "$IPCC_MD5" \
    "${reuse_args[@]}" \
    --output "$temporary" || true

if [[ ! -s "$temporary" ]]; then
    printf 'IPCC partial audit did not produce a report\n' >&2
    exit 1
fi
row_count="$(awk 'END {print NR-1}' "$temporary")"
if [[ "$row_count" -ne 6 ]]; then
    printf 'IPCC partial audit produced %s rows instead of 6\n' "$row_count" >&2
    exit 1
fi
failed_count="$(count_failed "$temporary")"
if ((failed_count > 0)); then
    failed="$DELIVERY_ROOT/results/ipcc_compatibility_audit.failed.tsv"
    mv "$temporary" "$failed"
    printf 'IPCC partial audit found %s failed BAMs; see %s\n' "$failed_count" "$failed" >&2
    exit 1
fi

mv "$temporary" "$current"
printf 'IPCC_PARTIAL_AUDIT_UPDATED pairs=%s audited=%s\n' "$pair_count" "$(count_audited "$current")"
