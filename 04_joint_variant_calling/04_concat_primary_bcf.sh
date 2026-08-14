#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

input_list="$DELIVERY_ROOT/manifests/primary_bcf.list"
expected_samples="$DELIVERY_ROOT/manifests/joint_calling_samples.txt"
output_dir="$PROJECT_ROOT/results/04_joint_calling"
output="$output_dir/ARS-UCD2.0.primary.57_biological_samples.bcf"
complete="$output.complete.tsv"
mkdir -p "$output_dir"
test -s "$expected_samples"
test "$(wc -l < "$expected_samples")" -eq 57

if [[ -s "$output" && -s "$output.csi" && -s "$complete" ]]; then
    bcftools index --stats "$output" >/dev/null
    bcftools query --list-samples "$output" > "$output.samples.check"
    cmp -s "$expected_samples" "$output.samples.check"
    rm -f "$output.samples.check"
    printf 'SKIP_COMPLETE output=%s\n' "$output"
    exit 0
fi

: > "$input_list.part"
while read -r contig; do
    input="$output_dir/by_contig/$contig.bcf"
    test -s "$input"
    test -s "$input.csi"
    test -s "$input.complete.tsv"
    bcftools query --list-samples "$input" > "$input.samples.check"
    cmp -s "$expected_samples" "$input.samples.check"
    rm -f "$input.samples.check"
    printf '%s\n' "$input" >> "$input_list.part"
done < "$DELIVERY_ROOT/manifests/primary_contigs.txt"
test "$(wc -l < "$input_list.part")" -eq 31
mv "$input_list.part" "$input_list"

output_part="$output.part.bcf"
rm -f -- "$output_part" "$output_part.csi" "$output.stats.txt.part" \
    "$output.samples.part" "$output.md5.part" "$complete.part"
bcftools concat --threads "$THREADS" --file-list "$input_list" \
    --output-type b --output "$output_part"
bcftools query --list-samples "$output_part" > "$output.samples.part"
cmp -s "$expected_samples" "$output.samples.part"
bcftools index --force --threads "$THREADS" "$output_part"
bcftools index --stats "$output_part" >/dev/null
bcftools stats --samples - "$output_part" > "$output.stats.txt.part"
output_sha256="$(sha256sum "$output_part" | awk '{print $1}')"
index_sha256="$(sha256sum "$output_part.csi" | awk '{print $1}')"
mv "$output_part" "$output"
mv "$output_part.csi" "$output.csi"
mv "$output.stats.txt.part" "$output.stats.txt"
mv "$output.samples.part" "$DELIVERY_ROOT/results/joint_vcf_samples.txt"
md5sum "$output" "$output.csi" > "$output.md5.part"
mv "$output.md5.part" "$output.md5"
printf 'samples\tcontigs\toutput_sha256\tindex_sha256\tscript_sha256\tcompleted_at\n' > "$complete.part"
printf '57\t31\t%s\t%s\t%s\t%s\n' \
    "$output_sha256" "$index_sha256" "$(sha256sum "$0" | awk '{print $1}')" \
    "$(date --iso-8601=seconds)" >> "$complete.part"
mv "$complete.part" "$complete"
