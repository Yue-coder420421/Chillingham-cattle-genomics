#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from pathlib import Path


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def value_or_dot(value: str | None) -> str:
    return value if value else "."


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-map", required=True, type=Path)
    parser.add_argument("--upload-manifest", required=True, type=Path)
    parser.add_argument("--download-manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    run_rows = read_tsv(args.run_map)
    uploads = {
        row["sample"]: row
        for row in read_tsv(args.upload_manifest)
        if row["kind"] == "SE_FASTQ"
    }
    downloads: dict[str, dict[str, dict[str, str]]] = {}
    for row in read_tsv(args.download_manifest):
        downloads.setdefault(row["sample"], {})[row["read"]] = row

    output_rows: list[dict[str, str]] = []
    for run_row in run_rows:
        layout = run_row["layout"]
        if layout == "HIFI":
            continue
        run = run_row["run_accession"]
        if layout == "SINGLE" and run in uploads:
            upload = uploads[run]
            r1 = upload["remote_relpath"]
            r2 = "."
            r1_bytes = upload["bytes"]
            r2_bytes = "0"
            r1_md5 = "."
            r2_md5 = "."
            source = "existing_trimmed"
            normalized_layout = "SE"
        elif layout == "SINGLE":
            download = downloads[run]["R1"]
            r1 = download["remote_relpath"]
            r2 = "."
            r1_bytes = download["bytes"]
            r2_bytes = "0"
            r1_md5 = download["md5"]
            r2_md5 = "."
            source = "public_fastq"
            normalized_layout = "SE"
        elif layout == "PAIRED":
            read1 = downloads[run]["R1"]
            read2 = downloads[run]["R2"]
            r1 = read1["remote_relpath"]
            r2 = read2["remote_relpath"]
            r1_bytes = read1["bytes"]
            r2_bytes = read2["bytes"]
            r1_md5 = read1["md5"]
            r2_md5 = read2["md5"]
            source = "public_fastq"
            normalized_layout = "PE"
        else:
            raise RuntimeError(f"Unsupported layout for {run}: {layout}")

        output_rows.append(
            {
                "run_accession": run,
                "biological_sample_id": run_row["biological_sample_id"],
                "layout": normalized_layout,
                "read1": r1,
                "read2": r2,
                "source": source,
                "group": value_or_dot(run_row.get("group")),
                "sample_title": value_or_dot(run_row.get("sample_title")),
                "read1_bytes": r1_bytes,
                "read2_bytes": r2_bytes,
                "read1_md5": r1_md5,
                "read2_md5": r2_md5,
            }
        )

    if len(output_rows) != 114:
        raise RuntimeError(f"Expected 114 Illumina runs, found {len(output_rows)}")
    if sum(row["layout"] == "SE" for row in output_rows) != 90:
        raise RuntimeError("Expected 90 SE runs")
    if sum(row["layout"] == "PE" for row in output_rows) != 24:
        raise RuntimeError("Expected 24 PE runs")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(output_rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(output_rows)
    print(f"runs={len(output_rows)}")
    print(f"biological_samples={len({row['biological_sample_id'] for row in output_rows})}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
