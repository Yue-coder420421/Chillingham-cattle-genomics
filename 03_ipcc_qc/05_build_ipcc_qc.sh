#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

mkdir -p "$PROJECT_ROOT/logs"
exec 8>"$PROJECT_ROOT/logs/ipcc_qc.lock"
flock -n 8 || { printf 'Another IPCC QC process is already running\n' >&2; exit 1; }

audit="$DELIVERY_ROOT/results/ipcc_compatibility_audit.tsv"
output_dir="$PROJECT_ROOT/results/03_ipcc_qc"
summary="$DELIVERY_ROOT/results/ipcc_mapping_qc_summary.tsv"
temporary="$summary.part.$$"
mkdir -p "$output_dir" "$DELIVERY_ROOT/results"
trap 'rm -f -- "$temporary"' EXIT

pass_count="$(awk -F '\t' '
    NR == 1 {for (field = 1; field <= NF; field++) if ($field == "status") status_field = field; next}
    status_field && $status_field == "PASS" {count++}
    END {print count+0}
' "$audit")"
if [[ "$pass_count" -ne 6 ]]; then
    printf 'IPCC compatibility gate has %s/6 passing BAMs\n' "$pass_count" >&2
    exit 1
fi

printf 'sample\tbiological_sample_id\tlayout\ttotal_reads\tmapped_percent\tmean_coverage\talignment_status\tbam\n' > "$temporary"
for number in 01 02 03 04 05 06; do
    sample="IPCC$number"
    bam="$PROJECT_ROOT/ipcc/$sample.ARS-UCD2.0.bam"
    prefix="$output_dir/$sample"
    flagstat="$prefix.flagstat.txt"
    coverage="$prefix.mosdepth.summary.txt"
    test -s "$bam"
    test -s "$bam.bai"

    if [[ ! -s "$flagstat" ]]; then
        samtools flagstat -@ "$THREADS" "$bam" > "$flagstat.part"
        mv "$flagstat.part" "$flagstat"
    fi
    if [[ ! -s "$coverage" ]]; then
        mosdepth --threads "$THREADS" --fast-mode --no-per-base --by 100000 \
            --fasta "$REFERENCE" "$prefix" "$bam"
    fi
    rm -f -- "$prefix.per-base.bed.gz" "$prefix.per-base.bed.gz.csi"

    total_reads="$(awk 'NR == 1 {print $1; exit}' "$flagstat")"
    mapped_percent="$(awk '/ mapped \(/ {line=$0; sub(/^.*\(/, "", line); sub(/%.*$/, "", line); print line; exit}' "$flagstat")"
    mean_coverage="$(awk -F '\t' '$1 == "total" {print $4; exit}' "$coverage")"
    test -n "$total_reads"
    test -n "$mapped_percent"
    test -n "$mean_coverage"
    printf '%s\t%s\tHIFI\t%s\t%s\t%s\tPASS\t%s\n' \
        "$sample" "$sample" "$total_reads" "$mapped_percent" "$mean_coverage" "$bam" >> "$temporary"
done

mv "$temporary" "$summary"
printf 'IPCC_QC_DONE samples=6 summary=%s\n' "$summary"
