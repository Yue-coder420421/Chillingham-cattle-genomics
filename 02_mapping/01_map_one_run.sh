#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s RUN_ACCESSION\n' "$0" >&2
    exit 2
fi

run="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
gpu_reserved_runs_file="${GPU_RESERVED_RUNS_FILE:-$PROJECT_ROOT/logs/gpu_reserved_runs.txt}"
if [[ -s "$gpu_reserved_runs_file" ]] && grep -Fqx -- "$run" "$gpu_reserved_runs_file"; then
    printf 'SKIP_GPU_RESERVED run=%s file=%s time=%s\n' \
        "$run" "$gpu_reserved_runs_file" "$(date --iso-8601=seconds)"
    exit 75
fi
activate_analysis_env

if [[ ! "$SORT_THREADS" =~ ^[0-9]+$ ]] || ((SORT_THREADS < 1)); then
    printf 'SORT_THREADS must be positive: %s\n' "$SORT_THREADS" >&2
    exit 2
fi
if [[ ! "$THREADS" =~ ^[0-9]+$ ]] || ((THREADS < 1)); then
    printf 'THREADS must be positive: %s\n' "$THREADS" >&2
    exit 2
fi
if [[ ! "$MAPPING_MAX_THREADS" =~ ^[0-9]+$ ]] || ((MAPPING_MAX_THREADS < 1)); then
    printf 'MAPPING_MAX_THREADS must be positive: %s\n' "$MAPPING_MAX_THREADS" >&2
    exit 2
fi
if [[ ! "$SORT_MAX_THREADS" =~ ^[0-9]+$ ]] || ((SORT_MAX_THREADS < 1)); then
    printf 'SORT_MAX_THREADS must be positive: %s\n' "$SORT_MAX_THREADS" >&2
    exit 2
fi
if ((THREADS > MAPPING_MAX_THREADS)); then
    THREADS="$MAPPING_MAX_THREADS"
fi
if ((SORT_THREADS > SORT_MAX_THREADS)); then
    SORT_THREADS="$SORT_MAX_THREADS"
fi

bwa_mem2_bin="$BWA_MEM2_STANDARD_BIN"
bwa_backend="standard"
bwa_reference_args=("$REFERENCE")
ert_marker="$BWA_MEM2_ERT_INDEX_PREFIX.complete"
ert_building="$BWA_MEM2_ERT_INDEX_PREFIX.building"
if [[ "$BWA_MEM2_BACKEND" == "auto" && -s "$ert_building" && ! -s "$ert_marker" ]]; then
    waited=0
    while [[ -s "$ert_building" && ! -s "$ert_marker" && "$waited" -lt "$BWA_MEM2_ERT_WAIT_SECONDS" ]]; do
        printf 'WAIT_ERT_INDEX waited=%s/%s marker=%s time=%s\n' \
            "$waited" "$BWA_MEM2_ERT_WAIT_SECONDS" "$ert_building" "$(date --iso-8601=seconds)"
        sleep 60
        waited=$((waited + 60))
    done
fi
case "$BWA_MEM2_BACKEND" in
    auto)
        if [[ -x "$BWA_MEM2_ERT_BIN" && -s "$ert_marker" ]]; then
            bwa_mem2_bin="$BWA_MEM2_ERT_BIN"
            bwa_backend="ert"
            bwa_reference_args=(-Z "$BWA_MEM2_ERT_INDEX_PREFIX")
        fi
        ;;
    ert)
        test -x "$BWA_MEM2_ERT_BIN"
        test -s "$ert_marker"
        bwa_mem2_bin="$BWA_MEM2_ERT_BIN"
        bwa_backend="ert"
        bwa_reference_args=(-Z "$BWA_MEM2_ERT_INDEX_PREFIX")
        ;;
    standard)
        ;;
    *)
        printf 'Unsupported BWA_MEM2_BACKEND: %s\n' "$BWA_MEM2_BACKEND" >&2
        exit 2
        ;;
esac

line="$(awk -F '\t' -v run="$run" 'NR > 1 && $1 == run {print; exit}' "$MAPPING_MANIFEST")"
if [[ -z "$line" ]]; then
    printf 'Run not found in manifest: %s\n' "$run" >&2
    exit 1
fi
IFS=$'\t' read -r run biological_sample layout read1_rel read2_rel source group sample_title read1_bytes read2_bytes read1_md5 read2_md5 <<< "$line"

read1="$PROJECT_ROOT/$read1_rel"
read2=""
if [[ "$read2_rel" != "." ]]; then
    read2="$PROJECT_ROOT/$read2_rel"
fi
sra_input="${SRA_INPUT:-}"
fasterq_memory="${FASTERQ_MEMORY:-128GB}"
fasterq_buffer="${FASTERQ_BUFFER:-32MB}"
fasterq_cursor_cache="${FASTERQ_CURSOR_CACHE:-2GB}"
if [[ -n "$sra_input" ]]; then
    if [[ "$layout" != "PE" ]]; then
        printf 'SRA_INPUT streaming mode requires a PE run: %s\n' "$run" >&2
        exit 1
    fi
    test -s "$sra_input"
    test -x "$SRA_TOOLKIT_DIR/fasterq-dump"
