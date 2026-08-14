#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


PERCENT = re.compile(r"\(([-0-9.]+)%")


def flagstat_values(path: Path) -> tuple[str, str, str]:
    total = mapped = properly_paired = "."
    for line in path.read_text().splitlines():
        if " in total " in line:
            total = line.split()[0]
        elif " mapped (" in line:
            match = PERCENT.search(line)
            mapped = match.group(1) if match else "."
        elif " properly paired (" in line:
            match = PERCENT.search(line)
            properly_paired = match.group(1) if match else "."
    return total, mapped, properly_paired


def duplicate_percentage(path: Path) -> str:
    lines = [line for line in path.read_text().splitlines() if line and not line.startswith("#")]
    for index, line in enumerate(lines):
        if line.startswith("LIBRARY\t") and index + 1 < len(lines):
            header = line.split("\t")
            values = lines[index + 1].split("\t")
            return format(float(values[header.index("PERCENT_DUPLICATION")]) * 100, ".4f")
    return "."


def mean_coverage(path: Path) -> str:
    with path.open() as handle:
        for row in csv.reader(handle, delimiter="\t"):
            if row and row[0] == "total":
                reference_bases = int(row[1])
                covered_bases = int(row[2])
                return f"{covered_bases / reference_bases:.6f}"
    return "."


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--mapping-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    with args.manifest.open(newline="", encoding="utf-8") as handle:
        manifest = list(csv.DictReader(handle, delimiter="\t"))
    fields = [
        "run_accession",
        "biological_sample_id",
        "layout",
        "total_reads",
        "mapped_percent",
        "properly_paired_percent",
        "duplicate_percent",
        "mean_coverage",
        "alignment_status",
    ]
    output_rows = []
    for row in manifest:
        run = row["run_accession"]
        run_dir = args.mapping_root / run
        flagstat = run_dir / f"{run}.flagstat.txt"
        metrics = run_dir / f"{run}.duplicate_metrics.txt"
        coverage = run_dir / f"{run}.mosdepth.summary.txt"
        complete = run_dir / f"{run}.complete.tsv"
        total, mapped, proper = flagstat_values(flagstat) if flagstat.exists() else (".", ".", ".")
        output_rows.append(
            {
                "run_accession": run,
                "biological_sample_id": row["biological_sample_id"],
                "layout": row["layout"],
                "total_reads": total,
                "mapped_percent": mapped,
                "properly_paired_percent": proper if row["layout"] == "PE" else ".",
                "duplicate_percent": duplicate_percentage(metrics) if metrics.exists() else ".",
                "mean_coverage": mean_coverage(coverage) if coverage.exists() else ".",
                "alignment_status": "PASS" if complete.exists() else "PENDING",
            }
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(output_rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
