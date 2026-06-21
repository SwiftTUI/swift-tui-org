#!/usr/bin/env python3
"""Cross-engine layout-comparison differ (SwiftUI vs SwiftTUI).

Joins the two exporters' per-entry JSON by `id`, normalizes both content
bounding boxes into the same cell space, computes the content-extent delta, and
emits a ranked Markdown report + CSV.

Coordination tooling — lives in the swift-tui-org root, never in a public child
(see docs/plans/2026-06-21-001-...). Reads ephemeral exporter output from
/tmp/layout-probe; writes the committed report to docs/reports/.

Inputs (produced by the env-gated exporters):
  /tmp/layout-probe/geometry/<id>.json   SwiftUI  (ImageRenderer pixel bbox -> cells)
  /tmp/layout-probe/swifttui/<id>.json   SwiftTUI (DefaultRenderer cell bbox + grid lines)
  /tmp/layout-probe/png/<id>.swiftui.png SwiftUI  render (linked from the report)

Usage:
  tools/layout-diff/diff.py [--probe-dir DIR] [--out REPORT.md] [--csv CSV] [--top N]
"""
from __future__ import annotations

import argparse
import csv
import json
import os
from dataclasses import dataclass

CANVAS_COLS = 60
CANVAS_ROWS = 30


@dataclass
class Row:
    id: str
    category: str
    marker: str
    ui: dict | None        # SwiftUI bbox (cells) {x,y,width,height}
    tui_raw: dict | None   # SwiftTUI bbox (cells, unclipped)
    tui: dict | None       # SwiftTUI bbox clipped to canvas
    overflow: bool
    deltas: tuple[int, int, int, int] | None  # (dx,dy,dw,dh) = tui - ui
    max_abs: int
    iou: float  # intersection-over-union of the two clipped bboxes (1.0 = identical extent)
    tier: str
    note: str


def clip_bbox(b: dict, cols: int, rows: int) -> tuple[dict, bool]:
    x0, y0 = b["x"], b["y"]
    x1, y1 = b["x"] + b["width"], b["y"] + b["height"]
    cx0, cy0 = max(x0, 0), max(y0, 0)
    cx1, cy1 = min(x1, cols), min(y1, rows)
    overflow = x1 > cols or y1 > rows or x0 < 0 or y0 < 0
    return {"x": cx0, "y": cy0, "width": max(0, cx1 - cx0), "height": max(0, cy1 - cy0)}, overflow


def iou_bbox(a: dict, b: dict) -> float:
    ax0, ay0, ax1, ay1 = a["x"], a["y"], a["x"] + a["width"], a["y"] + a["height"]
    bx0, by0, bx1, by1 = b["x"], b["y"], b["x"] + b["width"], b["y"] + b["height"]
    ix0, iy0 = max(ax0, bx0), max(ay0, by0)
    ix1, iy1 = min(ax1, bx1), min(ay1, by1)
    inter = max(0, ix1 - ix0) * max(0, iy1 - iy0)
    area_a = a["width"] * a["height"]
    area_b = b["width"] * b["height"]
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def classify(iou: float, missing: bool) -> str:
    # IoU is robust to the systematic SwiftUI-ink-vs-SwiftTUI-cell width narrowing;
    # it crushes only on true structural extent mismatches.
    if missing:
        return "MISSING"
    if iou >= 0.75:
        return "PASS"
    if iou >= 0.50:
        return "WARN"
    return "REVIEW"


def load(probe_dir: str) -> list[Row]:
    ui_dir = os.path.join(probe_dir, "geometry")
    tui_dir = os.path.join(probe_dir, "swifttui")
    rows: list[Row] = []

    ids = sorted(f[:-5] for f in os.listdir(tui_dir) if f.endswith(".json"))
    for id_ in ids:
        tui_j = json.load(open(os.path.join(tui_dir, f"{id_}.json")))
        ui_path = os.path.join(ui_dir, f"{id_}.json")
        ui_j = json.load(open(ui_path)) if os.path.exists(ui_path) else None

        ui_bbox = (ui_j or {}).get("contentBBoxCells")
        tui_raw = tui_j.get("contentBBoxCells")
        tui_bbox, overflow = (None, False)
        if tui_raw:
            tui_bbox, overflow = clip_bbox(tui_raw, CANVAS_COLS, CANVAS_ROWS)

        deltas = None
        max_abs = 0
        iou = 0.0
        missing = ui_bbox is None or tui_bbox is None
        if not missing:
            dx = tui_bbox["x"] - ui_bbox["x"]
            dy = tui_bbox["y"] - ui_bbox["y"]
            dw = tui_bbox["width"] - ui_bbox["width"]
            dh = tui_bbox["height"] - ui_bbox["height"]
            deltas = (dx, dy, dw, dh)
            max_abs = max(abs(dx), abs(dy), abs(dw), abs(dh))
            iou = iou_bbox(ui_bbox, tui_bbox)

        note = ""
        if overflow:
            note = "SwiftTUI content overflows canvas (clipped for diff)"

        rows.append(Row(
            id=id_,
            category=id_.split(".")[0],
            marker=tui_j.get("marker", ""),
            ui=ui_bbox, tui_raw=tui_raw, tui=tui_bbox,
            overflow=overflow, deltas=deltas, max_abs=max_abs, iou=iou,
            tier=classify(iou, missing), note=note,
        ))
    return rows


def fmt_bbox(b: dict | None) -> str:
    if not b:
        return "—"
    return f"{b['width']}×{b['height']} @({b['x']},{b['y']})"


def fmt_delta(d: tuple[int, int, int, int] | None) -> str:
    if d is None:
        return "—"
    return f"dx={d[0]:+d} dy={d[1]:+d} dw={d[2]:+d} dh={d[3]:+d}"