else
    test -s "$read1"
    if [[ "$layout" == "PE" ]]; then
        test -s "$read2"
    fi
fi
test -s "$REFERENCE"

output_dir="$PROJECT_ROOT/results/02_mapping/$run"
work_dir="$PROJECT_ROOT/results/02_mapping_work/$run"
mkdir -p "$output_dir" "$work_dir" "$PROJECT_ROOT/logs/mapping"
mapping_slots="${MAPPING_SLOTS:-1}"
mapping_reserve_slots="${MAPPING_RESERVE_SLOTS:-$mapping_slots}"
if ((mapping_slots < 1 || mapping_slots > 8)); then
    printf 'MAPPING_SLOTS must be between 1 and 8: %s\n' "$mapping_slots" >&2
    exit 2
fi
if ((mapping_reserve_slots < 1 || mapping_reserve_slots > mapping_slots)); then
    printf 'MAPPING_RESERVE_SLOTS must be between 1 and MAPPING_SLOTS: %s\n' \
        "$mapping_reserve_slots" >&2
    exit 2
fi
mapping_slot=0
mapping_lock_fd=""
for slot in $(seq 1 "$mapping_slots"); do
    exec {candidate_fd}>"$PROJECT_ROOT/logs/mapping/.slot.$slot.lock"
    if flock -n "$candidate_fd"; then
        mapping_slot="$slot"
        mapping_lock_fd="$candidate_fd"
        break
    fi
    eval "exec ${candidate_fd}>&-"
done
if [[ -z "$mapping_lock_fd" ]]; then
    printf 'All %s mapping slots are occupied\n' "$mapping_slots" >&2
    exit 1
fi
exec 9>"$output_dir/.lock"
flock -n 9 || { printf 'Run is already locked: %s\n' "$run" >&2; exit 1; }

complete="$output_dir/$run.complete.tsv"
if [[ -s "$complete" ]]; then
    printf 'SKIP_COMPLETE %s\n' "$run"
    exit 0
fi

rm -f -- "$work_dir"/sort.*.bam

exec > >(tee -a "$PROJECT_ROOT/logs/mapping/$run.log") 2>&1
printf 'START run=%s biological_sample=%s layout=%s slot=%s/%s reserve_slots=%s threads=%s sort_threads=%s sort_memory=%s time=%s\n' \
    "$run" "$biological_sample" "$layout" "$mapping_slot" "$mapping_slots" \
    "$mapping_reserve_slots" "$THREADS" "$SORT_THREADS" "$SORT_MEMORY" \
    "$(date --iso-8601=seconds)"
printf 'ALIGNER run=%s backend=%s binary=%s reference_arg=%s\n' \
    "$run" "$bwa_backend" "$bwa_mem2_bin" "${bwa_reference_args[*]}"

input_bytes=$((read1_bytes + read2_bytes))
required_free=$(((MIN_FREE_GB * 1024 * 1024 * 1024) + (MAPPING_WORK_FACTOR * input_bytes * mapping_reserve_slots)))
available_free="$(free_bytes)"
if ((available_free < required_free)); then
    printf 'ERROR insufficient_space available=%s required=%s\n' "$available_free" "$required_free" >&2
    exit 1
fi

rg="$(printf '@RG\tID:%s\tSM:%s\tLB:%s\tPL:ILLUMINA\tPU:%s' "$run" "$biological_sample" "$biological_sample" "$run")"
sorted_bam="$work_dir/$run.sorted.bam"
markdup_bam="$work_dir/$run.markdup.bam"
metrics="$output_dir/$run.duplicate_metrics.txt"

if [[ -s "$markdup_bam" && -s "$metrics" ]] && samtools quickcheck -v "$markdup_bam"; then
    printf 'RESUME run=%s checkpoint=markdup_bam\n' "$run"
