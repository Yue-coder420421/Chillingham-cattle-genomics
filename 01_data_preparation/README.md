# 1. Data Preparation

Objective: Prepare ARS-UCD2.0, 57 existing trimmed SE sequences, 33 public SE sequences, 24 pairs of public PE sequences, and 6 IPCC BAM/BAI files.

- `01_download_reference.sh`: Download or reuse NCBI `GCF_002263795.3`, verify the official MD5 checksum, and then unzip it.
- `02_check_reference_compatibility.py`: Compare the names, lengths, and order of each FASTA sequence against IPCC `@SQ` entries one by one.
- `03_index_reference.sh`: Generate `faidx`, the Picard dictionary, and BWA-MEM2 indexes.
- `04_download_public_fastq.py`: Downloads FASTQ files by sample breakpoint and verifies ENA size and MD5.
- `05_build_mapping_manifest.py`: Generates the 114-run manifest and binds RG `SM` to BioSample.
- `06_roll_public_runs.sh`: Executes the “download, align, verify, and release FASTQ” process in ascending order by volume.
- `07_roll_public_pe_sra.sh`: When ENA is too slow, pre-fetches PE SRAs one by one according to fixed shards, aligns them directly using interleaved paired-end reads, and decompresses FASTQ files without writing them to disk.
- `08_stage_sra_dependencies.py`: Parses the external dependencies of reference-compressed SRAs, places them uniformly into a shared cache, and reuses them via hard links to avoid redundant space consumption for each PE run.
- `09_validate_interleaved_fastq.py`: Stream-processes interleaved FASTQ files to check record integrity, sequence/quality length, and adjacent mate names; Used for sampling and acceptance testing of the PE streaming workflow.
- `10_download_public_se_sra.py`: Resumes downloading public SE files from the official AWS SRA mirror; executes `vdb-validate`; converts them to gzip FASTQ and writes the MD5 of the generated files; automatically falls back to the official ENA FASTQ in the manifest when SRA objects are unavailable, and verifies size and MD5.
- `11_build_sample_metadata.py`: Reconstructs complete metadata from the 112 lines of metadata, the source workbook, and the 120-input run map in the delivery package; strictly supplements the 2 Swiss runs and 6 IPCC runs.
