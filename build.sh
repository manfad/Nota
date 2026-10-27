#!/bin/bash
# Builds Nota and assembles Nota.app in the project root.
# --universal builds an arm64+x86_64 fat binary, for release; without it,
# a plain single-arch build for the machine running it.
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

# SwiftPM is asked where it put the binary rather than told: the folder a
# universal build lands in has moved between toolchains
# (.build/apple/Products/Release once, .build/out/Products/Release now).
if [ "$UNIVERSAL" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Nota"

APP="Nota.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Nota"
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
if [ "$UNIVERSAL" = "1" ]; then
    lipo -archs "$APP/Contents/MacOS/Nota"
fi
