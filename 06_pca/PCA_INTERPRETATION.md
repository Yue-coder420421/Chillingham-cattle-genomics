# Exploratory PCA interpretation

## Chillingham proximity

Distances use PC1, PC2, PC3, PC4, PC5 and are descriptive, not a formal ancestry test.

- swedish_modern: centroid distance 0.410489 (6 individuals).
- Swiss_modern: centroid distance 0.441715 (18 individuals).

## Technical diagnostics

- Strongest observed technical correlation: PC1 versus genotype_missingness, Pearson r=-0.950.
- The magnitude is large enough that coverage or missingness may contribute to PCA separation.
- Ancient versus modern median genotype missingness: 0.200105 versus 0.013150; median coverage: 12.973539X versus 19.367854X.
- Ancient/modern centroid distance across PC1, PC2, PC3: 0.59454.
- Largest data-type centroid separation across PC1, PC2, PC3: IPCC_HiFi versus Illumina_SE, distance 0.658917.
- Data types represented: IPCC_HiFi, Illumina_PE, Illumina_SE.
- Robust PCA outliers (threshold |z| >= 4 across PC1, PC2, PC3, PC4, PC5): 13.

Ancient/modern or SE/PE/IPCC separation must not be interpreted as biology when it tracks missingness, coverage, or data type. Final origin inference should require agreement among PCA, ADMIXTURE, NJ, IQ-TREE, and metadata.
