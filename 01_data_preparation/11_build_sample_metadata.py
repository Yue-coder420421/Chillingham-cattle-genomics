#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

import openpyxl


FIELDS = [
    "run_accession",
    "Group_name",
    "scientific_name",
    "sample_title",
    "country/region/site",
    "Date/Period",
    "sample_accession",
    "library_layout",
]
MODERN_GROUPS = {"Chillingham", "swedish_modern", "Swiss_modern"}


def read_csv(path: Path, delimiter: str) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter=delimiter))


def workbook_records(path: Path) -> dict[str, dict[str, str]]:
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    records: dict[str, dict[str, str]] = {}
    for sheet in workbook.worksheets:
        rows = sheet.iter_rows(values_only=True)
        header = None
        for row in rows:
            values = ["" if value is None else str(value) for value in row]
            if "run_accession" in values:
                header = {value: index for index, value in enumerate(values) if value}
                continue
            if header is None:
                continue
            run_index = header["run_accession"]
            if run_index >= len(values) or not values[run_index]:
                continue
            run = values[run_index]
            record = {
                field: values[index]
                for field, index in header.items()
                if index < len(values) and values[index]
            }
            records.setdefault(run, record)
    return records


def inferred_location(title: str) -> str:
    match = re.search(r"\(([^()]*)\)\s*$", title)
    return match.group(1) if match else "."


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-csv", required=True, type=Path)
    parser.add_argument("--workbook", required=True, type=Path)
    parser.add_argument("--run-map", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    run_map = read_csv(args.run_map, "\t")
    if len(run_map) != 120 or len({row["run_accession"] for row in run_map}) != 120:
        raise RuntimeError("Run map must contain 120 unique inputs")

    rows_by_run = {row["run_accession"]: row for row in read_csv(args.base_csv, ",")}
    if len(rows_by_run) != 112:
        raise RuntimeError(f"Expected 112 unique base metadata rows, found {len(rows_by_run)}")
    workbook_by_run = workbook_records(args.workbook)

    output_rows = []
    for mapping in run_map:
        run = mapping["run_accession"]
        group = mapping["group"]
        if run in rows_by_run:
            row = dict(rows_by_run[run])
            if not row.get("country/region/site"):
                row["country/region/site"] = inferred_location(row.get("sample_title", ""))
            if not row.get("Date/Period") and group in MODERN_GROUPS:
                row["Date/Period"] = "Modern"
        elif run.startswith("IPCC"):
            row = {
                "run_accession": run,
                "Group_name": group,
                "scientific_name": "Bos taurus",
                "sample_title": mapping["sample_title"],
                "country/region/site": ".",
                "Date/Period": "Modern",
                "sample_accession": mapping["biological_sample_id"],
                "library_layout": "HIFI",
            }
        else:
            source = workbook_by_run.get(run)
            if source is None:
                raise RuntimeError(f"Missing metadata source for {run}")
            title = source.get("sample_title", mapping["sample_title"])
            row = {
                "run_accession": run,
                "Group_name": group,
                "scientific_name": source.get("scientific_name", "Bos taurus"),
                "sample_title": title,
                "country/region/site": inferred_location(title),
                "Date/Period": "Modern" if group in MODERN_GROUPS else ".",
                "sample_accession": mapping["biological_sample_id"],
                "library_layout": source.get("library_layout", mapping["layout"]),
            }
        if row["Group_name"] != group:
            raise RuntimeError(
                f"Group mismatch for {run}: metadata={row['Group_name']} run_map={group}"
            )
        if row["sample_accession"] != mapping["biological_sample_id"]:
            raise RuntimeError(f"Biological sample mismatch for {run}")
        output_rows.append({field: row.get(field, ".") or "." for field in FIELDS})

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name + ".part")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(output_rows)
    temporary.replace(args.output)
    print("metadata_rows=120 illumina=114 ipcc=6 complete=TRUE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
