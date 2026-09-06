# Nota — product spec (decided 2026-09-01)

"Notepad++ in a Notes.app body." Native macOS, AppKit, SwiftPM, no dependencies.

## Promo website (2026-09-05)

- `../nota-web` (outside the repo since 2026-09-05; was `website/`) is a separate static Astro landing page: hero, persistent tabs, inline images,
  split/reading previews, Zen benefits, file support, Vim, bookmarks, and native/open-source/no-login benefits.
- Features share one compact section: a vertical rotating wheel of eight tabs at left, the selected
  description below it, and a matching real screenshot at right. It advances every 5.5 seconds
  while visible; hover pauses temporarily, manual navigation or keyboard focus pauses until Play.
  Up/Down, Home/End, click, and previous/next controls work. Reduced motion disables autoplay and
  transitions; without JavaScript, expandable descriptions remain available. Page scrolling is not captured.
- Real screenshots use isolated demo content. The minimal screenshot uses chrome preferences.
- Download links go to GitHub releases; source links go to `manfad/Nota`. A packaged release is
  needed before public promotion. No backend, login, additional pages, or app behavior changes.

## Model
- **Tabs are the notes.** An open tab is the unit; the cache dir is the truth until ⌘S.
  Closed tabs are gone (after the Save / Don't Save / Cancel prompt; Don't Save = ⌘D in the alert, and ⌘W — whatever
  Close Tab is bound to — pressed again on the prompt, so two strokes of the same key close a dirty tab with no mouse; decided 2026-09-06).
- Files are plain text of any kind — .md .txt .xml .json .css .js .html .yaml .toml .csv .log .ini .sh .py .swift and
  anything else that is text (Notepad++ model). Nota registers as an editor for text/source types (Finder "Open With",
  drag onto the Dock icon, drop onto the window). No syntax highlighting. Not .docx / binaries — except the four
  Nota views rather than edits: a PDF, a picture, an EPUB and a rich-text document (see PDF, Image tabs, EPUB and
  RTF). An `.rtf` file or an `.rtfd` package opens as a viewer tab of its own (done 2026-09-05, see Done 26 and the
  RTF section): the document as its author wrote it, read and never written, with nothing to save. It used to be
  imported as plain text instead (Done 17, superseded).
- Editing a named file only updates the cache; disk changes on ⌘S only. A named file keeps its extension, encoding
  (UTF-8 / UTF-16 / Latin-1 / Windows-1252 detected on open) and line endings (LF / CRLF) on save.
- The save panel splits the extension out of the name field into its own editable "Format" combo box (pick one of
  Nota's known extensions, or type another), so it is never lost to the panel's own name-typed-with-a-dot handling; a
  named file's extension preselects it, and otherwise the last extension chosen through the panel is remembered
  (`Preferences.lastSaveExtension`, default `md`) and offered again next time. The combo stands as one more row of the
  panel's own form (2026-09-06): "Format:" right-aligned into the column "Save As:" and "Where:" share, the combo
  starting where the fields start, both anchored to the panel's centre line (`SavePanelForm`), since the panel centres
  its form and the accessory alike. It sits under "Where:" — the accessory area is the only place macOS gives an app,
  and a row between "Save As:" and "Tags:" is not on offer; decided to keep it there rather than hide Tags.
- The footer shows a text note's own shape at the right of the counts, `UTF-8` and `LF` as two capsule badges in
  the vim chip's family (done 2026-09-04, see Done 2): clicking either pops a menu to convert it, which marks the tab
  dirty for the next ⌘S; hover brightens the capsule so it reads as pressable. Empty over a PDF or a picture, which
  has neither.
- **A named tab watches its file** (done 2026-09-04). Each note owns a `FileWatcher`: a `DispatchSource` on the file's
  own descriptor *and* one on the folder holding it. Most editors save by writing a temporary file and renaming it
  over the original, which leaves the first descriptor open on an inode nobody can reach again, so the file's watch is
  opened afresh by name on every `.rename` / `.delete`, and the folder — where a rename into place shows up — is what
  finds a file that is briefly not there. What counts as a change is the file's size and modification date together
  (`FileStamp`), asked on the watcher's own queue as a filter and again on the main thread as the answer, so Nota's own
  ⌘S — which records the stamp it has just made — never reloads itself, and a neighbouring file moving in the same
  folder costs nothing.
- A **clean** tab reloads silently: the file's text, the caret's offset and the scroll position kept as near as the new
  text allows, `TextFileFormat` re-detected (a file rewritten as CRLF saves back as CRLF), and the undo history
  dropped, since it is a list of ranges into text that is no longer there. A PDF, a picture and a book reload the
  same way, silently, since none of them is ever dirty — a book unpacks its file again, at the chapter you were on. A **dirty** tab reloads nothing: its tab wears a hairline ring round the
  unsaved dot — the dot still says "unsaved", the ring says the file has moved as well — and the editor column's
  bottom-trailing corner, the one ⌘F and ⌘L do not use, carries a `Pill.swift` bar: a `clock.arrow.circlepath` glyph,
  `Changed on disk`, and the two quiet words `Reload` and `Keep mine`. Reload takes the file's text and clears dirty;
  Keep mine dismisses, keeps the ring, and the next ⌘S writes over the file. The offer stands on the tab until it is
  answered rather than being spent by being shown, so switching away and back still asks and a window coming forward
  finds it already up; only a further change on disk raises it again. One offer per change, and never a modal. A file
  that has gone is not a change at all — the missing-file behaviour below is untouched — and with more than one window
  open only the window actually holding the tab reacts.
- What a file *is* is read from its bytes first, not its name: `%PDF-` magic makes it a PDF, a picture's signature
  makes it a picture, a zip whose first entry is a stored `mimetype` reading `application/epub+zip` makes it a book,
  and otherwise whether it decodes as text makes it a note, whatever it is called — a `report` or `config` with no
  extension opens correctly, and a PDF named `notes` opens as a PDF. A file's name is only consulted when its bytes cannot say
  (missing, unreadable, or a real binary). What a file is *rendered as* (Markdown vs. LaTeX vs. HTML) is the one
  exception — that stays by extension, since it is the author's own word for it (see Markdown preview).
- ⌘S default for a new note: `.md`, opens in the last-used folder; any extension typed in the panel is kept.
- File › Open Recent (done 2026-09-04): `NSDocumentController`'s own list, noted on every named-file open (not on
  session restore) and rebuilt into the submenu each time it opens; Clear Menu empties it.
- Multi-window: ⇧⌘N opens another window, ⌘N and ⌘T stay new tabs, and every menu action means the window in front.
  `session.json` keeps `windows: [{tabs, selectedTabID, frame}]` — one entry per window, in order, each with its own
  frame; a file written before that (a flat tab list) comes back as one window, and the first window is still mirrored
  flat for a release so an older build opens the session it finds.
- Closing the last window = hide (app stays alive). Closing any other window really closes it, and its tabs go to the
  end of the window that was in front before it, so nothing is lost and nothing is asked. Quit never prompts;
  everything restores.
- Search: ⌘F opens Nota's own find bar (in note), ⌥⌘F opens it with the replace pill too; ⇧⌘F opens the search
  dialog across all open tabs (see Tabs).
  In vim mode `/` `?` are vim's own search, typed in the command pane (see Vim mode); `n` `N` `*` `#` repeat it;
  `:noh` clears highlights. ⌘F is the same bar in every mode, and closing it hands the highlights back to vim.
- The find bar is a pill floating in the top-trailing corner of the column, over the text, with that column's mode
  control dropped below it: a magnifying glass, the query field, the count (`3 of 12`, `12 matches`, `No matches`),
  and chevron-up / chevron-down / ✕, in `secondaryLabelColor` on a raised surface with a hairline round it. Nothing is
  pushed down for it; it fades (opacity, ≤150ms, no movement) and its field shows no focus ring. Typing searches as
  you go, from where the caret was when the bar opened; Return and ⇧Return step, Esc closes, ⌘G / ⇧⌘G wrap, ⌘E seeds
  the query from the selection and the find pasteboard. Case- and diacritic-insensitive.
- Matches wear the quiet band vim's `'hlsearch'` uses — temporary attributes, never the text — except the one you are
  on, which wears `findHighlightColor` with its text in black. Nothing is selected while the bar is open: the caret
  sits at that match's start, and a click elsewhere is the new place for ⌘G to walk from. The bands stop at 2000
  matches and the count then says `2000+`; an edit re-scans 150 ms after the keystrokes stop, and a note past
  `BigFile.threshold` not at all. Closing puts the bands down, leaves the match selected and hands back the keyboard
  and the corner. A tab switch closes the bar.
- Replace is a **second pill**, not a taller one: the magnifying glass fades in another 300×34 pill of the same
  surface 6pt below the find one, holding an `arrow.2.squarepath` glyph, a replace field ("Replace") and two quiet
  words, `Replace` and `All`. It goes when the glass is clicked again and when the find pill closes; neither pill ever
  changes size, and the mode control clears the whole stack. ⌥⌘F ("Find and Replace…") opens both, with the keyboard
  in the replace field when there is already a query. Tab walks between the fields; there Return replaces and steps
  on, ⌥Return replaces all, Esc closes. The pill is remembered per column, not per tab.
- Replace acts on the match you are standing on; clicked away, it steps to the next instead. The replacement is
  verbatim, never a pattern, and goes in as an ordinary edit — undo, the dirty flag, the save and vim all see one.
  Replace All changes every match, not only the 2000 wearing a band, in one undo, and leaves the caret where it was.
  Over the rendered page and in any tab that is not editable the glass is a plain glyph and ⌥⌘F is ⌘F.
- **Go to line** is the same pill again (done 2026-09-04): ⌘L ("Go to Line…") opens one with an
  `arrow.right.to.line` glyph, a field ("Go to line"), the note's line total (`1,234 lines`) and a ✕. It takes `N` or
  `N:M`, 1-based, and moves as you type — to the first thing on line N that is not a space, or to column M clamped to
  the line's end, centred where there is room. Past the end is the last line; junk leaves the caret alone and reads
  `Not a line`. Return and the ✕ keep the place, Esc puts the caret and the scroll position back. Editor only, so the
  menu item is disabled in reading mode and on a PDF or a picture. ⌘L and ⌘F share the corner; vim's `:N` is its own.

## Editor
- System font (SF Pro) 13pt default, full-width text, no line-width cap.
- Line numbers in a left gutter (Settings toggle, default on). One number per hard line; wrapped continuation rows are blank.
  Settings toggle "Gutter separator" (default off) draws a hairline (separatorColor) along the gutter's inner edge.
- Settings toggle "Word wrap" (default on). Off: a long line runs on and the editor scrolls sideways; the gutter stays
  pinned at the left edge. The Markdown render always wraps.
- Settings (⌘,): a source list of eight pages down the left — General, Appearance, Editor, Preview,
  Tab bar, Status bar, Shortcuts, About — over one shared Save button, which applies every page's draft
  together and is greyed until something changes. The sidebar is a `.sidebar`-material column, 180pt,
  running the full height with the traffic lights over it (the titlebar is transparent and the title is
  not drawn); each row is an accent-coloured SF Symbol beside its name, and the page on screen is a
  rounded row filled in the accent colour. The pane beside it carries the page's title at the top,
  centred and bold, then the controls in inset rounded groups: a 10pt-radius card, a hairline between one
  44pt row and the next, the label left and the control on the right edge, an on/off setting wearing an
  `NSSwitch` rather than a checkbox, and a quiet footnote under the group where one is owed. **General**
  — language and theme ("System Default follows the Mac."). The language popup lists five, each naming
  itself in its own script: System Default, English, 简体中文, 繁體中文, Bahasa Melayu. System Default reads
  the Mac's own preferred language — `zh-Hant` / `zh-TW` / `zh-HK` → 繁體中文, `zh-Hans` / `zh-CN` / bare
  `zh` → 简体中文, `ms` → Bahasa Melayu, anything else English. **Appearance** — font family, size, line
  spacing, editor padding. **Tab bar** — a first group of "Show tab bar" and "Auto-hide tab bar", then a
  second group for what the strip shows: Traffic lights, Bookmark button, Settings button; no footnote —
  the keys (⌘T, ⌘P, ⇧⌘D, ⌘, and ⌘W) all keep working with the strip and its buttons hidden, but the page
  does not say so. "Auto-hide tab bar" and "Traffic lights" are both greyed while
  "Show tab bar" is off — turning the strip off already takes the lights with it, the way zen does, so
  there is nothing left for either row to do. Whenever the lights are gone from their corner, the strip
  takes their slot, starting at the same 12pt inset it uses beside a left sidebar; a tab torn off from it
  is placed under the pointer by the strip's current inset, not always the lights' 82pt.
  **Editor** — word wrap, line numbers, gutter separator, vim mode. **Preview** — start supported files
  in preview mode. **Status bar** — show status bar, then which regions it shows. **About** — the app
  icon at 96pt, "Nota", `Version N.N.N` and one line saying what Nota is. The window is 760×520,
  resizable down to a floor; a page taller than the pane scrolls inside it, and the page you left it on
  is the page it opens on next time, for the life of the window.
- **Auto-hide tab bar** (Settings › Tab bar, default off): the strip and the traffic lights
  leave the layout exactly as "Hide tab bar" takes them — the split runs to the top of the window and the
  document with it, a 12pt drag band lying over its top padding — but the top 28pt of the window is a hot zone. The pointer reaching
  it slides the strip in over the split (0.15s, alpha and a slide down from its own height), opaque in the
  editor's own `textBackgroundColor` and with no hairline under it, so it looks exactly like the strip in its
  normal place; nothing is pushed down for it. The traffic lights come
  back with it, plain show, and the strip's leading inset switches from 12pt back to 82pt to clear them —
  unless "Hide traffic lights" is also on, in which case the lights stay off and the strip keeps the 12pt
  inset through the reveal. The pointer leaving the strip or the band starts a 0.3s grace period, after
  which the strip (and the lights, if it brought them back) slides away again; coming back cancels it, and
  so does a reorder drag, a tear-off, an open tab context menu, or a pointer still over the strip — each
  buys another grace period rather than interrupting the gesture. The hot zone takes no clicks: hit testing
  goes straight through it to the document. Zen mode and "Hide tab bar" both win: under either the strip
  and the lights are gone for good, the hot zone watches for nothing, and leaving zen does not pop a strip
  that is waiting on the pointer.
- **The version** is one string, `AppVersion.current`, and the About page is where it is read. Every
  commit bumps its patch number by one and writes the same number into `Info.plist`, so the About page,
  the Finder and the bundle never disagree — `.githooks/pre-commit` does it, installed with
  `git config core.hooksPath .githooks`, and a commit that sets the version by hand is left alone.
