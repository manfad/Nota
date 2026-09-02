# Nota — product spec (decided 2026-09-01)

"Notepad++ in a Notes.app body." Native macOS, AppKit, SwiftPM, no dependencies.

## Model
- **Tabs are the notes.** An open tab is the unit; the cache dir is the truth until ⌘S.
  Closed tabs are gone (after the Save / Don't Save / Cancel prompt; Don't Save = ⌘D).
- Files are plain text of any kind — .md .txt .xml .json .css .js .html .yaml .toml .csv .log .ini .sh .py .swift and
  anything else that is text (Notepad++ model). Nota registers as an editor for text/source types (Finder "Open With",
  drag onto the Dock icon, drop onto the window). No syntax highlighting. Not .docx / .rtf / binaries.
- Editing a named file only updates the cache; disk changes on ⌘S only. A named file keeps its extension, encoding
  (UTF-8 / UTF-16 / Latin-1 / Windows-1252 detected on open) and line endings (LF / CRLF) on save.
- ⌘S default for a new note: `.md`, opens in the last-used folder; any extension typed in the panel is kept.
- Window close = hide (app stays alive). Quit never prompts; everything restores.
- Search: ⌘F native find bar (in note); ⇧⌘F across all open tabs. In vim mode `/` `?` are vim's own search, typed in the
  command pane (see Vim mode); `n` `N` `*` `#` repeat it; `:noh` clears highlights. ⌘F stays native in every mode.
  Find bar field shows no focus ring.

## Editor
- System font (SF Pro) 13pt default, full-width text, no line-width cap.
- Line numbers in a left gutter (Settings toggle, default on). One number per hard line; wrapped continuation rows are blank.
  Settings toggle "Gutter separator" (default off) draws a hairline (separatorColor) along the gutter's inner edge.
- Settings toggle "Word wrap" (default on). Off: a long line runs on and the editor scrolls sideways; the gutter stays
  pinned at the left edge. The Markdown render always wraps.
- Settings (⌘,): font family, size, line spacing, editor padding, word wrap, vim mode, hotkey.
- Status bar: `[MODE]` bottom-left when vim mode is on · `N words · N characters` · `N pt` beside gear.

## Markdown preview — three modes (⇧⌘P cycles, View menu; per tab, remembered in the session)
- **Editor** (default), **Split**, **Reading**. ⇧⌘P cycles editor → split → reading → editor; ⌥⇧⌘P jumps to reading and
  back out to the editor. The View menu keeps "Markdown Preview" (checkmarked in split and reading) and adds
  "Reading Mode" (checkmarked in reading). Both checkmarks are the front tab's.
- Markdown files only: a note whose file is spelled `.md`, saved. Every other tab — an untitled note, a `.txt`, anything
  not yet saved — has no render, no mode control, and both View items are disabled there, so ⇧⌘P and ⌥⇧⌘P do nothing.
- Split: a read-only rendered pane beside the editor (trailing side, resizable, 50% default, min 240pt); the image sidebar
  stays outermost. Reading: the editor collapses and the render takes its column. Either way the window keeps its frame —
  the panes share the room out between them. A mode you ask for slides across in 0.2s (Reduce Motion snaps; a tab switch
  snaps); taps during a slide land once it has. Split remembers its divider, as a fraction, across reading and editor.
- Shared chrome: the tab strip runs across the top of both columns and the status bar across the bottom of both, so the
  editor/preview divider starts under the tabs and stops above the footer. The pane has no header of its own — it is the
  render and nothing else, starting at the top of its column with the editor's own leading inset.
