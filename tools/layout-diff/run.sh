#!/usr/bin/env bash
#
# Cross-engine layout-comparison sweep (SwiftUI vs SwiftTUI) — headless.
#
# Runs the two geometry exporters + the IoU differ, then the SwiftTUI pixel
# exporter (via the swift-tui-swiftui @_spi(Raster) seam) + the side-by-side
# visual contact sheet. No window server, no kitty, no screencapture.
#
# Outputs:
#   /tmp/layout-probe/{png,geometry,swifttui,swifttui-png,pixel}/   ephemeral
#   /tmp/layout-probe/{results.csv,contact-sheet.png}              ephemeral
#   docs/reports/2026-06-21-layout-comparison-sweep.md             committed (geometry)
#   docs/reports/2026-06-21-layout-comparison-pixel-sweep.md       committed (pixels)
#
# Usage: tools/layout-diff/run.sh
set -euo pipefail

root=$(cd -- "$(dirname "$0")/../.." && pwd)
examples="$root/swift-tui-examples"

echo "[1/5] SwiftTUI geometry exporter (layouts) -> /tmp/layout-probe/swifttui"
LAYOUT_EXPORT=1 swiftly run swift test \
  --package-path "$examples/layouts" --filter LayoutComparisonExport

echo "[2/5] SwiftUI geometry+PNG exporter (LayoutsSwiftUI, all 56) -> /tmp/layout-probe/{png,geometry}"
LAYOUT_EXPORT_ALL=1 swiftly run swift test \
  --package-path "$examples/LayoutsSwiftUI" --filter MeasuringOverlaySpike

echo "[3/5] geometry differ -> docs/reports/2026-06-21-layout-comparison-sweep.md"
python3 "$root/tools/layout-diff/diff.py"

echo "[4/5] SwiftTUI pixel exporter (@_spi(Raster) seam) -> /tmp/layout-probe/swifttui-png"
swiftly run swift run \
  --package-path "$root/tools/layout-diff/swifttui-raster" swifttui-raster-export

echo "[5/5] side-by-side contact sheet -> /tmp/layout-probe/contact-sheet.png"
python3 "$root/tools/layout-diff/pixel_compare.py"
