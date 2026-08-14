#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import subprocess
from pathlib import Path


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, check=False)


def md5sum(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_expected_md5(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    checksums = {}
    for line in path.read_text(encoding="ascii").splitlines():
        checksum, name = line.split(maxsplit=1)
        checksums[name.lstrip("*")] = checksum.lower()
    return checksums


def read_expected_sq(path: Path) -> list[tuple[str, int]]:
    records = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("@SQ\t"):
            fields = dict(field.split(":", 1) for field in line.split("\t")[1:])
            records.append((fields["SN"], int(fields["LN"])))
    return records


def read_reusable_rows(path: Path | None) -> dict[str, dict[str, str]]:
    if path is None or not path.is_file():
        return {}
    with path.open(newline="", encoding="utf-8") as handle:
        return {row["sample"]: row for row in csv.DictReader(handle, delimiter="\t")}


def can_reuse_pass(
    row: dict[str, str] | None,
    bam: Path,
    bai: Path,
    expected_md5: dict[str, str],
) -> bool:
    if row is None or row.get("status") != "PASS" or not expected_md5:
        return False
    checks = (
        "quickcheck",
        "coordinate_sorted",
        "reference_exact_match",
        "sample_name_match",
        "read_group_present",
        "index_present",
        "index_query_ok",
        "md5_match",
    )
    try:
        return (
            bam.is_file()
            and bai.is_file()
            and int(row.get("bam_bytes", "-1")) == bam.stat().st_size
            and all(row.get(field) == "TRUE" for field in checks)
            and row.get("bam_md5") == expected_md5.get(bam.name)
            and row.get("bai_md5") == expected_md5.get(bai.name)
            and md5sum(bai) == expected_md5.get(bai.name)
        )
    except (OSError, ValueError):
        return False


def parse_header(text: str) -> tuple[str, list[tuple[str, int]], list[str], list[str]]:
    sort_order = "."
    sq_records: list[tuple[str, int]] = []
    rg_ids: list[str] = []
    sample_names: list[str] = []
    for line in text.splitlines():
        if line.startswith("@HD\t"):
            fields = dict(field.split(":", 1) for field in line.split("\t")[1:] if ":" in field)
            sort_order = fields.get("SO", ".")
        elif line.startswith("@SQ\t"):
            fields = dict(field.split(":", 1) for field in line.split("\t")[1:])
            sq_records.append((fields["SN"], int(fields["LN"])))
        elif line.startswith("@RG\t"):
            fields = dict(field.split(":", 1) for field in line.split("\t")[1:] if ":" in field)
            if "ID" in fields:
                rg_ids.append(fields["ID"])
            if "SM" in fields:
                sample_names.append(fields["SM"])
    return sort_order, sq_records, sorted(set(rg_ids)), sorted(set(sample_names))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipcc-dir", required=True, type=Path)
    parser.add_argument("--expected-sq", required=True, type=Path)
    parser.add_argument("--expected-md5", type=Path)
    parser.add_argument("--reuse-pass-from", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    expected_sq = read_expected_sq(args.expected_sq)
    expected_md5 = read_expected_md5(args.expected_md5)
    reusable_rows = read_reusable_rows(args.reuse_pass_from)
    rows = []
    reused = 0
    for number in range(1, 7):
        sample = f"IPCC{number:02d}"
        bam = args.ipcc_dir / f"{sample}.ARS-UCD2.0.bam"
        bai = bam.with_name(bam.name + ".bai")
        if not bam.exists():
            rows.append({"sample": sample, "bam": str(bam), "status": "MISSING_BAM"})
            continue
        reusable = reusable_rows.get(sample)
        if reusable is not None:
            actual_bytes = bam.stat().st_size
            try:
                expected_bytes = int(reusable.get("bam_bytes", "-1"))
            except ValueError:
                expected_bytes = -1
            if expected_bytes < 0 or actual_bytes != expected_bytes:
                rows.append(
                    {
                        "sample": sample,
                        "bam": str(bam),
                        "bam_bytes": str(actual_bytes),
                        "status": "PARTIAL_BAM",
                    }
                )
            elif not bai.is_file() or bai.stat().st_size == 0:
                rows.append(
                    {
                        "sample": sample,
                        "bam": str(bam),
                        "bam_bytes": str(actual_bytes),
                        "status": "MISSING_BAI",
                    }
                )
            elif can_reuse_pass(reusable, bam, bai, expected_md5):
                rows.append({**reusable, "bam": str(bam), "bam_bytes": str(actual_bytes)})
                reused += 1
            else:
                rows.append(
                    {
                        "sample": sample,
                        "bam": str(bam),
                        "bam_bytes": str(actual_bytes),
                        "status": "REUSE_VALIDATION_FAILED",
                    }
                )
            continue
        quickcheck = run(["samtools", "quickcheck", "-v", str(bam)])
        header = run(["samtools", "view", "-H", str(bam)])
        sort_order, sq_records, rg_ids, sample_names = parse_header(header.stdout)
        index_check = run(["samtools", "idxstats", str(bam)]) if bai.exists() else None
        bam_md5 = md5sum(bam) if expected_md5 else "."
        bai_md5 = md5sum(bai) if expected_md5 and bai.exists() else "."
        checks = {
            "quickcheck": quickcheck.returncode == 0,
            "coordinate_sorted": sort_order == "coordinate",
            "reference_exact_match": sq_records == expected_sq,
            "sample_name_match": sample_names == [sample],
            "read_group_present": bool(rg_ids),
            "index_present": bai.exists(),
            "index_query_ok": index_check is not None and index_check.returncode == 0,
            "md5_match": not expected_md5
            or (
                expected_md5.get(bam.name) == bam_md5
                and expected_md5.get(bai.name) == bai_md5
            ),
        }
        rows.append(
            {
                "sample": sample,
                "bam": str(bam),
                "bam_bytes": bam.stat().st_size,
                "sort_order": sort_order,
                "contig_count": len(sq_records),
                "rg_ids": ",".join(rg_ids),
                "sample_names": ",".join(sample_names),
                "bam_md5": bam_md5,
                "bai_md5": bai_md5,
                **{key: str(value).upper() for key, value in checks.items()},
                "status": "PASS" if all(checks.values()) else "FAIL",
            }
        )

    fields = [
        "sample",
        "bam",
        "bam_bytes",
        "sort_order",
        "contig_count",
        "rg_ids",
        "sample_names",
        "bam_md5",
        "bai_md5",
        "quickcheck",
        "coordinate_sorted",
        "reference_exact_match",
        "sample_name_match",
        "read_group_present",
        "index_present",
        "index_query_ok",
        "md5_match",
        "status",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n", extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    failures = sum(row["status"] != "PASS" for row in rows)
    print(f"ipcc_bams={len(rows)} reused_pass={reused} failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