- **Shortcuts page**: the Summon recorder first (it is the one key that works while Nota is not in front),
  in a group of its own, then one group per menu the commands live in — File, Window, Find, Edit, View,
  Nota — each under a small caption, one row per command. The page scrolls; the rest of the window does not.
  Adjustable: New Tab ⌘T, New Window ⇧⌘N, Open… ⌘O, Close Tab ⌘W, Save ⌘S, Save As… ⇧⌘S, Bookmark This
  Tab ⌘D, Show Bookmarks… ⇧⌘D, Tabs Dialog ⌘P, Next Tab ⌃Tab, Previous Tab ⌃⇧Tab, Find… ⌘F, Find Next ⌘G,
  Find Previous ⇧⌘G, Search All Notes… ⇧⌘F, Go to Line… ⌘L, Toggle Comment ⌘/, Indent ⌘], Outdent ⌘[,
  Increase Font Size ⌘+, Decrease Font Size ⌘-, Actual Size ⌘0, Image Gallery ⌘B ("Table of
  Contents" while a book or PDF tab is in front), Mode Toggle ⇧⌘P,
  Reading Mode ⌥⇧⌘P, Zen Mode ⌥⌘Z, Settings… ⌘,. The system-standard items are not adjustable and are
  reserved against: ⌘Q ⌘H ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A ⌘M, and neither is ⌘N, Nota's older new-tab key.
  A row records the next combination you press: ⌘ or ⌃ has to be in it (⌘ with a letter is fine), Esc
  cancels, Delete puts the command's own key back. Edits are a draft like everything else here.
  Two rows on one combination, or a row on a reserved one, shows a red line naming both and holds Save
  back until it is resolved. **Reset to Defaults**, at the foot of the page, clears every override in
  the draft.
  Only the moved keys are stored, as JSON under one defaults key, so a default Nota changes later moves
  with it. The menu bar reads the table when it is built and is rebuilt whole the moment the table
  changes — the menu items, the bookmarks toggle and the find bar's tooltips all come from that one
  place, so a moved key works everywhere at once.
- Status bar: `[MODE]` bottom-left when vim mode is on · `N words · N characters` (· `3 / 7 done` on a `.md` with
  task items) · `N pt` beside gear.
- **Lists continue themselves (done 2026-09-05)** — Return at the end of a list item opens the next one, in any text
  tab and not only a `.md`: the same indent, the same delimiter and the counter stepped on once. `1.` → `2.`,
  `3)` → `4)`, `a.` → `b.`, `z.` → `aa.`, `A.` → `B.`, `viii.` → `ix.`, `IV.` → `V.`, and a bullet (`-`, `*`, `+`)
  handed on as it stands; case is kept exactly, so an upper-case list never turns lower-case, and a `- [ ]` or
  `- [x]` box comes back as a fresh unticked `- [ ]`. A lone `i`, `v` or `x` is both a letter and a numeral, and the
  two step on differently, so Nota looks up: the token is roman only when the nearest non-blank line above it at the
  same indent carries a roman marker of the same case — `h.` above `i.` gives `j.`, `viii.` above it gives `ii.`, and
  with nothing above it at all a bare `i.` is the numeral. Tokens that read only one way (`ii`, `iv`, `xii`; `b`,
  `k`, `aa`) never ask. Return on an item with nothing typed on it takes the marker off and leaves an empty line,
  which is how the list is ended; Return in the middle of an item still opens the next marker and takes the rest of
  the text with it. ⇧Return and ⌥Return are the plain newline, and in vim mode the whole hand stands aside outside
  insert mode, where `o` and `O` are vim's own. One `shouldChangeText` edit, so it is one undo step.
- **Line operations (done 2026-09-04)** — the hands Notepad++ leaves in the fingers, in the Edit menu and outside vim:
  ⌥↑ / ⌥↓ move the caret's line, or every line the selection touches, up or down one (nothing at either end, and the
  newline count never changes, so no stray line is left behind); ⇧⌥↓ duplicates them below with the caret or the
  selection on the copy; ⌘D duplicates the line with nothing in hand and, with something in hand, adds the next place
  the same characters appear as another selection range — case-sensitive, literal, round the end of the note and back,
  and typing then goes into every range at once (AppKit keeps only one *empty* range, so the editor holds the rest of
  the carets itself until the selection moves for any other reason); ⌘/ toggles a line comment, stripping the token
  when every line with anything on it already carries one and otherwise putting `token + space` in at the smallest
  indent the block shares — `#` for py sh bash zsh rb yaml yml toml ini cfg conf, `//` for js ts jsx tsx swift c h cpp
  hpp java kt go rs cs scala php, `--` for sql lua hs, `%` for tex latex, `;` for lisp clj el, and nothing (a disabled
  item) for md txt html css json and anything Nota does not know; Tab / ⇧Tab indent and outdent a multi-line selection
  by a tab, single-line Tab still being AppKit's own tab while single-line ⇧Tab outdents the caret's line, and
  ⌘] / ⌘[ do the same on one line as on many.
  Every one is a single `shouldChangeText` / `didChangeText` edit — one undo step, one dirty flag, one thing for vim
  and the save to see — and every one asks the note's `LineIndex` which lines it is about, so ⌥↓ in a 100 MB log costs
  the two lines it swaps. Hard lines throughout: word wrap moves nothing. The items are nil-targeted, so they arrive
  at whatever view holds the keyboard and grey out over a rendered page, a PDF, a picture, the find field and in every
  vim mode but insert, where the same keys are vim's own.

## Markdown preview — three modes (⇧⌘P cycles, View menu; per tab, remembered in the session)
- **Editor** (default), **Split**, **Reading**. ⇧⌘P cycles editor → split → reading → editor; ⌥⇧⌘P jumps to reading and
  back out to the editor. The View menu keeps "Mode Toggle" (checkmarked in split and reading) and adds
  "Reading Mode" (checkmarked in reading). Both checkmarks are the front tab's.
- Rendered files only: a note whose file is spelled `.md` (`.markdown`, `.mdown`, `.mkd`; 2026-09-06), saved — or `.tex` (`.latex`, `.ltx`), which gets the LaTeX
  render below instead, or `.html` (`.htm`, `.xhtml`), which gets the HTML preview, and everything else here unchanged. Every
  other tab — an untitled note, a `.txt`, a `.css`, anything not yet saved — has no render, no mode control, and both
  View items are disabled there, so ⇧⌘P and ⌥⇧⌘P do nothing.
- Split: a read-only rendered pane beside the editor (trailing side, resizable, 50% default, min 240pt); the image sidebar
  stays outermost. Reading: the editor collapses and the render takes its column. Either way the window keeps its frame —
  the panes share the room out between them. A mode you ask for slides across in 0.2s (Reduce Motion snaps; a tab switch
  snaps); taps during a slide land once it has. Split remembers its divider, as a fraction, across reading and editor.
- Shared chrome: the tab strip runs across the top of both columns and the status bar across the bottom of both, so the
  editor/preview divider starts under the tabs and stops above the footer. The pane has no header of its own — it is the
  render and nothing else, starting at the top of its column with the editor's own leading inset.
  Outside split the divider is not drawn at all (fixed 2026-09-06): the split's own `DocumentSplitView` draws nothing
  while a column is closed, since the controller lays the divider out against the window's edge regardless of the
  delegate — a 1pt dark line right beside the sidebar's, so the seam read as two lines in dark mode.
- Mode control: what the corner slot (below) holds over a tab with a render. Three segments —
  `pencil` / `rectangle.split.2x1` / `book`, tool tips naming the state and its keys —
  floating over the top-trailing corner of a column, 8pt under the strip and 12pt off the trailing edge, and nothing
  behind it — the control's own rounded bezel is the whole of it, with no plate or hairline around that. There is one per
  column: the editor's in editor and split modes, the preview's in split and reading. Split shows both, one in each
  column's corner; the editor mode shows only the editor's, reading only the preview's, since the editor column is
  collapsed there. Both drive the one mode the tab is in and stay in step. It sits over the text rather than in a row of
  its own: nothing is pushed down for it, and the text starts at the strip's bottom edge. Idle segments in
  `secondaryLabelColor`, the selected one in the standard filled look; its icons and opaque bezel fill are re-resolved
  in the control's effective appearance whenever the Mac switches between light and dark. Hover only: it fades in (opacity, ≤150ms, no
  movement) when the pointer is anywhere in the top 44pt of that column and fades out when it leaves; while it is away
  the band takes no clicks, so the text under it stays reachable. ⌘F's find bar wants the same corner: the control drops
  the pill's height plus 6pt and goes on working underneath it rather than leaving, and the hover band grows by the same
  amount so the whole top of the column still reveals it. The move is instant — the bar fades, the control is simply
  lower by the time it arrives — and only the column whose bar is up moves its own; the other column's is untouched.
- Reading has no automatic exits. The only ways out are the mode control, ⇧⌘P / ⌥⇧⌘P and the View menu — nothing you do
  to the page itself changes the mode. Clicking a block does nothing: no jump, no caret move, no block lit under it
  (links still open). Typing a printable character does nothing either — there is no editor on screen for it to land in.
  Arrow and page keys scroll the render, and ⌘F searches the render itself, opening Nota's own find bar in the corner
  over it; the render's own mode control drops below that bar while it is up and stays one hover away. The keyboard
  belongs to the render in reading mode, and to the editor in the other two.
- Zen takes the chrome and leaves the columns: the tab strip, status bar, gutter, image sidebar and both mode controls
  go, and the mode the tab is in does not change. Split keeps both panes side by side, at the divider they were left at;
  the editor mode is the text alone; reading is the render alone. In split each column's top edge is then the window's
  own: nothing is held back for the traffic lights (they are gone), a 12pt drag band lies over each column's top
  padding, and both use zen's wider 40pt margin, so the two bodies of text line up. Coming out of zen brings the chrome back and nothing else.
- Per tab, not per app: ⇧⌘P sets the mode of the tab in front only, and switching tabs lays out for the tab you land on —
  a new ⌘T tab and a freshly opened file start in the editor. The mode rides in `session.json`, so each tab comes back the
  way it was left (a session written when the pane was a yes/no comes back split where it was open).
- Settings "Open Markdown, LaTeX and HTML files in reading mode" (default off): opening a `.md`, `.tex` or `.html`
  file opens that tab in reading. Session restore ignores it — the tab's saved mode wins.
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
- **Task lists (done 2026-09-04).** `- [ ]` / `- [x]` (`[X]` too, and in an ordered list) draw as real checkboxes —
  an SF Symbol `square` / `checkmark.square.fill` at the block's own font size, standing in the slot the bullet would
  have taken, so a task item shows a box and no bullet and the `[ ]` never reaches the page. Foundation's parser has
  no task-list extension, so `TaskList` recognises one twice over: in the rendered text, as a list item whose
  paragraph opens with a box, and in the source, as a line that opens with a list marker and a box. Pressing a box —
  in split *and* in reading, since a checkbox is a control rather than a jump — finds the item's line through the
  source map, rewrites the one character between its brackets on the editor's `shouldChangeText` / `didChangeText`
  path so ⌘Z puts it back, and leaves the caret and the editor's scroll exactly where they were; it lights no band,
  selects nothing and starts no drag, and the render comes back changed the way it does after any keystroke. The
  footer adds `3 / 7 done` after the counts, in the footer's own `·`, for a `.md` with at least one task item and for
  nothing else — counted on the spot with the words for an ordinary note, and on the background word-count pass for a
  big one, never on the main thread.

### LaTeX
- `$…$` inline, `$$…$$`, and a ```` ```math ```` fence (`latex` and `tex` open one too) are laid out by Nota itself: a
  TeX subset into attributed text — Greek and symbols by Unicode, `^` `_` as real super/subscript, `\frac` stacked with
  a hairline, `\sqrt` with a vinculum, `\sum` `\int` `\prod` with limits, `\left(` `\right)` sized to what they
  hold, `\text{}`, `\mathbf` `\mathit`, spacing `\,` `\;` `\quad`. No WebView and no dependency (so no KaTeX /
  MathJax / iosMath), and the same monochrome as everything else in the pane.
- The maths is taken out of the source before Foundation's parser sees it, each formula standing as an image token in
  its place — otherwise `$a_1$` and `$b_2$` would pair their underscores into an emphasis and the formulas would be
  gone before the render began.
- A `$` opens only with a non-space against it, and closes only on the same line, with a non-space against it and no
  digit after it — so `costs $5 and $10 more` is a sentence about money. A `$$` opens and closes inside one paragraph;
  a blank line ends the paragraph, and an unclosed delimiter is left as the text it is, so a cursor left of a `$` being
  typed never swallows the rest of the note. `\$` is a dollar everywhere.
- Code wins: a `$` inside a code span, a fenced block or an indented one is a dollar, never a delimiter.
- Formulas are measured against the render's own font, so Settings' size carries them and maths in a heading takes the
  heading's face. Nothing about one depends on the pane's width — widening the column re-wraps the words around it and
  leaves the maths alone.
- TeX the subset has never heard of renders as itself inside the formula; TeX that cannot be read at all — an unbalanced
  brace, a `\left` with no `\right` — comes back as the raw source in the code-span style. Never a broken render,
  never a blank.
- A paragraph that is nothing but `$$…$$`, and a ```` ```math ```` fence, is a display block: centred in the pane, with
  the air a fenced block is given above and below, and a block of its own for block sync — clicking it selects its
  `$$` or its fence in the source, and a caret in that source lights it. A `$$…$$` inside a sentence stays in the
  sentence, set in display style where it stands.

## The corner slot (done 2026-09-05, Todo 4)
- One band per column, and the front tab says what stands in it. The band, the hover, the fade, the hit testing and
  the drop out of ⌘F's way are exactly as the mode control's above; only the thing in the corner changes.
- A tab whose note `supportsRenderedPreview` gets the mode control. A `.json` text tab gets the Beautify / Compact
  button. Every other tab — a `.txt`, an untitled note, a PDF, a picture, a book — gets nothing: the overlay goes away
  whole, so the band takes no clicks and the text under it stays as reachable as any other. Zen empties every slot.
- Keyed on the note, never on a list of extensions kept in the overlay, so a new kind of render is offered the mode
  control the moment `RenderedPreviewKind` learns to spell it.
- The mode control is per column (editor's in editor and split, preview's in split and reading); the JSON button is
  the editor column's alone, since a `.json` tab has no second column.

## JSON — Beautify / Compact (done 2026-09-05, Todo 5)
- A saved `.json` tab carries one small button in the corner slot, in the segmented control's own bezel and size:
  `text.alignleft` "Beautify JSON" when the file is compact, `arrow.down.right.and.arrow.up.left` "Compact JSON" when
  it is already laid out. One button, because the file is in one of the two shapes already and the only thing worth
  offering is the other one. Its symbol is drawn in `secondaryLabelColor`, `tertiaryLabelColor` while disabled, and
  re-resolved when the Mac switches between light and dark, like the segments beside it.
- Which way it points is read off the text: a newline anywhere outside a string literal means the file is laid out,
  and the file's own trailing newline does not count. Invalid JSON leaves the button in place but disabled, with
  "Not valid JSON: line N" naming the 1-based line the parse stopped at.
- The state is worked out when the tab arrives in front and re-parsed on the same half-second debounce the footer's
  counts use after typing, never once a keystroke.
