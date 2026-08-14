#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

cache_dir="${PE_SRA_CACHE:-$PROJECT_ROOT/tools/sra_cache_pe}"
dependency_cache="${SRA_DEPENDENCY_CACHE:-$PROJECT_ROOT/tools/sra_dependencies}"
dependency_mirror="${SRA_DEPENDENCY_MIRROR:-sra-downloadb.be-md.ncbi.nlm.nih.gov}"
wait_for_se="${WAIT_FOR_SE:-1}"
queue_name="${PE_QUEUE_NAME:-primary}"
gpu_reserved_runs_file="${GPU_RESERVED_RUNS_FILE:-$PROJECT_ROOT/logs/gpu_reserved_runs.txt}"
shard_count="${PE_SHARD_COUNT:-1}"
shard_index="${PE_SHARD_INDEX:-0}"
mapping_slots="${PE_MAPPING_TOTAL_SLOTS:-$shard_count}"
mapping_threads="${PE_MAPPING_THREADS_PER_JOB:-$THREADS}"
parallel_max_input_bytes="${PE_PARALLEL_MAX_INPUT_BYTES:-32212254720}"
fastq_required="${PE_FASTQ_REQUIRED:-0}"
validate="$SRA_TOOLKIT_DIR/vdb-validate"
align_info="$SRA_TOOLKIT_DIR/align-info"
dependency_fetcher="$script_dir/08_stage_sra_dependencies.py"
smoke_complete="$PROJECT_ROOT/results/02_mapping/ERR3305549/ERR3305549.complete.tsv"
mkdir -p "$cache_dir" "$dependency_cache" "$PROJECT_ROOT/logs"
test -x "$validate"
test -x "$align_info"
test -s "$dependency_fetcher"

