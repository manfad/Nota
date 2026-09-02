#!/bin/bash
# Builds Nota and assembles Nota.app in the project root.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Nota.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Nota "$APP/Contents/MacOS/Nota"
cp Info.plist "$APP/Contents/Info.plist"

# The icon is optional so the script still works before one has been drawn.
if [ -f Icon/Nota.icns ]; then
    cp Icon/Nota.icns "$APP/Contents/Resources/Nota.icns"
fi

# Ad-hoc sign so macOS keeps a stable identity for the app.
codesign --force --sign - "$APP"

echo
echo "Built $PWD/$APP"
echo "Run it with:  open $APP"
