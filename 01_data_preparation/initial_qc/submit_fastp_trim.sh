#!/bin/bash
#$ -N fastp_trim
#$ -cwd
#$ -pe sharedmem 4
#$ -l h_rt=08:00:00
#$ -l h_vmem=4G
#$ -V

set -euo pipefail

LIST=$1
RUN=$(sed -n "${SGE_TASK_ID}p" "$LIST")

FASTP=/users/document

if [[ -z "${RUN}" ]]; then
    echo "ERROR: no run ID found for SGE_TASK_ID=${SGE_TASK_ID}"
    exit 1
fi

if [[ ! -x "${FASTP}" ]]; then
    echo "ERROR: fastp was not found at:"
    echo "${FASTP}"
    exit 127
fi

mkdir -p fastq_trimmed fastp_reports logs

INPUT=$(find fastq_public -type f -name "${RUN}.fastq.gz" -print -quit)

if [[ -z "${INPUT}" ]]; then
    echo "ERROR: could not find ${RUN}.fastq.gz under fastq_public/"
    exit 1
fi

OUTPUT="fastq_trimmed/${RUN}.trim.fastq.gz"
HTML_REPORT="fastp_reports/${RUN}.fastp.html"
JSON_REPORT="fastp_reports/${RUN}.fastp.json"

echo "Run ID: ${RUN}"
echo "Input: ${INPUT}"
echo "Output: ${OUTPUT}"
echo "Started: $(date)"

"${FASTP}" \
    --in1 "${INPUT}" \
    --out1 "${OUTPUT}" \
    --thread 4 \
    --disable_quality_filtering \
    --overrepresentation_analysis \
    --html "${HTML_REPORT}" \
    --json "${JSON_REPORT}" \
    --dont_overwrite

echo "Finished: $(date)"
