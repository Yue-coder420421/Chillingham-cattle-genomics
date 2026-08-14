#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

wait_seconds="${WAIT_SECONDS:-300}"
mkdir -p "$PROJECT_ROOT/logs"
exec 9>"$PROJECT_ROOT/logs/ipcc_compatibility_wait.lock"
flock -n 9 || { printf 'Another IPCC compatibility watcher is already running\n' >&2; exit 1; }

audit="$DELIVERY_ROOT/results/ipcc_compatibility_audit.tsv"
current_audit="$DELIVERY_ROOT/results/ipcc_compatibility_audit.current.tsv"
qc_summary="$DELIVERY_ROOT/results/ipcc_mapping_qc_summary.tsv"

count_passing_ipcc() {
    if [[ ! -s "$current_audit" ]]; then
        printf '0\n'
        return
    fi
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
                    if ($field == "status") status_field = field
                }
                next
            }
            sample_field && bytes_field && status_field &&
                $sample_field == sample && $status_field == "PASS" {print $bytes_field; exit}
        ' "$current_audit")"
        actual_bytes="$(stat -c %s "$bam" 2>/dev/null || printf 0)"
        if [[ "$expected_bytes" =~ ^[0-9]+$ ]] && [[ "$expected_bytes" == "$actual_bytes" ]] && \
            [[ -s "$bam" && -s "$bai" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

while true; do
    missing=0
    for number in 01 02 03 04 05 06; do
        bam="$PROJECT_ROOT/ipcc/IPCC${number}.ARS-UCD2.0.bam"
        bai="$bam.bai"
        if [[ ! -s "$bam" || ! -s "$bai" ]]; then
            missing=$((missing + 1))
        fi
    done
    if ((missing > 0)); then
        printf 'WAIT missing_pairs=%s time=%s\n' "$missing" "$(date --iso-8601=seconds)"
        sleep "$wait_seconds"
        continue
    fi

    if ! "$script_dir/04_refresh_partial_audit.sh"; then
        printf 'WARN ipcc_audit_refresh_failed time=%s\n' "$(date --iso-8601=seconds)" >&2
        sleep "$wait_seconds"
        continue
    fi

    ipcc_pass="$(count_passing_ipcc)"
    if [[ "$ipcc_pass" -ne 6 ]]; then
        printf 'WAIT audited_pass=%s/6 time=%s\n' "$ipcc_pass" "$(date --iso-8601=seconds)"
        sleep "$wait_seconds"
        continue
    fi

    cp "$current_audit" "$audit.part.$$"
    mv "$audit.part.$$" "$audit"
    if [[ ! -s "$qc_summary" ]]; then
        printf 'RESUME_IPCC_QC time=%s\n' "$(date --iso-8601=seconds)"
        "$script_dir/05_build_ipcc_qc.sh"
    fi
    printf 'DONE_GATE report=%s time=%s\n' "$audit" "$(date --iso-8601=seconds)"
    exit 0
done
