#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

base_url="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/002/263/795/GCF_002263795.3_ARS-UCD2.0"
archive_name="GCF_002263795.3_ARS-UCD2.0_genomic.fna.gz"
reference_dir="$PROJECT_ROOT/reference"
archive="$reference_dir/$archive_name"
partial="$archive.part"
checksums="$reference_dir/ncbi_md5checksums.txt"

mkdir -p "$reference_dir" "$DELIVERY_ROOT/results"
curl --fail --location --retry 20 --output "$checksums" "$base_url/md5checksums.txt"

expected_md5="$(awk -v name="./$archive_name" '$2 == name {print $1}' "$checksums")"
test -n "$expected_md5"
if [[ ! -s "$archive" ]]; then
    curl --fail --location --retry 100 --retry-all-errors --retry-delay 5 \
        --continue-at - --output "$partial" "$base_url/$archive_name"
    mv "$partial" "$archive"
fi
printf '%s  %s\n' "$expected_md5" "$archive" | md5sum --check -
gzip -t "$archive"

if [[ ! -s "$REFERENCE" ]]; then
    pigz -dc "$archive" > "$REFERENCE.part"
    mv "$REFERENCE.part" "$REFERENCE"
fi
md5sum "$REFERENCE" > "$REFERENCE.md5"
printf 'reference=%s\n' "$REFERENCE"