- Mode control: three segments — `pencil` / `rectangle.split.2x1` / `book`, tool tips naming the state and its keys —
  floating over the top-trailing corner of a column, 8pt under the strip and 12pt off the trailing edge, and nothing
  behind it — the control's own rounded bezel is the whole of it, with no plate or hairline around that. There is one per
  column: the editor's in editor and split modes, the preview's in split and reading. Split shows both, one in each
  column's corner; the editor mode shows only the editor's, reading only the preview's, since the editor column is
  collapsed there. Both drive the one mode the tab is in and stay in step. It sits over the text rather than in a row of
  its own: nothing is pushed down for it, and the text starts at the strip's bottom edge. Idle segments in
  `secondaryLabelColor`, the selected one in the standard filled look. Hover only: it fades in (opacity, ≤150ms, no
  movement) when the pointer is anywhere in the top 44pt of that column and fades out when it leaves; while it is away
  the band takes no clicks, so the text under it stays reachable. ⌘F's find bar opens in the editor's corner and takes
  it for as long as the bar is up; the preview's is untouched.
- Reading has no automatic exits. The only ways out are the mode control, ⇧⌘P / ⌥⇧⌘P and the View menu — nothing you do
  to the page itself changes the mode. Clicking a block does nothing: no jump, no caret move, no block lit under it
  (links still open). Typing a printable character does nothing either — there is no editor on screen for it to land in.
  Arrow and page keys scroll the render, and ⌘F searches the render itself, opening the native find bar above it; that
  bar takes the corner from the render's own mode control while it is up. The keyboard belongs to the render in reading
  mode, and to the editor in the other two.
- Zen takes the chrome and leaves the columns: the tab strip, status bar, gutter, image sidebar and both mode controls
  go, and the mode the tab is in does not change. Split keeps both panes side by side, at the divider they were left at;
  the editor mode is the text alone; reading is the render alone. In split each column's top edge is then the window's
  own, so both take the same 28pt drop clear of the traffic-light zone, both carry a drag strip there, and both use zen's
  wider 40pt margin, so the two bodies of text line up. Coming out of zen brings the chrome back and nothing else.
- Per tab, not per app: ⇧⌘P sets the mode of the tab in front only, and switching tabs lays out for the tab you land on —
  a new ⌘T tab and a freshly opened file start in the editor. The mode rides in `session.json`, so each tab comes back the
  way it was left (a session written when the pane was a yes/no comes back split where it was open).
- Settings "Open Markdown files in reading mode" (default off): opening a `.md` file opens that tab in reading. Session
  restore ignores it — the tab's saved mode wins.
- Native: Foundation's Markdown parser (`AttributedString(markdown:)`, full interpretation) + Nota's own block styling.
  No WebView, no dependencies, no theming. Same font family/size as the editor; headings scale from it (H1 ×1.6 … H6 ×1.0,
  semibold); lists indented with `•` / `1.`; block quotes with a leading hairline bar in secondaryLabelColor; code spans
  and fenced blocks in the monospaced system font on labelColor @ 5%; thematic break = hairline; tables as aligned
  monospaced rows (best effort); links underlined in labelColor (monochrome), clickable; emphasis/strong/strike.
- `Image N` chips render as the actual pictures from the asset store, scaled to the pane width; remote images are not
  fetched (the alt text shows instead).
- Live: re-rendered ~150 ms after typing stops; the pane keeps its relative scroll position.
- Block sync (both ways). Every rendered block (heading, paragraph, list item, quote, code block, table, rule, image)
  knows its source range. Clicking a block selects it — a quiet band, labelColor @ 6%, full pane width — scrolls the
  editor so that source is visible and puts the caret at the block's first character (vim: normal mode, block caret on
  it) — in split only; reading takes no block clicks at all. Moving the caret in the editor lights the block it is in and scrolls the preview to keep it visible. One block
  lit at a time; the band clears when the text changes under it. No proportional scroll following any more.

## Zen mode
- ⌥⌘Z toggles: tab strip, traffic lights, status bar, line-number gutter, image sidebar and the Markdown mode controls all
  hide; what is left is the note itself — the text (same font/width, padding grows to 40pt), or in split the text and the
  render still side by side, or in reading the render alone. ⌘ shortcuts still work (⌘T, ⌘W, ⌘P, ⌘B forces the sidebar back for that note).
  Remembered per session; combine with ⌃⌘F for full screen if wanted.

