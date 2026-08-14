#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

results_root="${GONE_RESULTS_ROOT:-$PROJECT_ROOT/results/08_ne}"
read -r -a populations <<< "${GONE_POPULATIONS:-Chillingham swedish_modern Swiss_modern}"
if [[ $# -gt 0 ]]; then
    populations=("$@")
fi

for population in "${populations[@]}"; do
    GONE_INPUT_BFILE="${GONE_INPUT_BFILE:-$PROJECT_ROOT/results/05_variant_filtering/05_hwe1e-5}" \
        "$script_dir/02_run_gone_population.sh" "$population"
done

python "$script_dir/04_plot_ne.py" \
    --results-root "$results_root" \
    --populations "${populations[@]}" \
    --output-prefix "$results_root/Chillingham_vs_modern_Ne" \
    --keep-summary "$results_root/keep_files/population_keep_summary.tsv"

printf 'GONE_SELECTED_POPULATIONS_OK populations=%s results_root=%s\n' \
    "${populations[*]}" "$results_root"
