#!/usr/bin/env bash
set -euo pipefail

run="${1:-ERR3305549}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

required_index="$REFERENCE.bwt.2bit.64"
while [[ ! -s "$required_index" ]] || pgrep -f -- "bwa-mem2 index $REFERENCE" >/dev/null; do
    printf 'WAIT reference_index=%s time=%s\n' "$required_index" "$(date --iso-8601=seconds)"
    sleep 30
done

"$script_dir/01_map_one_run.sh" "$run"
"$script_dir/04_update_mapping_qc.sh"
