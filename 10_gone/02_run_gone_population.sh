#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s POPULATION\n' "$0" >&2
    exit 2
fi

population="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

input="${GONE_INPUT_BFILE:-$PROJECT_ROOT/results/05_variant_filtering/05_hwe1e-5}"
results_root="${GONE_RESULTS_ROOT:-$PROJECT_ROOT/results/08_ne}"
keep="$results_root/keep_files/$population.keep"
gone_source="$PROJECT_ROOT/tools/GONE/Linux"
run_dir="$results_root/$population"
test -s "$keep"
test -d "$gone_source/PROGRAMMES"
mkdir -p "$run_dir"

if [[ -s "$run_dir/$population.complete.tsv" && -s "$run_dir/Output_Ne_$population" ]]; then
    printf 'GONE_POPULATION_ALREADY_COMPLETE population=%s output=%s\n' \
        "$population" "$run_dir/Output_Ne_$population"
    exit 0
fi

exec 9>"$results_root/.gone.lock"
flock 9

rm -rf "$run_dir/PROGRAMMES"
cp -a "$gone_source/PROGRAMMES" "$run_dir/PROGRAMMES"
cp "$gone_source/script_GONE.sh" "$gone_source/INPUT_PARAMETERS_FILE" "$run_dir/"
chmod +x "$run_dir/script_GONE.sh" "$run_dir/PROGRAMMES/"*
sed -i "s/^threads=.*/threads=$THREADS  ### controlled by delivery config/" "$run_dir/INPUT_PARAMETERS_FILE"

if [[ ! -s "$run_dir/$population.ped" || ! -s "$run_dir/$population.map" ]]; then
    plink \
        --bfile "$input" \
        --chr-set 29 \
        --keep "$keep" \
        --recode \
        --out "$run_dir/$population"
else
    printf 'GONE_RECODE_REUSED population=%s ped=%s map=%s\n' \
        "$population" "$run_dir/$population.ped" "$run_dir/$population.map"
fi
individuals="$(wc -l < "$run_dir/$population.ped")"
if ((individuals < 5)); then
    printf 'Too few individuals for GONE: %s\n' "$individuals" >&2
    exit 1
fi

cd "$run_dir"
bash script_GONE.sh "$population" 2>&1 | tee "$population.GONE.log"
test -s "Output_Ne_$population"
printf 'population\tindividuals\tcompleted_at\n%s\t%s\t%s\n' \
    "$population" "$individuals" "$(date --iso-8601=seconds)" > "$population.complete.tsv"
