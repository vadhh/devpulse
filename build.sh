#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is unavailable. Install Command Line Tools:"
  echo "  xcode-select --install"
  exit 1
fi

echo "==> Building DevPulse"
swift build -c release

PRODUCT="$ROOT/build/DevPulse.pock"
DEST="$HOME/Library/Application Support/Pock/Widgets/DevPulse.pock"

echo "==> Assembling bundle"
rm -rf "$PRODUCT"
mkdir -p "$PRODUCT/Contents/MacOS"
cp DevPulse/Info.plist "$PRODUCT/Contents/Info.plist"
cp .build/release/libDevPulse.dylib "$PRODUCT/Contents/MacOS/DevPulse"
codesign --force --sign - "$PRODUCT"

echo "==> Installing widget"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$PRODUCT" "$DEST"

echo "==> Relaunching Pock"
pkill -x Pock 2>/dev/null || true
# Reopening while the old process is still exiting fails with error -600.
while pgrep -x Pock >/dev/null; do sleep 0.2; done
open -a Pock

echo
echo "Installed:"
echo "  $DEST"
echo
echo "Now open Pock -> Customize Pock... and drag DevPulse onto the Touch Bar."
