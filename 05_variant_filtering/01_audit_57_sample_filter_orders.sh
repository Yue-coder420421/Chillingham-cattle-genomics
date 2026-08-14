#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"
activate_analysis_env

input="${1:-$PROJECT_ROOT/results/04_joint_calling/ARS-UCD2.0.primary.57_biological_samples.bcf}"
output_dir="$PROJECT_ROOT/results/05_variant_filtering"
autosomes="$DELIVERY_ROOT/manifests/autosomes.txt"
rename_map="$DELIVERY_ROOT/manifests/autosome_rename.tsv"
mkdir -p "$output_dir" "$DELIVERY_ROOT/results"
test -s "$input"
test -s "$autosomes"
test -s "$rename_map"

autosomes_clean="$output_dir/autosomes.regions.txt"
tr -d '\r' < "$autosomes" > "$autosomes_clean.part"
test "$(wc -l < "$autosomes_clean.part")" -eq 29
awk 'NF != 1 {exit 1}' "$autosomes_clean.part"
mv "$autosomes_clean.part" "$autosomes_clean"
autosomes_csv="$(paste -sd, "$autosomes_clean")"
test -n "$autosomes_csv"

run_plink2() {
    plink2 --threads "$THREADS" --memory "${PLINK_MEMORY_MB:-49152}" "$@"
}

bcftools view \
    --threads "$THREADS" \
    --regions "$autosomes_csv" \
    --types snps \
    --min-alleles 2 \
    --max-alleles 2 \
    --output-type b \
    --output "$output_dir/01_autosomal_biallelic_snps.bcf" \
    "$input"
bcftools index --force --threads "$THREADS" "$output_dir/01_autosomal_biallelic_snps.bcf"

bcftools +setGT "$output_dir/01_autosomal_biallelic_snps.bcf" \
    --output-type b \
    --output "$output_dir/02_genotype_gq_dp.bcf" \
    -- \
    --target-gt q \
    --new-gt . \
    --include "FMT/GQ<$MIN_GQ || FMT/DP<$MIN_DP"
bcftools index --force --threads "$THREADS" "$output_dir/02_genotype_gq_dp.bcf"

bcftools annotate \
    --rename-chrs "$rename_map" \
    --output-type b \
    --output "$output_dir/03_numeric_autosomes.bcf" \
    "$output_dir/02_genotype_gq_dp.bcf"
bcftools index --force --threads "$THREADS" "$output_dir/03_numeric_autosomes.bcf"

run_plink2 \
    --bcf "$output_dir/03_numeric_autosomes.bcf" \
    --chr-set 29 \
    --double-id \
    --set-all-var-ids '@:#:$r:$a' \
    --make-bed \
    --out "$output_dir/01_pre_geno"
run_plink2 --bfile "$output_dir/01_pre_geno" --chr-set 29 --geno 0.2 --make-bed --out "$output_dir/02_geno20"
run_plink2 --bfile "$output_dir/02_geno20" --chr-set 29 --mind 0.8 --make-bed --out "$output_dir/03_mind80"
run_plink2 --bfile "$output_dir/03_mind80" --chr-set 29 --maf 0.01 --make-bed --out "$output_dir/04_maf01"
run_plink2 --bfile "$output_dir/04_maf01" --chr-set 29 --hwe 1e-5 --make-bed --out "$output_dir/05_hwe1e-5"
run_plink2 \
    --bfile "$output_dir/05_hwe1e-5" \
    --chr-set 29 \
    --indep-pairwise 50 5 0.2 \
    --out "$output_dir/06_ld"
run_plink2 \
    --bfile "$output_dir/05_hwe1e-5" \
    --chr-set 29 \
    --extract "$output_dir/06_ld.prune.in" \
    --make-bed \
    --out "$output_dir/07_pca_ld_pruned"

# Sensitivity branch: remove samples first, then apply variant missingness.
# This branch is compared with the primary branch before downstream selection.
run_plink2 --bfile "$output_dir/01_pre_geno" --chr-set 29 --mind 0.8 --make-bed --out "$output_dir/08_mind80_first"
run_plink2 --bfile "$output_dir/08_mind80_first" --chr-set 29 --geno 0.2 --make-bed --out "$output_dir/09_mind_then_geno20"
run_plink2 --bfile "$output_dir/09_mind_then_geno20" --chr-set 29 --maf 0.01 --make-bed --out "$output_dir/10_mind_then_maf01"
run_plink2 --bfile "$output_dir/10_mind_then_maf01" --chr-set 29 --hwe 1e-5 --make-bed --out "$output_dir/11_mind_then_hwe1e-5"
run_plink2 \
    --bfile "$output_dir/11_mind_then_hwe1e-5" \
    --chr-set 29 \
    --indep-pairwise 50 5 0.2 \
    --out "$output_dir/12_mind_then_ld"
