# Joint Variant Calling

The production control is chromosome-parallel bcftools with minimum mapping and
base quality 20. It consumes 114 Illumina run alignments plus six IPCC BAMs.
Runs sharing an RG `SM` become one biological-sample column; the required cohort
has exactly 57 columns, not 120 run columns.

Execution order:

1. `00_make_contig_lists.py`
2. `01_build_alignment_list.py`
3. `03_run_primary_contigs.sh`
4. `04_concat_primary_bcf.sh`

Production gates require 114 committed Illumina alignments, identical final and
current IPCC audits, six GPU-local BAMs with exact audited byte counts and
nonempty indexes, 120 input rows, and 57 expected biological samples.
