# Jot — product spec (decided 2026-09-01)

"Notepad++ in a Notes.app body." Native macOS, AppKit, SwiftPM, no dependencies.

## Model
- **Tabs are the notes.** An open tab is the unit; the cache dir is the truth until ⌘S.
  Closed tabs are gone (after the Save / Don't Save / Cancel prompt; Don't Save = ⌘D).
- Files are plain text. Editing a named file only updates the cache; disk changes on ⌘S only.
- ⌘S default: `.md`, opens in the last-used folder.
- Window close = hide (app stays alive). Quit never prompts; everything restores.
- Search: ⌘F native find bar (in note); ⇧⌘F across all open tabs. In vim mode `/` `?` are vim's own search, typed in the
  command pane (see Vim mode); `n` `N` `*` `#` repeat it; `:noh` clears highlights. ⌘F stays native in every mode.

## Editor
- System font (SF Pro) 13pt default, full-width text, no line-width cap.
- Line numbers in a left gutter (Settings toggle, default on). One number per hard line; wrapped continuation rows are blank.
  Settings toggle "Gutter separator" (default off) draws a hairline (separatorColor) along the gutter's inner edge.
- Settings (⌘,): font family, size, line spacing, editor padding, vim mode, hotkey.
- Status bar: `[MODE]` bottom-left when vim mode is on · `N words · N characters` · `N pt` beside gear.

## Zen mode
- ⌥⌘Z toggles: tab strip, traffic lights, status bar, line-number gutter, and image sidebar all hide; only the text remains
  (same font/width, padding grows to 40pt). ⌘ shortcuts still work (⌘T, ⌘W, ⌘P, ⌘B forces the sidebar back for that note).
  Remembered per session; combine with ⌃⌘F for full screen if wanted.

## Images
- Stored as originals in `<support>/assets/<uuid>.<ext>`; token in text `![](jot://<uuid>.<ext>)`.
- Inline: always a text chip `Image N`, numbered in document order, renumbered live.
- Sidebar (native split pane, 150pt, side per Settings): 104pt thumbnails with `Image N` captions. Auto-shows when the note has ≥1 image,
  hides when none; ⌘B toggles it manually for the session. Settings: sidebar side Left / Right (default Right). Click → select chip; double-click → open in Preview.
  Context menu: Copy Image / Save Image As… / Reveal in Finder. Bottom-pinned utility row with a Settings gear (leading edge).
- ⌘A ⌘C carries images (RTFD) to other apps; Jot→Jot paste re-links without duplicating assets.
- Orphan assets are never auto-deleted.

## Tabs
- Min readable width ~110pt, strip scrolls horizontally past that. ⌘P fuzzy tab switcher by title.
- Middle-click closes. ⌘T new, ⌘W close, ⌘1–9, ⌃Tab/⌃⇧Tab.

## Summon
- Global hotkey, default ⌥Space, toggles show/hide. Configurable in Settings (key recorder). No menu-bar item.

## Vim mode (Settings checkbox, off by default)
- Opens in normal mode. Esc alternatives: ⌃[ and ⌃C only (no jk).
- Near-full: motions (h j k l w b e W B E 0 ^ $ gg G { } f t F T ; , % counts), operators d c y < > = ~ g~ gu gU
  with motions, doubled forms (dd cc yy >> << == guu gUU g~~), x X p P, u ⌃r, `.` (incl. the typed text of an insert
  session; `3.` overrides the count), text objects (iw aw iW aW is as ip ap, i" a" i' a' i` a`, i( i[ i{ i< and pairs, it at),
  visual v V (real NSTextView selection; o swaps ends; gv), o O a A I, J, r, ~, registers ("a–"z, "A–"Z append,
  "0 yank, "1–"9 deletes, "- small delete, "_ black hole, "+ "* = pasteboard), q macros (@a @@), marks (m ' ` '' '. '^ '< '>).
  `=` re-indents to the nearest non-blank line above (prose, not code). Visual changes are not recorded for `.`.
- Clipboard shared (unnamedplus): y/d write, p reads the system pasteboard (images survive).
- Ex commands: :w [name], :q (closes the tab), :q!, :wq, :x, :N, :s / :%s with g i flags, :noh,
  :tabnew, :tabn, :tabp, :e path. Unknown → "Not an editor command" in the status bar.
- ⌘ shortcuts keep working in every mode.
- Config file `~/.config/jot/vimrc` (vimscript subset): `map`/`noremap` and the n/i/v/o variants,
  `unmap`, `let mapleader`, `<leader>`, `<C-x>` `<S-x>` `<A-x>` `<CR>` `<Esc>` `<Space>` key notation,
  `set`/`set no` for ignorecase smartcase incsearch hlsearch wrap number relativenumber scrolloff tabstop shiftwidth expandtab,
  `"` comments. Reloaded on save (file watcher) and via `:source`. Parse errors show line number in the status bar.
  Settings has "Open vimrc" (creates a commented template on first use).
- Mode shown bottom-left of the status bar.
- Command pane: `:` `/` `?` open a one-line pane directly above the footer (present in zen mode too, since the footer is not),
  overlaying the bottom of the editor so the text does not jump. Prefix character in secondaryLabelColor, text in labelColor,
  same SF 11pt as the footer, bar caret, hairline (separatorColor) on top. Enter runs / searches, Esc ⌃[ ⌃C cancel; the pane
  collapses on either. Messages ("Not an editor command", "E486: Pattern not found", "3 substitutions on 2 lines",
  "search hit BOTTOM, continuing at TOP") show in the pane until the next key. Search is incremental (caret follows as you
  type, Esc restores), wraps, ICU regex like `:s`; matches highlighted monochrome (labelColor @ 12%) while `hlsearch`.
- Footer: LEFT mode indicator (+ showcmd), MIDDLE counts — Settings picks which of words / characters /
  images / lines show (default words + characters) — never tail-truncated: segments drop from the right, then numbers-only,
  RIGHT `line:col` (always shown). Mode indicator is monochrome/typographic ("as if Apple built vim"): sentence-case
  label, SF 11pt medium, secondaryLabelColor, in a quiet capsule (labelColor @ 6%, radius 9, h18) in every mode, Insert
  included; no per-mode colours anywhere. "recording @a" shows beside the badge (footer showcmd slot), not in the pane. Mode is conveyed primarily by cursor shape.
- Borrowed from NppVim (https://github.com/h-jangra/NppVim): `gt`/`gT` (+ `:bn`/`:bp`) switch tabs; ex ranges
  (`:10,20` `:'<,'>` `:%` `.` `$`) with `:d [reg]` `:y [reg]` `:j` `:m {addr}` `:t {addr}` `:sort [!iun]`;
  `:help` opens a read-only help tab listing supported keys; `:rc`/`:erc` opens the vimrc, `:so` reloads;
  `command Alias cmd` in vimrc; insert-mode ⌃W ⌃U ⌃T ⌃D; `:reg` / `:marks` open a scratch tab; `set cursorline`.
  Not borrowed: jj escape, keyboard-layout switching, `:!cmd` filters, visual-block.

## Explicitly out
- Created-date header, git/auto-commit, theming, menu-bar icon, collapse/expand images, jk escape, app icon (for now).