## Images
- Stored as originals in `<support>/assets/<uuid>.<ext>`; token in text `![](nota://<uuid>.<ext>)`.
  Reading also accepts `![](jot://…)`, the scheme used before the app was renamed, so existing notes keep their pictures;
  only `nota://` is ever written, so a file brought through the editor is updated on its next save.
- Inline: always a text chip `Image N`, numbered in document order, renumbered live. Clicking one selects the chip itself, so ⌘C
  copies the picture and ⌫ or typing replaces it; in vim the block caret sits on it instead. Dragging and ⇧-clicking select as usual.
- Sidebar (native split pane, 150pt, side per Settings): 104pt thumbnails with `Image N` captions. Auto-shows when the note has ≥1 image,
  hides when none; ⌘B toggles it manually for the session. Settings: sidebar side Left / Right (default Right). Click → select chip; double-click → open in Preview.
  Context menu: Copy Image / Save Image As… / Reveal in Finder. Bottom-pinned utility row with a Settings gear (leading edge).
- ⌘A ⌘C carries images (RTFD) to other apps, and when the selection holds exactly one image the picture also goes
  as PNG/TIFF, so it pastes into terminals, browsers and Slack; two or more images offer no picture flavour.
  Nota→Nota paste prefers Nota's own flavour, re-linking without duplicating assets.
- Plain-text flavour (what a terminal actually receives): each image becomes `![Image N](<absolute asset path>)` by default, so
  an agent reading the paste can open the picture itself; Settings ("Copy images as:") can switch this back to a bare
  U+FFFC placeholder character per image, the old behaviour.
- Pasting from a web page (Chrome, Safari, Notion, Obsidian…) reads `public.html` and Safari's web archive, which are the only
  flavours a browser puts the pictures in. Taken only when the markup holds an `<img>`: a text-only copy still lands as plain
  text, untouched. Each picture comes from the markup's own `src` — inline `data:` bytes, a web archive subresource, or the URL
  fetched (5s) — and one that resolves to nothing is dropped, keeping the words around it.
- Orphan assets are never auto-deleted.

## Tabs
- Min readable width ~110pt, strip scrolls horizontally past that. A + pinned at the trailing end of the strip opens a new tab (same as ⌘T); overflowing tabs scroll in the remaining space. ⌘P fuzzy tab switcher by title.
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
- Config file `~/.config/nota/vimrc` (vimscript subset): `map`/`noremap` and the n/i/v/o variants,
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
  RIGHT `Ln N, Col M` (always shown). Mode indicator is monochrome/typographic ("as if Apple built vim"): sentence-case
  label, SF 11pt medium, secondaryLabelColor, in a quiet capsule (labelColor @ 6%, radius 9, h18) in every mode, Insert
  included; no per-mode colours anywhere. "recording @a" shows beside the badge (footer showcmd slot), not in the pane. Mode is conveyed primarily by cursor shape.
- Borrowed from NppVim (https://github.com/h-jangra/NppVim): `gt`/`gT` (+ `:bn`/`:bp`) switch tabs; ex ranges
  (`:10,20` `:'<,'>` `:%` `.` `$`) with `:d [reg]` `:y [reg]` `:j` `:m {addr}` `:t {addr}` `:sort [!iun]`;
  `:help` opens a read-only help tab listing supported keys; `:rc`/`:erc` opens the vimrc, `:so` reloads;
  `command Alias cmd` in vimrc; insert-mode ⌃W ⌃U ⌃T ⌃D; `:reg` / `:marks` open a scratch tab; `set cursorline`.
  Not borrowed: jj escape, keyboard-layout switching, `:!cmd` filters, visual-block.

## Explicitly out
- Created-date header, git/auto-commit, theming, menu-bar icon, collapse/expand images, jk escape, app icon (for now).
