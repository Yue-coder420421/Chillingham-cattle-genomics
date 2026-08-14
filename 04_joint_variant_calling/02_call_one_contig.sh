#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s CONTIG\n' "$0" >&2
    exit 2
fi

contig="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

alignment_list="$DELIVERY_ROOT/manifests/joint_calling_alignments.list"
expected_samples="$DELIVERY_ROOT/manifests/joint_calling_samples.txt"
output_dir="$PROJECT_ROOT/results/04_joint_calling/by_contig"
mkdir -p "$output_dir" "$PROJECT_ROOT/logs/joint_calling"
output="$output_dir/$contig.bcf"
complete="$output.complete.tsv"
if [[ -s "$output" && -s "$output.csi" && -s "$complete" ]]; then
    bcftools index --stats "$output" >/dev/null
    bcftools query --list-samples "$output" > "$output.samples.check"
    cmp -s "$expected_samples" "$output.samples.check"
    rm -f "$output.samples.check"
    printf 'SKIP_COMPLETE %s\n' "$contig"
    exit 0
fi

exec > >(tee -a "$PROJECT_ROOT/logs/joint_calling/$contig.log") 2>&1
printf 'START contig=%s time=%s\n' "$contig" "$(date --iso-8601=seconds)"
output_part="$output.part.bcf"
rm -f -- "$output_part" "$output_part.csi" "$output.samples.part" \
    "$output.stats.txt.part" "$complete.part"
test -s "$expected_samples"
test "$(wc -l < "$expected_samples")" -eq 57
bcftools mpileup \
    --threads "$THREADS" \
    --fasta-ref "$REFERENCE" \
    --regions "$contig" \
    --min-MQ "$MIN_MAPQ" \
    --min-BQ "$MIN_BASEQ" \
    --annotate FORMAT/DP,FORMAT/AD \
    --bam-list "$alignment_list" \
    --output-type u |
    bcftools call \
        --threads "$THREADS" \
        --multiallelic-caller \
        --variants-only \
        --annotate FORMAT/GQ \
        --output-type b \
        --output "$output_part"
bcftools query --list-samples "$output_part" > "$output.samples.part"
if ! cmp -s "$expected_samples" "$output.samples.part"; then
    printf 'ERROR sample_list_mismatch contig=%s expected=%s actual=%s\n' \
        "$contig" "$expected_samples" "$output.samples.part" >&2
    exit 1
fi
bcftools index --force --threads "$THREADS" "$output_part"
bcftools index --stats "$output_part" >/dev/null
bcftools stats "$output_part" > "$output.stats.txt.part"
output_sha256="$(sha256sum "$output_part" | awk '{print $1}')"
index_sha256="$(sha256sum "$output_part.csi" | awk '{print $1}')"
mv "$output_part" "$output"
mv "$output_part.csi" "$output.csi"
mv "$output.samples.part" "$output.samples.txt"
mv "$output.stats.txt.part" "$output.stats.txt"
printf 'contig\tsamples\toutput_sha256\tindex_sha256\tscript_sha256\tcompleted_at\n' > "$complete.part"
printf '%s\t57\t%s\t%s\t%s\t%s\n' \
    "$contig" "$output_sha256" "$index_sha256" \
    "$(sha256sum "$0" | awk '{print $1}')" "$(date --iso-8601=seconds)" \
    >> "$complete.part"
mv "$complete.part" "$complete"
printf 'DONE contig=%s time=%s\n' "$contig" "$(date --iso-8601=seconds)"
