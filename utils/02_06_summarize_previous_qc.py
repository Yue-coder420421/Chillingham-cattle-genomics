#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--previous-qc", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    qc = pd.read_csv(args.previous_qc, sep="\t")
    metadata = pd.read_csv(args.metadata)
    qc = qc.rename(
        columns={
            "Sample": "run_accession",
            "Layout": "layout",
            "Mapped_reads": "mapped_reads",
            "Mapping_rate(%)": "mapping_percent",
            "Duplicate_rate(%)": "duplicate_fraction_reported_as_percent",
            "Mean_coverage(X)": "mean_coverage",
        }
    )
    required = {
        "run_accession",
        "layout",
        "mapped_reads",
        "mapping_percent",
        "duplicate_fraction_reported_as_percent",
        "mean_coverage",
    }
    missing = required.difference(qc.columns)
    if missing:
        raise RuntimeError(f"Missing previous-QC columns: {sorted(missing)}")

    for column in (
        "mapped_reads",
        "mapping_percent",
        "duplicate_fraction_reported_as_percent",
        "mean_coverage",
    ):
        qc[column] = pd.to_numeric(qc[column], errors="coerce")
    qc["duplicate_percent"] = qc["duplicate_fraction_reported_as_percent"] * 100

    metadata_columns = ["run_accession", "Group_name", "sample_accession"]
    missing_metadata = set(metadata_columns).difference(metadata.columns)
    if missing_metadata:
        raise RuntimeError(f"Missing metadata columns: {sorted(missing_metadata)}")
    data = qc.merge(metadata[metadata_columns], on="run_accession", how="left", validate="one_to_one")
    data["Group_name"] = data["Group_name"].fillna("Unassigned")
    data["sample_accession"] = data["sample_accession"].fillna(data["run_accession"])
    data["mapping_lt_10_percent"] = data["mapping_percent"] < 10
    data["coverage_lt_0_1x"] = data["mean_coverage"] < 0.1

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    corrected = output_dir / "quick_previous_SE_QC_corrected.tsv"
    columns = [
        "run_accession",
        "sample_accession",
        "Group_name",
        "layout",
        "mapped_reads",
        "mapping_percent",
        "duplicate_percent",
        "mean_coverage",
        "mapping_lt_10_percent",
        "coverage_lt_0_1x",
    ]
    data.sort_values(["mean_coverage", "mapping_percent"], ascending=[False, False])[columns].to_csv(
        corrected, sep="\t", index=False, float_format="%.4f"
    )

    summary = (
        data.groupby("Group_name", dropna=False)
        .agg(
            run_count=("run_accession", "size"),
            biological_sample_count=("sample_accession", "nunique"),
            mapping_median_percent=("mapping_percent", "median"),
            mapping_min_percent=("mapping_percent", "min"),
            mapping_max_percent=("mapping_percent", "max"),
            duplicate_median_percent=("duplicate_percent", "median"),
            coverage_median_x=("mean_coverage", "median"),
            runs_mapping_lt_10_percent=("mapping_lt_10_percent", "sum"),
            runs_coverage_lt_0_1x=("coverage_lt_0_1x", "sum"),
        )
        .sort_values("mapping_median_percent")
    )
    summary.to_csv(
        output_dir / "quick_previous_SE_QC_group_summary.tsv",
        sep="\t",
        float_format="%.4f",
    )

    order = summary.index.tolist()
    palette = plt.get_cmap("tab10")
    colors = {group: palette(index % 10) for index, group in enumerate(order)}
    figure, axes = plt.subplots(1, 3, figsize=(15, max(5.5, len(order) * 0.7)), constrained_layout=True)
    metrics = [
        ("mapping_percent", "Mapped reads (%)"),
        ("duplicate_percent", "Duplicate reads (%)"),
        ("mean_coverage", "Mean coverage (X)"),
    ]
    rng = np.random.default_rng(20260728)
    for axis, (column, label) in zip(axes, metrics, strict=True):
        values = [data.loc[data["Group_name"] == group, column].dropna().to_numpy() for group in order]
        axis.boxplot(values, orientation="horizontal", tick_labels=order, showfliers=False, widths=0.55)
        for position, (group, group_values) in enumerate(zip(order, values, strict=True), start=1):
            jitter = rng.uniform(-0.14, 0.14, size=len(group_values))
            axis.scatter(group_values, position + jitter, s=24, alpha=0.75, color=colors[group], edgecolors="none")
        axis.set_xlabel(label)
        axis.grid(axis="x", color="#d9d9d9", linewidth=0.7)
        axis.set_axisbelow(True)
    axes[1].tick_params(labelleft=False)
    axes[2].tick_params(labelleft=False)
    figure.suptitle("Previous SE mapping QC baseline (before ARS-UCD2.0 reanalysis)", fontsize=14)
    figure.savefig(output_dir / "quick_previous_SE_QC_overview.png", dpi=240)
    figure.savefig(output_dir / "quick_previous_SE_QC_overview.pdf")
    plt.close(figure)

    report = output_dir / "QUICK_RESULTS_STATUS.md"
    report.write_text(
        "\n".join(
            [
                "# Quick results available before full reanalysis",
                "",
                "These values come from the previous SE mapping and are a baseline only. They are not the final ARS-UCD2.0 reanalysis results.",
                "",
                f"- Previous SE runs summarized: {len(data)}",
                f"- Biological samples represented: {data['sample_accession'].nunique()}",
                f"- Runs with mapping below 10%: {int(data['mapping_lt_10_percent'].sum())}",
                f"- Runs with mean coverage below 0.1X: {int(data['coverage_lt_0_1x'].sum())}",
                "- Historical duplicate values were fractions mislabeled as percentages; the corrected output multiplies them by 100.",
                "- Reference FASTA versus IPCC @SQ compatibility is an exact ordered match; see reference_vs_ipcc_sq.tsv.",
                "- Final mapping QC, PCA, ADMIXTURE, phylogeny, and Ne results require completion of the new mapping and joint calling.",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(f"runs={len(data)}")
    print(f"biological_samples={data['sample_accession'].nunique()}")
    print(f"groups={len(summary)}")
    print(f"output_dir={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
