# Nota

A little native notepad for the Mac. One window, tabs in the title bar, a plain
text editor. AppKit, Swift Package Manager, no dependencies.

Website: https://www.nota-app.xyz

## Install

```sh
brew install --cask manfad/nota/nota
# or
curl --proto '=https' --tlsv1.2 -LsSf https://nota-app.xyz/install.sh | sh
```

Or download `Nota-<version>.zip` from [Releases](https://github.com/manfad/Nota/releases).
macOS 14 or later. Nota is not notarized yet: if macOS blocks it, allow it once
under System Settings › Privacy & Security.

## What it opens

- **Edit:** any UTF-8 text file. `.txt`, `.json`, `.yaml`, `.toml`, `.xml`, `README`.
- **Split, source beside a preview:** `.md`, `.html`, `.tex`, `.csv`, `.tsv`, `.sql`, `.svg`.
- **Read only:** `.pdf`, `.epub`, `.rtf`, images (`.png`, `.jpg`, `.gif`, `.webp`, `.heic`, `.bmp`).

Markdown and LaTeX previews are drawn by Nota itself, maths included. HTML is
rendered by WebKit. A `.sql` dump runs into an in-memory SQLite database you
can query; nothing is written back.

## How it works

- Every tab is mirrored to `~/Library/Application Support/Nota/` a moment after
  you stop typing. Quit, relaunch, and every tab is back, unsaved ones included.
- Your files are only written by ⌘S and ⇧⌘S.
- Paste or drop an image and it sits inline as a chip. The note stays a text
  file; the picture lives in `assets/`.
- Closing the window hides it. Nota keeps running and reopens instantly.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘T / ⌘W | New tab / close tab |
| ⌘O | Open a file |
| ⌘S / ⇧⌘S | Save / Save As… |
| ⌘1 – ⌘9, ⌃Tab | Switch tabs |
| ⌘P | Go to tab |
| ⌘F, ⇧⌘F | Find in tab, find across tabs |
| ⇧⌘P | Preview beside the editor |
| ⌥⌘Z | Zen mode |
| ⌥Space | Summon Nota from anywhere |
| ⌘, | Settings |

## Build

```sh
./build.sh      # assembles and ad-hoc signs Nota.app
open Nota.app
swift test
```

`NOTA_SUPPORT_DIR=/tmp/nota-test ./Nota.app/Contents/MacOS/Nota` runs against a
scratch folder instead of your notes. Needs macOS 14+ and Swift 5.9+.

## Release

`swift test` green, commit (the pre-commit hook bumps the patch version), then
`./release.sh`: it builds a universal `Nota.app`, zips it, tags, pushes, creates
the GitHub release and updates the Homebrew tap `manfad/homebrew-nota`.
`RELEASE_NOTES=notes.md` and `TAP_DIR=path` override the defaults.