- Clicking replaces the whole note through the editor's own undoable path — one `shouldChangeText` /
  `didChangeText` edit, the way a line operation replaces its lines — so the tab goes dirty, ⌘Z puts the file back
  exactly as it was, and the save, vim and the footer see one edit. The caret goes to the top (every line has moved)
  and the button flips at once.
- `JSONFormat` is Nota's own walker, not `JSONSerialization`: every token — string, number, `true`, `false`, `null`,
  and every key — is re-emitted as the byte range it occupied in the source, so key order, array order, number
  spelling (`1.50` stays `1.50`) and every escape inside a string survive both directions, and beautifying then
  compacting gives back exactly what was there. Pretty is two-space indent, `"key": value`, one element to a line,
  with an empty `{}` or `[]` left on the line it is on; compact is no whitespace at all outside a string. The file's
  trailing newline is kept if it had one. The grammar is RFC 8259 and nothing beside it — no comments, no trailing
  commas, no single quotes, no unquoted keys.

## PDF
- A PDF opens in a tab of its own and is read there, whatever it is named — its magic bytes decide, not its
  extension, so a PDF named `report` opens as one and a `.pdf` that is really a text file opens as text (see Model).
  Entry points are the same as any other file's: ⌘O, a drag onto the window or the Dock icon, Finder's "Open With"
  (declared `Viewer` / `Alternate`, so nothing is taken over), and `:e path`. Opening one that is already open comes
  back to its tab.
- The tab is locked in reading: the document takes the whole column, the editor stays collapsed, and there is no mode
  control in either corner. ⇧⌘P, ⌥⇧⌘P and both View items do nothing there and are disabled — a PDF has no Markdown
  render to have a mode about.
- A page fits the column's width but is never drawn past actual size (done 2026-09-04): `autoScales` is off and the
  scale is `min(scaleFactorForSizeToFit, 1)`, refitted when the column changes size, so a portrait page in a wide
  window is paper rather than 36pt type — a wider page still shrinks to fit, since that cap is one-sided.
- Drawn by PDFKit (`PDFView`, single page continuous, page breaks shown) on the same background the
  editor and the render use, so the column does not change colour between a Markdown tab and a PDF one. No WebView
  and no dependency: PDFKit ships with macOS. The pages are pinned edge to edge rather than inset — `PDFView` scales
  and centres each page in the room it has, so an inset would shrink the paper rather than give the text a margin.
- Read, never written. The tab is never dirty, ⌘S and Save As are disabled, `:w` does nothing, ⌘W closes with no
  prompt, and nothing about it is written to the cache — the file on disk is the whole of it. The document is parsed
  once per tab and held, so switching back to it does not read the file again.
- The page you were on comes back: it rides in the session in the same key the caret does, and the tab reopens there.
  A file that has gone — deleted while the tab was open, or missing when the session comes back — keeps its tab, stays
  clean, and shows a quiet centred `Couldn't open "name.pdf".` in the editor's own font.
- The document's own outline stands in the sidebar (decided 2026-09-05), the column a note's pictures are shown in:
  `PDFDocument.outlineRoot` walked depth first, the depth kept as an indent, and clicking a line goes to the
  destination it names rather than the top of its page. The line rung is the last entry landing on or before the page
  in front — an outline says where a section begins, so you are inside the one you most recently passed — and it
  follows the pages. A PDF with no outline lists nothing, so the column stays away exactly as it does for a note with
  no pictures; ⌘B pins it open on the quiet `No contents` hint rather than offering a gallery for a document that has
  no pictures to gather. See Images for the column itself.
- ⌘F searches the document (done 2026-09-04): the same pill in the same corner, "Find in document", over PDFKit's own
  selections rather than a text storage. Every match wears a quiet band drawn over the page, the one you are on wears
  `findHighlightColor` and is the page's selection, and the count reads the same `3 of 12` / `12 matches` /
  `No matches` (`2000+` past the same cap the editor stops at). Typing searches from the page you are reading; ⌘G,
  ⇧⌘G, Return and ⇧Return walk and wrap; ⌘E seeds from what is selected on the page; Esc puts the bands down, leaves
  the match selected and hands the keyboard back to the document. A document cannot be typed into, so the glass is
  only a glass and Find and Replace… is greyed out — the one Find item a PDF turns down. PDFKit's own find bar never
  appears: `NotaPDFView` takes `performTextFinderAction:` off it.
- ⌘+ / ⌘- / ⌘0 zoom the page here (done 2026-09-04). The three keys are one pair of hands doing two jobs, and what
  decides is which of the two the reader can see: with an editor on screen — any text tab in edit or split — they are
  the font size they have always been, and the Markdown and LaTeX renders follow it. With the content alone on screen
  and its size nothing to do with a font — a PDF, a picture, an HTML page in reading mode — they zoom that content:
  ×1.25 a press, "Actual Size" back to however it draws itself (a page or a picture fitted to the column, a page at
  100%), clamped to 0.25…8 for a document and a picture and 0.5…5 for a page. A render in reading mode stays with the
  font, since the font already *is* the zoom there. The first two View items say which job they are doing — "Zoom In"
  / "Zoom Out" against "Increase Font Size" / "Decrease Font Size" — and "Actual Size" is the name of both. The zoom
  is the tab's for as long as the tab is open and is not in `session.json`: how close you were reading is not where
  you were reading. A pinch on a document is the same number, read back off the scale PDFKit lands on.
- Footer: the middle counts pages (`12 pages`, `1 page`), the right says which one (`Page 3 of 12`), and it is empty
  when there is no document to be in. Everything else in the chrome — the strip, the vim badge, zen — is unchanged.

## RTF (done 2026-09-05, Todo 26)
- A rich-text document opens in a tab of its own and is read there, the fourth viewer after a PDF, a picture and a
  book. The bytes decide, not the name: `{\rtf` at the front of a file is rich text whatever the file is called, so
  a `.txt` written by TextEdit opens as the document it is and a `.rtf` holding nothing but prose opens as an
  ordinary editable text tab. An RTFD is the one kind with no first bytes to read — it is a folder, not a file — so
  it is known by being one: a package spelled `.rtfd` with a `TXT.rtf` inside it.
- Entry points are the same as any other file's: ⌘O, a drag onto the strip, the band or the render column, the Dock
  icon, Finder's "Open With", and `:e path`. Opening one that is already open comes back to its tab.
- The tab is locked in reading, exactly as a PDF's is: the document takes the whole column, the editor stays
  collapsed, there is no mode control in either corner, and ⇧⌘P, ⌥⇧⌘P and both View items do nothing there.
- Read once with `NSAttributedString(url:options:documentAttributes:)`, which takes both flavours by the same URL and
  brings an RTFD's pictures along as attachments, and drawn in a read-only `NSTextView` inside a scroll view on the
  editor's own background, at the editor's own left and right margin — the one viewer whose content is text, so it
  lines up with the text beside it rather than running edge to edge the way a page or a picture does. The document's
  own fonts, sizes, colours and paragraph layout are what you read: this is a view of a document, not a re-rendering
  of one. It is selectable, so ⌘C takes the words (and their formatting) out of it, and never editable.
- Two things are settled on the way in and nothing else is. Text the author left plain black on no background is
  drawn in `labelColor` — an RTF is written for paper, `\cf0` is "the body text" rather than a colour anybody chose,
  and taking it at its word would print black type onto Nota's dark ground. A colour that was chosen stands: a red
  word is red in both appearances, and so is a black word with a highlight behind it, since a colour laid against a
  background of its own is a pair. And every attachment is given explicit bounds, which is what the zoom below
  scales.
- Read, never written, the same as a PDF: never dirty, ⌘S and Save As disabled, `:w` does nothing, ⌘W closes with no
  prompt, and nothing about it is written to the cache — the file on disk is the whole of it. The document is parsed
  once per tab and held, so switching back to it does not read the file again. A file rewritten under the tab is
  simply read afresh, and one that has gone — or that holds nothing AppKit can parse — keeps its tab, stays clean,
  and shows a quiet centred `Couldn't open "name.rtf".` in the editor's own font.
- ⌘F is the same pill in the same corner, "Find in document", over this pane's own text storage through
  `TextFindSession` — the session the editor and the rendered page already use, since what is being searched here is
  an `NSTextView` like theirs. Find and Replace… is greyed out: a document Nota does not edit cannot be typed into.
- ⌘+ / ⌘- / ⌘0 zoom the document, the way they zoom a page rather than the way they change a font: every font, every
  measurement in a paragraph style and every attachment is multiplied, so the type grows and the lines re-wrap to the
  column instead of the document being magnified as a picture of itself. Measured from the document as it was read
  rather than from the last zoom, so ⌘+ and ⌘- back to where you started put the type back exactly; clamped to
  0.25…8, and, like every other tab's zoom, the tab's own for as long as the tab is open and not in `session.json`.
- The session keeps how far down the document the reader had got, as a share of its scrollable height — the same
  field a book's chapter uses for the same reason, since pixels would mean somewhere else in a column of another
  width. There is only one place to be in a document, so the number a PDF's page rides in is always 0 here.
- Files let go on the document open as tabs, the way they do anywhere else over the render column. Nothing lands
  *in* it: there is no note here to put a picture in.
- The tab, picker and bookmark icon is `doc.richtext`.
- Footer: the middle counts the document's words and characters exactly as a text note's does (`68 words · 349
  characters`), because rich text is words on a page; the right is empty, since there is no caret behind it and no
  page to be on, and so are the encoding and line-ending badges.
- Print goes with Todo 1.

## Image tabs (decided 2026-09-04)
- A picture opens in a tab of its own and is looked at there, the way a PDF is read in one: PNG, JPEG, GIF, TIFF,
  WebP and HEIC, each known by the bytes it starts with, so a screenshot named `report` opens as a picture and a
  `.png` that is really a log opens as text (see Model). A bitmap is the one exception, known by its name instead:
  `BM` is two bytes, and two bytes is not enough to tell a picture from the first line of a sentence.
- Where it lands is the drop target's business, not the file's. Through ⌘O, the Finder, the Dock, the command line,
  `:e path` and the session it is a tab; dropped into the text of a note it is still what it has always been, a
  picture imported into that note as a chip (see Images). The same `.png` does both, depending only on where it went.
- The window has three tab targets and one chip target. The tab strip is one, the band across the top of the
  window where a hidden, auto-hidden or zen window keeps its drag region is another, and the render column is the
  third — files let go on any of them open as tabs, one per file, pictures and `.svg`s included, each classified
  exactly as ⌘O classifies it. The text of a note is the chip target, and only there does a picture become part of
  the note. A drag carrying no file is refused by both bands; a file drag hovering an auto-hidden strip holds it
  open until the drop is done.
- The render column is a tab target in every kind: the Markdown or LaTeX render, an HTML page, a drawing, a PDF, a
  picture and a chapter of a book all take a drop anywhere over them, and there is no text there to put a chip in.
  WebKit and PDFKit both answer for a dropped file themselves — by loading it in place, which would throw away what
  was being read — so neither ever sees the drag: the types they registered for are taken off those views and only
  `public.file-url` is put back.
- An `.svg` let go on the text opens as a tab, never as a chip. A drawing is text with the picture beside it, the
  same arrangement a `.html` has, and the system filing it under images is the one thing that used to say otherwise
  — it was claimed as a picture and then lost, since the asset store cannot read a drawing's bytes as one.
  `TextFile.isDrawing` is the single place that disagrees with the system, and `AssetStore.isImageFile`,
  `Note.isImageFile` and the deliberate exclusions all ask it.
- The tab is locked in reading, exactly as a PDF's is: the picture takes the whole column, the editor stays collapsed,
  there is no mode control in either corner, and ⇧⌘P, ⌥⇧⌘P and both View items are disabled.
- Drawn by an `NSImageView` inside a scroll view, on the editor's own background, edge to edge. Its own size when the
  column is big enough to hold it, shrunk to fit when it is not, centred either way, and never blown up past its own
  pixels — a 16pt icon is a 16pt icon. A GIF animates.
- Read, never written, the same as a PDF: never dirty, ⌘S and Save As disabled, nothing written to the cache, ⌘W with
  no prompt. The picture is read once per tab and held, so switching back to it does not read the file again and does
  not restart a GIF. A file that has gone keeps its tab and shows `Couldn't open "name.png".` in the editor's own font.
- Footer: the middle is the picture's size in pixels (`1200 × 800`), taken from the file's own representation rather
  than its points, and the right is empty — there is nowhere in a picture to be.
- An `.svg` is not one of these. See the HTML preview above.

## EPUB (done 2026-09-04, Todo 3; contents moved to the sidebar 2026-09-05)
- A book opens in a tab of its own and is read there, the third viewer after a PDF and a picture. The bytes decide,
  not the name: an EPUB is a zip whose first entry is a stored `mimetype` reading `application/epub+zip`, which the
  OCF specification insists on and which is what tells a book from every other archive. A plain `.zip` is still
  refused, and a `.epub` that is really text opens as text.
- The archive is unpacked to a temporary folder with `/usr/bin/ditto` — no zip library, since the system already has
  one — and read from there: `META-INF/container.xml` names the package document, the package's manifest lists the
  files and its **spine** is the reading order. The folder belongs to the book and goes when the tab does.
- A chapter is drawn in the same `WKWebView` a `.html` tab is read through, loaded against its own path under
  `nota-file://`, so the book's own stylesheets, fonts and pictures resolve out of the unpacked folder and the page
  is the author's own. EPUB 2 and 3; no DRM.
- The contents come from EPUB 3's `nav` document, and from the NCX off the spine's `toc` attribute when there is no
  nav — flattened, with the nesting kept as a level. They stand in the sidebar (decided 2026-09-05), the column a
  note's pictures are shown in and a PDF's outline stands in: the same split item, the same 150pt, the same side,
  brought up on its own when a book tab comes to the front and put away by the same ⌘B, which reads "Table of
  Contents" there. The line naming the chapter on screen is rung and follows along as chapters turn; clicking one
  goes to that chapter and to the `#anchor` it named. Zen takes the column the way it takes the gallery. A book whose
  contents are empty lists nothing and the column stays away. Nothing new is persisted. See Images for the column.
- `@` in the ⌘P switcher lists nothing for a book tab: the contents are on screen beside the chapter now, and a list
  that closes the moment you choose from it is the wrong shape for a table of contents. A text note's `@` headings
  are unchanged.
- Chapters turn with `→` / `←` or a page key at the end of a chapter. The page reports those keys rather than
  swallowing them, so nothing changes for a `.html` tab. Both ends of the book are ends: there is nothing before the
  first chapter or after the last. There is no floating chapter bar (removed 2026-09-05): a control the reader
  cannot put away has no business standing over the page, and the sidebar says which chapter this is without one.
- ⌘F is the page's own find session, the same pill in the same corner. ⌘+ / ⌘- zoom the chapter the way they zoom any
  other page.
