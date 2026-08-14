#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from pathlib import Path


def resolve_alignment(complete: Path, run: str, status: dict[str, str]) -> Path | None:
    reported = Path(status.get("output", ""))
    format_name = status.get("format", "").upper()
    suffix = ".cram" if format_name == "CRAM" else ".bam"
    candidates = [reported]
    if reported.name:
        candidates.append(complete.parent / reported.name)
    candidates.append(complete.parent / f"{run}.markdup{suffix}")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mapping-manifest", required=True, type=Path)
    parser.add_argument("--mapping-root", required=True, type=Path)
    parser.add_argument("--ipcc-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--sample-list", type=Path)
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()

    with args.mapping_manifest.open(newline="", encoding="utf-8") as handle:
        manifest = list(csv.DictReader(handle, delimiter="\t"))
    alignments: list[tuple[str, str, str]] = []
    missing = []
    for row in manifest:
        run = row["run_accession"]
        complete = args.mapping_root / run / f"{run}.complete.tsv"
        if not complete.exists():
            missing.append(run)
            continue
        with complete.open(newline="", encoding="utf-8") as handle:
            status = next(csv.DictReader(handle, delimiter="\t"))
        alignment = resolve_alignment(complete, run, status)
        if alignment is None:
            if args.allow_incomplete:
                missing.append(run)
                continue
            raise RuntimeError(f"Completed alignment is missing for {run}: {status.get('output', '')}")
        expected_bytes = int(status["bytes"])
        if alignment.stat().st_size != expected_bytes:
            if args.allow_incomplete:
                missing.append(run)
                continue
            raise RuntimeError(f"Completed alignment size mismatch: {alignment}")
        suffix = ".crai" if status["format"].upper() == "CRAM" else ".bai"
        index = alignment.with_name(alignment.name + suffix)
        if not index.is_file() or index.stat().st_size == 0:
            if args.allow_incomplete:
                missing.append(run)
                continue
            raise RuntimeError(f"Completed alignment index is missing: {index}")
        alignments.append((run, row["biological_sample_id"], str(alignment)))

    for number in range(1, 7):
        sample = f"IPCC{number:02d}"
        bam = args.ipcc_dir / f"{sample}.ARS-UCD2.0.bam"
        bai = bam.with_name(bam.name + ".bai")
        if not bam.is_file() or not bai.is_file() or bam.stat().st_size == 0 or bai.stat().st_size == 0:
            missing.append(sample)
            continue
        alignments.append((sample, sample, str(bam)))

    if missing and not args.allow_incomplete:
        raise RuntimeError(f"Missing {len(missing)} required alignments: {','.join(missing[:10])}")
    if not args.allow_incomplete and len(alignments) != 120:
        raise RuntimeError(f"Expected 120 run/BAM inputs, found {len(alignments)}")
    biological_samples = list(dict.fromkeys(sample for _, sample, _ in alignments))
    if not args.allow_incomplete and len(biological_samples) != 57:
        raise RuntimeError(
            f"Expected 57 biological samples, found {len(biological_samples)}"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(f"{path}\n" for _, _, path in alignments), encoding="utf-8")
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    with args.summary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(["input_id", "biological_sample_id", "alignment"])
        writer.writerows(alignments)
    if args.sample_list is not None:
        args.sample_list.parent.mkdir(parents=True, exist_ok=True)
        args.sample_list.write_text(
            "\n".join(biological_samples) + "\n", encoding="utf-8"
        )
    print(f"alignment_inputs={len(alignments)}")
    print(f"biological_samples={len(biological_samples)}")
    print(f"missing={len(missing)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