def crop_lines(lines: list[str], b: dict | None, pad: int = 0) -> list[str]:
    if not b or not lines:
        return lines[:12]
    y0 = max(0, b["y"] - pad)
    y1 = min(len(lines), b["y"] + b["height"] + pad)
    x0 = max(0, b["x"] - pad)
    x1 = b["x"] + b["width"] + pad
    return [ln[x0:x1] for ln in lines[y0:y1]]


def write_report(rows: list[Row], out: str, probe_dir: str, top: int) -> None:
    ranked = sorted(rows, key=lambda r: (r.iou, r.id))  # lowest overlap (worst) first
    tiers = {t: sum(1 for r in rows if r.tier == t) for t in ("PASS", "WARN", "REVIEW", "MISSING")}

    L: list[str] = []
    L.append("# Layout comparison sweep — Phase 0/1 (content-extent delta)\n")
    L.append("- **Date:** 2026-06-21")
    L.append(f"- **Entries:** {len(rows)}  ·  canvas {CANVAS_COLS}×{CANVAS_ROWS} cells (10 pt/cell)")
    L.append(f"- **Tiers:** PASS {tiers['PASS']} · WARN {tiers['WARN']} · REVIEW {tiers['REVIEW']} · MISSING {tiers['MISSING']}")
    L.append("- **Generated by:** `tools/layout-diff/run.sh` (see `tools/layout-diff/README.md`). Auto-generated — re-run to refresh; do not hand-edit.")
    L.append("")
    L.append("## Method & caveats\n")
    L.append(
        "Each scenario is rendered headlessly in both engines and reduced to a "
        "**content bounding box** in the shared cell space: SwiftUI via "
        "`ImageRenderer` (pixel-ink bbox ÷ scale ÷ 10), SwiftTUI via "
        "`DefaultRenderer` (non-blank cell bbox). The SwiftTUI bbox is **clipped "
        "to the canvas** before diffing (SwiftTUI does not clip to the proposal; "
        "ImageRenderer does).")
    L.append("")
    L.append(
        "> This is a **triage signal**, not a gate. SwiftUI measures antialiased "
        "*ink extent* while SwiftTUI measures *whole cells*, so width/height "
        "deltas of a few cells are expected measurement noise — they rank an "
        "entry for human/LLM review, they do not assert a bug. Per-element "
        "SwiftUI geometry was found **not headlessly automatable** (Phase-0 "
        "accessibility spike: SwiftUI's a11y subtree does not materialize in an "
        "offscreen test process), so this sweep compares content extent, not "
        "per-element rects. True SwiftTUI pixel renders + DSSIM/AE heatmaps await "
        "the `@_spi(Raster)` seam (deferred).")
    L.append("")
    L.append("## Ranked by extent overlap (lowest IoU = most divergent first)\n")
    L.append("| IoU | tier | id | SwiftUI bbox | SwiftTUI bbox | delta (cells) | note |")
    L.append("|---:|:--|:--|:--|:--|:--|:--|")
    for r in ranked:
        L.append(
            f"| {r.iou:.2f} | {r.tier} | `{r.id}` | {fmt_bbox(r.ui)} | "
            f"{fmt_bbox(r.tui)} | {fmt_delta(r.deltas)} | {r.note} |")
    L.append("")

    L.append(f"## Top {top} for review (SwiftUI render + SwiftTUI cell grid)\n")
    tui_dir = os.path.join(probe_dir, "swifttui")
    for r in [r for r in ranked if r.tier != "PASS"][:top]:
        L.append(f"### `{r.id}` — IoU {r.iou:.2f} ({r.tier})\n")
        L.append(f"- marker: `{r.marker}`  ·  delta: {fmt_delta(r.deltas)}  {('· ' + r.note) if r.note else ''}")
        rel = os.path.relpath(os.path.join(probe_dir, "png", f"{r.id}.swiftui.png"),
                              os.path.dirname(out))
        L.append(f"- SwiftUI render: `{os.path.join(probe_dir, 'png', r.id + '.swiftui.png')}`")
        L.append("")
        tui_j = json.load(open(os.path.join(tui_dir, f"{r.id}.json")))
        cropped = crop_lines(tui_j.get("lines", []), r.tui_raw, pad=1)
        L.append("SwiftTUI cell grid (cropped to content):\n")
        L.append("```")
        L.extend(ln.rstrip() for ln in cropped)
        L.append("```")
        L.append("")

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("\n".join(L))


def write_csv(rows: list[Row], path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "category", "tier", "max_abs_delta",
                    "ui_bbox", "tui_bbox_clipped", "tui_bbox_raw", "overflow", "deltas"])
        for r in rows:
            w.writerow([r.id, r.category, r.tier, r.max_abs,
                        fmt_bbox(r.ui), fmt_bbox(r.tui), fmt_bbox(r.tui_raw),
                        r.overflow, fmt_delta(r.deltas)])


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--probe-dir", default="/tmp/layout-probe")
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    p.add_argument("--out", default=os.path.join(root, "docs/reports/2026-06-21-layout-comparison-sweep.md"))
    p.add_argument("--csv", default="/tmp/layout-probe/results.csv")
    p.add_argument("--top", type=int, default=8)
    args = p.parse_args()

    rows = load(args.probe_dir)
    write_csv(rows, args.csv)
    write_report(rows, args.out, args.probe_dir, args.top)
    tiers = {t: sum(1 for r in rows if r.tier == t) for t in ("PASS", "WARN", "REVIEW", "MISSING")}
    print(f"diffed {len(rows)} entries: {tiers}")
    print(f"report: {args.out}")
    print(f"csv:    {args.csv}")


if __name__ == "__main__":
    main()
