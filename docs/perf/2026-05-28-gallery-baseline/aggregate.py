#!/usr/bin/env python3
"""Aggregate TermUIPerf run directories into a per-(scenario, mode) table.

Reads each run's run.json + summary.json + frames.tsv (header-indexed, so it is
robust to column reordering) and emits a CSV plus a ranked text table. Stdlib
only.

Usage:
  aggregate.py [RUNS_ROOT] [OUT_CSV]
Defaults:
  RUNS_ROOT = ../../../swift-tui/.perf/runs   (relative to this script)
  OUT_CSV   = ./aggregate.csv
"""
import csv
import glob
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else 0.0


def to_float(cell):
    # phase-timing cells are plain floats; guard against "-" / "x/y" / "".
    try:
        return float(cell)
    except (ValueError, TypeError):
        return None


def to_int(cell):
    try:
        return int(cell)
    except (ValueError, TypeError):
        return None


def parse_frames(path):
    """Return per-column lists keyed by header name, plus row count."""
    with open(path, newline="") as fh:
        reader = csv.reader(fh, delimiter="\t")
        rows = list(reader)
    if not rows:
        return {}, 0
    header = rows[0]
    idx = {name: i for i, name in enumerate(header)}
    data = rows[1:]

    def col(name):
        i = idx.get(name)
        if i is None:
            return []
        return [r[i] if i < len(r) else "" for r in data]

    return {name: col(name) for name in idx}, len(data)


def summarize_run(run_dir):
    run = {}
    rj = os.path.join(run_dir, "run.json")
    sj = os.path.join(run_dir, "summary.json")
    ft = os.path.join(run_dir, "frames.tsv")
    if not (os.path.exists(sj) and os.path.exists(ft)):
        return None

    meta = json.load(open(rj)) if os.path.exists(rj) else {}
    summ = json.load(open(sj))
    cols, n = parse_frames(ft)

    scenario = summ.get("scenario") or meta.get("scenario", os.path.basename(run_dir))
    mode = summ.get("render_mode") or meta.get("render_mode", "?")

    def fcol(name):
        return [to_float(c) for c in cols.get(name, [])]

    def icol(name):
        return [to_int(c) for c in cols.get(name, [])]

    # NOTE on validity: PerfTerminalHost is a stub PresentationSurface that
    # hardcodes present_strategy=fullRepaint, present_cells=width*height,
    # present_bytes=0, present_ms=0. So present_* columns are ARTIFACTS and are
    # excluded here. The damage_* columns are computed in the runtime raster/
    # commit tail independent of the host, so they are REAL and used instead.
    # Skip the cold first frame for body medians.
    pipeline = [p for p in fcol("pipeline_ms")[1:] if p is not None]
    damage = [d for d in icol("damage_cells")[1:] if d is not None]
    focus = [v for v in icol("focus_syncs") if v is not None]
    anim = [v for v in icol("animation_controller_active_animations") if v is not None]
    zero_damage = sum(1 for d in damage if d == 0)

    fi = summ.get("frame_interval_ms", {})

    return {
        "scenario": scenario,
        "mode": mode,
        "committed_frames": summ.get("committed_frame_count", n),
        "total_cpu_s": round(summ.get("total_cpu_seconds", 0) or 0, 3),
        "cpu_per_frame_ms": round(1000 * (summ.get("cpu_seconds_per_committed_frame", 0) or 0), 2),
        "interval_p50_ms": round(fi.get("p50", 0) or 0, 2),
        "pipeline_med_ms": round(median([float(p) for p in pipeline]), 2),
        "pipeline_max_ms": round(max(pipeline, default=0), 2),
        "resolve_med_ms": round(median(fcol("resolve_ms")[1:]), 2),
        "measure_med_ms": round(median(fcol("measure_ms")[1:]), 2),
        "place_med_ms": round(median(fcol("place_ms")[1:]), 2),
        "draw_med_ms": round(median(fcol("draw_ms")[1:]), 2),
        "raster_med_ms": round(median(fcol("raster_ms")[1:]), 2),
        "commit_med_ms": round(median(fcol("commit_ms")[1:]), 2),
        "damage_cells_med": int(median(damage)) if damage else 0,
        "damage_cells_max": max(damage, default=0),
        "pct_zero_damage": round(100 * zero_damage / max(1, len(damage))),
        "focus_syncs_sum": sum(focus),
        "anim_active_max": max(anim, default=0),
    }


def main():
    runs_root = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(
        os.path.join(HERE, "../../../swift-tui/.perf/runs")
    )
    out_csv = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "aggregate.csv")

    rows = []
    for run_dir in sorted(glob.glob(os.path.join(runs_root, "*"))):
        if not os.path.isdir(run_dir):
            continue
        row = summarize_run(run_dir)
        if row:
            rows.append(row)

    if not rows:
        print(f"No runs found under {runs_root}", file=sys.stderr)
        sys.exit(1)

    fields = list(rows[0].keys())
    with open(out_csv, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {out_csv} ({len(rows)} runs)\n")

    # Ranked view (async only): steady CPU first, then committed frames.
    print("=== Ranked by total CPU (async mode) — valid metrics only ===")
    ranked = sorted(
        (r for r in rows if r["mode"] == "async"),
        key=lambda r: (-r["total_cpu_s"], -r["committed_frames"]),
    )
    hdr = ["scenario", "committed_frames", "total_cpu_s", "cpu_per_frame_ms",
           "damage_cells_med", "pct_zero_damage", "resolve_med_ms", "commit_med_ms",
           "pipeline_med_ms", "anim_active_max"]
    print("\t".join(hdr))
    for r in ranked:
        print("\t".join(str(r[h]) for h in hdr))


if __name__ == "__main__":
    main()
