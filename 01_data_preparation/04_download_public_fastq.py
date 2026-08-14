#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


def md5sum(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate(path: Path, row: dict[str, str]) -> bool:
    return path.stat().st_size == int(row["bytes"]) and md5sum(path) == row["md5"].lower()


def download_file(root: Path, row: dict[str, str]) -> str:
    destination = root / row["remote_relpath"]
    partial = destination.with_name(destination.name + ".part")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if validate(destination, row):
            return f"SKIP {row['sample']} {destination.name}"
        raise RuntimeError(f"Existing file failed validation: {destination}")

    subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--continue-at",
            "-",
            "--retry",
            "100",
            "--retry-all-errors",
            "--retry-delay",
            "10",
            "--output",
            str(partial),
            row["url"],
        ],
        check=True,
    )
    if not validate(partial, row):
        raise RuntimeError(f"Downloaded file failed size or MD5 validation: {partial}")
    os.replace(partial, destination)
    return f"DONE {row['sample']} {destination.name} bytes={destination.stat().st_size}"


def download_sample(root: Path, rows: list[dict[str, str]], min_free_gb: int) -> str:
    required = sum(int(row["bytes"]) for row in rows) + min_free_gb * 1024**3
    if shutil.disk_usage(root).free < required:
        raise RuntimeError(f"Insufficient free space for {rows[0]['sample']}: need {required} bytes")
    messages = [download_file(root, row) for row in sorted(rows, key=lambda item: item["read"])]
    return " | ".join(messages)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--layout", choices=("SE", "PE"), required=True)
    parser.add_argument("--sample", action="append", default=[])
    parser.add_argument("--sample-file", type=Path)
    parser.add_argument("--max-samples", type=int)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--min-free-gb", type=int, default=120)
    args = parser.parse_args()

    selected = set(args.sample)
    if args.sample_file:
        selected.update(line.strip() for line in args.sample_file.read_text().splitlines() if line.strip())
    with args.manifest.open(newline="", encoding="utf-8") as handle:
        rows = [
            row
            for row in csv.DictReader(handle, delimiter="\t")
            if row["layout"] == args.layout and (not selected or row["sample"] in selected)
        ]

    grouped: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        grouped.setdefault(row["sample"], []).append(row)
    samples = sorted(grouped, key=lambda sample: sum(int(row["bytes"]) for row in grouped[sample]))
    if args.max_samples is not None:
        samples = samples[: args.max_samples]

    failures: list[str] = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(download_sample, args.root, grouped[sample], args.min_free_gb): sample
            for sample in samples
        }
        for future in as_completed(futures):
            sample = futures[future]
            try:
                print(future.result(), flush=True)
            except Exception as exc:
                message = f"FAIL {sample}: {exc}"
                print(message, file=sys.stderr, flush=True)
                failures.append(message)

    print(f"SUMMARY layout={args.layout} samples={len(samples)} failures={len(failures)}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
