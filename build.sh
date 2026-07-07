#!/bin/zsh
# Builds AudioRouter.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/AudioRouter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AudioRouter "$APP/Contents/MacOS/AudioRouter"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: stable enough for local TCC (audio capture) permission.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Install with: cp -R $APP /Applications/"
