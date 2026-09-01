#!/bin/bash
# Builds Jot and assembles Jot.app in the project root.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Jot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Jot "$APP/Contents/MacOS/Jot"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS keeps a stable identity for the app.
codesign --force --sign - "$APP"

echo
echo "Built $PWD/$APP"
echo "Run it with:  open $APP"
