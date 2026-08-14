#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fam", required=True, type=Path)
    parser.add_argument("--run-map", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--groups",
        nargs="+",
        default=["Chillingham", "swedish_modern", "Swiss_modern"],
    )
    args = parser.parse_args()

    with args.run_map.open(newline="", encoding="utf-8") as handle:
        sample_group = {
            row["biological_sample_id"]: row["group"]
            for row in csv.DictReader(handle, delimiter="\t")
        }
    fam_rows = [line.split() for line in args.fam.read_text().splitlines() if line.strip()]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    summary = []
    for group in args.groups:
        retained = [(row[0], row[1]) for row in fam_rows if sample_group.get(row[1]) == group]
        if len(retained) < 5:
            raise RuntimeError(f"GONE group {group} has only {len(retained)} retained individuals")
        output = args.output_dir / f"{group}.keep"
        output.write_text("".join(f"{fid}\t{iid}\n" for fid, iid in retained), encoding="utf-8")
        summary.append((group, len(retained), str(output)))

    with (args.output_dir / "population_keep_summary.tsv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(["population", "individuals", "keep_file"])
        writer.writerows(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
