# 3. IPCC BAM Compatibility

`02_run_compatibility_gate.sh` checks both the reference FASTA and six IPCC BAMs.

The compatibility check includes reference build, contig name/length/order, BAM header, SM, RG, coordinate sort, BAI, `idxstats`, `quickcheck`, and the BAM/BAI MD5 values provided in the submission package. If any item fails, the script returns a non-zero value, and the submission is not allowed to proceed to the joint calling stage.

`03_wait_and_run_gate.sh` automatically runs the full gate check after all 6 final BAM/BAI pairs have arrived. It ignores `.part` transfer files and uses locks to prevent duplicate launches; if the final audit has already passed 6/6 but QC is interrupted, it only resumes `05_build_ipcc_qc.sh` and does not recalculate all BAM/BAI MD5s.

`04_refresh_partial_audit.sh` updates the rolling audit only when new complete BAM/BAI pairs are added, checking the reference sequence, RG/SM, sorting, indexing, `quickcheck`, and BAM/BAI MD5s to avoid repeatedly reading large, unchanged BAMs every 5 minutes. Once the final audit passes, it directly performs an atomic sync of the final report without waiting for the incremental audit lock.

After the full audit passes, the audit script first releases the incremental audit lock, then `05_build_ipcc_qc.sh`—which holds an independent lock—generates `flagstat`, `mosdepth` results, and `ipcc_mapping_qc_summary.tsv` for the six IPCC BAMs. This table provides the mapped percentage and mean coverage of the IPCC to the PCA metadata; the script refuses to run if the 6/6 PASS requirement is not met.

Translated with DeepL.com (free version)