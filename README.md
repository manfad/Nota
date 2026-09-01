# Jot

A small native macOS notepad — Notepad++ habits in a Notes.app body. One window,
a tab strip in the title bar, a plain-text editor, a thin status line. AppKit,
pure SwiftPM, no dependencies.

The editor is deliberately plain: system font on `textBackgroundColor`, so it
follows light and dark mode on its own. No themes, no rich text, no syntax
highlighting.

## The cache model

1. Every tab is continuously mirrored to `~/Library/Application Support/Jot/` —
   `session.json` for the tab list, cursor, font size, `cache/<uuid>.txt` for
   each tab's text, and `assets/` for inline images. Writes are atomic (temp
   file + rename).
2. Writes are debounced ~300 ms after the last keystroke, and forced on tab
   switch, tab close, window close, and quit.
3. **Your real files are only ever written by ⌘S / ⇧⌘S.** Saving defaults to
   `.md` (plain text is still offered) and opens in the folder you last saved to. Typing in a named
   note updates the cache and marks the tab dirty; the file on disk is untouched.
4. On launch every tab comes back, dirty edits included. A clean tab re-reads
   its file so external changes show up; a dirty tab's cache wins; a file that
   has gone missing keeps its cached text and is marked dirty.
5. Closing the window only hides it and the app keeps running, so reopening
   from the Dock is instant. Nothing ever prompts you on close or quit — the
   only prompt is closing a single dirty tab.

## Images

Paste a screenshot, paste an image file, or drag a png/jpg/gif in from the
Finder and it appears inline. Nothing about the file format changes: the image
bytes go to `~/Library/Application Support/Jot/assets/<uuid>.<ext>` and the note
itself gets a plain-text token where the picture sits.

```
Here is the crash:
![](jot://5f3c1a9e-….png)
and here is the fix.
```

That token is exactly what the cache file and your saved `.txt` contain, so a
note with images is still an ordinary text file, still greppable, still fine in
any other editor.

In the text an image is a **chip** reading `[Image 1]` — editor font, softly
filled, sitting in the line like a word — so a note with twenty screenshots
still reads as prose. The number is the image's position in the note and is
renumbered as you paste, delete and undo.

The pictures themselves live in the **image sidebar**: a native split pane —
a `sidebar` item on the left or an `inspector` item on the right, per Settings —
holding a single column of 104pt thumbnails captioned `Image N`, in document
order, drawn the way Preview shows pages: a shadowed card with the selection
washed in behind it. It slides in on its own
when the tab has images and away when it has none; ⌘B (View > Show Images) pins
it open or shut for the rest of the session. Click a thumbnail to put the caret
on its chip, or click a `[Image N]` chip in the text to bring the sidebar out
and jump to that thumbnail. Double-click a thumbnail to open the file in
Preview, or right-click to copy it, save it elsewhere, or reveal the asset in
the Finder.

An asset that has gone missing still gets a chip, reading `[Image 1 — missing]`,
and keeps its token, so nothing is silently lost.

Copying inside Jot moves images between tabs by reference — no second copy of
the file is made. Copying out gives other apps an RTFD flavour carrying the
image bytes, so Notes, Mail and Pages receive the picture, while anything
asking for plain text gets the words with the tokens stripped out. Word and
character counts ignore images entirely.

**Assets are never deleted automatically**, not even when you delete the image
from a note or close the tab. A `.txt` you saved somewhere else may still point
at one, and Jot has no way to know about those files. Prune
`~/Library/Application Support/Jot/assets/` by hand if it ever grows.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘T | New tab |
| ⌘N | Reopen the window (or new tab if it is already up) |
| ⌘O | Open a file into a new tab |
| ⌘W | Close the current tab |
| ⌘S | Save (save panel for an untitled note) |
| ⇧⌘S | Save As… |
| ⌘1 – ⌘9 | Select tab 1–9 |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘+ / ⌘- / ⌘0 | Font size up / down / back to 13 pt |
| ⌘, | Settings |
| ⌘F / ⌘G / ⇧⌘G | Find bar, find next, find previous |
| ⇧⌘F | Search across all open tabs |
| ⌘P | Go to tab (fuzzy match on title) |
| ⌘B | Show / hide the image sidebar |
| ⌥⌘Z | Zen mode |
| ⌥Space | Summon: show or hide Jot from anywhere |
| ⌥⌘I | Pin the image sidebar open or shut |
| ⌘Z / ⇧⌘Z | Undo / redo — history is per tab |
| ⌘Q | Quit |

Each tab owns its own text storage and undo manager, so undo never reaches
into a neighbouring tab.

## Line numbers

A left gutter numbers every hard line; a line that wraps onto three rows still
gets one number, with the continuation rows blank, and the line the caret is on
is drawn a shade darker. The gutter takes over the left inset, and the editor's
trailing edge is pulled in by the same amount so the right margin still matches
the padding setting. Positions come from the layout manager's own line
fragment rects, so the numbers stay welded to the text at any size or spacing.
On by default, off in Settings.

## Zen mode

⌥⌘Z takes everything away but the words: the tab strip, traffic lights, status
bar and line-number gutter all fade out over 150ms, the sidebar collapses, and
the text gets a 40pt margin. Every ⌘ shortcut still works — ⌘T and ⌘W without a
visible strip, ⌘B to bring the sidebar back for the note you are on. The top
28pt still drags the window. It is a per-session state: Jot always launches
with its chrome.

## Settings

⌘, or the gear at the right of the status bar opens a single-pane Settings
window: font family (System, Serif, Rounded, Monospaced, or any installed font
via the font panel), font size, line spacing, editor padding, the line-number
gutter, which side the image sidebar sits on, and the summon shortcut (click the field and press the keys; Clear
turns it off). Everything is
stored in `UserDefaults` behind one `Preferences` type and applied to the open
tabs immediately — nothing needs a restart, and the font size stays in step with
⌘+ / ⌘- / ⌘0 and the size restored from the session.

## Build and run

```sh
./build.sh      # swift build -c release, assembles and ad-hoc signs Jot.app
open Jot.app
swift test      # unit tests for the pure logic
```

Set `JOT_SUPPORT_DIR` to point the cache at a scratch directory — handy for
exercising a real launch without touching the notes you are working on:

```sh
JOT_SUPPORT_DIR=/tmp/jot-test ./Jot.app/Contents/MacOS/Jot
```

Requires macOS 14+ (the native sidebar and inspector split items) and a
Swift 5.9+ toolchain.