if [[ ! "$queue_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf 'PE_QUEUE_NAME contains unsupported characters: %s\n' "$queue_name" >&2
    exit 2
fi
if [[ ! "$shard_count" =~ ^[0-9]+$ ]] || ((shard_count < 1 || shard_count > 4)); then
    printf 'PE_SHARD_COUNT must be between 1 and 4: %s\n' "$shard_count" >&2
    exit 2
fi
if [[ ! "$shard_index" =~ ^[0-9]+$ ]] || ((shard_index < 0 || shard_index >= shard_count)); then
    printf 'PE_SHARD_INDEX must be between 0 and PE_SHARD_COUNT-1: %s\n' "$shard_index" >&2
    exit 2
fi
if [[ ! "$mapping_slots" =~ ^[0-9]+$ ]] || ((mapping_slots < shard_count || mapping_slots > 4)); then
    printf 'PE_MAPPING_TOTAL_SLOTS must be between PE_SHARD_COUNT and 4: %s\n' "$mapping_slots" >&2
    exit 2
fi
if [[ ! "$mapping_threads" =~ ^[0-9]+$ ]] || ((mapping_threads < 1)); then
    printf 'PE_MAPPING_THREADS_PER_JOB must be positive: %s\n' "$mapping_threads" >&2
    exit 2
fi
if [[ ! "$parallel_max_input_bytes" =~ ^[0-9]+$ ]] || ((parallel_max_input_bytes < 1)); then
    printf 'PE_PARALLEL_MAX_INPUT_BYTES must be positive: %s\n' "$parallel_max_input_bytes" >&2
    exit 2
fi
if [[ "$fastq_required" != "0" && "$fastq_required" != "1" ]]; then
    printf 'PE_FASTQ_REQUIRED must be 0 or 1: %s\n' "$fastq_required" >&2
    exit 2
fi

queue_lock="$PROJECT_ROOT/logs/pe_sra_rolling.lock"
if [[ "$queue_name" != primary || "$shard_count" -gt 1 ]]; then
    queue_lock="$PROJECT_ROOT/logs/pe_sra_rolling.$queue_name.lock"
fi
exec 9>"$queue_lock"
flock -n 9 || { printf 'Another PE SRA rolling process is already running: %s\n' "$queue_name" >&2; exit 1; }

while [[ ! -s "$smoke_complete" ]]; do
    printf 'WAIT smoke_test=%s time=%s\n' "$smoke_complete" "$(date --iso-8601=seconds)"
    sleep 60
done

se_expected="$(awk -F '\t' 'NR > 1 && $3 == "SE" {count++} END {print count+0}' "$MAPPING_MANIFEST")"
pe_expected="$(awk -F '\t' 'NR > 1 && $3 == "PE" {count++} END {print count+0}' "$MAPPING_MANIFEST")"

pe_run_rows() {
    awk -F '\t' 'NR > 1 && $3 == "PE" {printf "%.0f\t%s\n", ($9 + $10), $1}' "$MAPPING_MANIFEST" |
        sort -n -k1,1 |
        awk -F '\t' -v threshold="$parallel_max_input_bytes" '
            NR <= 2 {printf "0\t%d\t%s\t%s\n", NR, $1, $2; next}
            $1 <= threshold {printf "1\t%.0f\t%s\t%s\n", $1, $1, $2; next}
            {printf "2\t%.0f\t%s\t%s\n", -$1, $1, $2}
        ' |
        sort -n -k1,1 -k2,2 |
        cut -f 3,4 |
        awk -v shard_index="$shard_index" -v shard_count="$shard_count" \
            '((NR - 1) % shard_count) == shard_index'
}

se_completed() {
    local count=0
    while IFS=$'\t' read -r run biological_sample layout rest; do
        [[ "$layout" == "SE" ]] || continue
        [[ -s "$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv" ]] && count=$((count + 1))
    done < <(tail -n +2 "$MAPPING_MANIFEST")
    printf '%s\n' "$count"
}

pe_completed() {
    local count=0
    while IFS=$'\t' read -r run biological_sample layout rest; do
        [[ "$layout" == "PE" ]] || continue
        [[ -s "$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv" ]] && count=$((count + 1))
    done < <(tail -n +2 "$MAPPING_MANIFEST")
    printf '%s\n' "$count"
}

fastq_file_ready() {
    local path="$1"
    local expected_bytes="$2"
    local expected_md5="$3"
    local marker="$path.md5-validated"
    local actual_bytes
    local actual_md5
    [[ -s "$path" ]] || return 1
    actual_bytes="$(stat -c %s "$path")"
    [[ "$actual_bytes" == "$expected_bytes" ]] || return 1
    if [[ -s "$marker" && "$path" -ot "$marker" ]] && \
        [[ "$(cat "$marker")" == "$expected_md5" ]]; then
        return 0
    fi
    actual_md5="$(md5sum "$path" | awk '{print $1}')"
    [[ "$actual_md5" == "$expected_md5" ]] || return 1
    printf '%s\n' "$actual_md5" > "$marker.part"
    mv "$marker.part" "$marker"
}

printf 'CONFIG queue=%s shard=%s/%s mapping_slots=%s mapping_threads=%s parallel_max_input_bytes=%s fastq_required=%s wait_for_se=%s\n' \
    "$queue_name" "$shard_index" "$shard_count" "$mapping_slots" "$mapping_threads" \
    "$parallel_max_input_bytes" "$fastq_required" "$wait_for_se"

while :; do
    pass_pending=0
    pass_progress=0
    while IFS=$'\t' read -r input_bytes run; do
        complete="$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv"
        [[ ! -s "$complete" ]] || continue
        if [[ -s "$gpu_reserved_runs_file" ]] && grep -Fqx -- "$run" "$gpu_reserved_runs_file"; then
            printf 'SKIP_GPU_RESERVED queue=%s shard=%s/%s run=%s file=%s time=%s\n' \
                "$queue_name" "$shard_index" "$shard_count" "$run" \
                "$gpu_reserved_runs_file" "$(date --iso-8601=seconds)"
            continue
        fi
        pass_pending=1

    manifest_line="$(awk -F '\t' -v run="$run" 'NR > 1 && $1 == run {print; exit}' "$MAPPING_MANIFEST")"
    IFS=$'\t' read -r _ _ layout read1_rel read2_rel _ _ _ read1_bytes read2_bytes read1_md5 read2_md5 <<< "$manifest_line"
    read1="$PROJECT_ROOT/$read1_rel"
    read2="$PROJECT_ROOT/$read2_rel"
    fastq_ready=0
    if [[ "$layout" == "PE" ]] && \
        fastq_file_ready "$read1" "$read1_bytes" "$read1_md5" && \
        fastq_file_ready "$read2" "$read2_bytes" "$read2_md5"; then
        fastq_ready=1
        printf 'FASTQ_READY run=%s read1=%s read2=%s time=%s\n' \
            "$run" "$read1" "$read2" "$(date --iso-8601=seconds)"
    elif [[ "$fastq_required" == "1" ]]; then
        printf 'SKIP_FASTQ queue=%s shard=%s/%s run=%s read1=%s read2=%s time=%s\n' \
            "$queue_name" "$shard_index" "$shard_count" "$run" "$read1" "$read2" \
            "$(date --iso-8601=seconds)"
        continue
    fi

    sra="$cache_dir/$run/$run.sra"
    if ((fastq_ready == 0)); then
        if [[ ! -s "$sra" ]]; then
            required_free=$(((MIN_FREE_GB * 1024 * 1024 * 1024) + ((MAPPING_WORK_FACTOR + 1) * input_bytes)))
            available_free="$(free_bytes)"
            if ((available_free < required_free)); then
                printf 'ERROR insufficient_space_before_prefetch run=%s available=%s required=%s\n' \
                    "$run" "$available_free" "$required_free" >&2
                exit 1
            fi
            printf 'PREFETCH run=%s expected_fastq_bytes=%s time=%s\n' "$run" "$input_bytes" "$(date --iso-8601=seconds)"
            mkdir -p "$(dirname "$sra")"
            sra_part="$sra.part"
            if [[ ! -e "$sra_part" && -s "$sra.tmp" ]]; then
                mv "$sra.tmp" "$sra_part"
            fi
            curl -fL --retry 100 --retry-all-errors --retry-delay 5 --continue-at - \
                -o "$sra_part" "https://sra-pub-run-odp.s3.amazonaws.com/sra/$run/$run"
            mv "$sra_part" "$sra"
        fi
        flock "$PROJECT_ROOT/logs/pe_sra_dependencies.lock" \
            python3 "$dependency_fetcher" \
                --sra "$sra" \
                --align-info "$align_info" \
                --cache-dir "$dependency_cache" \
                --mirror-host "$dependency_mirror"
        validation_marker="$sra.vdb-validated"
        if [[ ! -s "$validation_marker" || "$sra" -nt "$validation_marker" ]]; then
            "$validate" "$sra"
            printf '%s\n' "$(date --iso-8601=seconds)" > "$validation_marker.part"
            mv "$validation_marker.part" "$validation_marker"
        else
            printf 'RESUME run=%s checkpoint=vdb_validate\n' "$run"
        fi
    fi

    if [[ "$wait_for_se" == "1" ]]; then
        while [[ "$(se_completed)" -lt "$se_expected" ]]; do
            printf 'WAIT queue=%s shard=%s/%s se_mapping=%s/%s cached_pe=%s time=%s\n' \
                "$queue_name" "$shard_index" "$shard_count" "$(se_completed)" "$se_expected" \
                "$run" "$(date --iso-8601=seconds)"
            sleep 300
        done
        wait_for_se=0
    fi

    exec {phase_lock_fd}>"$PROJECT_ROOT/logs/pe_mapping_phase.lock"
    mapping_reserve_slots="$mapping_slots"
    mapping_mode=parallel
    if ((input_bytes > parallel_max_input_bytes)); then
        flock -x "$phase_lock_fd"
        mapping_reserve_slots=1
        mapping_mode=large_exclusive
    else
        flock -s "$phase_lock_fd"
    fi
    pass_progress=1
    if ((fastq_ready == 1)); then
        printf 'MAP_PE_FASTQ queue=%s shard=%s/%s run=%s read1=%s read2=%s mode=%s reserve_slots=%s time=%s\n' \
            "$queue_name" "$shard_index" "$shard_count" "$run" "$read1" "$read2" "$mapping_mode" \
            "$mapping_reserve_slots" "$(date --iso-8601=seconds)"
        THREADS="$mapping_threads" MAPPING_SLOTS="$mapping_slots" \
            MAPPING_RESERVE_SLOTS="$mapping_reserve_slots" REMOVE_INPUT_AFTER_SUCCESS=1 \
            "$script_dir/../02_illumina_mapping/01_map_one_run.sh" "$run"
        rm -f -- "$sra" "$sra.vdb-validated" "$read1.md5-validated" "$read2.md5-validated"
        rmdir -- "$(dirname "$sra")" 2>/dev/null || true
    else
        printf 'MAP_PE_SRA queue=%s shard=%s/%s run=%s source=%s mode=%s reserve_slots=%s time=%s\n' \
            "$queue_name" "$shard_index" "$shard_count" "$run" "$sra" "$mapping_mode" \
            "$mapping_reserve_slots" "$(date --iso-8601=seconds)"
        THREADS="$mapping_threads" MAPPING_SLOTS="$mapping_slots" \
            MAPPING_RESERVE_SLOTS="$mapping_reserve_slots" \
            SRA_INPUT="$sra" REMOVE_INPUT_AFTER_SUCCESS=1 \
            "$script_dir/../02_illumina_mapping/01_map_one_run.sh" "$run"
    fi
        flock -u "$phase_lock_fd"
        eval "exec ${phase_lock_fd}>&-"
    done < <(pe_run_rows)
    if ((pass_pending == 0)); then
        break
    fi
    if ((pass_progress == 0)); then
        printf 'WAIT_FASTQ_PASS queue=%s shard=%s/%s time=%s\n' \
            "$queue_name" "$shard_index" "$shard_count" "$(date --iso-8601=seconds)"
        sleep 300
    fi
done

shard_expected=0
shard_completed=0
while IFS=$'\t' read -r input_bytes run; do
    shard_expected=$((shard_expected + 1))
    [[ -s "$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv" ]] && shard_completed=$((shard_completed + 1))
done < <(pe_run_rows)
if ((shard_completed != shard_expected)); then
    printf 'ERROR incomplete_PE_shard queue=%s completed=%s expected=%s\n' \
        "$queue_name" "$shard_completed" "$shard_expected" >&2
    exit 1
fi

printf 'SHARD_DONE queue=%s shard=%s/%s completed=%s time=%s\n' \
    "$queue_name" "$shard_index" "$shard_count" "$shard_completed" "$(date --iso-8601=seconds)"
while [[ "$(pe_completed)" -lt "$pe_expected" ]]; do
    printf 'WAIT_OTHER_PE_SHARDS queue=%s completed=%s expected=%s time=%s\n' \
        "$queue_name" "$(pe_completed)" "$pe_expected" "$(date --iso-8601=seconds)"
    sleep 300
done

"$script_dir/../02_illumina_mapping/04_update_mapping_qc.sh"
printf 'DONE queue=%s all_PE_runs=%s time=%s\n' "$queue_name" "$pe_expected" "$(date --iso-8601=seconds)"
