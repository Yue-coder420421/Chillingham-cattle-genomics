#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sq", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    names = []
    for line in args.sq.read_text(encoding="utf-8").splitlines():
        if line.startswith("@SQ\t"):
            fields = dict(field.split(":", 1) for field in line.split("\t")[1:])
            names.append(fields["SN"])
    expected_primary = [f"NC_{37328 + index:06d}.1" for index in range(29)] + [
        "NC_037357.1",
        "NC_082638.1",
    ]
    if names[:31] != expected_primary:
        raise RuntimeError("Unexpected ARS-UCD2.0 autosome/X/Y order")
    if len(names) < len(expected_primary):
        raise RuntimeError("Reference dictionary lacks expected primary chromosomes")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "autosomes.txt").write_text("\n".join(names[:29]) + "\n", encoding="ascii")
    (args.output_dir / "primary_contigs.txt").write_text(
        "\n".join(expected_primary) + "\n", encoding="ascii"
    )
    (args.output_dir / "autosome_rename.tsv").write_text(
        "".join(f"{name}\t{index}\n" for index, name in enumerate(names[:29], 1)),
        encoding="ascii",
    )
    print(f"autosomes=29 primary_contigs=31 total_reference_contigs={len(names)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