else
    if [[ -s "$sorted_bam" ]] && samtools quickcheck -v "$sorted_bam"; then
        printf 'RESUME run=%s checkpoint=sorted_bam\n' "$run"
    else
        rm -f -- "$sorted_bam"
        if [[ -n "$sra_input" ]]; then
            printf 'INPUT_MODE run=%s mode=SRA_INTERLEAVED_PE source=%s\n' "$run" "$sra_input"
            nice -n "$NICE_LEVEL" "$SRA_TOOLKIT_DIR/fasterq-dump" --split-spot --stdout \
                -e "$THREADS" -m "$fasterq_memory" -b "$fasterq_buffer" \
                -c "$fasterq_cursor_cache" -t "$work_dir" "$sra_input" |
                nice -n "$NICE_LEVEL" "$bwa_mem2_bin" mem -p -t "$THREADS" -R "$rg" "${bwa_reference_args[@]}" - |
                nice -n "$NICE_LEVEL" samtools sort -@ "$SORT_THREADS" -m "$SORT_MEMORY" -T "$work_dir/sort" -o "$sorted_bam" -
        elif [[ "$layout" == "SE" ]]; then
            nice -n "$NICE_LEVEL" "$bwa_mem2_bin" mem -t "$THREADS" -R "$rg" "${bwa_reference_args[@]}" "$read1" |
                nice -n "$NICE_LEVEL" samtools sort -@ "$SORT_THREADS" -m "$SORT_MEMORY" -T "$work_dir/sort" -o "$sorted_bam" -
        else
            nice -n "$NICE_LEVEL" "$bwa_mem2_bin" mem -t "$THREADS" -R "$rg" "${bwa_reference_args[@]}" "$read1" "$read2" |
                nice -n "$NICE_LEVEL" samtools sort -@ "$SORT_THREADS" -m "$SORT_MEMORY" -T "$work_dir/sort" -o "$sorted_bam" -
        fi
        samtools quickcheck -v "$sorted_bam"
    fi

    picard -Xmx"$PICARD_HEAP" MarkDuplicates \
        INPUT="$sorted_bam" \
        OUTPUT="$markdup_bam" \
        METRICS_FILE="$metrics" \
        REMOVE_DUPLICATES=false \
        CREATE_INDEX=false \
        ASSUME_SORT_ORDER=coordinate \
        VALIDATION_STRINGENCY=SILENT \
        TMP_DIR="$work_dir"
    samtools quickcheck -v "$markdup_bam"
fi

samtools flagstat -@ "$THREADS" "$markdup_bam" > "$output_dir/$run.flagstat.txt"
samtools stats -@ "$THREADS" "$markdup_bam" > "$output_dir/$run.stats.txt"

case "${PERSIST_FORMAT^^}" in
    BAM)
        output="$output_dir/$run.markdup.bam"
        index="$output.bai"
        if [[ -s "$output" && -s "$index" ]] && samtools quickcheck -v "$output"; then
            printf 'RESUME run=%s checkpoint=final_bam\n' "$run"
        else
            mv "$markdup_bam" "$output"
            samtools index -@ "$THREADS" -o "$index.part" "$output"
            mv "$index.part" "$index"
        fi
        ;;
    CRAM)
        output="$output_dir/$run.markdup.cram"
        index="$output.crai"
        if [[ -s "$output" && -s "$index" ]] && samtools quickcheck -v "$output"; then
            printf 'RESUME run=%s checkpoint=final_cram\n' "$run"
        else
            samtools view -@ "$THREADS" -C -T "$REFERENCE" -o "$output.part" "$markdup_bam"
            samtools index -@ "$THREADS" -o "$index.part" "$output.part"
            mv "$output.part" "$output"
            mv "$index.part" "$index"
        fi
        ;;
    *)
        printf 'Unsupported PERSIST_FORMAT: %s\n' "$PERSIST_FORMAT" >&2
        exit 1
        ;;
esac

samtools quickcheck -v "$output"
mosdepth_summary="$output_dir/$run.mosdepth.summary.txt"
mosdepth_regions="$output_dir/$run.regions.bed.gz"
if [[ -s "$mosdepth_summary" && -s "$mosdepth_regions" ]]; then
    printf 'RESUME run=%s checkpoint=mosdepth\n' "$run"
else
    mosdepth --threads "$THREADS" --fast-mode --no-per-base --by 100000 --fasta "$REFERENCE" "$output_dir/$run" "$output"
fi
rm -f -- "$output_dir/$run.per-base.bed.gz" "$output_dir/$run.per-base.bed.gz.csi"
output_md5="$(md5sum "$output" | awk '{print $1}')"
output_bytes="$(stat -c %s "$output")"
printf '%s  %s\n' "$output_md5" "$(basename "$output")" > "$output.md5"
printf 'run_accession\tbiological_sample_id\tlayout\tformat\toutput\tbytes\tmd5\tcompleted_at\n' > "$complete.part"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run" "$biological_sample" "$layout" "${PERSIST_FORMAT^^}" "$output" "$output_bytes" "$output_md5" "$(date --iso-8601=seconds)" >> "$complete.part"
mv "$complete.part" "$complete"

rm -rf "$work_dir"
if [[ "$REMOVE_INPUT_AFTER_SUCCESS" == "1" ]]; then
    if [[ -n "$sra_input" ]]; then
        printf '%s\t%s\tSRA\t%s\n' "$(date --iso-8601=seconds)" "$run" "$sra_input" >> "$PROJECT_ROOT/logs/removed_input_after_validated_alignment.tsv"
        rm -f -- "$sra_input"
        rmdir -- "$(dirname "$sra_input")" 2>/dev/null || true
    else
        printf '%s\t%s\tFASTQ\t%s\t%s\n' "$(date --iso-8601=seconds)" "$run" "$read1" "${read2:-.}" >> "$PROJECT_ROOT/logs/removed_input_after_validated_alignment.tsv"
        rm -f -- "$read1"
        if [[ -n "$read2" ]]; then
            rm -f -- "$read2"
        fi
    fi
fi
printf 'DONE run=%s output=%s bytes=%s time=%s\n' "$run" "$output" "$output_bytes" "$(date --iso-8601=seconds)"
