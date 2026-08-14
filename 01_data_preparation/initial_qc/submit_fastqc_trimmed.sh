#!/bin/bash
#$ -N fastqc_trimmed
#$ -cwd
#$ -pe sharedmem 2
#$ -l h_rt=04:00:00
#$ -l h_vmem=4G
#$ -V

set -euo pipefail

LIST=$1

RUN=$(sed -n "${SGE_TASK_ID}p" "$LIST")

if [[ -z "${RUN}" ]]; then
    echo "ERROR: no run ID found for SGE_TASK_ID=${SGE_TASK_ID}"
    exit 1
fi

INPUT="fastq_trimmed/${RUN}.trim.fastq.gz"

module load igmm/apps/FastQC/0.11.9

mkdir -p qc_report_trimmed

if [[ ! -s "${INPUT}" ]]; then
    echo "ERROR: missing or empty input file: ${INPUT}"
    exit 1
fi

echo "Running FastQC for: ${INPUT}"
echo "Started at: $(date)"

fastqc \
    -t 2 \
    -o qc_report_trimmed \
    "${INPUT}"

echo "Finished at: $(date)"
