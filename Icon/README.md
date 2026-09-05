# Nota app icon

- `artwork.png` — the icon as the user supplied it on 2026-09-06 (1254×1254, the tile already drawn on a white ground with a drop shadow).
- `logo.png` — the source the script reads (1024×1024, no alpha): the drawn tile cropped out of `artwork.png` a touch inside its own edge, so the script's squircle mask never meets the white outside the drawn corners. Everything below is generated from it.
- `make-icon.swift` — masks the artwork into the standard macOS app-icon tile (a continuous-corner squircle, 824×824 inset 100pt inside the 1024×1024 canvas, corner radius 185.4), renders every iconset size, and runs `iconutil` to produce `Nota.icns`. It also writes `preview-512.png` and `preview-32.png` for review. Generated: `Nota.iconset/`, `Nota.icns`, both previews.
- Rebuild with `swift Icon/make-icon.swift` from the repo root (or `./Icon/make-icon.swift`); it regenerates all outputs from `logo.png` each run.
