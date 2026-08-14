#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd


DISPLAY_NAMES = {
    "Chillingham": "Chillingham",
    "swedish_modern": "Swedish modern",
    "Swiss_modern": "Swiss modern",
}

COLORS = {
    "Chillingham": "#0072B2",
    "swedish_modern": "#D55E00",
    "Swiss_modern": "#009E73",
}


def read_gone(path: Path, population: str) -> pd.DataFrame:
    data = pd.read_csv(path, sep=r"\s+", skiprows=1)
    data.columns = ["generation", "Ne"]
    data["population"] = population
    return data


def summarize_changes(data: pd.DataFrame, interval: int) -> pd.DataFrame:
    rows = []
    for population, subset in data.groupby("population", sort=False):
        subset = subset.sort_values("generation").reset_index(drop=True).copy()
        subset["smoothed_Ne"] = subset["Ne"].rolling(5, center=True, min_periods=1).median()
        subset["previous_Ne"] = subset["smoothed_Ne"].shift(interval)
        subset["fold_change"] = subset["smoothed_Ne"] / subset["previous_Ne"]
        candidates = subset.replace([float("inf"), float("-inf")], pd.NA).dropna(
            subset=["fold_change"]
        )
        if candidates.empty:
            continue
        peak = candidates.loc[candidates["fold_change"].idxmax()]
        peak_index = int(peak.name)
        earlier = subset.iloc[peak_index - interval]
        rows.append(
            {
                "population": population,
                "from_generation": int(earlier["generation"]),
                "to_generation": int(peak["generation"]),
                "direction": "toward_older_generations",
                "smoothed_Ne_from": float(earlier["smoothed_Ne"]),
                "smoothed_Ne_to": float(peak["smoothed_Ne"]),
                "fold_change": float(peak["fold_change"]),
                "comparison_interval_generations": interval,
                "smoothing": "centered_5_generation_median",
            }
        )
    return pd.DataFrame(rows)


def draw(
    data: pd.DataFrame,
    output: Path,
    log_scale: bool,
    sample_counts: dict[str, int],
) -> None:
    figure, axis = plt.subplots(figsize=(9, 6))
    for population, subset in data.groupby("population", sort=False):
        display_name = DISPLAY_NAMES.get(population, population)
        if population in sample_counts:
            display_name = f"{display_name} (n={sample_counts[population]})"
        axis.plot(
            subset["generation"],
            subset["Ne"],
            linewidth=2.1,
            color=COLORS.get(population),
            label=display_name,
        )
    axis.set_xlabel("Generations ago")
    axis.set_ylabel("Effective population size (Ne)")
    if log_scale:
        axis.set_yscale("log")
    axis.legend(frameon=False, loc="upper center", bbox_to_anchor=(0.5, 1.01), ncol=3)
    axis.grid(color="#D9D9D9", linewidth=0.7, alpha=0.55)
    axis.tick_params(axis="both", length=0)
    axis.margins(x=0.01)
    for spine in axis.spines.values():
        spine.set_visible(False)
    figure.tight_layout()
    figure.savefig(output.with_suffix(".png"), dpi=300, bbox_inches="tight")
    figure.savefig(output.with_suffix(".pdf"), bbox_inches="tight")
    plt.close(figure)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-root", required=True, type=Path)
    parser.add_argument("--populations", nargs="+", required=True)
    parser.add_argument("--output-prefix", required=True, type=Path)
    parser.add_argument("--keep-summary", type=Path)
    parser.add_argument("--max-generations", type=int, default=200)
    parser.add_argument("--change-interval", type=int, default=5)
    args = parser.parse_args()

    frames = []
    for population in args.populations:
        path = args.results_root / population / f"Output_Ne_{population}"
        if not path.exists():
            raise RuntimeError(f"Missing GONE output: {path}")
        frames.append(read_gone(path, population))
    data = pd.concat(frames, ignore_index=True)
    data = data[data["generation"] <= args.max_generations].copy()
    args.output_prefix.parent.mkdir(parents=True, exist_ok=True)
    data.to_csv(args.output_prefix.with_suffix(".tsv"), sep="\t", index=False)

    changes = summarize_changes(data, args.change_interval)
    changes.to_csv(args.results_root / "Ne_change_summary.tsv", sep="\t", index=False)
    sample_counts = {}
    if args.keep_summary and args.keep_summary.is_file():
        keep_data = pd.read_csv(args.keep_summary, sep="\t")
        sample_counts = dict(zip(keep_data["population"], keep_data["individuals"], strict=True))
    draw(
        data,
        args.output_prefix.with_name(args.output_prefix.name + "_线性坐标_Linear"),
        False,
        sample_counts,
    )
    draw(
        data,
        args.output_prefix.with_name(args.output_prefix.name + "_对数坐标_Log"),
        True,
        sample_counts,
    )
    lines = [
        "# Effective population size interpretation",
        "",
        "GONE estimates are shown for the most recent generations. Largest increases are descriptive "
        f"changes over {args.change_interval} generations after a centered 5-generation median smooth; "
        "no interval is highlighted in the final figures.",
        "",
    ]
    for row in changes.itertuples(index=False):
        sample_text = (
            f", n={int(sample_counts[row.population])}" if row.population in sample_counts else ""
        )
        lines.append(
            f"- {row.population}{sample_text}: largest curve increase moving toward older generations "
            f"from {row.from_generation} to {row.to_generation} generations ago, "
            f"{row.fold_change:.3f}-fold "
            f"({row.smoothed_Ne_from:.3f} to {row.smoothed_Ne_to:.3f})."
        )
    lines.extend(
        [
            "",
            "Chillingham and Swedish estimates use only six individuals each. Recent sharp changes can be "
            "amplified by small sample size, LD, phasing uncertainty, population structure, and marker "
            "ascertainment; the descriptive interval is not by itself proof of a demographic expansion.",
            "",
        ]
    )
    report = args.results_root / "NE_INTERPRETATION.md"
    temporary = report.with_name(report.name + ".part")
    temporary.write_text("\n".join(lines), encoding="utf-8")
    temporary.replace(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