run_plink2 \
    --bfile "$output_dir/11_mind_then_hwe1e-5" \
    --chr-set 29 \
    --extract "$output_dir/12_mind_then_ld.prune.in" \
    --make-bed \
    --out "$output_dir/13_mind_then_pca_ld_pruned"

count_variants() { wc -l < "$1.bim"; }
count_samples() { wc -l < "$1.fam"; }
joint_variants="$(bcftools index --nrecords "$input")"
prepared_variants="$(bcftools index --nrecords "$output_dir/02_genotype_gq_dp.bcf")"
joint_samples="$(bcftools query --list-samples "$input" | wc -l)"
initial_variants="$(count_variants "$output_dir/01_pre_geno")"
geno_variants="$(count_variants "$output_dir/02_geno20")"
mind_variants="$(count_variants "$output_dir/03_mind80")"
maf_variants="$(count_variants "$output_dir/04_maf01")"
hwe_variants="$(count_variants "$output_dir/05_hwe1e-5")"
ld_variants="$(count_variants "$output_dir/07_pca_ld_pruned")"
mind_first_samples="$(count_samples "$output_dir/08_mind80_first")"
mind_first_geno_variants="$(count_variants "$output_dir/09_mind_then_geno20")"
mind_first_maf_variants="$(count_variants "$output_dir/10_mind_then_maf01")"
mind_first_hwe_variants="$(count_variants "$output_dir/11_mind_then_hwe1e-5")"
mind_first_ld_variants="$(count_variants "$output_dir/13_mind_then_pca_ld_pruned")"

summary="$DELIVERY_ROOT/results/variant_filtering_summary.tsv"
printf 'step\tthreshold\tvariants_before\tremoved\tretained\tsamples_retained\n' > "$summary"
printf 'BCF_preparation\t29_autosomes;SNP;biallelic;GQ>=%s;DP>=%s\t%s\t%s\t%s\t%s\n' \
    "$MIN_GQ" "$MIN_DP" "$joint_variants" "$((joint_variants - prepared_variants))" \
    "$prepared_variants" "$joint_samples" >> "$summary"
printf 'PLINK_geno\t0.2\t%s\t%s\t%s\t%s\n' "$initial_variants" "$((initial_variants - geno_variants))" "$geno_variants" "$(count_samples "$output_dir/02_geno20")" >> "$summary"
printf 'PLINK_mind\t0.8\t%s\t%s\t%s\t%s\n' "$geno_variants" "$((geno_variants - mind_variants))" "$mind_variants" "$(count_samples "$output_dir/03_mind80")" >> "$summary"
printf 'PLINK_maf\t0.01\t%s\t%s\t%s\t%s\n' "$mind_variants" "$((mind_variants - maf_variants))" "$maf_variants" "$(count_samples "$output_dir/04_maf01")" >> "$summary"
printf 'PLINK_hwe\t1e-5\t%s\t%s\t%s\t%s\n' "$maf_variants" "$((maf_variants - hwe_variants))" "$hwe_variants" "$(count_samples "$output_dir/05_hwe1e-5")" >> "$summary"
printf 'LD_pruning\t50_5_0.2\t%s\t%s\t%s\t%s\n' "$hwe_variants" "$((hwe_variants - ld_variants))" "$ld_variants" "$(count_samples "$output_dir/07_pca_ld_pruned")" >> "$summary"

sensitivity_summary="$DELIVERY_ROOT/results/variant_filtering_sensitivity_summary.tsv"
printf 'branch\torder\tvariants_before\tvariants_after_geno\tvariants_after_maf\tvariants_after_hwe\tld_pruned_variants\tsamples_retained\n' > "$sensitivity_summary"
printf 'primary\tgeno_then_mind\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$initial_variants" "$geno_variants" "$maf_variants" "$hwe_variants" "$ld_variants" "$(count_samples "$output_dir/07_pca_ld_pruned")" >> "$sensitivity_summary"
printf 'sensitivity\tmind_then_geno\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$initial_variants" "$mind_first_geno_variants" "$mind_first_maf_variants" "$mind_first_hwe_variants" "$mind_first_ld_variants" "$mind_first_samples" >> "$sensitivity_summary"

printf 'filter_order=chromosomes,SNP,biallelic,GQ,DP,geno,mind,maf,hwe,LD\n' > "$DELIVERY_ROOT/results/variant_filtering_parameters.txt"
printf 'MIN_GQ=%s\nMIN_DP=%s\nGENO=0.2\nMIND=0.8\nMAF=0.01\nHWE=1e-5\nLD=50,5,0.2\n' \
    "$MIN_GQ" "$MIN_DP" >> "$DELIVERY_ROOT/results/variant_filtering_parameters.txt"
printf 'SENSITIVITY_BRANCH=mind_then_geno\nPRIMARY_BRANCH=geno_then_mind\n' \
    >> "$DELIVERY_ROOT/results/variant_filtering_parameters.txt"
