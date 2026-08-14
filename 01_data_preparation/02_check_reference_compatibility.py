#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def read_fasta(path: Path) -> list[tuple[str, int]]:
    records: list[tuple[str, int]] = []
    name: str | None = None
    length = 0
    with path.open(encoding="ascii") as handle:
        for line in handle:
            if line.startswith(">"):
                if name is not None:
                    records.append((name, length))
                name = line[1:].split()[0]
                length = 0
            else:
                length += len(line.strip())
    if name is not None:
        records.append((name, length))
    return records


def read_sq(path: Path) -> list[tuple[str, int]]:
    records: list[tuple[str, int]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("@SQ\t"):
            continue
        fields = dict(field.split(":", 1) for field in line.split("\t")[1:])
        records.append((fields["SN"], int(fields["LN"])))
    return records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fasta", required=True, type=Path)
    parser.add_argument("--sq", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()

    fasta = read_fasta(args.fasta)
    expected = read_sq(args.sq)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("w", encoding="utf-8", newline="") as handle:
        handle.write("index\texpected_name\texpected_length\tfasta_name\tfasta_length\tmatch\n")
        for index in range(max(len(fasta), len(expected))):
            expected_row = expected[index] if index < len(expected) else ("", "")
            fasta_row = fasta[index] if index < len(fasta) else ("", "")
            handle.write(
                f"{index + 1}\t{expected_row[0]}\t{expected_row[1]}\t"
                f"{fasta_row[0]}\t{fasta_row[1]}\t{str(expected_row == fasta_row).upper()}\n"
            )

    exact_match = fasta == expected
    print(f"fasta_contigs={len(fasta)}")
    print(f"expected_contigs={len(expected)}")
    print(f"exact_ordered_match={str(exact_match).upper()}")
    return 0 if exact_match else 1


if __name__ == "__main__":
    raise SystemExit(main())
