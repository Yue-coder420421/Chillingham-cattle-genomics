# 5. Variant Filtering Before PCA

`01_filter_for_pca.sh` runs the main branch and retains one order-sensitive branch:

1. 29 autosomes
2. SNPs only
3. Biallelic SNPs
4. Genotype GQ
5. Genotype DP
6. Main branch: PLINK `--geno 0.2`
7. Main branch: PLINK `--mind 0.8`
8. PLINK `--maf 0.01`
9. PLINK `--hwe 1e-5`
10. LD pruning `50 5 0.2`

Simultaneously run the `mind 0.8 -> geno 0.2` sensitivity branch, outputting `variant_filtering_sensitivity_summary.tsv` to compare the two sequences. The main result selection will be recorded in the parameter table.

Output `variant_filtering_sensitivity_summary.tsv`, recording the combined BCF counts for the autosomal/biallelic/GQ/DP datasets, and separately recording the number of SNPs before filtering, removed, and retained for `--geno 0.2`.
