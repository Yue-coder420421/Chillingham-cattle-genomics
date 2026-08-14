#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-pairs", type=int)
    args = parser.parse_args()

    pending_spot = ""
    records = 0
    pairs = 0
    while True:
        header = sys.stdin.readline()
        if not header:
            break
        sequence = sys.stdin.readline()
        separator = sys.stdin.readline()
        quality = sys.stdin.readline()
        if not sequence or not separator or not quality:
            raise RuntimeError("Truncated FASTQ record")
        if not header.startswith("@") or not separator.startswith("+"):
            raise RuntimeError(f"Malformed FASTQ record at record {records + 1}")
        if len(sequence.rstrip("\r\n")) != len(quality.rstrip("\r\n")):
            raise RuntimeError(f"Sequence and quality lengths differ at record {records + 1}")

        spot = header.split(maxsplit=1)[0].removeprefix("@")
        if records % 2 == 0:
            pending_spot = spot
        elif spot != pending_spot:
            raise RuntimeError(
                f"Interleaved mates differ at pair {pairs + 1}: {pending_spot} != {spot}"
            )
        else:
            pairs += 1
        records += 1

    if records % 2:
        raise RuntimeError("Interleaved FASTQ has an odd number of records")
    if args.expected_pairs is not None and pairs != args.expected_pairs:
        raise RuntimeError(f"Expected {args.expected_pairs} pairs, observed {pairs}")
    print(f"status=PASS pairs={pairs} records={records}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
