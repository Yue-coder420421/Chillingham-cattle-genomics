# PCA component selection

**Primary choice: PC1-PC6 (six components).**

The final PCA used 33 samples and 2,910,265 LD-pruned SNPs. PC1-PC6 explain 44.92% of the eigenvalue sum; adding PC7 gives 48.75%. The PC6-to-PC7 eigenvalue gap is 0.36302, after the six axes that show the major sample-group structure.

Four independent 500,000-SNP random subsets were used as a stability check. The minimum absolute coordinate correlation with the full PCA is 0.999644 for PC6 and 0.992136 for PC8. Thus PC1-PC6 are stable and conservative for primary correction; PC1-PC8 is retained as a sensitivity set.

Broken-stick is shown as a null reference in the scree plot. It is intentionally not used as the sole decision rule because it identifies only the dominant axis in this strongly structured, small-n dataset. A fixed 80/90% variance threshold is also inappropriate here.

Use PC1-PC3 for figures, PC1-PC6 as the default downstream covariate set, and PC1-PC8 for sensitivity analyses.
