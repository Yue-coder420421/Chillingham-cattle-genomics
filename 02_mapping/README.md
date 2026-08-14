# 2. Illumina Remapping

`01_map_one_run.sh RUN` performs BWA-MEM2, coordinate sort, Picard MarkDuplicates, indexing, quickcheck, flagstat, stats, mosdepth, and MD5.

Read Group Rules:

- `ID`: run accession
- `PU`: run accession
- `SM`: biological sample/BioSample ID
- `LB`: biological sample ID
- `PL`: ILLUMINA

By default, CRAM files are retained when server space is insufficient; set `PERSIST_FORMAT=BAM` to retain BAM files directly. `04_update_mapping_qc.sh` aggregates 114 lines of mapping QC.

`05_resume_se_queue.sh` waits for the smoke test to pass, then continues processing SE FASTQ files that have been uploaded or downloaded using named queues. A global slot lock limits the total concurrency across all queues; with the current 48-core configuration, there are two main queues for two tasks plus three single-task accelerators, totaling 5 mapping slots. The corresponding FASTQ files are deleted from the server only after all CRAM, indexing, QC, and MD5 checks are fully completed; local source files remain unaffected.

`01_map_one_run.sh` also supports PE streaming mode with `SRA_INPUT=/path/RUN.sra`: `fasterq-dump --split-spot --stdout` is directly piped to `bwa-mem2 mem -p`, without generating decompressed PE FASTQ files. `MAPPING_SLOTS` controls the actual global lock scope; `MAPPING_RESERVE_SLOTS` defaults to the same value but can be set to calculate workspace reservations based on a single task only when an external exclusive lock ensures single-task operation. PE workers run a single 40-thread BWA in serial via phase lock; the sort process uses 3 threads independently, keeping Mapping CPU concurrency below 90% of the 48-core quota.

`07_install_bwa_mem2_ert.sh` compiles the BWA-MEM2 ERT and builds the ARS-UCD2.0 ERT index in `/dev/shm`. `09_cache_bwa_mem2_ert.sh` copies the index to the server’s persistent disk after indexing is complete, reserving at least 120 GiB of free space after the copy; PE Mapping will not start until the persistent copy is complete. After a VM reboot, the installation script prioritizes copying the persistent copy back to `/dev/shm`, eliminating the need for a two-hour recalculation. `BWA_MEM2_BACKEND=auto` enables ERT only when both the binary and the full index marker are present; the `ALIGNER` line in each Mapping log records the actual backend, binary, and index.

`08_wait_install_bwa_mem2_ert.sh` waits in the background for the current standard BWA to finish before invoking the installation script to build the index; during this wait, a building marker is created, causing the next PE task to wait for ERT to complete rather than preemptively reverting to the standard backend.

Translated with DeepL.com (free version)

In SRA streaming mode, the `fasterq-dump` sorting memory is increased by default from the tool’s default of 100 MB to 64 GB, and a 16 MB output buffer and 1 GB cursor cache are used. These settings can be adjusted via `FASTERQ_MEMORY`, `FASTERQ_BUFFER`, and `FASTERQ_CURSOR_CACHE`; the configuration for concurrent tasks must reserve sufficient memory for BWA indexing and the system.

`06_summarize_previous_qc.py` is used solely to quickly summarize the baseline data from previous SE Mapping QC runs. The duplication rate for the old tables is actually a ratio of 0 to 1 but was incorrectly labeled as a percentage; this script converts it to a true percentage and outputs a corrected table, grouped summaries, and a graph. The final conclusions must be based on the results of this reanalysis.


Translated with DeepL.com (free version)