#!/usr/bin/env bash
#
# Cross-engine layout-comparison sweep (SwiftUI vs SwiftTUI) — headless.
#
# Runs both env-gated exporters in the swift-tui-examples submodule, then the
# IoU differ, producing a ranked discrepancy report. No window server, no kitty,
# no screencapture, no permissions — entirely ImageRenderer + DefaultRenderer.
#
# Outputs:
#   /tmp/layout-probe/{png,geometry,swifttui}/   ephemeral exporter artifacts
#   /tmp/layout-probe/results.csv                ephemeral
#   docs/reports/2026-06-21-layout-comparison-sweep.md   committed report
#
# Usage: tools/layout-diff/run.sh
set -euo pipefail

root=$(cd -- "$(dirname "$0")/../.." && pwd)
examples="$root/swift-tui-examples"

echo "[1/3] SwiftTUI exporter (layouts) -> /tmp/layout-probe/swifttui"
LAYOUT_EXPORT=1 swiftly run swift test \
  --package-path "$examples/layouts" --filter LayoutComparisonExport

echo "[2/3] SwiftUI exporter (LayoutsSwiftUI, all 56) -> /tmp/layout-probe/{png,geometry}"
LAYOUT_EXPORT_ALL=1 swiftly run swift test \
  --package-path "$examples/LayoutsSwiftUI" --filter MeasuringOverlaySpike

echo "[3/3] differ -> docs/reports/2026-06-21-layout-comparison-sweep.md"
python3 "$root/tools/layout-diff/diff.py"
