#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


def md5sum(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gzip_is_valid(path: Path) -> bool:
    try:
        with gzip.open(path, "rb") as handle:
            while handle.read(8 * 1024 * 1024):
                pass
        return True
    except (OSError, EOFError):
        return False


def completed_alignment_exists(root: Path, run: str) -> bool:
    complete = root / "results" / "02_mapping" / run / f"{run}.complete.tsv"
    if not complete.is_file():
        return False
    try:
        with complete.open(newline="", encoding="utf-8") as handle:
            status = next(csv.DictReader(handle, delimiter="\t"))
        alignment = Path(status["output"])
        if not alignment.is_absolute():
            alignment = root / alignment
        return alignment.is_file() and alignment.stat().st_size == int(status["bytes"])
    except (KeyError, StopIteration, OSError, ValueError):
        return False


def wait_for_free_space(root: Path, run: str, expected_bytes: int, min_free_gb: int) -> None:
    required = min_free_gb * 1024**3 + 4 * expected_bytes
    while True:
        available = shutil.disk_usage(root).free
        if available >= required:
            return
        print(
            f"WAIT_SPACE run={run} available={available} required={required}",
            flush=True,
        )
        time.sleep(60)


def stage_sra(cache: Path, toolkit: Path, run: str, url_template: str) -> Path:
    run_cache = cache / run
    run_cache.mkdir(parents=True, exist_ok=True)
    sra = run_cache / f"{run}.sra"
    partial = run_cache / f"{run}.sra.part"
    prefetch_partial = run_cache / f"{run}.sra.tmp"
    if not sra.is_file():
        if prefetch_partial.is_file() and not partial.exists():
            os.replace(prefetch_partial, partial)
        subprocess.run(
            [
                "curl",
                "-fL",
                "--retry",
                "100",
                "--retry-all-errors",
                "--retry-delay",
                "5",
                "--continue-at",
                "-",
                "--output",
                str(partial),
                url_template.format(run=run),
            ],
            check=True,
        )
        os.replace(partial, sra)

    validation_marker = sra.with_name(sra.name + ".vdb-validated")
    if not validation_marker.is_file() or sra.stat().st_mtime_ns > validation_marker.stat().st_mtime_ns:
        subprocess.run([str(toolkit / "vdb-validate"), str(sra)], check=True)
        validation_marker.write_text("PASS\n", encoding="ascii")
    return sra


def download_ena_fallback(
    destination: Path,
    row: dict[str, str],
    sra_error: subprocess.CalledProcessError,
) -> str:
    run = row["sample"]
    url = row.get("url", "").strip()
    if not url:
        raise RuntimeError(f"No ENA fallback URL is available for {run}") from sra_error

    partial = destination.with_name(destination.name + ".part")
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
            url,
        ],
        check=True,
    )
    actual_md5 = md5sum(partial)
    if partial.stat().st_size != int(row["bytes"]) or actual_md5 != row["md5"].lower():
        raise RuntimeError(f"ENA fallback failed size or MD5 validation: {partial}")
    os.replace(partial, destination)
    return (
        f"DONE_ENA_FALLBACK {run} {destination.name} bytes={destination.stat().st_size} "
        f"sra_returncode={sra_error.returncode}"
    )


def download_one(
    root: Path,
    toolkit: Path,
    cache: Path,
    row: dict[str, str],
    threads: int,
    sra_url_template: str,
    min_free_gb: int,
) -> str:
    run = row["sample"]
    destination = root / row["remote_relpath"]
    generated_partial = destination.with_name(destination.name + ".sra.part")
    generated_md5 = destination.with_name(destination.name + ".sra-generated.md5")
    destination.parent.mkdir(parents=True, exist_ok=True)

    if completed_alignment_exists(root, run):
        return f"SKIP_MAPPED {run} {destination.name}"

    if destination.exists():
        actual_md5 = md5sum(destination)
        if destination.stat().st_size == int(row["bytes"]) and actual_md5 == row["md5"].lower():
            return f"SKIP_ENA {run} {destination.name}"
        if generated_md5.exists() and generated_md5.read_text().split()[0] == actual_md5 and gzip_is_valid(destination):
            return f"SKIP_SRA {run} {destination.name}"
        raise RuntimeError(f"Existing destination cannot be validated: {destination}")

    wait_for_free_space(root, run, int(row["bytes"]), min_free_gb)
    fasterq = toolkit / "fasterq-dump"
    try:
        sra = stage_sra(cache, toolkit, run, sra_url_template)
    except subprocess.CalledProcessError as sra_error:
        return download_ena_fallback(destination, row, sra_error)

    command = (
        "set -o pipefail; "
        f"{shlex.quote(str(fasterq))} --split-spot --stdout -e {threads} "
        f"{shlex.quote(str(sra))} "
        f"| pigz -p {threads} > {shlex.quote(str(generated_partial))}"
    )
    subprocess.run(["bash", "-c", command], check=True)
    if not gzip_is_valid(generated_partial):
        raise RuntimeError(f"Generated gzip is invalid: {generated_partial}")
    actual_md5 = md5sum(generated_partial)
    os.replace(generated_partial, destination)
    generated_md5.write_text(f"{actual_md5}  {destination.name}\n", encoding="ascii")
    shutil.rmtree(cache / run)
    return f"DONE_SRA {run} {destination.name} bytes={destination.stat().st_size}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--toolkit", required=True, type=Path)
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--threads-per-worker", type=int, default=8)
    parser.add_argument("--min-free-gb", type=int, default=120)
    parser.add_argument(
        "--sra-url-template",
        default="https://sra-pub-run-odp.s3.amazonaws.com/sra/{run}/{run}",
    )
    args = parser.parse_args()

    with args.manifest.open(newline="", encoding="utf-8") as handle:
        rows = [row for row in csv.DictReader(handle, delimiter="\t") if row["layout"] == "SE"]
    rows.sort(key=lambda row: (int(row["bytes"]), row["sample"]))
    args.cache.mkdir(parents=True, exist_ok=True)

    failures: list[str] = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(
                download_one,
                args.root,
                args.toolkit,
                args.cache,
                row,
                args.threads_per_worker,
                args.sra_url_template,
                args.min_free_gb,
            ): row
            for row in rows
        }
        for future in as_completed(futures):
            row = futures[future]
            try:
                print(future.result(), flush=True)
            except Exception as exc:
                message = f"FAIL {row['sample']}: {exc}"
                print(message, file=sys.stderr, flush=True)
                failures.append(message)

    print(f"SUMMARY samples={len(rows)} failures={len(failures)}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