- Read in Nota's light or dark, not on the paper it was typeset for (2026-09-06). In dark mode a reader stylesheet goes
  into every chapter at document start (`HTMLPreviewView.readerThemeCSS`, only when `appliesReaderTheme`, which the
  book pane sets): every run of text in the label colour, links in the system blue, rules and table borders in the
  separator grey, the body's own paper made transparent so the column's ground shows through — the same call the RTF
  viewer makes for black body text, for the same reason: `color: #000` in a book's sheet is "the text", not a colour
  anybody chose. Light mode is the author's page untouched, and a `.html` tab is the author's page in both.
- Read, never written, the same as a PDF: locked in reading, never dirty, ⌘S and Save As disabled, nothing in the
  cache, ⌘W with no prompt, no mode control and both View items greyed out. A file that has gone — or one that will
  not come apart, a torn archive or a package with no spine — keeps its tab and shows `Couldn't open "name.epub".`
  in the editor's own font, never a crash and never a text tab of gibberish.
- The session keeps two numbers per tab: the chapter, in the same key a PDF's page uses, and how far down it the
  reader had got, as a share of the chapter's own scrollable height — the chapter alone would come back to the top of
  one half read, and pixels would mean somewhere else in a column of another width.
- Footer: the middle counts chapters (`9 chapters`, `1 chapter`), the right says which one (`Chapter 3 of 9`), and it
  is empty when there is no book to be in.
- Print goes with Todo 1.

## LaTeX preview (decided 2026-09-03)
- A `.tex` (`.latex`, `.ltx`) file is a tab with a render beside it, the way a `.md` is: the same three modes, the same
  floating mode control in each column's corner, ⇧⌘P / ⌥⇧⌘P and the View items, per tab and remembered in the session.
  The setting is "Open Markdown, LaTeX and HTML files in reading mode".
- Native, no dependency, no WebView: Nota's own parser of a LaTeX subset into attributed text, the equations drawn by the
  maths engine the Markdown render already uses. Not TeX's pixels — Nota's reading layout of the document.
- Article level: `\maketitle` from `\title` `\author` `\date`, `abstract`, numbered `\section` `\subsection`
  `\subsubsection` (1, 1.1, 1.1.1) and `\paragraph`, the `*` forms unnumbered, paragraphs, `\textbf` `\textit` `\emph`
  `\texttt` `\underline` `\textsc` `\verb`, `itemize` `enumerate` `description` (nested, `\item[label]`), `$…$`
  `\(…\)` `\[…\]` `equation` `align` `gather` `multline` `eqnarray` `displaymath` (numbered on the right, `align`'s
  rows one formula each on `\\` with the `&`s dropped; `*` forms and `\nonumber` unnumbered) through the maths engine,
  `verbatim` `lstlisting` `minted` as code blocks, `quote` `quotation`, `center`, `\footnote` as a bracketed note in the
  secondary colour, `\cite` `\ref` `\eqref` `\pageref` `\label` as grey placeholders showing their key, `\url`
  `\href` underlined and clickable, `\includegraphics` as the picture when the path resolves beside the file — the
  extension tried when the path has none — and the path as alt text otherwise, `tabular` best effort like the Markdown
  table, `figure`/`table` with a `Figure N:` / `Table N:` caption, `%` comments stripped (`\%` is a percent sign),
  `\\` and `\newline`, `~` as a non-breaking space, `--` `---` as dashes, `` ` ` '' `` as quotes, `\ldots` as an
  ellipsis, `\LaTeX` and `\TeX` as themselves.
- The preamble renders nothing: `\documentclass`, `\usepackage`, `\newcommand` and the rest are skipped, and only the
  title fields are taken from it. A file with no `\begin{document}` is rendered whole as body. Uses of a `\newcommand`
  show raw, since expansion is beyond article level.
- Unknown: a command the subset does not know renders as its raw source, `\foo{bar}`, inline in the code-span style; an
  unknown environment renders whole as a code block. Never a blank, never a broken page, the same rule the maths engine
  keeps.
- Block sync both ways, as for Markdown, and exact rather than heuristic: the parser knows every block's source range,
  so no source map is searched for.
- The render and the pane are the Markdown ones: `RenderStyle` holds the look both wear — heading scales, list indents,
  quote bar, code box, table, rule — and `RenderedPreviewView` holds everything a rendered pane does, so each renderer is
  a subclass that says which grammar it reads and nothing else.
- Export as PDF… on a `.tex` tab is a Todo (see Todo 1).
- Out for now: `\input` `\include`, theorem environments, `\newcommand` expansion, bibliographies from `.bib`.

## HTML preview (decided 2026-09-03)
- A `.html` (`.htm`) file is a tab with a preview beside it, the way a `.md` is: the same three modes, the same
  floating mode control in each column's corner, ⇧⌘P / ⌥⇧⌘P and the View items, per tab and remembered in the session.
  The View item is "Mode Toggle" there as everywhere. The setting is "Open Markdown, LaTeX and HTML files in reading mode".
- Drawn by WebKit (`WKWebView`): HTML is the one place a WebView is the native answer, the way PDFKit is for a PDF.
  The page is the page — CSS, the document's own type, scripts, images and stylesheets beside the file — not Nota's
  reading layout of it. No dependency; WebKit ships with macOS. A `.css` or a `.js` is still source and has no preview.
- The pane is edge to edge, like a PDF: HTML lays out to the viewport it is given, so an inset would be a second
  margin the page has to pay for. The column's background is the editor's until the page paints over it.
- Live: the editor's text is what is shown, ~150 ms after typing stops, so unsaved edits are the page; the pane keeps
  its scroll. Relative URLs resolve beside the file. A link that leaves the page — http(s), another file — opens in
  the browser; an in-page `#` stays. The keyboard belongs to the page in reading mode, and to the editor in the other
  two: a click in split must not steal the caret.
- No block sync: a DOM is not a list of source ranges, and a click in the page is a click in the page (links still
  open).
- ⌘F searches the page (done 2026-09-04), in reading mode, where the page has the keyboard: the same pill in the same
  corner, "Find in page", the same counts and the same keys. In split the editor has the keyboard and ⌘F is the
  editor's, unchanged. The search itself is a script injected into every page alongside the scroll reporter, in the
  same separate world: every text node is gathered into one string — so a match across an inline element, `ca<b>fe</b>`,
  is still a match — folded a character at a time (decomposed, combining marks stripped, lowercased, with a map back
  to where each folded character came from, since `İ` lowercases to two), matched, and turned into DOM `Range`s. The
  bands are CSS custom highlights (`CSS.highlights`, `::highlight(nota-find)` and `nota-find-current`), so nothing is
  added to the author's DOM and no attribute is written on it — the same promise the editor's temporary attributes
  make. Stepping is by index in the page, which is what makes `3 of 12` exact and wrapping trivial, and Esc puts the
  bands down and leaves the match as a real selection. Never WebKit's own find: `WKWebView.find` selects one match at
  a time, cannot band or count the rest, and takes the selection away from the reader. Every answer crosses a process
  boundary, so the session is asynchronous and carries a token — a reply about the query two keystrokes ago is not
  news about the one being typed now. A page loaded again puts the query to the new document.
- Untitled notes and every other extension have no HTML preview. Save As to `.html` is what turns a note into one.
- An `.svg` is the same arrangement (decided 2026-09-04): text you edit, a drawing beside it, the same pane and the
  same three modes, and the View item is the same "Mode Toggle". It is handed to WebKit as `image/svg+xml`, so the root
  `<svg>` is the document rather than a tag inside a page the file never had. It is never one of the picture tabs
  below — its bytes are text, and the system filing it under images does not make it one.
- Shipped: `HTMLPreviewView` is the column's third content view. The editor's text is loaded under `nota-file://`, whose
  path is the file's own, and `PageFiles` hands WebKit the bytes for everything the page draws. A `file://` base URL does
  not work: WebKit's page process is given permission to read a folder only by `loadFileURL`, so text loaded against a
  file URL renders with every stylesheet and picture beside it silently missing. A link the reader clicks becomes a
  `file://` URL again on its way to the browser. The page reports its own scroll on each frame, so a reload puts the
  reader back where they were.

## SQL preview (done 2026-09-05, Todo 6; second pass 6-A; third pass 6-B; the query's jump 6-C)
- A `.sql` file is a tab with a preview beside it, the way a `.md` is: the same three modes, the same floating mode
  control in each column's corner, ⇧⌘P / ⌥⇧⌘P and the View items, per tab and remembered in the session. The View item
  is "Mode Toggle" there as everywhere. What stands in the column is not a rendering of the text — it is the database
  the text builds.
- Run, not drawn. A dump is a program: the only way to know what `Shop.sql` holds is to run it. `SQLDump` opens a
  database in memory (`sqlite3_open_v2(":memory:")`, the system SQLite, no dependency) and runs the editor's own text
  into it — unsaved edits included — statement by statement through the `sqlite3_prepare_v2` tail loop, which is what
  makes a semicolon inside a string literal a semicolon in a string. The file on disk is never opened by SQLite and
  nothing is ever written anywhere: the database lives as long as the tab and is thrown away with it.
- A statement that will not go in stops the run and says which one it was, in an alert on the window:
  `Couldn’t run “Shop.sql”.` over the message SQLite gave and the statement it gave it about. Once, and not on every
  keystroke — a dump being typed is broken most of the way through being written, so the same message is raised on
  the run that first finds it and then held until the file runs clean again (a different message, and a different
  tab, are different news). Everything the statements before it made is still there and still readable — half a
  database is half a database, not none.
