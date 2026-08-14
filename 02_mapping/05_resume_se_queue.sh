#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

smoke_complete="$PROJECT_ROOT/results/02_mapping/ERR3305549/ERR3305549.complete.tsv"

while [[ ! -s "$smoke_complete" ]]; do
    printf 'WAIT smoke_test=%s time=%s\n' "$smoke_complete" "$(date --iso-8601=seconds)"
    sleep 60
done

expected="$(awk -F '\t' 'NR > 1 && $3 == "SE" {count++} END {print count+0}' "$MAPPING_MANIFEST")"
max_jobs="${MAX_MAPPING_JOBS:-1}"
total_slots="${MAPPING_TOTAL_SLOTS:-$max_jobs}"
threads_per_job="${MAPPING_THREADS_PER_JOB:-$THREADS}"
queue_name="${MAPPING_QUEUE_NAME:-primary}"
if ((max_jobs < 1 || max_jobs > 8)); then
    printf 'MAX_MAPPING_JOBS must be between 1 and 8: %s\n' "$max_jobs" >&2
    exit 2
fi
if ((total_slots < max_jobs || total_slots > 8)); then
    printf 'MAPPING_TOTAL_SLOTS must be between MAX_MAPPING_JOBS and 8: %s\n' "$total_slots" >&2
    exit 2
fi
if ((threads_per_job < 1)); then
    printf 'MAPPING_THREADS_PER_JOB must be positive: %s\n' "$threads_per_job" >&2
    exit 2
fi
if [[ ! "$queue_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf 'MAPPING_QUEUE_NAME contains unsupported characters: %s\n' "$queue_name" >&2
    exit 2
fi
queue_lock="$PROJECT_ROOT/logs/se_mapping_queue.lock"
if [[ "$queue_name" != primary ]]; then
    queue_lock="$PROJECT_ROOT/logs/se_mapping_queue.$queue_name.lock"
fi
exec 9>"$queue_lock"
flock -n 9 || { printf 'SE mapping queue is already running: %s\n' "$queue_name" >&2; exit 1; }
declare -A retry_after
declare -A run_by_pid
declare -A active_run

count_completed() {
    local count=0
    while IFS=$'\t' read -r run biological_sample layout rest; do
        [[ "$layout" == "SE" ]] || continue
        [[ -s "$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv" ]] && count=$((count + 1))
    done < <(tail -n +2 "$MAPPING_MANIFEST")
    printf '%s\n' "$count"
}

count_active_jobs() {
    local count=0 pid
    for pid in "${!run_by_pid[@]}"; do
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

reap_jobs() {
    local pid run exit_code now
    now="$(date +%s)"
    for pid in "${!run_by_pid[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        run="${run_by_pid[$pid]}"
        if wait "$pid"; then
            unset 'retry_after[$run]'
            printf 'JOB_DONE run=%s pid=%s time=%s\n' "$run" "$pid" "$(date --iso-8601=seconds)"
        else
            exit_code="$?"
            retry_after[$run]="$((now + 600))"
            printf 'RETRY_LATER run=%s pid=%s exit=%s after=%s\n' \
                "$run" "$pid" "$exit_code" "${retry_after[$run]}" >&2
        fi
        unset 'active_run[$run]'
        unset 'run_by_pid[$pid]'
    done
}

find_next_run() {
    local now input_bytes run read1_rel read2_rel layout
    now="$(date +%s)"
    while IFS=$'\t' read -r input_bytes run read1_rel read2_rel layout; do
        [[ "$layout" == "SE" ]] || continue
        [[ ! -s "$PROJECT_ROOT/results/02_mapping/$run/$run.complete.tsv" ]] || continue
        [[ -s "$PROJECT_ROOT/$read1_rel" ]] || continue
        [[ -z "${active_run[$run]:-}" ]] || continue
        [[ "${retry_after[$run]:-0}" -le "$now" ]] || continue
        printf '%s\n' "$run"
        return
    done < <(
        awk -F '\t' 'NR > 1 {printf "%.0f\t%s\t%s\t%s\t%s\n", ($9 + $10), $1, $4, $5, $3}' "$MAPPING_MANIFEST" |
            sort -n -k1,1
    )
}

while true; do
    reap_jobs
    completed="$(count_completed)"
    active_jobs="$(count_active_jobs)"
    printf 'STATUS queue=%s completed=%s expected=%s active=%s/%s total_slots=%s threads_per_job=%s free_bytes=%s time=%s\n' \
        "$queue_name" "$completed" "$expected" "$active_jobs" "$max_jobs" "$total_slots" "$threads_per_job" \
        "$(free_bytes)" "$(date --iso-8601=seconds)"
    if ((completed >= expected && active_jobs == 0)); then
        "$script_dir/04_update_mapping_qc.sh"
        printf 'DONE completed=%s expected=%s time=%s\n' "$completed" "$expected" "$(date --iso-8601=seconds)"
        exit 0
    fi

    launched=0
    active_jobs="$(count_active_jobs)"
    while ((active_jobs < max_jobs)); do
        next_run="$(find_next_run)"
        [[ -n "$next_run" ]] || break
        active_run[$next_run]=1
        printf 'MAP queue=%s run=%s threads=%s slots=%s time=%s\n' \
            "$queue_name" "$next_run" "$threads_per_job" "$total_slots" "$(date --iso-8601=seconds)"
        THREADS="$threads_per_job" MAPPING_SLOTS="$total_slots" REMOVE_INPUT_AFTER_SUCCESS=1 \
            "$script_dir/01_map_one_run.sh" "$next_run" &
        pid="$!"
        run_by_pid[$pid]="$next_run"
        active_jobs=$((active_jobs + 1))
        launched=1
    done

    active_jobs="$(count_active_jobs)"
    if ((active_jobs > 0)); then
        sleep 5
    elif ((launched == 0)); then
        sleep 60
    fi
done
