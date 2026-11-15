#!/usr/bin/env python3
"""Summarize FIO JSON output without third-party packages."""

import csv
import json
import math
import re
import statistics
import sys
from pathlib import Path

FILE_PATTERN = re.compile(r"case([A-D])_qd([0-9]+)_rep([0-9]+)\.json$")
CASE_DETAILS = {
    "A": ("randread", "4k", "100%"),
    "B": ("randrw", "4k", "70%"),
    "C": ("randrw", "8k", "30%"),
    "D": ("read", "256k", "100%"),
}
PERCENTILES = ("50.000000", "95.000000", "99.000000")
METRICS = (
    "total_iops",
    "total_bw_mib_s",
    "read_iops",
    "write_iops",
    "read_avg_us",
    "read_p95_us",
    "read_p99_us",
    "write_avg_us",
    "write_p95_us",
    "write_p99_us",
)
DEPTH_BUCKETS = {
    "1": "iodepth_1_pct",
    "2": "iodepth_2_pct",
    "4": "iodepth_4_pct",
    "8": "iodepth_8_pct",
    "16": "iodepth_16_pct",
    "32": "iodepth_32_pct",
    ">=64": "iodepth_ge64_pct",
}


def percentile_us(stats: dict, percentile: str) -> float:
    values = stats.get("lat_ns", {}).get("percentile", {})
    if not values:
        values = stats.get("clat_ns", {}).get("percentile", {})
    key = next((key for key in values if math.isclose(float(key), float(percentile))), None)
    if key is None:
        raise ValueError(f"FIO output is missing the {percentile}% latency percentile.")
    return float(values[key]) / 1000


def direction_stats(job: dict, direction: str) -> dict:
    stats = job.get(direction, {})
    if not stats or float(stats.get("total_ios", 0)) == 0:
        return {
            f"{direction}_iops": 0.0,
            f"{direction}_avg_us": None,
            f"{direction}_p95_us": None,
            f"{direction}_p99_us": None,
        }
    mean_ns = stats.get("lat_ns", {}).get("mean")
    if mean_ns is None:
        mean_ns = stats.get("clat_ns", {}).get("mean")
    if mean_ns is None:
        raise ValueError(f"FIO output is missing {direction} mean latency.")
    return {
        f"{direction}_iops": float(stats.get("iops", 0)),
        f"{direction}_avg_us": float(mean_ns) / 1000,
        f"{direction}_p95_us": percentile_us(stats, PERCENTILES[1]),
        f"{direction}_p99_us": percentile_us(stats, PERCENTILES[2]),
    }


def load_run(path: Path) -> dict:
    match = FILE_PATTERN.fullmatch(path.name)
    if not match:
        raise ValueError(f"Unexpected result filename: {path.name}")
    case_id, depth, repetition = match.groups()
    pattern, block_size, read_mix = CASE_DETAILS[case_id]
    with path.open(encoding="utf-8") as result_file:
        output = json.load(result_file)
    jobs = output.get("jobs", [])
    if not jobs:
        raise ValueError(f"No jobs found in {path.name}")
    job = jobs[0]
    read_stats = direction_stats(job, "read")
    write_stats = direction_stats(job, "write")
    depth_stats = job.get("iodepth_level", {})
    return {
        "case": case_id,
        "pattern": pattern,
        "block_size": block_size,
        "read_mix": read_mix,
        "queue_depth": int(depth),
        "repetition": int(repetition),
        "total_iops": read_stats["read_iops"] + write_stats["write_iops"],
        "total_bw_mib_s": (
            float(job.get("read", {}).get("bw_bytes", 0))
            + float(job.get("write", {}).get("bw_bytes", 0))
        )
        / (1024 * 1024),
        "read_iops": read_stats["read_iops"],
        "write_iops": write_stats["write_iops"],
        "read_avg_us": read_stats["read_avg_us"],
        "read_p95_us": read_stats["read_p95_us"],
        "read_p99_us": read_stats["read_p99_us"],
        "write_avg_us": write_stats["write_avg_us"],
        "write_p95_us": write_stats["write_p95_us"],
        "write_p99_us": write_stats["write_p99_us"],
        **{
            field: float(depth_stats.get(bucket, 0))
            for bucket, field in DEPTH_BUCKETS.items()
        },
    }


def write_csv(path: Path, rows: list[dict], fields: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def summarize(rows: list[dict]) -> list[dict]:
    groups: dict[tuple[str, int], list[dict]] = {}
    for row in rows:
        groups.setdefault((row["case"], row["queue_depth"]), []).append(row)

    summaries = []
    for (case_id, depth), runs in sorted(groups.items()):
        pattern, block_size, read_mix = CASE_DETAILS[case_id]
        summary = {
            "case": case_id,
            "pattern": pattern,
            "block_size": block_size,
            "read_mix": read_mix,
            "queue_depth": depth,
            "repetitions": len(runs),
        }
        for metric in (*METRICS, *DEPTH_BUCKETS.values()):
            values = [float(run[metric]) for run in runs if run[metric] is not None]
            summary[f"{metric}_mean"] = statistics.mean(values) if values else ""
            summary[f"{metric}_stdev"] = (
                statistics.stdev(values) if len(values) > 1 else (0.0 if values else "")
            )
        summaries.append(summary)
    return summaries


def main() -> int:
    lab_dir = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.cwd()
    results_dir = lab_dir / "results"
    if not results_dir.is_dir():
        print(f"Error: results directory does not exist: {results_dir}", file=sys.stderr)
        return 2
    result_files = sorted(path for path in results_dir.glob("case*_qd*_rep*.json"))
    if not result_files:
        print(f"Error: no FIO result JSON files found in {results_dir}", file=sys.stderr)
        return 2

    try:
        rows = [load_run(path) for path in result_files]
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"Error while reading FIO results: {error}", file=sys.stderr)
        return 2

    run_fields = [
        "case",
        "pattern",
        "block_size",
        "read_mix",
        "queue_depth",
        "repetition",
        *METRICS,
        *DEPTH_BUCKETS.values(),
    ]
    summary_fields = [
        "case",
        "pattern",
        "block_size",
        "read_mix",
        "queue_depth",
        "repetitions",
        *[f"{metric}_{stat}" for metric in METRICS for stat in ("mean", "stdev")],
        *[
            f"{metric}_{stat}"
            for metric in DEPTH_BUCKETS.values()
            for stat in ("mean", "stdev")
        ],
    ]
    write_csv(lab_dir / "run_results.csv", rows, run_fields)
    write_csv(lab_dir / "summary.csv", summarize(rows), summary_fields)
    print(f"Analyzed {len(rows)} runs.")
    print(f"Per-run metrics: {lab_dir / 'run_results.csv'}")
    print(f"Mean and sample standard deviation: {lab_dir / 'summary.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
