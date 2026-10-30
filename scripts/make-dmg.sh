#!/usr/bin/env bash
# Packages dist/PanelLingo.app into dist/PanelLingo-<version>.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${PANELLINGO_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/PanelLingo.app/Contents/Info.plist)}"
STAGE=$(mktemp -d)
cp -R dist/PanelLingo.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="dist/PanelLingo-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "PanelLingo $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Built $OUT"
