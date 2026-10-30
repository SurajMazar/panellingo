#!/usr/bin/env bash
# Builds PanelLingo.app from the Swift package (no Xcode project needed).
#   scripts/build-app.sh [debug|release] [--universal]
# Output: dist/PanelLingo.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
UNIVERSAL="${2:-}"
SWIFT_BUILD="${SWIFT_BUILD:-swift build}"
ARCH_FLAGS=()
if [[ "$UNIVERSAL" == "--universal" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

$SWIFT_BUILD -c "$CONFIG" --product PanelLingo ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
$SWIFT_BUILD -c "$CONFIG" --product panellingo-cli ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$($SWIFT_BUILD -c "$CONFIG" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

APP=dist/PanelLingo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PanelLingo" "$APP/Contents/MacOS/PanelLingo"
cp "$BIN_DIR/panellingo-cli" "$APP/Contents/MacOS/panellingo-cli"
cp Sources/PanelLingo/Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (if any) live next to the binary.
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
VERSION="${PANELLINGO_VERSION:-}"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
# Ad-hoc signature so Gatekeeper/TCC treat it as a stable app (replace with Developer ID for distribution).
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" --options runtime "$APP"
echo "Built $APP"

# Local builds are installed into /Applications (skipped on CI or with PANELLINGO_NO_INSTALL=1).
if [[ -z "${CI:-}" && "${PANELLINGO_NO_INSTALL:-}" != "1" ]]; then
  DEST="${PANELLINGO_INSTALL_DIR:-/Applications}/PanelLingo.app"
  WAS_RUNNING=0
  if pgrep -xq PanelLingo; then
    WAS_RUNNING=1
    # Projects autosave, so a normal quit loses nothing.
    osascript -e 'tell application "PanelLingo" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -xq PanelLingo || break; sleep 0.25; done
  fi
  rm -rf "$DEST.new"
  ditto "$APP" "$DEST.new"
  rm -rf "$DEST"
  mv "$DEST.new" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "Installed $DEST"
  # Reopen it if it was running (it restores the last chapter).
  if [[ "$WAS_RUNNING" == "1" ]]; then open "$DEST"; echo "Relaunched PanelLingo"; fi
fi
