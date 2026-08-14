#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env
parallel_contigs="${PARALLEL_CONTIGS:-2}"
calling_threads="${CALLING_THREADS_PER_CONTIG:-8}"

if ((parallel_contigs < 1 || parallel_contigs > 2)); then
    printf 'PARALLEL_CONTIGS must be between 1 and 2 until a larger layout is accepted: %s\n' \
        "$parallel_contigs" >&2
    exit 2
fi
if ((calling_threads < 1 || calling_threads > 8)); then
    printf 'CALLING_THREADS_PER_CONTIG must be between 1 and 8: %s\n' "$calling_threads" >&2
    exit 2
fi

ipcc_audit="$DELIVERY_ROOT/results/ipcc_compatibility_audit.tsv"
ipcc_current_audit="$DELIVERY_ROOT/results/ipcc_compatibility_audit.current.tsv"
test -s "$ipcc_audit"
test -s "$ipcc_current_audit"
cmp -s "$ipcc_audit" "$ipcc_current_audit" || {
    printf 'Final and current IPCC audits differ; refusing production Calling\n' >&2
    exit 1
}
ipcc_pass_count=0
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
    ' "$ipcc_current_audit")"
    actual_bytes="$(stat -c %s "$bam" 2>/dev/null || printf 0)"
    if [[ "$expected_bytes" =~ ^[0-9]+$ ]] && \
        [[ "$expected_bytes" == "$actual_bytes" ]] && [[ -s "$bam" && -s "$bai" ]]; then
        samtools quickcheck -v "$bam"
        ipcc_pass_count=$((ipcc_pass_count + 1))
    fi
done
if [[ "$ipcc_pass_count" -ne 6 ]]; then
    printf 'IPCC compatibility gate has %s/6 passing BAMs\n' "$ipcc_pass_count" >&2
    exit 1
fi
if (( $(free_bytes) < MIN_FREE_GB * 1024 * 1024 * 1024 )); then
    printf 'Insufficient free space before joint calling\n' >&2
    exit 1
fi
memory_current="$(cat )"
if ((memory_current >= )); then
    printf 'Cgroup memory is above the 72 GiB Calling launch gate: %s\n' \
        "$memory_current" >&2
    exit 1
fi

python "$script_dir/00_make_contig_lists.py" \
    --sq "$IPCC_SQ" \
    --output-dir "$DELIVERY_ROOT/manifests"
python "$script_dir/01_build_alignment_list.py" \
    --mapping-manifest "$MAPPING_MANIFEST" \
    --mapping-root "$PROJECT_ROOT/results/02_mapping" \
    --ipcc-dir "$PROJECT_ROOT/ipcc" \
    --output "$DELIVERY_ROOT/manifests/joint_calling_alignments.list" \
    --summary "$DELIVERY_ROOT/results/joint_calling_alignment_inputs.tsv" \
    --sample-list "$DELIVERY_ROOT/manifests/joint_calling_samples.txt"

test "$(wc -l < "$DELIVERY_ROOT/manifests/joint_calling_alignments.list")" -eq 120
test "$(wc -l < "$DELIVERY_ROOT/manifests/joint_calling_samples.txt")" -eq 57

printf 'CALLING_CONFIG parallel_contigs=%s threads_per_contig=%s\n' \
    "$parallel_contigs" "$calling_threads"
xargs -r -n 1 -P "$parallel_contigs" \
    env THREADS="$calling_threads" "$script_dir/02_call_one_contig.sh" \
    < "$DELIVERY_ROOT/manifests/primary_contigs.txt"
complete_count="$(find "$PROJECT_ROOT/results/04_joint_calling/by_contig" \
    -maxdepth 1 -type f -name '*.bcf.complete.tsv' | wc -l)"
test "$complete_count" -eq 31
