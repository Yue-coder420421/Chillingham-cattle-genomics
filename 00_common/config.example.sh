#!/usr/bin/env bash

# Copy this file to config.sh and edit only the local values.
# Do not commit config.sh.

PROJECT_ROOT="${PROJECT_ROOT:-/path/to/Chillingham-cattle-genomics}"
DATA_ROOT="${DATA_ROOT:-$PROJECT_ROOT/data}"
RESULTS_ROOT="${RESULTS_ROOT:-$PROJECT_ROOT/results}"
DELIVERY_ROOT="${DELIVERY_ROOT:-$PROJECT_ROOT}"

REFERENCE="${REFERENCE:-$DATA_ROOT/reference/GCF_002263795.3_ARS-UCD2.0_genomic.fna}"
IPCC_SQ="${IPCC_SQ:-$DATA_ROOT/private/ipcc_reference.sq}"
MAPPING_MANIFEST="${MAPPING_MANIFEST:-$PROJECT_ROOT/01_data_preparation/manifests/illumina_mapping_manifest.tsv}"

# General resources
THREADS="${THREADS:-8}"
SORT_THREADS="${SORT_THREADS:-4}"
SORT_MEMORY="${SORT_MEMORY:-2G}"
MAPPING_MAX_THREADS="${MAPPING_MAX_THREADS:-48}"
SORT_MAX_THREADS="${SORT_MAX_THREADS:-16}"
MAPPING_SLOTS="${MAPPING_SLOTS:-1}"
MAPPING_RESERVE_SLOTS="${MAPPING_RESERVE_SLOTS:-$MAPPING_SLOTS}"
MAX_MAPPING_JOBS="${MAX_MAPPING_JOBS:-1}"
MAPPING_TOTAL_SLOTS="${MAPPING_TOTAL_SLOTS:-$MAX_MAPPING_JOBS}"
MAPPING_THREADS_PER_JOB="${MAPPING_THREADS_PER_JOB:-$THREADS}"
MIN_FREE_GB="${MIN_FREE_GB:-100}"
MAPPING_WORK_FACTOR="${MAPPING_WORK_FACTOR:-3}"
NICE_LEVEL="${NICE_LEVEL:-0}"

# Executables. Commands should normally be available on PATH.
FASTP="${FASTP:-fastp}"
FASTQC="${FASTQC:-fastqc}"
BWA_MEM2_STANDARD_BIN="${BWA_MEM2_STANDARD_BIN:-bwa-mem2}"
SRA_TOOLKIT_DIR="${SRA_TOOLKIT_DIR:-/path/to/sratoolkit/bin}"

# Mapping outputs
PERSIST_FORMAT="${PERSIST_FORMAT:-CRAM}"
PICARD_HEAP="${PICARD_HEAP:-16g}"
REMOVE_INPUT_AFTER_SUCCESS="${REMOVE_INPUT_AFTER_SUCCESS:-0}"

# Optional BWA-MEM2 ERT optimisation. Standard BWA-MEM2 remains the default.
BWA_MEM2_BACKEND="${BWA_MEM2_BACKEND:-standard}"
BWA_MEM2_ERT_BIN="${BWA_MEM2_ERT_BIN:-$PROJECT_ROOT/tools/bwa-mem2-ert/bwa-mem2}"
BWA_MEM2_ERT_INDEX_PREFIX="${BWA_MEM2_ERT_INDEX_PREFIX:-$DATA_ROOT/reference/bwa-mem2-ert/ARS-UCD2.0}"
BWA_MEM2_ERT_PERSISTENT_PREFIX="${BWA_MEM2_ERT_PERSISTENT_PREFIX:-$BWA_MEM2_ERT_INDEX_PREFIX}"
BWA_MEM2_ERT_WAIT_SECONDS="${BWA_MEM2_ERT_WAIT_SECONDS:-0}"

# Dissertation-specific genotype thresholds.
# Set these to the exact values reported in the final Methods; do not guess.
MIN_GQ="${MIN_GQ:-}"
MIN_DP="${MIN_DP:-}"
PLINK_MEMORY_MB="${PLINK_MEMORY_MB:-49152}"

# GONE must point explicitly to the retained 33-sample analysis branch.
# It must not point to an output of the failed 57-sample filtering audit.
GONE_INPUT_BFILE="${GONE_INPUT_BFILE:-}"
GONE_RESULTS_ROOT="${GONE_RESULTS_ROOT:-$RESULTS_ROOT/10_gone}"
GONE_POPULATIONS="${GONE_POPULATIONS:-Chillingham swedish_modern Swiss_modern}"
GONE_THREADS="${GONE_THREADS:-24}"
GONE_COMMIT="${GONE_COMMIT:-2288c61d21a1fd21ad01b693f59990f117566448}"

activate_analysis_env() {
    # Keep required executables on PATH, or replace this no-op with the local
    # environment activation command after copying to config.sh.
    :
}

free_bytes() {
    df -PB1 "$PROJECT_ROOT" | awk 'NR == 2 {print $4}'
}
