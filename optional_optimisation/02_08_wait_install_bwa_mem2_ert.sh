#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

mkdir -p "$PROJECT_ROOT/logs" "$(dirname "$BWA_MEM2_ERT_INDEX_PREFIX")"
exec 9> "$PROJECT_ROOT/logs/bwa_mem2_ert_waiter.lock"
flock -n 9 || exit 0
exec > >(tee -a "$PROJECT_ROOT/logs/bwa_mem2_ert_waiter.log") 2>&1

building="$BWA_MEM2_ERT_INDEX_PREFIX.building"
printf '%s\t%s\twaiting_for_active_bwa\n' "$$" "$(date --iso-8601=seconds)" > "$building"
trap 'rm -f -- "$building"' EXIT

while pgrep -f '(^|/)(bwa-mem2|bwa-mem2\.avx512bw) mem ' >/dev/null; do
    printf 'WAIT_ACTIVE_BWA time=%s\n' "$(date --iso-8601=seconds)"
    sleep 120
done

printf 'START_INSTALLER time=%s\n' "$(date --iso-8601=seconds)"
"$script_dir/07_install_bwa_mem2_ert.sh"
rm -f -- "$building"
trap - EXIT
printf 'DONE_WAITER time=%s\n' "$(date --iso-8601=seconds)"