- Two buttons say what the keys do (decided 2026-09-05): a small `Run` push button (`play.fill`, tool tip "Run the
  query  ⌘↩") stands over the query box at its leading edge, inside the band the corner slot keeps clear, low in it, 6pt over
  the box — the box is no lower for it — and does what ⌘↩ does; and the bar's refresh control wears its word — `arrow.clockwise` and `Refresh`, borderless like the page
  arrows — rather than an arrow alone.
- The grid is always there (decided 2026-09-05). A table with no rows, a query that found none and a file with no
  tables in it yet are each still a table: the header stands — the picked table's columns from the schema, the
  query's own, or three blank ones when there is no table to take them from — over the same striped rows, and the
  bar's range says "No rows". No caption in the middle of an empty pane; the one left is the big file's "Run to read
  this dump.", which is an instruction rather than a state. A blank column is not sortable.
- The grid: a plain `NSTableView`, 22pt rows (taller with the editor's font), one vertical hairline between columns,
  alternating rows, a `#` gutter numbering rows from the top of the *table* rather than of the page, and the last
  column taking up whatever slack the others leave. Cells are monospaced at the editor's size; numbers are set right
  so they line up on their last digit; `NULL` is dimmed and slanted, so a column of them reads as nothing rather than
  as the word; a blob is `⟨12 KB⟩` and never its bytes. What a column is too narrow to show is one hover away, and a
  header's tool tip is the declared type from `PRAGMA table_info`. A header click sorts by that column and a second
  click turns it round — the database's own `ORDER BY`, so it orders the whole table and pages it again from the top.
  The header is Nota's own: flat rather than the system's light gradient bezel, the sorted column's name in
  semibold with a small accent chevron beside it. The sort is taken on the click's release
  (`tableView(_:didClick:)`) and not on its press, and a page of the same columns keeps the very column objects it
  had — the header tracks the mouse until the button comes up, and rebuilding its columns underneath it was what
  made a header click do nothing.
- Picking values out of the grid is a spreadsheet's, not a list's. A click takes one cell; a drag takes the
  rectangle between where it started and where it is; the arrows move that cursor and ⇧ with them grows the
  rectangle from its anchor. Whole rows are still there where a row is what is wanted: a click in the `#` gutter
  takes one, and ⇧ anywhere takes the run between. The two never stand at once — picking either puts the other down,
  because a wash under a wash says nothing about what ⌘C would take. What is picked out wears the accent at low
  strength with a hairline of it round the rectangle's outer edge only, and the cursor cell carries a border of its
  own; the gutter takes a fainter wash on every row of the selection. Esc puts it down, and so does a new page: a
  (row, column) held across a page, a sort or a new set of columns would quietly point at somebody else's value.
  ⌘C copies what is drawn — tab separated, a line per row, only the columns inside the rectangle for a cell
  selection and every column for a row one, `NULL` copied as the word because that is what the cell says. Nothing in
  the grid is editable.
- Space stands the cursor up into its row and sits it back down (decided 2026-09-05). With a cell picked out —
  clicked or arrowed to — Space takes the whole row it is in, exactly the selection a click in the `#` gutter makes,
  and Space again puts the cursor back on the cell it stood up from. No ⇧ needed, and neither press scrolls the grid
  (a table's own Space is a page down, which over a sheet of cells is nothing anyone asked for) or reaches the editor
  as a typed space. A row taken from the gutter was not stood up from anywhere, so Space over one does nothing.
- A cell clicked walks the editor to where that row is written (decided 2026-09-05), the way a click on a rendered
  Markdown block walks it to the paragraph behind it. In split only — reading has no editor on screen — and without
  taking the keyboard: the grid keeps it, so the arrows go on walking the cells. A row of a multi-row
  `INSERT … VALUES (…),(…)` lands on its own tuple and not on the statement's head. It is `SQLSourceMap` that knows:
  while `SQLDump` runs the file it writes down each statement's own characters, and for an insert the rowids it made
  (`sqlite3_changes` and `sqlite3_last_insert_rowid` read together), and every page of a table carries its rowids
  beside its values (`SELECT rowid, *`, the rowid taken back out before the grid ever sees it). A row that an
  `UPDATE` further down the file changed still points at the `INSERT` that wrote it: that is where the row *is*
  written. Anything with no rowid to be looked up by does nothing at all rather than landing somewhere arbitrary — a
  `WITHOUT ROWID` table, a query of a shape no rowid fits, a row whose insert is not in this file — and so does a
  statement whose tuples do not add up to the rows it claims, which is pointed at whole instead. `PreviewContent`
  grew one callback for it, `onSourceReveal`: a block click is a jump and takes the caret with it, this is a look
  and does not.
- A query's rows jump too, when they are one table's rows (decided 2026-09-05, Todo 6-C). The last statement of the
  box is read once by `SQLQueryRewrite` — loosely, since SQLite has already said the text is good — and if it is
  plainly `SELECT <list> FROM <one table> [WHERE / ORDER BY / LIMIT …]` the page is asked of that query with the
  table's rowid spliced in after the `SELECT` keyword: `SELECT "c".rowid AS "__nota_rowid", <the reader's own list>
  FROM customers c`. Nothing else about the text is touched, the rowid column is taken back out before the grid sees
  it, and the page remembers which table its rowids are of, so a click looks the row up in that table's `INSERT`.
  `SELECT *` works, an alias works (the rowid is asked of the alias, since `FROM customers c` puts `customers` out
  of reach), and the count, a header's sort and the second page are all the rewritten query's. Refused, and read
  exactly as written instead: a join, a comma-separated `FROM`, `GROUP BY`, `DISTINCT`, a `UNION`, an aggregate
  call, a leading `WITH`, a sub-select anywhere, `ORDER BY 2` (a positional order counts the columns the rewrite
  would have changed), a schema-qualified name, and a table with no rowid. The rewrite is an offer and never a
  requirement: it is prepared under the same read-only authorizer as anything else in the box, and one SQLite will
  not take — an alias in quotes is the reachable case, since it is not read as an alias here — is dropped without a
  word and the reader's own query runs, with no rowids, exactly as it did before.
- A hundred rows to a page (`LIMIT 100 OFFSET`), with `COUNT(*)` beside it. The bar over the grid is the table
  `NSPopUpButton` at the leading edge, an `arrow.clockwise` button beside it ("Run again"), and `1–100 of 4,213`
  between ‹ › at the trailing one; the footer says
  `7 tables` in place of the counts and `Rows 1–100 of 4,213` in place of the caret, both through `TextStats` — but
  only while the column is on screen, since in the editor mode a `.sql` tab is source like any other and the words
  and the caret stand.
- The pane begins a `ModeControlOverlay.hoverBandHeight` band below the top of the column, left clear for the
  floating Editor · Split · Reading control that lives in that corner. Under it is the query box: five rows of the
  editor's monospaced font in a rounded bezel that takes the accent while the typing is going there, `SELECT …` for
  a placeholder, and no rich text or smart substitutions at all — what is typed is what is run, and a query box that
  turned `'shipped'` into curly quotes would be a box that lies. Return makes a line, because a query is written
  over lines; ⌘↩ runs it, the key every database tool answers to. Esc puts it down and the picked table comes back,
  and picking a table puts it down too: picking a table is asking for that table. What is typed there can never change the database: every
  statement in the box is prepared under an authorizer (`sqlite3_set_authorizer`) that allows `SQLITE_SELECT`,
  `SQLITE_READ`, `SQLITE_FUNCTION` and `SQLITE_RECURSIVE` and denies everything else, and the *whole* text is
  prepared before anything runs — so `DELETE FROM t` comes back "not authorized" and so does `SELECT 1; DELETE FROM t`,
  rather than the second half running behind the first. The last statement of the text is what is drawn, wrapped as a
  sub-select so the paging and the count are Nota's arithmetic rather than something the query has to have been
  written for. A query that will not run is an alert — `Couldn’t run the query.` over the message, `near "*": syntax
  error` and the like, and under it the rule the box works by, `Only SELECT queries run here. The tables are
  read-only.` (a refused write says only the rule: SQLite's "not authorized" is no explanation) — one per press, since a question is asked one ⌘↩ at a time; the page that was being read is
  left alone under it. Running a query changes nothing about the grid's own hands: a cell is still picked out by one
  click — the same click that takes the keyboard back from the box — and still walks the editor to its row whenever
  the query carried rowids. Both alerts go through one test hook, so a test never puts a modal on screen.
- Off the main thread, always: the run and every page are asked on one serial queue and answered back on the main
  one, each carrying a token, so an answer about the file two keystrokes ago is dropped rather than drawn. An
  ordinary dump is run again ~150 ms after typing stops, on the same debounce the Markdown render uses. A big file
  (the `BigFile` threshold) is never run on its own — a hundred megabytes of inserts is not something to start
  between two keystrokes — and typing after a run does not run it again; the `arrow.clockwise` button is what asks
  for one. One button rather than two (decided 2026-09-05): over a small dump it says "as the file is now" and over
  a big one it says "read it", which is the same press. It builds a fresh database and asks for the same page again,
  keeping the picked table, the query, the sort and the page offset where they can be kept — and, since the reader
  asked for it, a file that still will not run says so again rather than holding the message it was holding.
- The table being read and the query beside it ride in `session.json` (`sqlTable`, `sqlQuery`), so a dump comes back
  open where it was left; a session written before this has neither key and opens on the first table with an empty
  box. `PreviewContent` grew one callback for it — `onStateChange`, "the content wrote something on the note" — and
  the window answers it with a session save and nothing else.
- ⌘F is the editor's, unchanged, in every mode: the find bar's machinery bands ranges in text, and a page of cells is
  not text — the query box is how you find a row in a database. Nothing about the grid takes the find bar's corner.
- Untitled notes and every other extension have no SQL preview. Save As to `.sql` is what turns a note into one.
  `Examples/Shop.sql` is the demo: four tables that know about each other, and more rows than one page.

## CSV preview (done 2026-09-06, Todo 27)
- A `.csv` or `.tsv` file is a tab with a preview beside it, exactly the way a `.sql` is: the same three modes, the
  same floating mode control in each column's corner, ⇧⌘P / ⌥⇧⌘P and the View items, per tab and remembered in the
  session, and the "open supported files in reading mode" setting opens one in reading like every other rendered
  kind. The View item is "Mode Toggle" there as everywhere. `RenderedPreviewKind.csv` and `PreviewContentKind.csv`
  are the whole of the plumbing; `CSVPreviewView` is the eighth content view the column holds.
- Read, not run. A delimited file is already a table, so unlike a dump there is no engine and nothing to ask:
  `CSVTable` walks the editor's own text once — unsaved edits included — and comes back with a header, the records
  under it and where each record is written. Nota's own RFC 4180 scanner, no Foundation CSV and no dependency. The
  comma for a `.csv` and the tab for a `.tsv`, spelled by the name the author gave the file and never sniffed.
- What the scanner keeps, because a real file breaks all of it: a field that opens with `"` is quoted, `""` inside
  it is one quote, and a separator or a newline inside it is text; a field that does *not* open with one keeps its
  quotes as characters, because `Laptop Sleeve 14"` means fourteen inches. CRLF, LF and a lone CR all end a record
  (a CRLF is one Swift `Character` and the two UTF-16 units the editor's storage holds, which is exactly the shape
  the record wants); a trailing newline is the end of the last record rather than the start of an empty one; a blank
  line anywhere is skipped, since it is whitespace in the file and not a row of nothing. A byte-order mark is the
  encoding saying hello and not the first letter of the first header. The first record is the header, and a header
  cell with nothing in it is named for its place — `Column 3` — so every column has something to click on. Rows are
  ragged in practice: a short one is padded with empty cells and a long one widens the table, naming the columns it
  made the same way. Nothing is ever thrown away and no record is ever a failure — an unterminated quote closes at
  the end of the file.
- The chrome is one bar and nothing else: the `arrow.clockwise` `Refresh` button at the leading edge ("Read again")
  and `1–100 of 2,345` between ‹ › ("Previous page", "Next page") at the trailing one — the dump's bar with the
  table picker, the query box and the Run button taken out of it, since a table has nothing to pick between and
  nothing to be asked. The bar starts a `ModeControlOverlay.hoverBandHeight` band below the top of the column, left
  clear for the floating Editor · Split · Reading control, so the header row is never behind it.
- The grid is the dump's own, `SQLGridView` unchanged: the spreadsheet cell cursor, the rectangle a drag picks out,
  the `#` gutter numbering rows from the top of the table, ⇧ and Space, the flat header with its accent chevron, the
  last column taking up the slack, and ⌘C copying what is drawn, tab separated. Cells are monospaced at the editor's
  size and every one of them is text — there is no schema to say otherwise, so nothing is set right and nothing is
  dimmed. A value written over lines draws its first line and says the whole of itself in a tool tip, as does one
  the column is too narrow for.
- A hundred rows to a page, the same hundred a dump pages by, and the footer says `2,345 rows · 6 columns` in place
  of the counts and `Rows 1–100 of 2,345` in place of the caret, both through `TextStats` — but only while the
  column is on screen, since in the editor mode a `.csv` tab is source like any other.
- A header click sorts by that column and a second click turns it round, on the click's release for the reason the
  dump's is. The sort orders the whole table and the page is cut from that, so sorting four thousand rows by name
  shows the first hundred names and not the first hundred rows rearranged. A column every non-empty value of which
  parses as a number is ordered as numbers — `9` before `10` — and one value that is not is enough to make the whole
  column text, ordered by the reader's own language with case ignored. An empty cell is nothing, and nothing sorts
  before everything. Ties keep the file's own order. A blank column is not sortable, and neither is the `#` gutter.
  A column is identified by its position *and* its name, since a CSV is free to have two columns called `id`.
- A cell clicked walks the editor to the line the row is written on, in split only and without taking the keyboard —
  the same `onSourceReveal` a dump's cell click uses, so the grid keeps the focus and the arrows go on walking the
  cells. `CSVTable` takes the ranges down as it reads: a record whose quoted field runs over three lines has all
  three, and the range begins where the record begins.
- Off the main thread, always: the read is asked on a serial queue and answered back on the main one carrying a
  token, so an answer about the file two keystrokes ago is dropped rather than drawn. An ordinary file is read again
  ~150 ms after typing stops, on the same debounce the Markdown render uses. A file past the `BigFile` threshold is
  never read on its own and typing after a read does not read it again; the `Refresh` button is what asks, and until
  it is pressed the pane says `Refresh to read this file.` A read the *reader* asked for keeps the sort and the page
  it was on; a read the *file* asked for drops the sort, since the columns may not even be the same ones.
- Nothing new is persisted: the mode the tab is in is all the session keeps, and `sqlTable` / `sqlQuery` stay a
  dump's. The file stays a text note in the editor — the preview is read-only and dirty and save semantics are
  untouched. ⌘F is the editor's, unchanged, in every mode.
- Untitled notes and every other extension have no table preview. Save As to `.csv` is what turns a note into one. A
  `.tsv` wears the `.csv` drawing in the strip. `Examples/Products.csv` is the demo: forty rows, quoted fields with
  commas and quotes in them, and one record written over two lines.

## Workspace (decided 2026-09-03, refactor before the LaTeX preview)
- The window controller has exactly one editor pane and one preview pane and talks to nothing inside them by name. The
  preview pane is a host holding one content view at a time; every content view — the Markdown render, the PDF view, the
  LaTeX render, the HTML page, later an image view — adopts one `PreviewContent` protocol (show a note, focus, takes
  keyboard, find bar visibility, freeze/thaw width, highlight and clear a block, block-click and status callbacks), and
  the host swaps them by the note's kind. Mode and divider logic stay where they are for now; moving them into a
  workspace controller of their own is a later step. Pure refactor: no behaviour changes, the existing preview and PDF
  tests pin it.

## Zen mode
- ⌥⌘Z toggles: tab strip, traffic lights, status bar, line-number gutter, image sidebar and the Markdown mode controls all
  hide; what is left is the note itself — the text (same font/width, padding grows to 40pt), or in split the text and the
  render still side by side, or in reading the render alone. ⌘ shortcuts still work (⌘T, ⌘W, ⌘P, ⌘B forces the sidebar back for that note).
  Remembered per session; combine with ⌃⌘F for full screen if wanted.

## Images
- The store: originals in `<support>/assets/<uuid>.<ext>`, which is what the editor, the chips, the sidebar and the
  render all draw from. An untitled note is only that — its text goes to the cache with `![](nota://<uuid>.<ext>)`
  tokens in it, and the store is the truth until ⌘S. Reading also accepts `![](jot://…)`, the scheme used before the
  app was renamed, so existing notes keep their pictures.
- The sidecar: saving under a name (⌘S, Save As) writes every chip's picture into `<basename>.assets/` beside the
  file — `notes.md` → `notes.assets/`, made on demand, each picture keeping the asset id it already has as its name
  — and the token in the file becomes an ordinary relative Markdown link, `![](notes.assets/3f9a….png)`. A saved
  note is then portable: copy the two together and any editor draws the pictures. The store is untouched; a sidecar
  is a copy made at save time. A picture already there with identical bytes is not written again. The path is
  percent-encoded in the link (`my%20notes.assets/…`), and both spellings are read back. `nota://` tokens found in a
  named file — written by an older version — read as they always did and are rewritten as sidecar links on the next
  save, which is what "a file brought through the editor is updated on its next save" means here.
- Opening: a relative image link, `![](pics/a.png)` or `![alt](…)`, that resolves to a real raster picture under the
  file's own folder becomes a chip — the sidecar's own links and anybody else's alike, so a Markdown file written
  elsewhere shows its pictures here for the first time. Never an absolute path, never `http`, never above the file's
  own folder. The note remembers the path the file spelled, so the next save writes that same link rather than
  moving the picture into `<basename>.assets/`; a picture beside the file is imported by content, so opening the
  same note twice does not grow a second asset. A link whose target is not there stays the literal text it was.
- Save As to a new name writes a new sidecar for the new name and leaves the old folder alone. A path the author
  chose (`pics/a.png`) is kept as it is; one inside another note's `.assets` folder is not, or the copy would go on
  pointing at the note it was copied from. Saving into another folder starts a sidecar of its own, since a relative
  path means nothing there.
- Inline: always a text chip `Image N`, numbered in document order, renumbered live. Clicking one selects the chip itself, so ⌘C
  copies the picture and ⌫ or typing replaces it; in vim the block caret sits on it instead. Dragging and ⇧-clicking select as usual.
- Sidebar (native split pane, 150pt, side per Settings): 104pt thumbnails with `Image N` captions. Auto-shows when the note has ≥1 image,
  hides when none; ⌘B toggles it manually for the session. Settings: sidebar side Left / Right (default Right). Click → select chip; double-click → open in Preview.
  Context menu: Copy Image / Save Image As… / Reveal in Finder.
- The same column is a table of contents while a tab that is read rather than edited is in front — a book's chapters
  (see EPUB), a PDF's outline (see PDF). One split item, one width, one side, one ⌘B and one pin; what stands in it is
  whatever the tab in front has to list. The lines arrive as a title, a nesting level and the line's own number, and
  the content view they came from is the only thing that knows what going there means, so one column serves both. A
  line is 13pt, one line truncated, indented 12pt a level, and the line naming what is on screen carries a grey wash
  — the ⌘P switcher's own selection rather than a blue document one. A picture tab has no contents and keeps the
  column away, and every editable tab — `.md`, `.tex`, `.html`, `.svg`, a plain note — is the gallery as before. The
  View item is named after what is listed: "Image Gallery" over a note, "Table of Contents" over a book or a PDF, ⌘B
  and its tick unchanged either way.
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
- Orphan assets are never auto-deleted, in the store or in a sidecar folder.

## Tabs
- One width for every tab, `clamp((viewport − plus − gaps) / n, 40, 180)`, shrinking as tabs are added; the strip never scrolls. The selected tab is raised to 60pt so its ✕ fits and the others shrink evenly to pay for it. Titles clip with a fade rather than an ellipsis; under 60pt the trailing slot goes and the unsaved dot rides on the icon. A separator hairline shows only between two plain tabs. The + rides after the last tab and pins at the trailing edge once the strip is full; it opens a new tab (same as ⌘T). ⌘P fuzzy tab switcher by title.
- There is no colour in the strip, so how much `labelColor` a shape carries is the only thing that says what state it
  is in. The selected tab is the strongest mark in it — a rounded fill at 10% (12% dark), its title in `labelColor` —
  and the pointer's wash on an unselected tab is a clear step lighter at 3.5% (5% dark), its title staying
  `secondaryLabelColor`, so two tabs never read as selected at once. The selected tab takes no wash of its own. That
  wash fades in and out over the same 0.12s the tab's dot→✕ cross-fade takes, rather than snapping on beside it. The
  strip buttons (+, bookmark, gear) wear the same wash and fade, one step darker at 9% (11.5% dark) while held; the
  disc behind a ✕ is 10% (13% dark) and 18% (22% dark) under a press.
- The strip's top-right corner holds two buttons past the +: the bookmark button (the ⌘P picker in bookmarks mode) and, last before the reserve, a Settings gear (⌘, by another door). Both pin at the trailing edge; the tabs and the + step left by exactly the slots they take.
- The switcher's first row sits above its search field and never filters away: "Add new tab", with a `plus`, which ↑ from the top of the list reaches and Return (or a click) turns into a new tab, ⌘T by another door. It is there in the `@` mode too. It is a one-row table of its own, sharing the list's cell view and taking the list's own resolved table style, so it is drawn as a list row — same inset, same rounded selection highlight, icon and title at the list rows' own x. In the bookmarks panel the row is the front tab's bookmark instead: "Bookmark this tab" with a `bookmark`, or "Remove bookmark from this tab" with `bookmark.fill` once it is one, and choosing it is ⇧⌘D by another door; with no tab to bookmark it is greyed and takes no selection.
- Every tab carries a leading icon for its kind, in the strip and in the switcher's rows, from `FileKindIcon`: most kinds (Markdown, plain text/no extension, PDF, EPUB, HTML, TeX, SQL, JSON, YAML, TOML, XML, CSV, common code and image extensions, and more — see `FileKindIcon.artStem(forExtension:)`) draw this app's own hand-drawn icon set, embedded as SVG text in the generated `FileKindArt.swift`; a kind the set has no art for falls back to an SF Symbol — pictures without art `photo`, logs `list.bullet.rectangle`, remaining code extensions `chevron.left.forwardslash.chevron.right`, an unsaved note `doc`, anything else `text.page` — with an older spelling behind any SF Symbol the running system lacks. Heading rows keep their bare indent, with no icon.
- `@` as the switcher's first character (Done 9) swaps the list for the front `.md` tab's headings, indented by level, and the rest of the query fuzzy-filters those instead; `MarkdownHeadings` reads them straight from the note's own text — ATX and setext, fences skipped the way `MarkdownSourceMap` skips them — off the main thread once a note is past `BigFile.threshold`. A tab that is not `.md` answers with a quiet "No headings" row.
- Choosing a heading puts the caret at its line start and scrolls it into view; in split or reading the render is walked to that block too, by hand through the `highlightBlock(containingSource:)` a caret move already drives.
- The selected tab is always fully in view: at 40pt the strip stops shrinking and becomes a sliding window over the tabs, anchored on the selected one. Closing with the ✕ freezes the widths until the pointer leaves the strip, so a run of closes keeps each next ✕ under it; ⌘W does not freeze.
- Tabs reorder by drag: the dragged tab rides the pointer and its neighbours slide into the gap; the order is the session's order.
- Middle-click closes. ⌘T new, ⌘W close, ⌘1–9, ⌃Tab/⌃⇧Tab. Right-click a tab for Bookmark / Remove Bookmark, Reveal in Finder (greyed on an untitled note; the same item sits at the foot of the File menu as ⌥⌘R, for the front tab) and Close Tab. Closing the only tab closes the window too, the way the title-bar close button does: the last window hides, any other closes for real.
- **Bookmarks** (Done 13). A bookmark is a file path, app-wide, kept in `session.json` beside the
  windows in the order they were added. ⇧⌘D bookmarks the tab in front — any named tab, PDFs and pictures included —
  and an untitled note is asked for a name first, staying unbookmarked if the save panel is cancelled. File ›
  Bookmarks holds that toggle (its title reads Remove Bookmark when the front tab is one), then every bookmark by file
  name with its kind icon and the full path as a tooltip, then Remove Missing Bookmarks; it is rebuilt on
  `menuNeedsUpdate` the way Open Recent is, except for the ⇧⌘D item itself, which is made once so the key equivalent
  is in the tree before the menu is ever opened. A bookmarked tab wears a 7pt `bookmark.fill` badge on the corner of
  its leading icon — bottom-right, moving to the bottom-left on a tab narrow enough that the unsaved dot has already
  taken that corner. A `bookmark` button pins in the strip's top-right, in a 24pt slot of its own past where the +
  pins; `TabStripLayout` reserves it, so the tabs and the + step left by exactly that much and nothing subtracts it
  twice. Pressing it opens the ⌘P panel in bookmarks mode: every bookmark, fuzzy-filtered by file name, ⌘⌫ (or ⌫ with
  the field empty) taking one off the list without closing the panel, and "No bookmarks" when there are none. Plain
  ⌘P lists the bookmarks this window does not already have open under the tabs — both halves ranked by the same fuzzy
  match and merged by score, with an open tab taking any tie — carrying the `bookmark` symbol instead of a kind icon
  so they read as not-open-yet. A bookmark whose file has gone stays in the list, greyed to tertiary in the picker and
  disabled in the menu, and Return on it does nothing; it goes when it is removed by hand or by Remove Missing
  Bookmarks. Choosing one selects the tab if this window has the file open, and otherwise opens it, which is also what
  puts it in Open Recent.
- **Search all notes** (Done 19). ⇧⌘F opens that same panel a third way: the field reads "Search all notes" and the
  query runs over every open tab's text through `NoteSearch`, live as it is typed and capped at
  `NoteSearch.resultLimit`. A row is one hit — the tab's title small on top with that tab's kind icon, the line the
  hit sits on under it with the matched characters in bold — so the rows are two lines tall rather than the list's
  usual one. There is no fixed row above the field in this mode: nothing it could mean, so ↑ from the top of the list
  stays put. An empty query lists nothing and says "Type to search all notes"; a query with no hits says "No results".
  ↑↓ and the pointer move the selection, Return or a click switches to that hit's tab, selects the match and scrolls
  it into view, and the query goes onto the find pasteboard so ⌘G carries on from there. Esc closes. The per-note find
  bar (⌘F) is untouched.
- A tab can move to another window: the note keeps its id, text, unsaved edits, caret and undo history, its cached
  text is never deleted on the way, and the window it left selects the neighbour (or keeps one untitled tab if it was
  the last). Dragging a tab out of the strip is that same move by hand: 40pt clear of the strip the tab becomes a
  window of its own that follows the pointer, another window's strip shows a caret where it would land, mouse-up
  docks it there or leaves the new window standing, and Esc puts it back.

## Summon
- Global hotkey, default ⌥Space, toggles show/hide. Configurable in Settings › Shortcuts, at the top of the
  tab, with a key recorder and Clear. No menu-bar item. It is a key *code*, not a key equivalent — Carbon
  registers a system-wide hotkey by position — which is why it is stored apart from the app shortcuts below it.

## Vim mode (Settings checkbox, off by default)
- The footer badge stands in for the vim mode while there is no editor in front (decided 2026-09-05): it reads
  `Read-only` over a PDF, a picture, a book or an RTF and `Reading` over a note in reading mode, and it is shown there
  whether vim is on or off; the pending-keys label stays away with it. Split and the editor give the word back to vim
  — `Normal`, `Insert` and the rest — and, with vim off, take the badge away again.
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
- Mac cursor keys in normal and visual mode: ⌥←/→ by word (w/b), ⌥↑/↓ by paragraph, Home/End line start/end,
  Page Up/Down as ⌃b/⌃f, ⌘-arrows as the Mac has them; insert mode was always the Mac's.
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

## Todo (in rough priority)
1. **Print / PDF.** ⌥⌘P prints the reading layout (⌘P is the tab switcher); Export as PDF… in File, same
   layout, page margins from the render's inset. Plain-text tabs print the text with line numbers if the gutter is on.
   Export a `.tex` tab as PDF via `pdflatex` / `tectonic` / `xelatex` if one is installed, showing the result in a PDF
   tab; with none installed it prints the native render, the same as the Markdown export.
   A PDF tab prints the PDF itself rather than a render — the open half of Done 12.
2. **Ship it, signed.** Developer ID signing and notarization in `build.sh` (ad-hoc today), so the .app opens on
   another Mac without the Gatekeeper allow-once dance (see Done 28 for the ad-hoc release itself).
3. **Tab strip overflow chevron.** The one piece of the Chromium strip still open (Done 15-A): a chevron at the
   trailing edge listing the tabs the window is not showing, in strip order, the selected one ticked.

## Done (the Todo ledger; numbers are the ones each item had while it was open, and code comments still cite them)
28. **GitHub releases, ad-hoc signed (done 2026-09-06).** `release.sh` is the one-shot publisher: tags the version
    from `Version.swift`, runs `./build.sh --universal` (see its own `--universal` flag) for an arm64+x86_64
    `Nota.app`, zips it as `Nota-<version>.zip`, pushes, and opens a GitHub release with generated notes. A Homebrew
    tap at `manfad/homebrew-nota` (cask `nota`) and the website's one-line `… https://nota-app.xyz/install.sh | sh`
    (that script itself lives in the website repo) both resolve to the same zip; `release.sh` rewrites the tap's
    `Casks/nota.rb` with the new version and sha256 on every run. Still ad-hoc signed, not notarized — see Todo 2.
27. **A `.csv` or `.tsv` is read as the table it is (done 2026-09-06).** A delimited file was a text note and
    nothing more: a hundred and forty characters of commas per line, read by counting them. It is a tab with a
    preview beside it now, the eighth content view the column holds, and the preview is the dump's grid with the
    database taken out of it. `CSVTable.swift` is the whole of the reading — Nota's own RFC 4180 scanner, pure and
    with no dependency — and it hands back a header, the rows, and the characters each record is written on;
    `CSVPreviewView.swift` is the pane, composing `SQLGridView` unchanged over one bar of `Refresh` and the page
    arrows. Everything the grid already knew how to do came with it: the cell cursor, the rectangle, the `#` gutter,
    ⇧ and Space, ⌘C as tab-separated text, and the flat header whose click sorts. What is new is the sort itself
    (numeric where the column is all numbers, the reader's own collation where it is not), the source map (a click
    on a cell walks the editor to the record's first line, quoted fields spanning lines and all), and the footer's
    `2,345 rows · 6 columns`. Nothing was changed about the SQL pane; nothing new rides in the session.

26. **RTF opens as a viewer tab (done 2026-09-05).** An `.rtf` or an `.rtfd` used to be imported — its plain text
   poured into a new untitled tab, the formatting and the pictures thrown away (Done 17, now superseded). That was
   the wrong shape: a rich-text document is something to read, not a note to be made out of. It is a viewer tab now,
   the fourth after a PDF, a picture and a book. `NoteKind.rtf` and `FileClass.rtf` join the others; `FileSniff`
   answers for it by the `{\rtf` header every RTF file starts with, asked before the text check since an RTF's own
   markup is ASCII and would otherwise open as a wall of control words, and an RTFD by being the package it is.
   `RTFPreviewView.swift` is the pane: `NSAttributedString(url:options:documentAttributes:)` into a read-only,
   selectable `NSTextView` at the editor's own margin, keeping the document's fonts and colours, with black body
   text swapped for `labelColor` so a page written for paper is legible on Nota's dark ground. ⌘F is
   `TextFindSession`, the same one the editor and the render use; ⌘+ scales every font, paragraph measurement and
   attachment, so the type re-wraps rather than being magnified. The session keeps how far down the document the
   reader was, in the field a book's chapter share uses. `TextFile.rtfPlainText` and
   `MainWindowController.importRTF` are gone, and with them the exception `Note.isOpenable` used to make for them.
   `.rtf` moves out of `deliberatelyExcludedTypes` and into the list `isTextFile` alone consults, which is what it
   always meant: a real RTF is not a note to edit, but a file merely *named* `.rtf` whose bytes are prose is prose
   and opens as it, dropped or not. See the RTF section.
6. **A `.sql` file is read as the database it builds (done 2026-09-05).** A dump was the one text file Nota could
   show you nothing useful about: two hundred `INSERT` statements are a program, and reading a program is not reading
   what it makes. A `.sql` tab now has the same three modes every other previewed file has, and what stands beside
   the source is the database itself — the tables the file builds, a hundred rows at a time, in a grid. The whole of
   it is the editor's own text, run into an in-memory SQLite (`SQLDump`, the system library, no dependency) every
   time the typing settles, statement by statement through the prepare/tail loop so a semicolon inside a string is a
   semicolon in a string; the file on disk is never opened by SQLite and nothing is ever written anywhere. A
   statement that will not go in stops the run and puts its message and its own text on a red line under the query
   box, with everything the statements before it made still readable — the failure a dump usually has is one bad line
   in the middle, and half a database is what you want to see then. The query box asks questions of that database and
   can never edit it: every statement in it is prepared under an authorizer that denies every action but a read, and
   the whole text is prepared before any of it runs, so `DELETE FROM t` and `SELECT 1; DELETE FROM t` are both
   refused rather than one of them half-running. Runs and pages go to a serial queue and come back with a token, so a
   stale answer is dropped rather than drawn, and a file over the `BigFile` threshold is never run on its own — it
   grows a Run button instead and typing does not start it again. `SQLPreviewView` is the column's seventh content
   view and `PreviewContent` grew one callback for it (`onStateChange`), which is what puts the picked table and the
   query into `session.json` beside the mode. ⌘F stays the editor's: a page of cells is not text for the find bar to
   band, and the query box is how you find a row in a database.
6-A. **SQL pane, second pass (done 2026-09-05).** Five things the pane got wrong once it was used on a real file.
   A header click sorted nothing: the sort was taken on `mouseDownInHeaderOfTableColumn:`, which arrives while the
   header is still tracking the mouse, and the page it asked for landed inside that tracking loop and rebuilt every
   column the header was holding — it is taken on `tableView(_:didClick:)` now, after the header has let go, and a
   page of the same columns keeps the column objects it had rather than tearing them down and building them again.
   The one-line query box sat in the corner the floating mode control floats in, so the two overlapped; the pane
   starts a hover band below the top of the column now and the box is five rows of the editor's monospaced font in a
   rounded bezel, Return a newline and ⌘↩ the run. The red error line under the box is gone: a query that will not
   run is an alert in the window's own words (`Couldn’t run the query.` over `near "*": syntax error`), and so is a
   file whose statements fail (`Couldn’t run “Shop.sql”.`) — that one once per distinct message, held until the file
   runs clean, because a dump mid-edit is broken on nearly every keystroke and an alert per keystroke is the pane
   arguing with the reader. The grid picks out cells rather than rows: click one, drag out a rectangle, walk it with
   the arrows, grow it with ⇧, ⌘C takes exactly what is drawn — with the `#` gutter and ⇧ still taking whole rows,
   and the two selections never up at once. The header is drawn flat in Nota's taste with its own accent chevron,
   since the system's grey triangle is small enough to be missed and the sorted column is the first thing a reader
   looks for. Everything else stands: a hundred rows to a page, the table pop-up, ‹ ›, the footer strings and the
   session's table and query.
6-B. **SQL pane, third pass (done 2026-09-05).** Three things asked for after the pane had been read with.
   The Run button and a refresh are the same press, so there is one button: `arrow.clockwise` beside the table
   pop-up, "Run again", which runs the file as it stands into a fresh database and asks for the same page back —
   same table, same query, same sort, same offset — and which is still the only way a big dump is ever run.
   Space stands the cell cursor up into its whole row, the selection the `#` gutter makes, and Space again sits it
   back down on the cell it came from; it never scrolls the grid and never reaches the editor. And a click on a value
   walks the editor beside it to the `INSERT` that wrote the row — its own tuple in a multi-row insert, found by
   counting parentheses outside string literals — in split only and without taking the keyboard, so the arrows go on
   walking the cells. That last one is a new file: `SQLSourceMap`, written down as the dump runs, holding each
   statement's own characters and the rowids each insert made (`sqlite3_changes` with `sqlite3_last_insert_rowid`),
   with every page of a table now carrying its rowids beside its values. What has no rowid — a query's result, a
   `WITHOUT ROWID` table — has no map and stays quiet rather than guessing. `PreviewContent` grew `onSourceReveal`
   for it, the half of a block click that moves the caret without asking for the keyboard. The empty grid was
   checked over as well and needed nothing: with no rows the table still fills the room under its header and AppKit
   draws the alternating stripes across it, which is what "the same table with nothing in it" should look like.
6-C. **The jump works for a query (done 2026-09-05).** A cell clicked in split walks the editor to the `INSERT`
   that wrote the row, but only ever for a table's page: a query's result carried no rowid, so after a run the grid
   was a sheet of values with nothing behind them. It carries one now for the query that is plainly one table's
   rows. `SQLQueryRewrite` reads the box's last statement — one `SELECT`, one `FROM`, no join, no comma-separated
   `FROM`, no `GROUP BY`, `DISTINCT`, `UNION`, aggregate call, leading `WITH`, sub-select or positional `ORDER BY` —
   and splices `<table or alias>.rowid AS "__nota_rowid",` in after the `SELECT` keyword, leaving every other
   character where the reader wrote it; `SQLDump.Page` grew `rowidTable` so a page says which table its rowids are
   of, and the pane looks the clicked row up in that rather than in the picked table. The count, a header's sort and
   the second page are all asked of the rewritten query. Everything else runs exactly as before — a rewrite SQLite
   refuses is dropped in silence, with no rowids and no alert. The other half of the report was looked into and
   found to be sound: after a run, a refresh and a page turn, one click still takes the keyboard from the query box
   and picks the cell out, and in a real window in split it still reaches the editor. Tests pin all three.
5. **Beautify and Compact a `.json` file (done 2026-09-05).** A JSON file that arrived as one 40 000-character line
   was unreadable here, and there was nothing to press about it. A `.json` tab now carries one button in the corner
   slot — `text.alignleft` "Beautify JSON" over a compact file, `arrow.down.right.and.arrow.up.left` "Compact JSON"
   over a laid-out one — in the segmented control's own small bezel, its symbol quiet in `secondaryLabelColor` and
   re-resolved with the appearance. One button rather than two: the file is already in one of the two shapes, so the
   only thing worth offering is the other. Which way it points is read off the text — a newline outside a string
   literal, the file's own trailing newline not counted — and worked out when the tab arrives and again on the
   half-second debounce the footer's counts use, never once a keystroke. `JSONFormat.swift` is the whole of the
   walking and none of it goes through `JSONSerialization`, which would answer by throwing the document away: keys
   would come back sorted, `1.50` would come back `1.5`, and an author's file would be handed back respelled. Every
   token — string, number, literal, and every key — is kept as the byte range it occupied in the source and put back
   down verbatim, so key order, array order, number spelling and every escape survive both directions and a beautify
   followed by a compact gives back exactly the bytes that were there. Pretty is two-space indent, `"key": value`,
   one element to a line, an empty `{}` or `[]` left on the line it is on; compact is no whitespace outside a string;
   the trailing newline is kept if the file had one. Invalid JSON leaves the button in place and disabled, with
   "Not valid JSON: line N" — the 1-based line the parse stopped at, which is the only thing the reader needs in
   order to go and look. The click replaces the whole note through `shouldChangeText` / `didChangeText`, the path a
   line operation uses, so it is one edit: the tab goes dirty, ⌘Z puts the file back, and the save, vim and the
   footer all see one thing happen. The caret goes to the top, because every line has moved.
4. **The corner is a slot, not a mode control (done 2026-09-05).** The band across the top of a column was built
   around the one thing it carried: `ModeControlOverlay` owned an `NSSegmentedControl` and the window asked
   `setAvailable(_:)` whether the tab was one of the rendered kinds. Everything else about it — the 44pt hover band,
   the 150ms opacity fade, the `hitTest` that hands every click but the control's own back to the text, the drop of
   the pill's height plus 6pt out of ⌘F's way — was already general, and none of it cared what was in the corner. The
   overlay is now that slot: `Content` is `.modeControl`, `.jsonFormat` or `.none`, the band and its behaviour are
   untouched, and `.none` takes the whole overlay away so the text under an empty band stays as clickable as any
   other line. The choice is made by asking the note rather than by a list of extensions kept in the overlay —
   `supportsRenderedPreview` for the mode control, `Note.isJSON` for the button — which is what lets a new
   `RenderedPreviewKind` arrive in this corner without a line of the overlay changing. The mode control's own surface
   is exactly as it was, segments, tints, clearance and all, and the JSON button (Done 5) is what the slot was opened
   for.
25. **Reveal in Finder (done 2026-09-05).** A tab's context menu gains Reveal in Finder between Bookmark and Close
   Tab, and File gets the same item at its foot as ⌥⌘R for the front tab. Both hand the file to
   `NSWorkspace.activateFileViewerSelecting`, through `MainWindowController.fileRevealer` so a test can catch the URL
   instead of bringing the Finder forward. An untitled note has no file: the context item is greyed (`TabBarItem.hasFile`)
   and the File item fails validation (`currentTabHasFile`).
24. **Languages: Malay and Traditional Chinese (done 2026-09-05).** The interface was English or 简体中文 and
   the code said so — one `usesChinese` flag and one table. `AppLanguage` grew `traditionalChinese` and
   `malay` (the existing raw values untouched, so a saved preference still decodes) and the flag became
   `resolved`, which answers with a real language rather than a yes/no: itself for a chosen one, and for
   `.system` whatever `AppLanguage.resolving(preferredLanguage:)` makes of the Mac's first preferred
   language — a pure function of the identifier, so the tests can ask without touching the Mac. `L10n.text`
   picks one of three tables from it, all keyed by the same English strings; `LocalizationTests` checks the
   key sets against each other, so a string added in English cannot ship translated in only one language.
   The inline `chinese:` override a few call sites pass still wins, but only for Simplified Chinese — every
   key it covers is in the other tables too. 繁體中文 is Taiwan/HK vocabulary rather than a character
   conversion (檔案, 視窗, 儲存, 拷貝, 顯示方式), and Malay leaves "Editor", "Format" and "Serif" as they
   stand, since those are the Malay words; `L10n.sharedWithEnglish` is that list, so the test can treat any
   other untranslated entry as a bug. The popup is `AppLanguage.allCases`, so case order is popup order,
   and nothing about applying a change moved: `AppDelegate` still compares the installed language and
   rebuilds the menu, and the Settings window relabels itself in place.
23. **A saved note keeps its pictures beside it (done 2026-09-05).** A note with pictures in it was readable only
   here: the file said `![](nota://3f9a….png)` and the bytes lived under Application Support, so mailing the file,
   putting it in a repository or opening it in any other editor gave prose with holes in it. Saving under a name now
   writes each chip's picture into `<basename>.assets/` next to the file and spells the token as an ordinary
   relative Markdown link, so `notes.md` and `notes.assets/` travel together and every reader draws them. The store
   is untouched and stays what the editor renders from — an untitled note still writes tokens to the cache, which is
   what keeps the cache the truth until ⌘S. The other half is the open path, and it is the half that pays: a
   relative link to a real picture under the file's own folder becomes a chip, so an existing Markdown file with
   local images shows them inline here for the first time, and the note remembers the path its author spelled so the
   next save puts the same link back rather than moving the picture. `Sidecar.swift` is the whole of the file-system
   side — the folder, the percent-encoding, the identical-bytes check, the resolver and the importer — and `NoteText`
   stays pure, taking a closure for each direction: `serialize(_:sidecar:)` asks what link a chip should get,
   `render(_:…:importing:)` asks what a relative link should become. `AssetStore.importFileDeduplicating(at:)` is
   what stops the store growing a copy of every picture on every open, comparing bytes and reading only the files of
   the same length. Nothing about the render changed: a chip is a chip whichever link it came from, so the preview
   draws it through the same attachment it always did.
22. **The sidebar becomes a table of contents for the tabs that are read, and the chapter bar goes (done
   2026-09-05).** A book's contents were reachable only through `@` in the ⌘P switcher — a list that closed the
   moment you chose from it, which is the wrong shape for the thing you navigate a book by — a PDF's outline was not
   reachable at all, and chapters turned with a pill floating in the column's bottom-trailing corner that the reader
   had no way to put away. All three are answered at once. The column a note's pictures stand in is now the
   document's own contents while a tab that is read rather than edited is in front: one split item, one width, one
   side, one ⌘B and one pin, with `ContentsSidebarView` swapped in beside `ImageSidebarView` rather than a second
   content mode inside it — the two share a rectangle and nothing else, one being picture cards with an asset store
   behind each and the other a list of indented lines. Nothing in the column knows what it is listing: lines arrive
   as `ContentsEntry` (title, level, the line's own number) and `PreviewContent` grew `contentsEntries`,
   `currentContentsLine` and `goToContentsLine`, so the window asks the content view rather than switching on a
   kind. `EPUBBook.contentsEntries` maps the book's `nav`/NCX and `PDFOutlineContents` walks `outlineRoot` depth
   first, each next to the view that reads it. `refreshImages` branches on the tab being read and
   `applySidebarVisibility` counts entries where it counted pictures, so auto-show, ⌘B, zen and the tab-strip inset
   all keep working unchanged; the ring is re-rung from `previewPositionDidChange`, so `→` in a book and a page
   scrolled past in a PDF both walk the list. The View item reads "Table of Contents" over a book or a PDF and
   "Image Gallery" over everything else, from the same validate path, keeping ⌘B and its tick — by the tab's kind
   rather than by whether there is anything to list, so ⌘B on an outline-less PDF shows the quiet `No contents` hint.
   `@` over a book now lists nothing; `MarkdownHeadings` for a text note is untouched.
21. **Drops the window used to swallow: a drawing on the text, anything on the render column (done 2026-09-05).**
   Two file drags landed nowhere. An `.svg` let go on the text was claimed as a picture — the system files a drawing
   under images, and `AssetStore.isImageFile` took the system's word — so it never reached `openableFiles` to open as
   a tab, and the store could not read its bytes as a picture either, so it vanished. There is one answer to what a
   picture is now: `TextFile.isDrawing` is the single place that disagrees with the system, `AssetStore.isImageFile`
   defers to `Note.isImageFile`, which asks it, and `isDeliberatelyExcluded` and `isTextFile` ask it too — a drawing
   was excluded as an image there, which is what stopped `Note.isOpenable` even after the chip was refused. The other
   drag was the render column: `PreviewPaneView.onDropFiles` only wired zen's drag band, so a file let go on a
   render, a page, a PDF, a picture or a chapter did nothing at all. Every content view now takes it — the protocol
   asks for `onDropFiles` rather than defaulting it, so a new kind of content cannot forget — and the column hands
   whatever lands to `openDroppedFiles`, the same as the strip. AppKit routes a drag by hit testing, so the views
   that actually receive it say so themselves rather than an overlay guessing: the render's text view, the web view,
   the PDF view. WebKit and PDFKit would each take the file by loading it in place and losing the tab, so both are
   unregistered from every drag type and given `public.file-url` back, and neither override calls `super`.
20. **The Mac's cursor keys in vim's normal and visual mode (done 2026-09-05).** A Mac keyboard's own navigation keys
   used to do nothing useful once vim was on: ⌥-arrows arrived as plain arrows, and Home, End, Page Up and Page Down
   fell through as function-key characters `handleCommand` quietly swallowed. `VimKey.Base` now has `.home`, `.end`,
   `.pageUp` and `.pageDown` — key codes 115, 119, 116, 121, and `<Home>` / `<End>` / `<PageUp>` / `<PageDown>` in the
   notation, so a vimrc can map them and `@a` writes them back out — and `handleNormal`'s arrow branch routes each key
   to the motion its letter uses: ⌥→ is `w`, ⌥← is `b`, ⌥↓ is `}`, ⌥↑ is `{`, Home is `0`, End is `$`, the page keys
   are `⌃f` and `⌃b`. One motion, so counts, operators (`d⌥→`) and visual mode all follow with no extra code — visual
   borrows normal mode's machinery for any key that is not a plain character. ⌘-arrows stay the Mac's: `NSTextView`
   does the moving in `handleCommandCursor`, and vim only adds afterwards what it adds after a click — the caret
   pulled off the end of the line, and the column the next `j` aims for. ⇧⌘ and every other ⌘ key is untouched, as is
   insert mode, which was always the Mac's.
19. **Search All Notes is a dialog (done 2026-09-05).** ⇧⌘F used to reveal a small `NSSearchField` in the strip's
   trailing corner with a drop-down of results hanging under it — a second piece of chrome, in a second shape, doing
   what the ⌘P panel already does. It is now that panel's third mode: `TabPickerPanel.showSearch(notes:…)` alongside
   `.tabs` / `.headings` / `.bookmarks`, same chrome, same field, same ↑↓ / hover / Return / Esc handling. Only the
   rows differ — two lines rather than one, the tab's title over the line the hit sits on — and the fixed row above
   the field is taken to no height at all, since a search has nothing to put there. `NoteSearch` is untouched and
   still pure; `SearchResultsPanel.swift`, the field, its constraints and the window-move repositioning are gone, and
   the strip's trailing constraint no longer has a second, wider variant to switch to. See the Tabs section.
18. **Lists continue themselves on Return (done 2026-09-05).** `ListContinuation.swift` reads the line the caret is
   on and says what Return means: the same marker stepped on once, with the indent, the delimiter and the case kept,
   or — on an item with nothing typed on it — the marker taken off and the list ended. Bullets, arabic numbers,
   letters and roman numerals, after `.` or `)`, and `- [ ]` boxes handed on fresh and unticked. A lone `i.` or `I.`
   is settled by the item above it at the same indent. All the arithmetic is pure; `NotaTextView.insertNewline`
   applies the answer as one `shouldChangeText` edit. See the Editor section.
17. **Import `.rtf` and RTFD as plain text (done 2026-09-05; superseded the same day by Done 26, which opens both
    as viewer tabs instead — the import path described below is gone).** Nota still refuses to edit an RTF or an RTFD package
    as a file, but no longer refuses to open one at all: `MainWindowController.open(url:)` — the single path ⌘O,
    drop, the Dock icon and Open Recent all funnel through — asks `TextFile.rtfPlainText(at:)` first, before the
    sniff or the exclusion below would otherwise refuse it. That reads the document with `NSAttributedString(rtf:
    documentAttributes:)` for a `.rtf` and `NSAttributedString(rtfdFileWrapper:documentAttributes:)` for an RTFD
    package and keeps only `.string` — no formatting, no pictures — deciding by the bytes actually parsing as RTF
    rather than by the extension, so a `.rtf` that is not really RTF still falls through to the ordinary rules
    untouched. A hit lands in a brand-new untitled tab rather than a tab bound to the file: `fileURL` stays nil, so
    ⌘S always asks where to put it and can never overwrite the rich document with plain text, and the tab is dirty
    from the moment it lands, since none of its text is on disk anywhere yet. Its title is the document's own base
    name rather than the usual `Untitled` — `untitledName` already took any string. `Note.isOpenable` gets the same
    check, so a dropped `.rtf` reaches the import instead of being silently refused. Neither the rtf's path nor the
    untitled tab it becomes is noted to File › Open Recent or the session as a file.
1. **External changes to an open file (done 2026-09-04).** A named tab watches its file — a `DispatchSource` on the
   file's descriptor and one on its folder, so a temp-file-and-rename save is caught as well as a write in place.
   Clean reloads silently, dirty is marked with a ring round its unsaved dot and offered Reload / Keep mine in a pill
   in the editor column's bottom-trailing corner (Notepad++ "file has been modified" without the modal storm).
   Missing file → the existing dirty behaviour. See the Model section for the whole of it.
2. **Encoding and line endings in the status bar (done 2026-09-04).** `UTF-8 · LF` at the right of the counts; click
   either half for a menu that converts (UTF-8 / UTF-16 / Latin-1 / Windows-1252; LF / CRLF), the current one ticked.
   Two clickable `NSTextField`s drawn as capsule badges in the vim chip's look, read straight off `note.format` and rebuilt
   whenever the front tab changes; picking another shape sets `note.format`, marks the tab dirty, and ⌘S writes the
   new shape — `write(note:to:)` already read `note.format`, so nothing there had to change. UTF-16 is one menu item
   for either byte order; converting to it gives the file a BOM (the only way `TextFile.decode` would ever recognise
   it again), converting away from it drops one, consistent with what detection would produce for that shape. A
   conversion the text cannot survive (`TextFile.canRepresent`, an emoji into Latin-1) is refused: the menu item is
   disabled rather than offered, with a tool tip saying why, and the old encoding stands. Empty over a PDF or a
   picture, which has no format of its own.
3. **Go to line (done 2026-09-04).** ⌘L opens a pill in the find bar's own corner — the same `PillView` chrome, one
   row — taking `N` or `N:M` and moving the caret as you type, off the note's `LineIndex` rather than a scan. See the
   Search section above for what it does; `:N` still does it in vim, untouched.
3. **EPUB viewer (done 2026-09-04; the second Todo 3, after Go to line above — code comments citing "Todo 3" mean
   this one).** An `.epub` opens as a viewer tab, the third kind after PDF and pictures: read-only, never dirty,
   never cached, a `book` icon in the strip. The sniff decides, not the extension — a zip whose first entry is a
   stored `mimetype` reading `application/epub+zip`, which is a fixed-offset read into the local file header at the
   front of the file and so costs nothing the 8 KB sniff was not already reading. `EPUBBook` unpacks the archive with
   `/usr/bin/ditto` (no ZIPFoundation: the system already ships an unzip) and parses container.xml, the OPF and the
   contents with Foundation's `XMLDocument`, strictly first and forgivingly after, since a nav document with an HTML
   entity in it is a book a browser would still read. `EPUBPreviewView` holds one `HTMLPreviewView` and drives it a
   chapter at a time, so the book's own CSS and pictures resolve from the unpacked folder through the same
   `nota-file://` scheme a `.html` tab uses, and ⌘F, the zoom and the keyboard are the page's own. See the EPUB
   section above for the whole of it.
4. **File › Open Recent (done 2026-09-04).** A submenu after Open… in `AppDelegate`, built by `RecentDocumentsMenu` —
   an `NSMenuDelegate` that rebuilds itself from `NSDocumentController.shared.recentDocumentURLs` on
   `menuNeedsUpdate`, most recent first, a separator, then Clear Menu (`clearRecentDocuments(nil)`).
   `MainWindowController.open(url:)` notes every named file it opens (`noteNewRecentDocumentURL`) — Open…, drag and
   drop, Finder's "Open With" and `:e` all funnel through it — but session restore does not, so launching never
   reorders what the reader chose to open by hand. Choosing an item opens the file the way `application(_:open:)`
   does, in the window in front. Tab reorder by drag in the strip was already shipped; see Tabs above.
5. **Task lists (done 2026-09-04).** `- [ ]` / `- [x]` as real checkboxes in the render, ticking one rewrites the one
   source character undoably; counted `3 / 7 done` in the footer for a `.md` that has any. See the Markdown preview
   section for what it does.
7. **Line operations (done 2026-09-04).** The Notepad++ hands outside vim mode: ⌥↑ / ⌥↓ move line, ⇧⌥↓ duplicate,
   ⌘D duplicate/select-next, ⌘/ toggle a `#`/`//` comment by extension, Tab / ⇧Tab indent a selection, ⌘] ⌘[ likewise.
   `LineOperations` works each one out from the note's `LineIndex` and hands the editor one replacement to apply; see
   the Editor section above for what each key does.
8. **Big files (done 2026-09-04, with 16).** Open a 100 MB log and a 200k-line CSV without the gutter, the chip scan or
   the word count freezing the run loop. A note past `BigFile.threshold` (1M UTF-16 units) is *big*. Every note owns a
   `LineIndex` — the start of every hard line, built once with chunked `getCharacters` and folded forward from
   `NSTextStorage.didProcessEditingNotification` one edit at a time — and the gutter, the footer's line count and the
   caret's `Ln, Col` read it by binary search. Pictures are counted through the attribute runs
   (`forEachAttachmentRun`; `enumerateAttribute` walks the characters), so a log with none costs one run. Words and
   characters of a big note count on a background queue from a snapshot — 0.5 s after the last keystroke, at once on
   open and tab switch — and the footer keeps the last answer until the new one lands; a small note counts on the spot
   as before. `NoteText` skips its regex when the text has no `](nota://` in it and `serialize` hands the string back
   when nothing is attached. A big note's cache write is debounced 2 s and done off the main thread.
   The storage's `string` bridges to Swift by copying: hot paths read `mutableString` instead.
9. **Headings outline (done 2026-09-04).** `@` in the ⌘P switcher lists the front `.md` tab's headings; choosing one puts the caret there
   and, in split/reading, scrolls the render to the block. Over a book the same `@` lists the book's own contents
   instead, and choosing one turns to that chapter (see Done 3, EPUB).
11. **Fix the word-wrap re-flow lag in the split slide (done 2026-09-04).** With word wrap on, the editor's text
    container is welded to the text view's width (`widthTracksTextView`), so narrowing the editor every frame of the
    0.2s divider slide re-wrapped the whole note every frame along with it. The editor now freezes that tracking at
    the width it is leaving for the length of the slide — the same trick `RenderedPreviewView.freezeWidth()` already
    plays for the render — and wraps once, to the width it landed at, when the divider lands.
12. **⌘F inside a PDF (done 2026-09-04) and Print of a PDF tab.** The find half is shipped: the same `FindBarView`
    pill the editor and the render use, driven by a `PDFFindSession` over PDFKit's selections — `findString` for the
    list and for each step, `highlightedSelections` for the bands and `currentSelection` for the one being stood on —
    with `NotaPDFView` taking `performTextFinderAction:` off `PDFView` so PDFKit's own bar never appears. See the PDF
    section for what it does. Printing the PDF itself is Todo 1.
13. **Bookmarks (done 2026-09-04).** A bookmark is a file's path and nothing else — not a tab, not a note id — so
    closing the tab does not lose the note. `Bookmarks` holds the one app-wide list, in the order they were added;
    `WindowRegistry` owns it, hands the same object to every window, and writes `SessionState.bookmarks` on any change
    it hears (`Bookmarks.didChange`, which is also what re-badges every window's strip). The key is decoded with
    `decodeIfPresent`, so a session written before this opens with none rather than refusing. ⇧⌘D toggles it — ⌘D is
    Duplicate Line — from File › Bookmarks and from a tab's new context menu; an untitled note is put through Save
    first and is bookmarked only if that lands (`savePanelProvider` makes the panel injectable, so the cancelled case
    is a test). See the Tabs section for the badge, the button and the two picker lists.
14. **Copying maths out of the render (done 2026-09-04).** `PreviewTextView.writeSelection` overrides the `.string`
    flavour: `forEachAttachmentRun` walks the selection and swaps each `MathAttachment` for its formula's `plainText`,
    leaving every other character — and the rich flavours, which already carry the formula as a real image — as they
    were.
15. **Tab strip, Chromium style (after the LaTeX preview; design agreed 2026-09-03 with a second reviewer).** Every
    tab shows a leading icon, per file kind (done 2026-09-04; custom art added 2026-09-04): `FileKindIcon` maps the
    name's extension to an icon — most kinds draw this app's own hand-drawn set, embedded by `Icon/make-file-icons.py`
    into `FileKindArt.swift`; a kind the set has no art for falls back to an SF Symbol (pictures without art `photo`,
    `.log` `list.bullet.rectangle`, remaining code extensions `chevron.left.forwardslash.chevron.right`, untitled
    `doc`, the rest `text.page`), with an older spelling behind any SF Symbol this macOS does not have — and the
    same icon in the ⌘P rows. Then, in this order:
    - **C. One press to select and drag (done 2026-09-03).** The first drag on a tab moved the window: native
      title-bar dragging and the tab's reorder gesture were running at the same time. Fix: `window.isMovable = false`
      turns the native drag off for the whole window; the strip refuses `mouseDownCanMoveWindow` and a press on empty
      strip space moves the window explicitly with `performDrag(with:)`; the icon and ✕ pass presses to the tab. Zen
      mode's drag region needs the same explicit drag. The tracking loop on the tab view stays; the strip-owned
      `NSApp.nextEvent` loop is the shape D needs, so it moves up when D starts.
    - **A. No scrolling; tabs shrink (done 2026-09-03).** Widths, `plusX`, the sliding window and the close freeze are
      a pure `TabStripLayout` with its own unit tests; `TabBarView` only places what it says, and the scroll offset,
      wheel handling and auto-scroll are gone. Titles clip with a 12pt fade, the trailing slot and its ✕ disappear
      under 60pt (the unsaved dot moves onto the icon), separators show only between two plain tabs, a ✕ close holds
      the widths still until the pointer leaves the strip, and a drag near either edge reveals one hidden slot at a
      time. The overflow chevron for the tabs the window is not showing is Todo 3.
    - **B. The + follows the tabs (done 2026-09-03).** `plusX = min(lastVisibleTab.maxX + 4, bounds.width − 24)`: it
      rides after the last tab and pins at the trailing edge once the strip is full. The buttons pinned in the
      trailing corner already narrow the bar's bounds, and nothing subtracts them twice.
    - **D. Tear-off (multi-window, done 2026-09-03).** Not `NSWindow.performDrag(with:)` (a modal window move: no further mouse events, so
      no drop target can highlight) and not `NSDraggingSession` (wrong look). Chromium-on-Mac's way: the same
      `NSApp.nextEvent` loop watches y; past ~40pt out of the strip it spawns a `MainWindowController`, moves the note
      across (no save prompt), and places the frame so the tab stays under the pointer (the traffic lights inset the
      first tab by 82pt); `windowNumber(at:)` finds another Nota strip for an insertion caret; mouse-up docks or leaves
      the window; the last tab out closes its source; Esc puts the tab back and kills the extra window. App shell:
      `AppDelegate` keeps a window list instead of one controller, summon and `application(_:open:)` target the key
      window, `setFrameAutosaveName` goes per-window. `session.json` gains `windows: [{tabs, selectedIndex, frame}]`,
      with today's flat tab list decoded as one window. ⌘N stays "new tab"; ⌘⇧N is a new window.
      Phase 1 (shell) done 2026-09-03: `WindowRegistry` holds the window list and says which is active (key, else last
      key, else first); `SessionState.windows` with a per-window frame and the flat mirror; `MainWindowController` is
      handed its `SessionWindow` and writes through an injected session writer, so one prune covers every window;
      `detachNote(at:keepingOneTab:)` / `attach(_:at:select:)` move a note between windows with no mouse and no prompt.
      Window close decided: the last window hides as it always did, and any other closes for real with its tabs handed
      to the most recently active other window rather than prompting or being lost.
      Phase 2 (the gesture) done 2026-09-03. The tracking loop stayed on `TabItemView` and moved to `NSApp.nextEvent`,
      which is what keeps the drags and the mouse-up coming once the new window is key and once the tab's own view has
      left the strip; past 40pt above or below the strip — or off either side of the window — `TabBarView` gives up its
      reorder and only forwards `tearOff` / `tabBarDragMoved` / `tabBarDragEnded` to its delegate.
      `MainWindowController` detaches the note, asks the registry for a window its own size placed so the tab is under
      the pointer, moves it with `setFrameOrigin` on every drag, and hit-tests `windowNumber(at:)` for another Nota
      strip, which draws a 2pt `controlAccentColor` caret in the gap the tab would drop into.
      A user can now drag a tab out into a window of its own, drop it on any Nota window's strip to move it there,
      and press Esc mid-drag to put the tab back in the slot it came from and take the extra window away; a window
      that gave up its last tab hides for the length of the gesture and is gone by the end of it.
      Two departures from Chromium: coming back over the strip the tab left does not re-dock it (the window simply
      follows the pointer, and only a release over a strip docks), and a window closing with tabs in it hands them to
      the most recently active window instead of closing them.
16. **Big files, in full (done 2026-09-04; see 8).** `SpellCheckPolicy`: the spell checker runs only for prose by
    extension (`md markdown txt text tex latex ltx rst adoc asciidoc org`, an untitled note, a file with no extension)
    and never for a big note; set per tab on install and again after Save As. `allowsNonContiguousLayout` on the
    editor's layout manager, and the two calls that defeated it — `applyWordWrap`'s full `ensureLayout` (now the
    visible rect) and `editorRect(for:)`'s (now the target character's range) — scoped. Still whole-text, later:
    `RenderedPreviewView.show` lays out its whole render; vim's `text` copies the storage per motion;
    `preferencesChanged` restyles every note in full (settings only).

Order from here: everything above the ledger is shipped through bookmarks and the tab strip (v0.5 and after). Next,
in Todo order: print / PDF export → Ship it, signed (Developer ID + notarization; the ad-hoc release itself is Done
28) → the strip's overflow chevron.
