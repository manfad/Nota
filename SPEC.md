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
- **Save is Nota's own dialog**, not `NSSavePanel` (done 2026-09-07, see Done 51): a sheet on the window, in the
  shape of the macOS save form and nothing else — "Save As:" over "Location:", the labels right-aligned into one
  column and the fields starting in the next; the name field and the Format popup share the first row, the popup at
  the field's end, since the extension is the tail of the name (merged 2026-09-07), with Cancel and Save (the default button,
  Return; Escape is Cancel) at the bottom. The name field carries the base name only, preselected, and the
  extension lives in the Format popup, so it is never lost to a panel's own name-typed-with-a-dot handling; a name
  typed with an extension of its own still wins over the popup (`SaveNameComposer`). A named file opens on its own
  name, extension and folder; a new note on the last extension chosen (`Preferences.lastSaveExtension`, default
  `md`, listed even when it is none of Nota's known ones) and the last folder saved into
  (`Preferences.lastSaveDirectory`), or Documents. The list is not the end of it (2026-09-07): under a separator
  the popup carries **None**, which writes the name bare, and **Other…**, which brings a small field out beside
  the popup, focused, for any extension at all — `.mdx`, `.text`, a `.txt` spelled some other way — and Save waits
  while that field is empty; a listed pick puts the field away again. Location is read only — `Choose…` opens the system's folder
  picker over the dialog (a nested modal, the form AppKit documents for a panel raised from a modal window), the
  one part worth keeping — and shows the folder's own icon and name with the
  whole path behind its tooltip. Saving over a file that is not the note's own asks first. The dialog is relabelled
  where it stands on a language change. Before this the extension lived in an accessory combo bolted under the
  system panel's "Where:" row, lined up with its form by measured offsets from the panel's centre line; the
  accessory area was the only place macOS gave an app, and the arithmetic went with it.
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
  bottom-trailing corner, the one ⌘F and ⌘J do not use, carries a `Pill.swift` bar: a `clock.arrow.circlepath` glyph,
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
- Search: ⌘F opens Nota's own find bar (in note), ⌘R opens it with the replace pill too; ⇧⌘F opens the search
  dialog across all open tabs — a note's text, a PDF's pages and a book's chapters alike (see Tabs).
  In vim mode `/` `?` are vim's own search, typed in the command pane (see Vim mode); `n` `N` `*` `#` repeat it;
  `:noh` clears highlights. ⌘F is the same bar in every mode, and closing it hands the highlights back to vim.
- The find bar is a pill floating in the top-trailing corner of the column, over the text, with that column's mode
  control dropped below it: the word `Find`, the query field (no placeholder), the count (`3 of 12`, `12 matches`,
  `No matches`), and chevron-up / chevron-down / ✕, in `secondaryLabelColor` on a raised surface with a hairline round
  it. The word is set in the field's own size (system 13) and is `secondaryLabelColor` until the keyboard is in that
  pill's field, `labelColor` while it is — so the lit word says where typing goes. Nothing is
  pushed down for it; it fades (opacity, ≤150ms, no movement) and its field shows no focus ring. Typing searches as
  you go, from where the caret was when the bar opened; Return and ⇧Return step, Esc closes, ⌘G / ⇧⌘G wrap, ⌘E seeds
  the query from the selection and the find pasteboard. Case- and diacritic-insensitive.
- Matches wear the quiet band vim's `'hlsearch'` uses — temporary attributes, never the text — except the one you are
  on, which wears `findHighlightColor` with its text in black. Nothing is selected while the bar is open: the caret
  sits at that match's start, and a click elsewhere is the new place for ⌘G to walk from. The bands stop at 2000
  matches and the count then says `2000+`; an edit re-scans 150 ms after the keystrokes stop, and a note past
  `BigFile.threshold` not at all. Closing puts the bands down, leaves the match selected and hands back the keyboard
  and the corner. A tab switch closes the bar.
- Replace is a **second pill**, not a taller one: clicking `Find` fades in another 300×34 pill of the same
  surface 6pt below the find one, holding the word `Replace`, a replace field (no placeholder) and two quiet
  words, `One` and `All`. Every one of these words — `Find`, `Replace`, `Jump`, `One`, `All` — is drawn in the language set and follows the setting as it changes (the identifier keeps the English key). It goes when `Find` or `Replace` is clicked again and when the find pill closes; neither pill
  ever changes size, and the mode control clears the whole stack. Both ⌘R ("Find and Replace…") and ⌘F are toggles:
  ⌘R with the bar closed opens both rows, with the keyboard in the replace field when there is already a query; ⌘R or
  ⌘F over a row that is out folds it away and puts the keyboard back in the query field; ⌘F over a folded bar refocuses
  the query field. Closing the bar takes the row down with it, so the next ⌘F is find and no more. Tab walks between
  the fields, and the lit word walks with it; there Return replaces and steps on, ⌥Return replaces all, Esc closes.
- Replace acts on the match you are standing on; clicked away, it steps to the next instead. The replacement is
  verbatim, never a pattern, and goes in as an ordinary edit — undo, the dirty flag, the save and vim all see one.
  Replace All changes every match, not only the 2000 wearing a band, in one undo, and leaves the caret where it was.
  Over the rendered page and in any tab that is not editable `Find` is only a word — clicking it does nothing — and
  ⌘R is ⌘F.
- **Jump to line** is the same pill again (done 2026-09-04): ⌘J ("Jump to Line…") opens one with the word
  `Jump` (a label, not a button, lit by the same rule), a field with no placeholder, the note's line total
  (`1,234 lines`) and a ✕. It takes `N` or
  `N:M`, 1-based, and moves as you type — to the first thing on line N that is not a space, or to column M clamped to
  the line's end, centred where there is room. Past the end is the last line; junk leaves the caret alone and reads
  `Not a line`. Return and the ✕ keep the place, Esc puts the caret and the scroll position back. Editor only, so the
  menu item is disabled in reading mode and on a PDF or a picture. ⌘J and ⌘F share the corner; vim's `:N` is its own.

## Editor
- System font (SF Pro) 13pt default, full-width text, no line-width cap.
- Line numbers in a left gutter (Settings toggle, default on). One number per hard line; wrapped continuation rows are blank.
  Settings toggle "Gutter separator" (default off) draws a hairline (separatorColor) along the gutter's inner edge.
- Settings toggle "Highlight current line" (default off) draws a quiet full-width band (labelColor at 4%) under the
  caret's line — the same band vim's `:set cursorline` draws. The two are independent inputs to one drawn state, so
  `:set nocursorline` never turns off a band the preference asked for, and switching the preference off never
  touches vim's own.
- Settings toggle "Word wrap" (default on). Off: a long line runs on and the editor scrolls sideways; the gutter stays
  pinned at the left edge. The Markdown render always wraps.
- Settings (⌘,): a source list of eight pages down the left — General, Appearance, Editor, Preview,
  Tab bar, Status bar, Shortcuts, About. There is no Save button: every control writes its own
  preference the moment it changes and the app follows at once — a switch on the flip, a popup on the
  pick, the size field on Return or on the focus leaving it, a shortcut on the key being recorded.
  Language and theme rebuild the dialog after writing, so the new wording is on screen without closing
  it. The one refusal is a shortcut clash (below): it is not written at all. The sidebar is a `.sidebar`-material column, 180pt,
  running the full height with the traffic lights over it (the titlebar is transparent and the title is
  not drawn); each row is an accent-coloured SF Symbol beside its name, and the page on screen is a
  rounded row filled in the accent colour. The pane beside it carries the page's title at the top,
  centred and bold, then the controls in inset rounded groups: a 10pt-radius card, a hairline between one
  44pt row and the next, the label left and the control on the right edge, an on/off setting wearing an
  `NSSwitch` rather than a checkbox, and no footnotes: the three there were (under General, under the
  Shortcuts list, and the tagline on About) went on 2026-09-07. **General**
  — language and theme. The language popup lists five, each naming
  itself in its own script: System Default, English, 简体中文, 繁體中文, Bahasa Melayu. System Default reads
  the Mac's own preferred language — `zh-Hant` / `zh-TW` / `zh-HK` → 繁體中文, `zh-Hans` / `zh-CN` / bare
  `zh` → 简体中文, `ms` → Bahasa Melayu, anything else English. The footer's counts speak the language too —
  "182 字 · 1860 字符", "182 字 · 1860 字元", "182 perkataan · 1860 aksara" — one word for one and for many,
  since neither Chinese nor Malay has a plural; and a new tab is 无标题 / 未命名 (Untitled 2, 无标题 2) while
  Malay keeps Untitled. A name a tab already has stays when the language changes (2026-09-07). **Appearance** — font family, size, line
  spacing, editor padding, sidebar side (Left / Right, default Right). **Tab bar** — a first group of "Show tab bar" and "Auto-hide tab bar", then a
  second group for what the strip shows: Traffic lights, Bookmark button, Bookmark dialog button, Settings
  button; no footnote — the keys (⌘T, ⇧⌘J, ⌘D, ⇧⌘D, ⌘, and ⌘W) all keep working with the strip and its
  buttons hidden, but the page does not say so. "Bookmark dialog button" keeps the older
  `hidesBookmarkButton` key, from when it was the strip's only bookmark button, so a session that switched
  it off keeps it off; the new row writes `hidesBookmarkToggleButton`. "Auto-hide tab bar" and "Traffic lights" are both greyed while
  "Show tab bar" is off — turning the strip off already takes the lights with it, the way zen does, so
  there is nothing left for either row to do. Whenever the lights are gone from their corner, the strip
  takes their slot, starting at the same 12pt inset it uses beside a left sidebar; a tab torn off from it
  is placed under the pointer by the strip's current inset, not always the lights' 82pt.
  **Editor** — word wrap, line numbers, gutter separator, highlight current line, vim mode. **Preview** — start supported files
  in preview mode. **Status bar** — show status bar, then which regions it shows. **Shortcuts** — Summon
  first, then the menu commands under the menu each lives in; the sentence explaining Summon ("Summon
  brings Nota to the front from any app, even while it is hidden.") is not a footnote under the group but
  sits behind a `?` after the row's label, in a transient popover a click opens and a click anywhere else
  closes. **About** — the app
  icon at 96pt, "Nota", `Version N.N.N`, one line saying what Nota is, and a **Check for Updates**
  button under it. The check is manual and remembered nowhere: pressing the button greys it and says
  "Checking…", then one line replaces that, centred and wrapped at 360pt at most (it folded to a word a
  line on 2026-09-07: a label that takes any width, in a stack that centres rather than stretches, was
  given none). "Nota is up to date." when nothing newer is published (a
  version *ahead* of the newest release counts as up to date, so a development build is never offered a
  downgrade). "Nota 1.1.0 is available." with a **Download** button that opens the release page in the
  browser. On a copy installed with Homebrew the same answer reads "Nota 1.1.0 is available. Update
  with:" over `brew upgrade --cask nota` as selectable monospaced text and no Download button — Nota
  never touches the clipboard for it. A check that fails says "Couldn't check for updates: " and the
  reason: unreachable, rate-limited (GitHub's anonymous allowance, worded as its own case), another
  status by number, an unreadable answer, or a release GitHub tagged with something that is not a
  version. The check is one anonymous `GET` of
  `https://api.github.com/repos/manfad/Nota/releases/latest` with a 10s timeout, comparing `tag_name`
  (a leading `v` dropped) with `AppVersion.current` as dotted integers — a missing or non-numeric part
  reads as 0, so `1.0.18` < `1.0.19` < `1.1.0` < `2.0.0` and `1.0` is `1.0.0`. A copy counts as
  Homebrew's when its bundle path is under a `/Caskroom/` or a `Caskroom/nota` directory exists under
  a Homebrew prefix: a cask *moves* `Nota.app` into `/Applications`, so the bundle path alone is
  indistinguishable from a hand-copied one. The window is 760×520,
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
  Tab ⌘D, Show Bookmarks… ⇧⌘D, Jump to Tab… ⇧⌘J, Next Tab ⌃Tab, Previous Tab ⌃⇧Tab, Find… ⌘F, Find Next ⌘G,
  Find Previous ⇧⌘G, Search All Tabs… ⇧⌘F, Jump to Line… ⌘J, Toggle Comment ⌘/, Indent ⌘], Outdent ⌘[,
  Increase Font Size ⌘+, Decrease Font Size ⌘-, Actual Size ⌘0, Sidebar ⌘B (the row's name; the View
  item still reads "Image Gallery", "Table of Contents" or "Page List" by the tab in front), Mode Toggle ⌘P,
  Reading Mode ⇧⌘P, Zen Mode ⌥⌘Z, Settings… ⌘,. On 2026-09-07 the Jump to Tab… moved from ⌘P to ⇧⌘J so Mode
  Toggle could take ⌘P and Reading Mode ⇧⌘P (they were ⇧⌘P and ⌥⇧⌘P), and Find and Replace… became ⌘R
  instead of ⌥⌘F; ⌘M stayed Minimize's. The system-standard items are not adjustable and are reserved
  against: ⌘Q ⌘H ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A ⌘M, and neither is ⌘N, Nota's older new-tab key, nor ⌘R and ⌘E, the
  two Find items that stay put.
  A row records the next combination you press: ⌘ or ⌃ has to be in it (⌘ with a letter is fine), Esc
  cancels, Delete puts the command's own key back. A key that lands somewhere free is written at once,
  like everything else here. Two rows on one combination, or a row on a reserved one, is refused
  instead: nothing is written, the field goes back to the key that is stored, and a red line names both.
  The line stays until the next key that lands somewhere free, on any row. **Reset to Defaults**, at the
  foot of the page, clears every override there and then.
  Only the moved keys are stored, as JSON under one defaults key, so a default Nota changes later moves
  with it. The menu bar reads the table when it is built and is rebuilt whole the moment the table
  changes — the menu items, the bookmarks toggle and the find bar's tooltips all come from that one
  place, so a moved key works everywhere at once.
- Status bar: `[MODE]` bottom-left when vim mode is on · `N words · N characters` (· `3 / 7 done` on a `.md` with
  task items) · `N pt` beside gear. The trailing row is format · encoding · line ending · cursor, each its own
  clickable badge and each switchable off in Settings › Status bar (see The format badge and the detector).
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

## Markdown preview — three modes (⌘P cycles, View menu; per tab, remembered in the session)
- **Editor** (default), **Split**, **Reading**. ⌘P walks editor → split → reading → split → editor: split is the
  middle, and from it the key moves on from wherever the tab came, so one press undoes the last and the render never
  jumps from full to gone (2026-09-07; it used to cycle round). ⇧⌘P jumps to reading and back out to the editor. The View menu keeps "Mode Toggle" (checkmarked in split and reading) and adds
  "Reading Mode" (checkmarked in reading). Both checkmarks are the front tab's.
- Rendered files only: a note whose file is spelled `.md` (`.markdown`, `.mdown`, `.mkd`; 2026-09-06), saved — or `.tex` (`.latex`, `.ltx`), which gets the LaTeX
  render below instead, or `.html` (`.htm`, `.xhtml`), which gets the HTML preview, and everything else here unchanged. Every
  other tab — an untitled note, a `.txt`, a `.css`, anything not yet saved — has no render, no mode control, and both
  View items are disabled there, so ⌘P and ⇧⌘P do nothing.
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
  `long.text.page.and.pencil` / `rectangle.split.2x1` / `book` (the editor's was a bare `pencil` until
  2026-09-07; a page with a pencil on it says "the text itself", where the pencil alone only said "write"),
  tool tips naming the state and its keys —
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
- Reading has no automatic exits. The only ways out are the mode control, ⌘P / ⇧⌘P and the View menu — nothing you do
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
- Per tab, not per app: ⌘P sets the mode of the tab in front only, and switching tabs lays out for the tab you land on —
  a new ⌘T tab and a freshly opened file start in the editor. The mode rides in `session.json`, so each tab comes back the
  way it was left (a session written when the pane was a yes/no comes back split where it was open).
- Settings "Open Markdown, LaTeX and HTML files in reading mode" (default off): opening a `.md`, `.tex` or `.html`
  file opens that tab in reading. Session restore ignores it — the tab's saved mode wins.
- Native: Foundation's Markdown parser (`AttributedString(markdown:)`, full interpretation) + Nota's own block styling.
  No WebView, no dependencies, no theming. Same font family/size as the editor; headings scale from it (H1 ×1.6 … H6 ×1.0,
  semibold; H1 and H2 underlined by a hairline the pane draws margin to margin, GitHub's way, as an attribute on
  the heading rather than a character of its own, so the text a click maps back is unchanged); lists indented with `•` / `1.`; block quotes with a leading hairline bar in secondaryLabelColor; code spans
  and fenced blocks in the monospaced system font on labelColor @ 5%; thematic break = hairline; tables as aligned
  monospaced rows (best effort); links underlined in labelColor (monochrome), clickable; emphasis/strong/strike.
- `Image N` chips render as the actual pictures from the asset store, scaled to the pane width; remote images are not
  fetched (the alt text shows instead).
- Live: re-rendered ~150 ms after typing stops; the pane keeps its relative scroll position.
- Block sync (both ways). Every rendered block (heading, paragraph, list item, quote, code block, table, rule, image)
  knows its source range. Clicking a block selects it — a quiet band, labelColor @ 6%, full pane width — scrolls the
  editor so that source is visible and **selects the whole block's source** there (decided 2026-09-06; vim comes back
  to normal mode for it) — in split only; reading takes no block clicks at all. A jump selects what it jumped to: the
  reader pointed at a paragraph and asked to be put in it, so typing replaces the block, ⌘Z puts it back, and an arrow
  key collapses the selection to one end the way any selection collapses. The same is true of a `.tex` tab's blocks
  and of a display formula, whose `$$` fences are part of what is selected. Moving the caret in the editor lights the block it is in and scrolls the preview to keep it visible. One block
  lit at a time; the band clears when the text changes under it. No proportional scroll following any more.
- A **click** is the block click above; a **drag** is not (done 2026-09-07). A press that stays put is the jump it has
  always been, and a press that sweeps selects the text it crosses, the way it does on any page — double-click a word,
  triple-click a paragraph, ⌘C copies. The two are told apart by waiting: `NSTextView`'s own tracking loop runs to the
  mouse up, and only a press that neither moved (a few points of slop for a shaky hand) nor left anything selected is
  reported as a block click, and that one puts the render's own selection back to nothing before it jumps — the render
  is not where a caret lives. A selection jumps nowhere and leaves the lit band exactly where it was. The pane still
  refuses first responder in split, so the caret and ⌘F stay the editor's, and a fresh render starts unselected.
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

## The format badge and the detector (done 2026-09-07, Todo 1)
- What a tab is *read as* is its file's extension and always was. The badge is the reader's own word on top of it:
  a fourth clickable capsule in the footer's trailing row, ahead of the encoding, so the row reads **format ·
  encoding · line ending · cursor** — what the text is, then how it is written down, then where the caret is in it.
  It says `Plain`, `MD`, `LaTeX`, `HTML`, `SVG`, `JSON`, `YAML`, `TOML`, `XML`, `CSV` or `SQL`, and it
  is empty over a PDF or a picture, which is not read as anything — it *is* something.
- Clicking it pops the same kind of footer menu the encoding half does: those eleven in that order, the tab's own
  ticked. Picking one applies at once — the corner slot's Editor · Split · Reading segments appear or go, ⌘P works
  or stops working, the split builds or tears down, the tab's icon follows, the footer's task count follows, and a
  `.json` or `.html` picked by hand carries the Beautify / Compact segment like any file spelled that way. Picking
  the format the *name* already says puts the override down rather than writing it: the name is saying it, and a
  later Save As is free to change what the tab is again. Picking `Plain` on a real `.md` is the other
  direction — the render goes and the whole window is source.
- It is an override in both directions and it is kept on the tab, not on the app: `Note.formatOverride`, written to
  `session.json` by the one spelling that means that format (`json`, `md`, `txt`) and restored with the tab. A
  spelling a later Nota does not know is simply not an override.
- Save panel: a tab the badge is showing as JSON opens the Format combo on `json`, so Save writes `blob.json` with
  no second decision — and every other extension is still one click away in the same combo, since this is a help
  and not a rule. After the write, an extension that means the same format drops the override — the name says it
  now — and one that means something else leaves it standing: the reader said what the tab is, and a file name did
  not unsay it.
- **A file whose format the reader has changed wants a new name.** Picking a format on a tab that *has* a file, and
  that the file's own extension does not already say, marks the tab dirty exactly as an edit does — the dot in the
  strip, the close confirmation, the session record — and leaves it owing a name: the next ⌘S opens the save panel
  instead of writing over `notes.txt`, with `md` already picked in the Format combo. Picking the name's own format
  again puts that need down; it does not put the dirty mark down, since dirty is one flag for the whole tab and
  there may be an edit under it this had nothing to do with. Answering the panel settles the name whichever way it
  is answered: saved as `notes.md` the override is dropped, saved as `notes-copy.txt` the override stands and the
  reader's word with it, and either way the *next* ⌘S writes where that one landed rather than asking again. The
  need is kept on the tab (`Note.needsSaveAs`, written to `session.json` only where it is owed), so a tab quit in
  that state comes back in it.
- Settings › Status bar has a **Format** row beside Encoding, on by default. The badge is also the one footer
  region that gives way in a narrow window: four badges at their full width would put a floor under the window
  itself, and the window's floor is the columns' business.
- **The detector.** `FormatDetector.detect(_:)` is a pure look at the characters — no file, no AppKit — asked in a
  fixed order and answering `nil` unless it is sure: JSON that parses, an `<?xml` prolog or an `<svg` or an `<html`
  root, `\documentclass`, two lines of `CREATE TABLE` / `INSERT INTO` / `SELECT` / `PRAGMA`, a `[section]` with two
  keys under it, three `key: value` lines with no Markdown in them, three even records of two or more fields, and
  two different Markdown signals. Under three non-blank lines or sixty characters it does not look at all. Prose
  with a colon in it, a shopping list of one kind of line, and three plain paragraphs are all `nil`, deliberately:
  an offer that is wrong is worse than no offer, because the reader has to read it and dismiss it and then it was
  noise.
- **The offer, when it is the typing that produced the text.** A floating pill in the editor column's
  bottom-trailing corner — the reload offer's corner, and never up at the same time as it: **`JSON detected` ·
  Preview in JSON · Not now**. Non-modal, never takes the keyboard, and gone the moment either word is clicked.
  Never an alert here: an alert would stop the typing that produced the text.
- **The offer, when the note arrived whole.** A paste or a drop gets a real question instead — a sheet on the
  window, `Markdown detected` over *Preview this tab in Markdown? You can change this any time from the format
  badge in the footer.*, with **Preview in Markdown** as the default button (Return) and **Not now** beside it.
  Nothing is interrupted: the typing an alert would have stopped is not happening, and the reader is looking
  straight at what they have just put there. The pill never stands under it — a paste while it is up takes it down
  first — and one question at a time: a second paste while the sheet is standing is ignored, since the sheet
  answers for the tab. Both words do exactly what the pill's do: the first is the footer's own `setFormat`, and
  "Not now" is remembered against the reading it declined, so neither half puts the same guess to that tab twice.
- It is offered to **untitled notes only** — no file, no override, no preview of its own. A file is never offered
  anything, not even a `.txt`: a name is its author saying what it is, and a `.txt` full of JSON is somebody's
  `.txt`. The badge is there for anybody who disagrees, and one click does it.
- It waits out the typing (about 1.5s after the last keystroke) and does not wait at all after a paste or a drop —
  a note that arrived whole is not typing that might carry on, so the question is there when the reader looks up.
  Once per tab per reading: "Not now" is remembered against the kind it declined, and only text that reads as
  something *else* asks again. Picking a format in the footer takes the pill down, and so does switching
  tabs — the reading is asked afresh for the tab you land on.

## Mermaid diagrams in Markdown (done 2026-09-07, Todo 6)
- A ```` ```mermaid ```` fence in a `.md` note draws as a diagram in the preview, in reading and in split. Nota reads
  and draws it itself — no WebView, no mermaid.js, no dependency of any kind — on exactly the footing the maths is
  on: the fence is lifted out of the source before Foundation's parser sees it (its `-->` and `|text|` are markup to
  a Markdown reader), rides through as an image token, and comes back as one block attachment.
- **The grammar.** `flowchart TD|TB|BT|LR|RL` and `graph …`. Nodes: a bare id, `A[rect]`, `A(rounded)`,
  `A([stadium])`, `A[[subroutine]]`, `A[(cylinder)]`, `A((circle))`, `A{diamond}`, `A{{hexagon}}`, `A>flag]`, with
  `A["quoted, so it may hold [brackets]"]` and `<br>` as a line break. A node keeps the shape and label it was first
  given; an id that only ever appears on the end of an arrow is a rectangle labelled with itself. Edges: `-->`,
  `---`, `-.->`, `-.-`, `==>`, `===`, `--x`, `--o`, `<-->`, with labels written `-- text -->`, `-. text .->`,
  `== text ==>` or `-->|text|`; chains `A --> B --> C` and fans `A & B --> C & D`. `subgraph id [Title]` /
  `subgraph Title` … `end`, nested as deep as it likes. `%%` comments, `;` between statements, and
  `click` / `style` / `classDef` / `class` / `linkStyle` / `direction` / `:::class` parsed and ignored.
  `sequenceDiagram`: `participant A`, `participant A as Alice`, `actor A` (a stick figure), and any name a message
  uses first, in order of first use; messages `->`, `-->`, `->>`, `-->>`, `-x`, `--x`, `-)`, `--)` (solid or dotted,
  open, filled, cross or async head), `+` / `-` activation suffixes and `activate` / `deactivate` (bars on the
  lifeline, nesting stacks them), self-messages as a loop off the lifeline, `Note left of` / `right of` / `over A`
  / `over A,B` with `<br/>`, frames `loop` / `alt`-`else` / `opt` / `par`-`and` / `critical`-`option` / `break` /
  `rect` nested freely, `autonumber` (each message numbered), and `title` / `accTitle` / `accDescr` / `box … end` /
  `link` / `links` / `create` / `destroy` read and never failed on. Headers stand at the top and again at the bottom
  as Mermaid draws them.
- **The layout** is Sugiyama's, in points measured against the render's own font: cycles broken by reversing the
  edges that close them, longest-path ranks along the direction, barycenter sweeps for the order inside each rank, a
  dummy node standing in every rank a long edge crosses so it is routed rather than drawn through what is in the
  way, then coordinates — rank gap 2.2em (wider when an edge label has to fit between two ranks), sibling gap 1.2em,
  boxes sized to their words with about 0.8em of air. Edges are drawn as smooth curves from one node's border to the
  other's, arrowheads as filled triangles, and a labelled edge carries its words on a small box with the line
  cleared out from under it. A subgraph frame is a rounded box around its nodes with its title along the top.
- **The fallback is today's behaviour.** A fence in a grammar Nota does not read — `gantt`, `classDiagram`, a stray
  sentence — and one it cannot parse — a bracket that never closes, an arrow with nothing on the end of it, a
  subgraph with no `end` — renders as the code block it already was, with no caption and no complaint. The question
  is asked *before* the fence is lifted out (`Mermaid.canDraw`), so nothing is ever taken out of the note and lost.
  A note being typed into is code until the moment it is a diagram, and never a blank.
- **Theming.** Nothing about a laid-out diagram is a colour: it is drawn through `MermaidPalette`, five semantic
  system colours resolved at draw time, so light and dark follow without a second layout — the same rule the maths
  draws by. Labels are set at the render's size × 0.9, in the system family unless the render is monospaced.
- The block is centred with the air a display formula is given, scaled down to the column with its aspect kept when
  it is wider than one, and has a block of its own for block sync: clicking it selects its fence in the source, and a
  caret in that fence lights it.

## The corner slot (done 2026-09-05, Todo 4; four options 2026-09-06, Todo 30)
- One band per column, and the front tab says what stands in it. The band, the hover, the fade, the hit testing and
  the drop out of ⌘F's way are exactly as the mode control's above; only the thing in the corner changes.
- A tab whose note `supportsRenderedPreview` gets the mode control. A `.json` or `.html` tab gets that same control
  with a **fourth segment** out front of it — its format's own Beautify / Compact action, ahead of the three modes.
  Every other tab — a `.txt`, an untitled note, a PDF, a picture, a book — gets nothing: the overlay goes away
  whole, so the band takes no clicks and the text under it stays as reachable as any other. Zen empties every slot.
- One capsule, never two pieces of chrome. Both files that carry an action have a render behind them now, so the
  action never stands on its own: it is one more segment of the same `NSSegmentedControl`, the same 28pt width and
  the same bezel, always the first segment when it is there — the modes shift one along to make room for it. The
  control stays `.selectOne` — a click that lands on the action fires the reformat and the selection goes straight
  back to the mode segment it was on, since nothing about a file's layout is a mode.
- Keyed on the note, never on a list of extensions kept in the overlay, so a new kind of render is offered the mode
  control the moment `RenderedPreviewKind` learns to spell it.
- The slot is per column: the editor's in editor and split, the preview's in split and reading. Both carry the
  action segment where they carry the modes, and both are kept in the same state — a segment that said "Beautify"
  in one column and "Compact" in the other would be a bug you could see.

## Beautify / Compact — JSON and HTML (done 2026-09-05, Todo 5; HTML and the fourth segment 2026-09-06, Todo 30)
- The action segment shows `rectangle.expand.vertical` "Beautify JSON" / "Beautify HTML" when the file is pulled
  together, and `rectangle.compress.vertical` "Compact JSON" / "Minify HTML" when it is already laid out — one
  box opening out and closing up, so either says what the other would do (a pair of diagonal arrows until
  2026-09-07; the Beautify side was
  `text.alignleft` until 2026-09-06 evening). One direction,
  because the file is in one of the two shapes already and the only thing worth offering is the other one. A page is
  *minified*, which is the word its own tools use; a document is *compacted*. All four tool tips are localised.
  The symbol is drawn in `secondaryLabelColor`, `tertiaryLabelColor` while disabled, and re-resolved when the Mac
  switches between light and dark, like the mode segments beside it.
- Which way it points is read off the text. For JSON: a newline anywhere outside a string literal means the file is
  laid out, and the file's own trailing newline does not count. A file that will not parse leaves the segment in
  place but disabled, with "Not valid JSON: line N" / "Not valid HTML: line N" naming the 1-based line the parse
  stopped at; the three mode segments beside it go on working.
- The state is worked out when the tab arrives in front and re-parsed on the same half-second debounce the footer's
  counts use after typing, never once a keystroke.
- Clicking replaces the whole note through the editor's own undoable path — one `shouldChangeText` /
  `didChangeText` edit, the way a line operation replaces its lines — so the tab goes dirty, ⌘Z puts the file back
  exactly as it was, and the save, vim and the footer see one edit. The caret goes to the top (every line has moved)
  and the segment flips at once. One path for both formats: the segment hands its kind and its action to the window,
  and the window asks whichever formatter that kind names (`JSONFormat`, `HTMLFormat`).
- `JSONFormat` is Nota's own walker, not `JSONSerialization`: every token — string, number, `true`, `false`, `null`,
  and every key — is re-emitted as the byte range it occupied in the source, so key order, array order, number
  spelling (`1.50` stays `1.50`) and every escape inside a string survive both directions, and beautifying then
  compacting gives back exactly what was there. Pretty is two-space indent, `"key": value`, one element to a line,
  with an empty `{}` or `[]` left on the line it is on; compact is no whitespace at all outside a string. The file's
  trailing newline is kept if it had one. The grammar is RFC 8259 and nothing beside it — no comments, no trailing
  commas, no single quotes, no unquoted keys.

## Structured previews — `.json` `.yaml` `.toml` `.xml` (done 2026-09-06, Todo 30)
- A `.json`, `.yaml` / `.yml`, `.toml` or `.xml` file is a tab with a preview beside it, exactly the way a `.sql` or
  a `.csv` is: the same three modes, the same floating control in each column's corner, ⌘P / ⇧⌘P and the View
  items, per tab and remembered in the session, and the "open supported files in reading mode" setting opens one in
  reading like every other rendered kind. The View item is "Mode Toggle" there as everywhere.
  `RenderedPreviewKind.tree(StructuredFormat)` and `PreviewContentKind.tree` are the whole of the plumbing;
  `TreePreviewView` is the tenth content view the column holds.
- Four grammars, one shape. A JSON object, a YAML mapping, a TOML table and an XML element are all a thing with
  named parts; a JSON array, a YAML sequence and a TOML array are all a thing with numbered parts; the leaves are
  strings, numbers, booleans, nulls, dates and — for XML — runs of text and comments. `StructuredDocument` is that
  shape, a parser's whole job is to turn its own grammar into it, and the view has never heard of JSON. Every node
  carries the 1-based line it starts on **and the whole span of source it was made from** — an `NSRange` in the
  UTF-16 units the editor counts in — plus a `valueRange`, the value alone without the key that names it. The first
  is what the caret is matched against; between them they are what a click on a row selects.
- `JSONTree` is Nota's own recursive descent over the UTF-8 bytes, RFC 8259 and nothing beside it. It is a *second*
  walker over the same grammar `JSONFormat` walks, deliberately: `JSONFormat` never looks inside a token, which is
  what makes beautify and compact lossless, while a tree is read — strings and keys come out unescaped for display,
  `\uD83D\uDE00` is one emoji, and numbers stay as spelled (`1.50` is `1.50`). Keys keep file order, duplicate keys
  are both kept, nesting is refused past 256, and every failure is a line and a short reason — "Expected `:`",
  "Unterminated string", "Control character in a string", "Extra content after the document".
- `XMLTree` is Foundation's `XMLParser` (SAX), because it already answers the one question a tree needs and a
  hand-written scanner would have to earn: which line every event happened on. An element is an object keyed by its
  **qualified** name — `svg:rect` stays `svg:rect`, and namespace processing is off, so `xmlns:svg` stays the
  attribute it is written as. Its attributes come first among its children, keyed `@name` with string values, in the
  order they are written — `XMLParser` hands them over as a dictionary, but their places in the start tag are read
  back out of the text for their spans, and that order is the file's (sorted by name until 2026-09-06 evening). A run of text and a `<![CDATA[…]]>` block are `.text`
  children, whitespace-only runs dropped (a pretty-printed file's indentation is layout, not content) and the rest
  trimmed; a comment is a `.comment`; a processing instruction and the doctype are skipped. The roots are the root
  element and any comment written beside it.
- A `.yaml` or `.yml` file is read as a tree by `YAMLTree`, Nota's own parser: no library, and nothing built through
  Foundation and read back, so a number keeps the spelling its author gave it and every row remembers the line it was
  written on. The subset is the part configuration files use — block mappings and sequences (including the sequence
  written at its key's own column, and the compact `- - a` and `- key: v`), flow collections across as many lines as
  they like, all five scalar styles with `|` and `>` chomping and explicit indentation, `#` comments, `---` documents
  each becoming a root, a leading `%YAML` directive, anchors and aliases, and `<<` merge keys, whose members fill in
  where the `<<` was written and lose to any key the mapping spells out. Types follow the YAML 1.2 core schema:
  `null`, `~` and an empty value are nothing; `true`/`True`/`TRUE` and their negatives are booleans; decimal, `0x` and
  `0o` integers, floats with an exponent, `.inf`, `-.inf` and `.nan` are numbers, kept as written; everything else,
  and anything quoted, is a string — so `yes` is a word and `1_000` is a name, the way 1.2 says and 1.1 did not. Tags
  are stripped, except that `!!str`, `!!int`, `!!float`, `!!bool` and `!!null` overrule the schema. What is outside
  the subset is an error naming its line rather than a tree that quietly disagrees with the file: a complex `? ` key,
  a tab in indentation, a dedent that lands between two levels, a mapping key where a sequence item belongs and the
  other way round, an alias with no anchor, a flow collection left open, a quote never closed.
- A `.toml` file is read by `TOMLTree`, TOML 1.0 and the whole of what a manifest uses: bare, quoted and dotted keys,
  `[table]` and `[a.b.c]`, `[[arrays of tables]]`, inline tables, and arrays spread over as many lines, trailing
  commas and comments as they need. All four string forms are read, multi-line basic strings dropping the newline
  after their opening delimiter and honouring a line-ending backslash. Numbers keep their spelling — `1_000` stays
  `1_000`, `0xDEADBEEF` stays `0xDEADBEEF`, `3.0` never becomes `3` — and so do dates and times, all four shapes,
  because `1979-05-27T07:32:00Z` and `1979-05-27 07:32:00Z` are one instant and two different lines of a file. A
  `[a.b.c]` header makes three nodes rather than one: the two above `c` are objects nobody wrote, conjured at the
  line that first mentioned them, so the tree reads down the way the file reads down whatever order the headers
  arrived in. An array of tables takes the first header's line, and each of its items its own. Refusals name their
  line: a key written twice, a table opened twice, a header that would tunnel through a value, a dotted key reaching
  into an inline table (closed the moment its `}` is typed), a bad escape, a string left open, a missing `=`, a
  number or date that is neither, and anything at all after a value on its line. (Two deliberate leniencies: inline
  tables may span lines, and leading zeros in integers are accepted.)
- The view is an `NSOutlineView` and not a render, because a tree is a thing you open and close rather than read top
  to bottom: the disclosure triangles, ⌥-click to open a whole subtree and the arrow keys are all AppKit's own. One
  column, no header, not a source list, the document's own `textBackgroundColor` and the editor's margin, starting
  14pt down from the top — the editor's own padding, not the corner slot's whole band, since 2026-09-07 — with the
  capsule floating over the first rows on hover the way it floats over the first lines of the source; rows under it
  still take their click.
- A row is the key in the system font in `labelColor` — an array item shows its own index in `secondaryLabelColor`
  instead, since that is the tree counting rather than the file saying something — then the value in the editor's
  monospaced face, coloured by what it is: `systemRed` for a string (in its quotes, so an empty one is still
  visible), `systemBlue` for a number, `systemPurple` for `true` / `false` / `null` / a date, `labelColor` for a run
  of XML text and `secondaryLabelColor` for a comment. A closed branch says how much is inside it after its key —
  `{3}` for three members, `[12]` for twelve items — in `tertiaryLabelColor`; a branch with no name at all, the
  document's own root, says it either way, since the row would otherwise be blank.
- The document opens expanded whole below 400 nodes and to its first two levels above that: a settings file opens
  showing everything, a big export opens showing its shape. It is re-parsed on the render's own key and debounce, so
  it follows the file as it is typed, and what was open is remembered **by node path** — a path that no longer
  exists is simply gone, a branch that has just been typed into being arrives closed — as is the scroll position.
- Where each node is written, per format (decided 2026-09-06). JSON: a member from its key's opening quote through
  the end of its value, an array item the value alone, a branch through its closing bracket, the root its own
  brackets. YAML: a mapping entry from its key through the end of its value, bringing the whole block written
  beneath it along; a sequence item is the value after its `- `, and a nested mapping item covers its whole block; a
  block scalar is its header and its content; an alias is the `*name` where it stands, though the members it pulled
  in still point at the anchor, which is where they are written. TOML: a pair from its key — the whole dotted key —
  through the end of its value; a `[table]` or `[[table]]` from the header's `[` through the last pair written under
  it; an object a dotted key conjured from the key that first mentioned it through the last pair inside it; an
  inline table and an array their own brackets; the root the whole file. XML: an element from its `<` through the
  end of its `</name>` or `/>`, an attribute the `name="value"` read back out of the start tag, a run of text its
  trimmed extent, and a CDATA block the whole `<![CDATA[…]]>`.
- Getting those out of `XMLParser` is the one place the reader had to be measured rather than believed. It says
  *where* an event happened and never how wide it was: `columnNumber` is 1-based, counted in **Unicode scalars** (an
  emoji is one column, a combining accent one of two — neither UTF-8 bytes nor UTF-16 units), and stands one past
  the thing just read for an end tag, a run of text and a comment. A start tag reports the `>` it ends on (the `/`
  for an empty element), and its `<` is found by looking back for the nearest one, which is exact because XML
  forbids a `<` inside a tag, attribute values included. A CDATA block is reported at the start of its *content*, so
  the block is nine scalars back and runs to its `]]>`. Every parser counts in its own units — bytes for JSON,
  Characters for YAML and TOML, scalars for XML — and `SourceOffsets` converts each to UTF-16 in one pass over the
  text, remembering only where the two rulers part company, which for an ASCII file is nowhere.
- A click on a row selects the whole node, key and value together: the row says `name  "Nota"`, and
  `"name": "Nota"` is what the reader pointed at (decided 2026-09-06 evening, after an afternoon of the value alone —
  the member is the thing the row names, and the key is how it is found again in the source). A click on a
  **branch** likewise selects the whole of it, key and body together. `valueRange` is still recorded, the value
  as written for every leaf, for whatever wants the value alone: JSON's token, YAML's scalar (a block scalar its `|` or `>`
  header and its content, an alias the `*name` where it stands), TOML's value, an XML attribute's quoted value and a
  run of text or a whole `<![CDATA[…]]>`. For a branch it is the bracketed form where there is one — a JSON object,
  a TOML inline table or array, a YAML flow collection — and nothing where there is not: a YAML block mapping, a
  TOML `[table]` and an XML element are their key and their body with nothing around them.
- Both halves of the block sync a render has. Clicking a row **selects that node's source** in the editor, in split
  only and *without* taking the keyboard — the `onSourceReveal` a dump's cell click uses, so the arrows go on
  walking the tree; a click on a disclosure triangle opens a branch and goes nowhere. And the caret lights the
  **deepest** node whose span it is standing in, with a quiet selection wash, scrolled into view; a row inside a
  closed branch is not on screen to light, so the deepest ancestor that *is* stands in for it. Two edges, both of
  them where a caret actually sits: one exactly at the end of a node is still in it, unless the node beside it
  begins there; and one in the indentation before the first node of a line is in that node. This is what a compact
  file needs — every node of a one-line export begins on line 1, so the line alone says nothing, and the caret walks
  the tree down as it moves along the line. A node whose parser could not say how wide it is falls back to the line,
  and then the *outermost* node beginning that line is lit.
- A file that will not parse shows a centred block in place of the tree, and the last good tree is *not* kept: a
  tree that no longer matched the text beside it would be a map of somewhere else. The block is a headline in
  `labelColor` naming the format the file is spelled as — "Not valid JSON" — and under it, quieter, the line and the
  parser's own reason: "Line 3 — Expected `:`". A file that *parses* but is one plain value — YAML and TOML read a
  pasted page or a paragraph of prose as a single scalar, and one row holding the whole file is not a reading of it —
  gets the same block, its detail "The whole file is one plain value, not a YAML document." And where
  `FormatDetector` reads the text as something else, a third line says so and says what to do about it: "It reads as
  HTML — choose that in the footer's format badge." Centred, word-wrapped, three quarters of the column's width at
  most, all of it localised (done 2026-09-07, Done 47).
- The tree's one column is exactly as wide as the column it is drawn in, so a row too long for it is cut off with an
  ellipsis rather than running off the edge: a row is a line of the tree, not a line of the file, and a leaf holding
  a whole page in one string used to make the column as wide as the string. There is nothing to scroll sideways to.
- ⌘F searches the tree itself in reading mode, where the outline has the keyboard (Done 47): the keys and the
  values as the rows spell them, a match opening every branch above it and taking the editor's caret with it. In
  split the editor has the keyboard and ⌘F is the editor's, the same rule the page keeps.
- ⌘+ / ⌘- are the editor's font size here, as they are for Markdown: the tree's own fonts follow it. Nothing new is
  persisted — the mode the tab is in is all the session keeps. The file stays a text note in the editor; the preview
  is read-only and dirty and save semantics are untouched. Untitled notes have no tree; Save As to `.json` is what
  makes one.

## PDF
- A PDF opens in a tab of its own and is read there, whatever it is named — its magic bytes decide, not its
  extension, so a PDF named `report` opens as one and a `.pdf` that is really a text file opens as text (see Model).
  Entry points are the same as any other file's: ⌘O, a drag onto the window or the Dock icon, Finder's "Open With"
  (declared `Viewer` / `Alternate`, so nothing is taken over), and `:e path`. Opening one that is already open comes
  back to its tab.
- The tab is locked in reading: the document takes the whole column, the editor stays collapsed, and there is no mode
  control in either corner. ⌘P, ⇧⌘P and both View items do nothing there and are disabled — a PDF has no Markdown
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
- The document's pages stand in the sidebar (done 2026-09-06), the column a note's pictures are shown in: one card
  per page, in order, under the word `Pages`, in the shape the gallery draws a picture in — the page fitted to a
  104pt square on a white card with a drop shadow, `Page N` under it. Clicking one goes to the top of that page. The
  card for the page in front wears the gallery's own accent wash and follows the reader as they scroll and page,
  scrolling itself into view. Every document has pages, so the column comes up on its own for every PDF the way it
  does for a note with a picture in it, and the quiet `No contents` hint is no longer anything a PDF can show. The
  View item reads "Page List" there. See Images for the column itself.
- The outline is not in the sidebar (decided 2026-09-06, and it was there from 2026-09-05 to then — see Done 29).
  Most PDFs have no bookmarks at all, so the column was empty for the common case, and a document is navigated by
  its pages. `PDFOutlineContents` is gone with it and the pane answers `contentsEntries` no more.
- A thumbnail is drawn off the main thread and only for the cards being looked at — a screenful either side of what
  is on screen, filled in as it is scrolled — at twice the card's size so it is a Retina picture, and kept for as
  long as the document is open, so a trip through another tab and back does not draw it again. The pages are drawn
  from a second `PDFDocument` opened on the thumbnail queue rather than from the one being read, since PDFKit's
  objects are not safe to touch from two threads at once. A five-hundred-page document therefore opens at the cost
  of a screenful of pages.
- ⌘F searches the document (done 2026-09-04): the same pill in the same corner, "Find in document", over PDFKit's own
  selections rather than a text storage. Every match wears a quiet band drawn over the page, the one you are on wears
  `findHighlightColor` and is the page's selection, and the count reads the same `3 of 12` / `12 matches` /
  `No matches` (`2000+` past the same cap the editor stops at). Typing searches from the page you are reading; ⌘G,
  ⇧⌘G, Return and ⇧Return walk and wrap; ⌘E seeds from what is selected on the page; Esc puts the bands down, leaves
  the match selected and hands the keyboard back to the document. A document cannot be typed into, so `Find` is
  only a word and Find and Replace… is greyed out — the one Find item a PDF turns down. PDFKit's own find bar never
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
- The zoom pill (done 2026-09-06). Where the keys zoom the content there is a pill in the bottom-left of the column
  — `−  100%  +`, the corner slot's twin at the other end of the diagonal and in the same small bezel. The number
  is a percentage of that content's own actual size, so a page or a picture fitted to the column reads 100% whatever
  scale that actually is, and a page at 100% reads 100%. `−` and `+` are ⌘- and ⌘+, and the percentage is Actual
  Size: the same three keys, pressed with the mouse. It is only there when it is wanted — it fades in on a zoom,
  shows the new number, and takes itself away a second and a half after the last one, and it is up for as long as
  the pointer is in the band across the bottom of the column, which is how a reader who wants the buttons rather
  than the keys finds them. Either reason is enough on its own. A tab with nothing to zoom — a render, a dump, a
  table, a note beside an editor — has no pill at all, and one arriving in front of a document takes the last one's
  number away on the spot rather than fading it out. Zen keeps it: a thing that is only there while it is being used
  has nothing to hide from a reader.
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
  collapsed, there is no mode control in either corner, and ⌘P, ⇧⌘P and both View items do nothing there.
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
  there is no mode control in either corner, and ⌘P, ⇧⌘P and both View items are disabled.
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
  note's pictures and a document's pages are shown in: the same split item, the same 150pt, the same side,
  brought up on its own when a book tab comes to the front and put away by the same ⌘B, which reads "Table of
  Contents" there. The line naming the chapter on screen is rung and follows along as chapters turn; clicking one
  goes to that chapter and to the `#anchor` it named. Zen takes the column the way it takes the gallery. A book whose
  contents are empty lists nothing and the column stays away. Nothing new is persisted. See Images for the column.
- `@` in the ⇧⌘J switcher lists nothing for a book tab: the contents are on screen beside the chapter now, and a list
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
  floating mode control in each column's corner, ⌘P / ⇧⌘P and the View items, per tab and remembered in the session.
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
  floating mode control in each column's corner, ⌘P / ⇧⌘P and the View items, per tab and remembered in the session.
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
- **A field in the page is the one exception (done 2026-09-07).** A page can carry an `input`, a `textarea`, a
  `select` or a `contenteditable`, and clicking one used to focus it in the DOM while every keystroke went on landing
  in the editor beside it — the form looked live and took nothing. A fourth injected script (same separate world)
  reports `focusin` / `focusout` on editable elements; while the page holds one, `HTMLPageView` accepts first
  responder and is given it, since WebKit delivers key events only to a first responder. Only a field does this — a
  click anywhere else in the page still leaves the caret where it was — and the keyboard is never thrown back:
  losing the field ends the exception and leaves the keys where they are, so the reader's next click decides. Losing
  first responder ends it too, whatever the DOM still believes is focused, so the click after that is ordinary again.
  A fresh load starts with no field held. Reading mode is unchanged; it has the keyboard already. While the page has
  it, ⌘F is the page's own bar and the rest of the nil-targeted items walk the responder chain as they always did.
- **A press in the page reveals its tag (done 2026-09-07).** A DOM is still not a list of source ranges, so there are
  no blocks and no band — but a press does its best rather than nothing. An injected script (`mousedown`, capture
  phase, never `preventDefault`, in the same separate world as the find script) reports the pressed element's place in
  `document.querySelectorAll('*')` order along with the tag names up to it; `HTMLSourceMap` tokenises the page's own
  text with `HTMLFormat`'s walker — one tokeniser over a page, not two — and lines the source's start tags up against
  that list by name. The DOM has elements no file wrote (an implied `html`, `head`, `body` or `tbody`; anything a
  script added) and occasionally the file has tags the DOM dropped, so the walk skips whichever side is ahead when the
  other's name turns up within four, and answers **nothing** when neither can find the other: a caret on the wrong tag
  is worse than no caret. What is revealed is the start tag, or the whole element when it holds nothing but text and
  inline markup and the walk found its end tag — `<h1>Hi</h1>` whole, `<div>` by its tag alone. It is `onSourceReveal`,
  the call a tree row and a grid cell make: the editor selects and scrolls, the page keeps the keyboard, and a link
  still opens (a press inside one is left alone). The page reports the press in every mode; the window acts on it
  where a reveal means anything, which is split — `revealSource` has always declined reading, where there is no
  editor on screen for a caret to be moved in. The map is rebuilt with each load and
  is `nil` for anything that is not the note's own text — a book's chapter, the message a broken drawing gets, and a
  page the tokeniser refuses (an unterminated comment, an unclosed quote, nesting past 256).
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
  `<svg>` is the document rather than a tag inside a page the file never had. It is checked first (`SVGCheck`, an
  `XMLParser` pass): an empty or unparsable drawing gets Nota's own page — "This drawing cannot be shown" over the
  line and column — in the column's colours, light or dark, since WebKit's XML error page is black type in a pink
  box whatever the appearance and prints the find bar's injected stylesheet as text under it (Done 46). It is never one of the picture tabs
  below — its bytes are text, and the system filing it under images does not make it one.
- Beautify / Minify a `.html` file. The corner slot on an HTML tab offers the same two shapes the `.json` tab
  offers, over Nota's own walker (`HTMLFormat`) rather than any HTML parser. Beautify indents by nesting, two spaces
  a level: each block-level element starts a line of its own, inline elements stay in the line with their text, and
  a block whose content is nothing but text and inline markup — `<li><a href="/">Home</a></li>`, `<td>1</td>`, an
  empty `<div></div>` — is that one line. Minify puts the page on one line with no whitespace between the tags.
  Both change the whitespace between and around tags and nothing else: tag names, attribute names, attribute order,
  attribute quoting, entity spelling and the words of the page all go back down as the exact bytes they were, and
  Beautify followed by Minify gives what Minify alone gives. Text is re-flowed only as far as collapsing runs of
  whitespace to one space and trimming a run where it meets a block tag; whitespace inside an inline element stays,
  since `<span>a </span><span>b</span>` renders a space and `<span>a</span><span>b</span>` does not. `script`,
  `style`, `pre`, `textarea` and `title` keep their content byte for byte, `</div>` inside a script included, and are
  never re-indented. HTML is forgiving and so is the walker: a stray end tag is emitted where it stands, an element
  whose end tag the author left out is written back without one, and nothing is ever added — no optional end tags
  are inferred, so `<ul><li>a<li>b</ul>` nests. The file's trailing newline is kept. The button points the other way
  — Minify — when the page has a newline anywhere outside a tag, a comment and a raw-text element, the file's own
  trailing newline not counted. The button is disabled, with the line in its tool tip, for what the walker cannot
  read at all: an unterminated comment, a tag or a quoted attribute value that runs off the end of the file, a
  raw-text element that never closes, or nesting past 256.
- Shipped: `HTMLPreviewView` is the column's third content view. The editor's text is loaded under `nota-file://`, whose
  path is the file's own, and `PageFiles` hands WebKit the bytes for everything the page draws. A `file://` base URL does
  not work: WebKit's page process is given permission to read a folder only by `loadFileURL`, so text loaded against a
  file URL renders with every stylesheet and picture beside it silently missing. A link the reader clicks becomes a
  `file://` URL again on its way to the browser. The page reports its own scroll on each frame, so a reload puts the
  reader back where they were.

## SQL preview (done 2026-09-05, Todo 6; second pass 6-A; third pass 6-B; the query's jump 6-C)
- A `.sql` file is a tab with a preview beside it, the way a `.md` is: the same three modes, the same floating mode
  control in each column's corner, ⌘P / ⇧⌘P and the View items, per tab and remembered in the session. The View item
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
  grew one callback for it, `onSourceReveal`: both halves select the source they point at, and the difference is the
  keyboard — a block click is a jump and takes it, this is a look and leaves it where it was.
- And inside that tuple, the clicked cell's own value (decided 2026-09-06). What the editor shows is not a caret at
  the row's head but a *selection* of that one value's text as written — its quotes part of it, the comma and the
  blanks around it not. `SQLSourceMap` walks the tuple once for it, honouring `'…'` with its `''` escapes, `X'…'`
  blobs, `NULL`, a negative number and a parenthesised expression written as a value, and counting only the commas
  at depth zero. Which value a column stands for is asked by *name* rather than by the grid's order, since the two
  need not agree: the list an `INSERT INTO t (b, a) VALUES (…)` gave when it gave one, and the table's own columns
  when it did not, so a query that asked for its columns in any order still lands on the right one. A cell that
  cannot be placed — a computed column of a query, a name in neither list, a tuple that will not read — is the whole
  tuple instead, and never nothing.
- Whatever dialect wrote the row (fixed 2026-09-07, Done 51). A `pg_dump`'s `COPY … FROM stdin` row is not SQL at
  all — no parentheses, no quotes, no column list anywhere near it — so its fields are placed by the tabs that
  separate them: a field is exactly what stands between two tabs, `\N` and an empty one included, named by the
  header's own list when it gave one and by the table's own order when it gave none, and a line too short for the
  column asked for is the whole row, the same fallback everything else takes. A `mysqldump`'s `INSERT` is rewritten
  on its way into SQLite, and a rewritten insert is an insert: its rows go on the map like every other row's, which
  they did not before, so clicking one of them pointed at nothing at all. Its `'Daniel O\'Brien'` is read as MySQL
  means it too — the backslash takes the quote after it with it — which is *not* how SQLite or a `pg_dump` with
  `standard_conforming_strings` writes a string, so the map is told which dialect it is reading rather than
  guessing: read it the wrong way round and every value after the escape lands somewhere it is not.
- And whatever else is picked out, in the same one call (done 2026-09-07, Done 49; a column across many rows fixed
  2026-09-07, Done 51). A run of whole rows — a click in the `#` gutter, a ⇧-click, Space — is the tuples those rows
  were written as, and not the values inside them, as *one* span from the earliest start to the latest end with
  whatever lies between them included, the way a selection over three paragraphs of text is one range. A rectangle a
  drag or a ⇧-arrow grew is one span *per row*: each row's own fields, spanned together with the separators between
  them, exactly as a single-row rectangle always was — so a column picked out of the grid is that column in the
  editor, and not the block of lines between its first row and its last, which one span over the lot used to make of
  it. The editor follows a drag rather than staying on the cell the press landed on: every mouse event that actually
  moves an edge says so again, and one that moves nothing says nothing. The schema is asked once per selection rather
  than once per cell, so a drag over a rectangle does not put a `PRAGMA table_info` to SQLite for every cell it
  crosses. Same rules as the single click throughout: split only, and the grid keeps the keyboard.
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
- ⌘F searches the grid (done 2026-09-07, Done 49): the same pill in the same corner, `Find in table`, the same counts
  and the same keys, in reading mode, where the grid is what is being read. In split ⌘F is the editor's, unchanged
  — and it stays the editor's after a click has put the first responder in the grid, which is why the rule is the
  pane's `takesKeyboard` and not where the first responder is. The grid and the query box both implement
  `performTextFinderAction(_:)`, which makes them the target whether they answer or not, so out of reading mode both
  hand the action straight back up the responder chain (`nextResponder?.tryToPerform`) and both keep the menu item
  enabled — it is the editor's find the key is about to run. The *whole* table is searched and
  not the hundred rows on screen, so `3 of 412` is exact and a match eleven pages down turns the page to it. It is
  one statement rather than a walk over the pages: `row_number()` over the very `ORDER BY` the page is cut with gives
  each hit its place in the table, and `instr(lower(CAST(col AS TEXT)), lower(?))` OR-ed over the columns is the
  sieve — which is case-insensitive for ASCII and exact for everything else, coarser than the editor's bar on
  purpose. Which columns of a returned row are the match is then decided in Swift from each value's *display* text,
  so `NULL` is the word on screen, a real is `12` rather than `12.0`, and a blob is its size. A query's result is
  searched the same way, over the reader's own query as a sub-select. ⌘F with the caret in the query box searches the
  rows rather than the five lines of the question. See the CSV section for the rest of the behaviour, which the two
  grids share.
- Untitled notes and every other extension have no SQL preview. Save As to `.sql` is what turns a note into one.
  `Examples/Shop.sql` is the demo: four tables that know about each other, and more rows than one page.
- A dump does not have to be SQLite's own (2026-09-07). A `.sql` from `mysqldump`, phpMyAdmin or `pg_dump` loads
  instead of stopping at its first foreign statement — "near SET: syntax error" on the `SET NAMES utf8mb4` every
  MySQL export opens with was the report. MySQL's session state (`SET`, `LOCK`/`UNLOCK TABLES`, `USE`), Postgres's
  (`SET`, `GRANT`/`REVOKE`, `SELECT pg_catalog.set_config`/`.setval`, `CREATE EXTENSION`/`SEQUENCE`, `ALTER … OWNER
  TO`, a constraint added after the fact) and psql's own `\` meta-commands are skipped as carrying no data;
  `START TRANSACTION` runs as `BEGIN`. A `CREATE TABLE`'s MySQL decoration (`ENGINE=`, `AUTO_INCREMENT`, `UNSIGNED`,
  a column's `CHARACTER SET`/`COLLATE`/`COMMENT`, `ON UPDATE CURRENT_TIMESTAMP`, `enum(…)`, `KEY`/`INDEX` lines — a
  column merely *named* `key` is a column) and Postgres's (`character varying`, `timestamp with/without time zone`,
  `boolean`, `numeric`, `bytea`, `json[b]`, `uuid`, `text[]`, `::text` casts, `DEFAULT nextval(…)`, `public.`
  prefixes, a `CHECK (… ANY (ARRAY[…]))`) are stripped before SQLite sees them, while `PRIMARY KEY`, `FOREIGN KEY`,
  SQLite's own collations and `WITHOUT ROWID` pass through, and `CREATE INDEX … USING btree` loses only the `USING`.
  MySQL's backslash escapes in a row's strings (`'O\'Brien'`, `\n`, `\\`) are decoded once the dump has shown
  itself to be MySQL's. A `pg_dump` `COPY table FROM stdin` block is read row by row into batched inserts, `\N` and
  its escapes resolved, `t`/`f` as 1/0 where the column was declared boolean, each row still traceable to its own
  line in the file. Anything still foreign stops the run as before, naming the statement as the file wrote it. See
  `SQLDumpDialect`. `Examples/sql/MySQL.sql` (a phpMyAdmin export) and `Examples/sql/PostgreSQL.sql` (a `pg_dump`
  export) are the same shop twice, with every spelling above in them, and the tests load both.

## CSV preview (done 2026-09-06, Todo 27)
- A `.csv` or `.tsv` file is a tab with a preview beside it, exactly the way a `.sql` is: the same three modes, the
  same floating mode control in each column's corner, ⌘P / ⇧⌘P and the View items, per tab and remembered in the
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
  clear for the floating Editor · Split · Reading control, so the pager at its trailing end is never behind it
  (an hour inside the band on 2026-09-07, with the pager pulled in, read worse). Refresh is one word on one line
  however narrow the column: the cell does not wrap, it truncates, and it is the last control on the bar to give way.
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
- A cell clicked selects that cell's own text in the editor, in split only and without taking the keyboard — the
  same `onSourceReveal` a dump's cell click uses, so the grid keeps the focus and the arrows go on walking the
  cells. The field *as written*, its quotes part of it, because they are the field's characters in the file
  (decided 2026-09-06). `CSVTable` takes both sets of ranges down as it reads — `sources` for the record and
  `fieldSources` for every field of it — so a record whose quoted field runs over three lines has all three and the
  record's range begins where the record begins. A cell that cannot be placed falls back to the whole record and
  never to nothing: a ragged row that never wrote the field the column stands for, and a click with no column under
  it. The header row is unchanged: a click there sorts.
- And whatever else is picked out, in the same one call (done 2026-09-07, Done 49; a column across many rows fixed
  2026-09-07, Done 51). A run of whole rows — a click in the `#` gutter, a ⇧-click, Space — is `sources`, the
  records' own lines, as *one* span from the earliest start to the latest end with whatever lies between them
  included, the way a selection over three paragraphs of text is one range. A rectangle a drag or a ⇧-arrow grew is
  one span *per row* — each row's own `fieldSources` it crossed, spanned together with the separators between them,
  exactly as a single-row rectangle always was — so a column picked out of the grid is that column in the editor,
  and not the block of lines between its first row and its last. The editor follows a drag rather than staying on
  the cell the press landed on: every mouse event that actually moves an edge says so again, and one that moves
  nothing says nothing. Same rules as the single click: split only, and the grid keeps the keyboard.
- Off the main thread, always: the read is asked on a serial queue and answered back on the main one carrying a
  token, so an answer about the file two keystrokes ago is dropped rather than drawn. An ordinary file is read again
  ~150 ms after typing stops, on the same debounce the Markdown render uses. A file past the `BigFile` threshold is
  never read on its own and typing after a read does not read it again; the `Refresh` button is what asks, and until
  it is pressed the pane says `Refresh to read this file.` A read the *reader* asked for keeps the sort and the page
  it was on; a read the *file* asked for drops the sort, since the columns may not even be the same ones.
- Nothing new is persisted: the mode the tab is in is all the session keeps, and `sqlTable` / `sqlQuery` stay a
  dump's. The file stays a text note in the editor — the preview is read-only and dirty and save semantics are
  untouched.
- ⌘F searches the table (done 2026-09-07, Done 49): the same pill in the same corner as every other column's,
  `Find in table`, `canReplace` off since a preview is read-only, and `3 of 412` / `412 matches` / `1 match` /
  `No matches` / `2000+` in the same words a document's says them. The *whole* table is searched in the order on
  screen — `CSVTable.ordering` and not the file's — so sorting by city changes which row the first match is on, and
  a match on the second page turns the page to it rather than being missed. Every match wears the editor's quiet
  band; the one being stood on wears AppKit's find yellow with its text spelled black, and *is* the cell cursor,
  since a match in a grid is a cell. The editor's caret follows it the way it follows a clicked cell — the field as
  it is written, quotes and all — and the query field keeps the keyboard. ⌘G and ⇧⌘G wrap and go on working with the
  pill down; ⌘E takes the cell the cursor is on for the query. Escape puts the bands down, leaves the reader standing
  on the match and hands the keyboard back to the grid. A refresh, a sort, a page turn, a re-run, a table pick — each
  one moves the rows under the list, so each one searches again and keeps the match the reader was on if it is still
  there; a page of other columns drops it. The bar row drops by the height of the pill while it is up, the same way
  the mode control does. Nothing of this reaches the file: a search is numbers held in `GridFindSession`.
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
- The same column lists what a tab that is read rather than edited offers instead — a book's chapters (see EPUB), a
  document's pages (see PDF). Three lists, one at a time: one split item, one width, one side, one ⌘B and one pin,
  and the tab's kind alone says which of the three stands in it. The lines arrive as a title, a nesting level and
  the line's own number, and the pages as a count, a thumbnail and where the reader is; the content view they came
  from is the only thing that knows what going there means, so one column serves every kind. A line is 13pt, one
  line truncated, indented 12pt a level, and the line naming what is on screen carries a grey wash — the ⇧⌘J
  switcher's own selection rather than a blue document one. A page card is the gallery's own card with a `Page N`
  caption, and the one in front wears the gallery's accent wash. A picture tab has nothing to list and keeps the
  column away, and every editable tab — `.md`, `.tex`, `.html`, `.svg`, a plain note — is the gallery as before.
- Each list stands under one word saying what it is, in the shape of Finder's own sidebar sections: 11pt semibold,
  secondary, at the list's leading margin (centred for an hour on 2026-09-06, then put back), with air above and below. `Images` over a note's pictures, `Contents`
  over a book's chapters, `Pages` over a document's pages. It sits at the top of the column, outside the scroll
  view, so it is still there when the list has been scrolled and still there when there is no list — an empty
  gallery says `Images` over its `No images`. After the word sits a count in a small capsule, 10pt semibold
  monospaced digits in the title's grey on a wash of it: how many pictures, how many pages, and over a book how
  many lines the contents have, sections included (chapters only for an hour on 2026-09-07, then the whole list).
  `0` is worn like any other number; the capsule is gone only while a column has not been told. The View menu keeps the longer names, which a menu has room for:
  "Image Gallery" over a note, "Table of Contents" over a book, "Page List" over a PDF, ⌘B and its tick unchanged in
  all three.
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
- One width for every tab, `clamp((viewport − plus − gaps) / n, 40, 180)`, shrinking as tabs are added; the strip never scrolls. The selected tab is raised to 60pt so its ✕ fits and the others shrink evenly to pay for it. Titles clip with a fade rather than an ellipsis; under 60pt the trailing slot goes and the unsaved dot rides on the icon. A separator hairline shows only between two plain tabs. The + rides after the last tab and pins at the trailing edge once the strip is full; it opens a new tab (same as ⌘T). ⇧⌘J fuzzy tab switcher by title.
- There is no colour in the strip, so how much `labelColor` a shape carries is the only thing that says what state it
  is in. The selected tab is the strongest mark in it — a rounded fill at 10% (12% dark), its title in `labelColor` —
  and the pointer's wash on an unselected tab is a clear step lighter at 3.5% (5% dark), its title staying
  `secondaryLabelColor`, so two tabs never read as selected at once. The selected tab takes no wash of its own. That
  wash fades in and out over the same 0.12s the tab's dot→✕ cross-fade takes, rather than snapping on beside it. The
  strip buttons (+, bookmark, gear) wear the same wash and fade, one step darker at 9% (11.5% dark) while held; the
  disc behind a ✕ is 10% (13% dark) and 18% (22% dark) under a press.
- The strip's top-right corner holds three buttons past the +, in this order (the first arrived 2026-09-07): a Bookmark button, `bookmark` and `bookmark.fill` once the front tab is one, which bookmarks that tab and unbookmarks it again — ⌘D by another door, tool tip "Bookmark" / "Remove Bookmark" with the key beside it, and greyed on a note with no file to bookmark; a Bookmark dialog button, Nota's own book-with-ribbon art rather than an SF Symbol (a template SVG in `BookmarksButton`, drawn at 14.5pt with a 5-unit stroke so its ink stands the same 12pt as the gear's; since 2026-09-07 — a closed book rather than a second loose ribbon, since two ribbons side by side said nothing about which was which); and, last before the reserve, a Settings gear (⌘, by another door). All three pin at the trailing edge, each in a 24pt slot with a 4pt gap; the tabs and the + step left by exactly the slots the visible ones take, and a hidden one hands its slot back and lets the rest close up.
- The switcher's first row sits above its search field and never filters away: "Add new tab", with a `plus`, which ↑ from the top of the list reaches and Return (or a click) turns into a new tab, ⌘T by another door. It is there in the `@` mode too. It is a one-row table of its own, sharing the list's cell view and taking the list's own resolved table style, so it is drawn as a list row — same inset, same rounded selection highlight, icon and title at the list rows' own x. In the bookmarks panel the row is the front tab's bookmark instead: "Bookmark this tab" with a `bookmark`, or "Remove bookmark from this tab" with `bookmark.fill` once it is one, and choosing it is ⇧⌘D by another door; with no tab to bookmark it is greyed and takes no selection.
- Every tab carries a leading icon for its kind, in the strip and in the switcher's rows, from `FileKindIcon`: a 96×64 rounded badge with the extension lettered inside it, drawn for 141 extensions and embedded as SVG text in the generated `FileKindArt.swift` (from `file-icon/` by `Icon/make-file-icons.py`). Every name gets one — a spelling the set did not draw twice folds onto the one it did (`.mjs` onto `js`, `.latex` and `.ltx` onto `tex`, `.zsh`/`.bash`/`.fish` onto `sh`, `.tif` onto `tiff`, `.mkd`/`.mdown` onto `md`, `.cc`/`.cxx` onto `cpp`, `.m`/`.mm` onto `c`), a name with no extension reads as `txt`, an unsaved note gets the lined-note badge (`untitled`: the rounded rectangle with three ruled lines, since 2026-09-07) and a kind nobody drew gets the `?` badge (`unknown`), so nothing falls through to an SF Symbol. Each stem is drawn twice, outlined and solid; a bookmarked tab draws the solid one. The badge is three units wide to two high, so its slot is 24 × 16 and it stands 15pt high beside an 11pt title. Heading rows keep their bare indent, with no icon.
- `@` as the switcher's first character (Done 9) swaps the list for the front `.md` tab's headings, indented by level, and the rest of the query fuzzy-filters those instead; `MarkdownHeadings` reads them straight from the note's own text — ATX and setext, fences skipped the way `MarkdownSourceMap` skips them — off the main thread once a note is past `BigFile.threshold`. A tab that is not `.md` answers with a quiet "No headings" row.
- Choosing a heading puts the caret at its line start and scrolls it into view; in split or reading the render is walked to that block too, by hand through the `highlightBlock(containingSource:)` a caret move already drives.
- The selected tab is always fully in view: at 40pt the strip stops shrinking and becomes a sliding window over the tabs, anchored on the selected one. Closing with the ✕ freezes the widths until the pointer leaves the strip, so a run of closes keeps each next ✕ under it; ⌘W does not freeze.
- Tabs reorder by drag: the dragged tab rides the pointer and its neighbours slide into the gap; the order is the session's order.
- Middle-click closes. ⌘T new, ⌘W close, ⌘1–9, ⌃Tab/⌃⇧Tab. Right-click a tab for Bookmark / Remove Bookmark, Reveal in Finder (greyed on an untitled note; the same item sits at the foot of the File menu as ⌥⌘R, for the front tab) and Close Tab. Closing the only tab leaves a blank Untitled tab in its place and keeps the window; closing that blank tab — no file, nothing typed — is what closes the window, the way the title-bar close button does: the last window hides, any other closes for real. So ⌘W pressed over and over walks every tab out, pauses on an empty window, and one more stroke closes it (decided 2026-09-07; before this, the last tab took the window with it).
- **Bookmarks** (Done 13). A bookmark is a file path, app-wide, kept in `session.json` beside the
  windows in the order they were added. ⇧⌘D bookmarks the tab in front — any named tab, PDFs and pictures included —
  and an untitled note is asked for a name first, staying unbookmarked if the save panel is cancelled. File ›
  Bookmarks holds that toggle (its title reads Remove Bookmark when the front tab is one), then every bookmark by file
  name with its kind icon and the full path as a tooltip, then Remove Missing Bookmarks; it is rebuilt on
  `menuNeedsUpdate` the way Open Recent is, except for the ⇧⌘D item itself, which is made once so the key equivalent
  is in the tree before the menu is ever opened; each bookmark's icon there is the filled art, 14pt high. A
  bookmarked tab draws its kind's icon filled in rather than outlined — the same badge, solid — and nothing is added
  to its corner, so the unsaved dot keeps that corner to itself. The ⇧⌘D picker fills a row's icon the same way:
  every bookmark row, and every open tab that is bookmarked. A `bookmark` button pins in the strip's top-right, in a 24pt slot of its own past where the +
  pins; `TabStripLayout` reserves it, so the tabs and the + step left by exactly that much and nothing subtracts it
  twice. Pressing it opens the ⇧⌘J panel in bookmarks mode: every bookmark, fuzzy-filtered by file name, ⌘⌫ (or ⌫ with
  the field empty) taking one off the list without closing the panel, and "No bookmarks" when there are none. Plain
  ⇧⌘J lists the bookmarks this window does not already have open under the tabs — both halves ranked by the same fuzzy
  match and merged by score, with an open tab taking any tie — carrying the `bookmark` symbol instead of a kind icon
  so they read as not-open-yet. A bookmark whose file has gone stays in the list, greyed to tertiary in the picker and
  disabled in the menu, and Return on it does nothing; it goes when it is removed by hand or by Remove Missing
  Bookmarks. Choosing one selects the tab if this window has the file open, and otherwise opens it, which is also what
  puts it in Open Recent.
- **Search all tabs** (Done 19, 37). ⇧⌘F opens that same panel a third way: the field reads "Search all tabs" and the
  query runs over every open tab through `NoteSearch`, live as it is typed and capped at `NoteSearch.resultLimit`.
  What each tab hands the search is its own (`Note.searchSource`): a note hands its storage string, a PDF hands its
  pages and a book hands its chapters, and a picture and a rich-text document hand nothing, there being nowhere in
  either to reveal a hit. A viewer's text is pulled off the file the first time the dialog asks and held with the rest
  of that tab's cache, so a second ⇧⌘F costs nothing and a file that changes under the tab is read afresh.
  A row is one hit — the tab's title small on top with that tab's kind icon, the line the
  hit sits on under it with the matched characters in bold — so the rows are two lines tall rather than the list's
  usual one. A hit on a page says which page it is printed on before the line ("Page 2 · …"); a note's and a
  chapter's say the line alone. There is no fixed row above the field in this mode: nothing it could mean, so ↑ from
  the top of the list stays put. An empty query lists nothing and says "Type to search all tabs"; a query with no hits
  says "No results".
  ↑↓ and the pointer move the selection, and Return or a click switches to that hit's tab and reveals it where it
  lives (`NoteSearchMatch.location`): a note's match is selected in the editor and scrolled in, a PDF's turns to its
  page and is selected on it, and a book's turns to its chapter and puts the query to that chapter's own find with the
  pill up — the reader lands on the chapter's first occurrence, the dialog having counted in the chapter's words and
  the page counting in its own document. The query goes onto the find pasteboard either way, so ⌘G carries on from
  there. Esc closes. The per-tab find bar (⌘F) is untouched.
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
4. **Half-bounce launch.** The Dock icon stops before its first bounce lands: a window with the strip and the
   selected tab's text on screen within ~300 ms of exec. Step 1 (done 2026-09-07): `LaunchTiming.swift` — marks
   at each launch phase, reported on stderr when the binary runs with `NOTA_LAUNCH_TIMING=1`. Then, in the order the
   numbers justify: housekeeping (cache prune, the launch-time session save, hotkey registration) after the first
   frame; the ten preview content views built lazily like the sidebars; tabs other than the selected one restored
   as shells and read on selection or in an idle pass.

## Done (the Todo ledger; numbers are the ones each item had while it was open, and code comments still cite them)
53. **The pills say what they are (done 2026-09-07).** All three floating pills led with an SF Symbol — a
    magnifying glass wearing a chevron, two arrows wearing another, an arrow-to-line — and each field carried a
    placeholder saying the same thing again ("Find in note", "Find in page", "Replace", "Go to line"). Each now
    leads with one word instead, set in the field's own size: `Find`, `Replace`, `Jump`. No chevrons, no
    placeholders anywhere, and the three "Find in …" strings are out of every localization table. The word is
    `secondaryLabelColor` until the keyboard is in that pill's own field and `labelColor` while it is, so in the
    two-pill stack Tab moves the light from `Find` to `Replace` and back; `PillTextField` notices the field
    editor arriving (`becomeFirstResponder`) and leaving (`textDidEndEditing`), which is one mechanism for all
    three pills. A window merely going inactive ends no editing, so the word stays lit while Nota is in the
    background, as the caret stays where it was. `Find` is still the replace toggle where there is anything to
    replace and inert where there is not; `Replace` still folds its own pill away. And both keys are toggles
    now: ⌘R over a row that is out folds it, ⌘F over one folds it and refocuses the query field, and `hide()`
    takes the row down so the next ⌘F is find-only — the row used to outlive the bar and come back uninvited.
    `PillWord` / `PillWordButton` / `PillWordLabel` and the colour rule live in `Pill.swift`; the toggling is
    `TextFindSession.show` / `showReplace` / `hideReplace` / `hide`.
52. **Mermaid diagrams inside Markdown (done 2026-09-07).** A ```` ```mermaid ```` fence draws as a diagram in the
    preview, read and laid out and drawn by Nota itself — the honest option (a) from the note, native parse plus
    native layout, no WebView and no mermaid.js. `Mermaid.swift` is the one door: it names the grammar off the
    first meaningful line and hands the source to that grammar's own file, so `flowchart` / `graph` and
    `sequenceDiagram` are built and tested apart and neither knows the other exists. `MermaidFlowchart.swift` is
    the flowchart: every bracket pair, every arrow and end cap, the four ways an edge label is written, chains,
    `&` fans, nested subgraphs, and the styling directives it parses only so it can ignore them; then a Sugiyama
    layout — back edges reversed, longest-path ranks, barycenter sweeps, a dummy node in every rank a long edge
    crosses; then drawing through `MermaidPalette`, whose colours are resolved at draw time so one layout is right
    in both appearances. The fence is lifted out of the note in `MarkdownMath`'s one pass, beside the maths and for
    the same reason, and comes back as `MermaidAttachment` — centred with a display formula's air, scaled down to
    a narrow column. `MermaidSequence.swift` is the sequence diagram, written the same afternoon in a parallel
    worktree against the same door: participants and actors, the eight arrow forms, activations, self-messages,
    notes, every frame kind with its dividers, `autonumber`; the lane layout spaces lifelines so every label between
    two neighbours fits, and headers stand top and bottom. Both files build their labels with
    `kCTForegroundColorFromContext`, so a label is the palette's colour and not CoreText's default black — the dark
    render was unreadable until it was. Nothing is lifted out unless `Mermaid.canDraw` says it can be drawn, so a
    `gantt`, a bracket that never closes and a half-typed arrow all stay the code block they already were. Pinned by
    `MermaidFlowchartTests` (the grammar, the layout, a fuzz run, a draw that has to leave ink),
    `MermaidSequenceTests` (the grammar, the lanes, ink in both appearances) and `MarkdownMermaidTests` (the seam,
    the fallbacks, the source map, the maths beside it).
51. **Nota's own Save dialog (done 2026-09-07).** `NSSavePanel` is gone from Save and Save As. `SaveDialog` is a
    sheet on the window with two rows — "Save As:" (the base name, selected and first responder, with the Format
    popup at the field's end: `SaveNameComposer.knownExtensions()`, carrying a remembered extension the list does
    not know) and "Location:" (read only: the folder's icon and name, the whole path in its tooltip) — over Cancel and a default
    Save. `Choose…` is the one thing left to the system, an `NSOpenPanel` for folders run modally over the dialog (nested in its own modal session).
    `presentSavePanel(for:)` keeps its signature and its synchronicity: `beginSheet` then `NSApp.runModal(for:)`
    until a button stops it, so `save(note:forcePanel:)` and every caller are untouched, and the `savePanelProvider`
    seam still stands the whole thing down for the tests. Save composes the URL with `SaveNameComposer` (a typed
    `notes.txt` still beating the popup), is unavailable while the name is blank, asks `confirmReplace` before
    writing over somebody else's file and stays put when the answer is no, and writes `lastSaveDirectory` /
    `lastSaveExtension` on the way out. Past the list, `None` saves the name bare and `Other…` opens a field for
    a typed extension (added the same day: the popup alone shut out a format it did not list). Every word goes through `L10n` and the dialog relabels itself on
    `Preferences.didChange`, so a language changed while it is open takes effect at once. `SavePanelReplaceValidator`,
    `saveFormatAccessory` and the `SavePanelForm` offsets are deleted. Pinned by `SaveDialogTests`.

51. **A column picked out of a grid is that column, not the lines it sits on (done 2026-09-07).** Dragging a
    rectangle over one column across many rows — a `Name` column, ten rows down — made the editor light every line
    in between: `sourceRange(of:)`, in both the `.csv` and the `.sql` pane, folded a selection of any shape into one
    span from its earliest thing to its latest, which is right for a run of whole rows and wrong for a rectangle,
    where the rows between two picked-out cells were never picked out at all. `onSourceReveal` (`PreviewContent` and
    every adopter) now carries an array of ranges rather than one: whole rows stay a single span, unchanged, and a
    rectangle is one span *per row* — each row's own fields spanned together with the separators between them,
    exactly as a single-row rectangle always was. `MainWindowController.revealSource` sets
    `NSTextView.selectedRanges` for more than one range, keeps `setSelectedRange` for one so nothing else about a
    plain click changes, and scrolls to the span of the whole selection so a column too tall for the screen shows
    what it can. Every other adopter — the render's block click, a dump's or a tree's single-row reveal, an HTML
    page's pressed element — hands back the one range it always did, now wrapped in an array of one.

    The same gesture over the two dialects' own dumps pointed at the wrong thing, or at nothing, so both are fixed
    beside it. A `pg_dump`'s rows are `COPY … FROM stdin` lines rather than tuples, which the tuple reader could
    make nothing of, so every cell of one fell back to the whole row: `SQLSourceMap.Statement` now says which shape
    it was written in (`Form.copyRow`, carrying the header's own column list), and a `COPY` row's fields are placed
    by the tabs that separate them — `\N` included, since that is what the file says there. A `mysqldump`'s inserts
    are rewritten before SQLite sees them, and the rewrite branch recorded no table and no rowids at all, so the map
    never claimed those rows and a click on one did nothing; both branches now take down what the insert made
    through one `SQLDump.insertRecord`. And MySQL's `'Daniel O\'Brien'` needed the scanner to know that a backslash
    inside a literal escapes what follows it, which standard SQL does not — `SQLSourceMap.backslashEscapes`, set
    from the dump's own dialect, since guessing either way puts every value after the escape somewhere it is not.
50. **Drag selects text in the render; a press in the page reveals its tag (done 2026-09-07).** Two halves of the same
    complaint: the preview column was readable and not usable. In a `.md` or `.tex` render every press was a block
    click, so there was no way to drag a sentence out of the rendered page — the gesture was spent before it began.
    It now waits: `super.mouseDown` runs AppKit's tracking loop, and the block click is reported afterwards, only for a
    press that neither moved nor selected anything. Double- and triple-click keep their word and paragraph, the pane
    still refuses first responder in split, and a selection leaves the band alone. In a `.html` page the spec said "no
    block sync" and meant it, which was true of a *list* of source ranges and too strong as a rule: the page can say
    which element was pressed in document order, and `HTMLSourceMap` can line that up against the start tags
    `HTMLFormat`'s walker finds in the file. The alignment is deliberately timid — it skips the DOM's implied and
    script-made elements, recovers within four tags, and gives up with `nil` rather than pointing at the wrong one —
    and it reveals rather than jumps, the same `onSourceReveal` the tree and the grids send. Pinned by
    `HTMLSourceMapTests` (9), three tests in `MarkdownPreviewTests` and two in `HTMLPreviewTests`. The same pass gave
    a page's fields the keyboard: clicking an `input` in split focused it in the DOM and nothing typed reached it,
    since `HTMLPageView` refuses first responder there. A `focusin` / `focusout` script now says when the page holds
    an editable element, and for exactly as long as it does the view takes the keys — the one exception to "a click
    in split must not steal the caret", ended by losing the field or losing the keyboard, and never by snatching the
    keys back. Two more `HTMLPreviewTests`.
49. **⌘F over a grid (done 2026-09-07).** A `.csv` and a `.sql` tab's find was the editor's in every mode, and the
    spec said so on purpose: a page of cells is not text, and the find bar's machinery bands ranges in a text
    storage. But the reader looking for a customer in four hundred rows has no business retyping them as a `WHERE`,
    and a `.csv` has no query box to retype them into at all. So the grid has its own: `GridFindSession` over
    `SQLGridView`, the third telling of the shape `TextFindSession` and `PDFFindSession` share, and a small
    `GridFindSource` both panes adopt — `matches(for:limit:)`, where the page on screen starts, what a cell says, and
    "turn to this row". The whole table is searched and never the page, which is the only thing that makes the count
    and the wrap mean anything; a match is a pair of numbers, the band is drawn by `SQLCellView` under the selection
    wash, and the current match *is* the cell cursor. The two panes answer the search in completely different ways
    and the session knows neither: the table walks `CSVTable.ordering` in memory, and the dump asks SQLite one
    statement — `row_number()` over the page's own `ORDER BY` for the row's place, `instr(lower(CAST(… AS TEXT)))`
    OR-ed over the columns for the sieve — since walking a table of two hundred thousand rows a page at a time is a
    `LIMIT … OFFSET` per hundred, each reading everything before it. That sieve is coarser than the editor's bar
    (ASCII case, no diacritic folding) and deliberately so; which columns of a returned row are the match is decided
    afterwards in Swift, from the display text, so a `NULL` and a real behave like what the reader sees. Landing on a
    match turns the page through the pane's own paging and never scrolls to the top, and the editor's caret follows
    it the way a clicked cell takes it. `SQLGridView` and the query box both forward the nil-targeted Find items in
    reading mode and hand them back up the chain out of it, so ⌘F reaches the grid from either and stays the
    editor's in split even with the first responder in the grid. In the same pass the editor stopped being shown
    only the first cell of a gesture: `SQLGridView.onSelectionReveal` says every *other* thing the reader does — the
    gutter, a ⇧-click, a drag, Space, a ⇧-arrow — and one function per pane turns the grid's `Selection` into one
    span, so a run of rows is the records or the `INSERT` tuples they were written as and a rectangle is the values
    it crossed. Pinned by `GridFindTests` (22).
48. **New file icons, filled when bookmarked (done 2026-09-07).** The old set was a 200×200 document outline with
    the extension lettered under it, and at 16pt in the strip nobody could read which kind it was. Replaced by a
    96×64 rounded badge with the extension lettered *inside* it, drawn for 141 extensions and drawn twice — outlined
    and solid — in `file-icon/icons` and `file-icon/icons-filled`. `Icon/make-file-icons.py` now reads both from this
    repo and writes `FileKindArt.outline` and `FileKindArt.filled`, shortening every coordinate on the way (two
    decimals at or above 1, six significant digits below it, since the glyph groups carry a `scale(0.018018 …)`);
    the export's 15-digit floats would otherwise have put 1.4 MB of decimal places into the binary. The set covers
    enough that no name reaches an SF Symbol any more: an unnamed spelling folds onto one that was drawn, no
    extension reads as `txt`, an unsaved note gets an empty badge and an unheard-of kind a `?`. The badge is three
    units wide to two high, so the strip's and the picker's icon slots became 24 × 16 (and `minInactiveWidth` 44 with
    them) and the art draws 15pt high beside an 11pt title. Bookmarking a tab now fills its icon in rather than
    putting a 7pt `bookmark.fill` on the corner of it — one mark, the same kind, and the unsaved dot gets that corner
    back. Same rule in the ⇧⌘D picker and in File › Bookmarks; the Bookmark button's own `bookmark`/`bookmark.fill`
    pair is untouched.
47. **⌘F over a tree preview (done 2026-09-07).** A `.json`, `.yaml`, `.toml` or `.xml` tab's find was the
    editor's in every mode, so reading mode — where there is no editor on screen at all — had no search. The tree
    has its own now: `TreeFindSession`, the third of the shape `TextFindSession` and `PDFFindSession` share, with
    the same pill floating in the same corner, the same five actions, the same `2000+` cap and the same words in
    the count. It is searched by what it *shows* — the key a file names a member with and the value as the row
    spells it, quotes and all, a comment counted as its text — case- and diacritic-insensitively, in the order the
    file writes the rows, a node's key before its value. Landing on a match opens every branch above it through
    `expandedPaths`, so the next parse keeps what the search opened, and collapses nothing: what the reader left
    open is theirs. There is no storage here to lay a temporary attribute on, so the bands are a background colour
    on the row's own attributed string — the editor's quiet wash on the others, AppKit's find yellow with black
    type on the one being stood on — and a query, a step and a re-parse each ask for the rows they touch to be
    drawn again. The editor's caret follows the *part* that matched: the value alone where the value did, the whole
    member where its key did, and in reading mode as well as split, since a find is the reader saying where they
    want to be. Escape puts the bands down, leaves the row selected and hands the keyboard back to the outline;
    ⌘G goes on working with the bar closed and brings the bands back with it. In split the editor keeps ⌘F,
    whatever was last clicked in the column: the outline answers `performTextFinderAction:` only while it is what
    is being read, which is the rule the page keeps, and otherwise hands the item *on* rather than dropping it —
    implementing the selector at all makes the outline the target, so a silent return greyed ⌘F out the moment a
    reader clicked a row. It goes up the chain to `MainWindowController`, which sits after the window and now
    answers for the Find menu itself (`performTextFinderAction:` into its own `TextFindSession`, and
    `validateUserInterfaceItem` saying what a text session handles). One fallback there serves every column. A re-parse runs the query again over the new rows and keeps
    the match being stood on if the same part of the same node is still there. Pinned by `TreeFindTests`.
    The same pass made the wrong-format state presentable, since a search over a file that is not a tree is a
    search of nothing: the one column is now held to the pane's own width, so a leaf holding a pasted page is
    cut off with an ellipsis rather than running off the edge; a file that parses into a single plain value is
    told the same news as a failure rather than shown as one enormous row; and the centred line became a
    centred block — the format named in `labelColor`, the line and the reason quieter under it, and, where
    `FormatDetector` reads the text as something else, the way out named in the reader's own terms: "It reads
    as HTML — choose that in the footer's format badge." Pinned by `TreeErrorTests`.
46. **A broken drawing gets a readable page (done 2026-09-07).** An `.svg` that would not parse — an empty one, on a
    fresh tab called SVG from the footer — went to WebKit as it stood, and WebKit's XML error page came back: black
    type in a pink box over a dark column, with the find bar's injected `::highlight` rules printed under it as
    text. `SVGCheck.problem(in:)` runs an `XMLParser` over the text first and `HTMLPreviewView.svgProblemPage`
    is what a failure shows, `color-scheme: light dark` and `CanvasText` so it reads in either appearance, the
    message escaped so a `<` in it stays a character. Pinned by
    `HTMLPreviewTests.testABrokenDrawingIsNamedBeforeWebKitSeesIt`.
45. **A Bookmark button in the strip, and a page in the corner (done 2026-09-07).** Bookmarking the tab in front
    was ⌘D or a trip through File › Bookmarks; the one bookmark button the strip had opened the picker instead,
    which is the list and not the act. There are three buttons past the + now — Bookmark, Bookmark dialog, gear —
    and the first of them is the act: `bookmark` while the tab is not one, `bookmark.fill` the moment it is, the
    same pair the badge on the tab's own icon wears, both in `secondaryLabelColor` rather than the accent. It is
    told what to say wherever the strip is refreshed, so a tab switch, a save, a rename and another window
    bookmarking the same file all reach it. A note with no file is asked for a name first, exactly as ⌘D asks —
    the button was greyed there for an hour, and so was the dialog's own "Bookmark this tab" row, until the
    user asked for ⌘D's behaviour from both doors. The dialog's row hands the toggle to the next turn of the run
    loop (`RunLoop.main.perform`): run inside the row's own click, in a non-activating panel that had just
    ordered itself out, the save panel never came up and the row stayed lit. Pinned by
    `BookmarksTests.testTheStripButtonAndTheDialogRowAskAnUntitledNoteForANameLikeCommandD`.
    The button beside it kept its job and changed its picture to
    `book.closed`: two bookmark ribbons in a row said nothing about which was which, and the second one is a list.
    `TabStripLayout` grew a third slot on the same 24pt-and-4pt rule, and a hidden button hands its slot back and
    lets the rest close up rather than leaving a hole. Settings › Tab bar lists all three — Bookmark button,
    Bookmark dialog button, Settings button — and the older `hidesBookmarkButton` key stayed with the dialog
    button it has always meant, the new row writing `hidesBookmarkToggleButton`. The corner slot's Editor segment
    changed drawing in the same pass: `long.text.page.and.pencil`, a page with a pencil on it, where the bare
    `pencil` only ever said "write".
44. **A rule under H1 and H2 (done 2026-09-07).** Set beside GitHub's render, Nota's had no line under a section's
    title. The two top levels now carry `notaHeadingRule`, and `RenderedPreviewView` draws a `separatorColor` hairline
    4pt under each one's last line, margin to margin, inside the extra air those two levels are given below (0.55em
    against 0.3em). Drawn, not spelled: an earlier cut appended a rule paragraph and moved every rendered string and
    click range along with it. Pinned by `MarkdownPreviewTests.testALevelOneOrTwoHeadingCarriesTheRuleAttribute` and
    `testThePaneDrawsAHairlineUnderALevelOneHeadingAcrossItsFullWidth`.
43. **The footer says what a tab is, and Nota offers to guess (done 2026-09-07).** A tab's preview came from its
    file extension and from nothing else, so a note pasted into a fresh tab had to be saved as `.md` before it
    could be read as anything. There is a fourth badge in the footer now, ahead of the encoding, showing what the
    tab is read as — `Plain Text`, `Markdown`, `JSON`, one of eleven (shortened to `Plain` and `MD` on 2026-09-07) — and its menu is the whole feature: pick one
    and the corner segments, ⌘P, the split, the icon and the task count all follow at once. `NoteFormat` is
    `RenderedPreviewKind` with the ordinary case put back, since plain text has no preview to name; the choice
    lives on the note as `formatOverride`, honoured by `previewKind`, `isJSON` and `isHTML`, and written to
    `session.json` as the one spelling that means that format. Picking what the file name already says puts the
    override down rather than writing it, and a save under the format's own extension does the same — the name is
    saying it now. Saved as something else, the reader's word stands. The save panel opens its Format combo on the
    badge, so a tab called JSON writes `blob.json` with no second decision — and a *file* the reader has renamed
    the format of goes dirty and owes a name for it: ⌘S there is the Save As flow, `md` picked in the combo and
    every other extension still there to pick instead, and once the panel has been answered the next ⌘S writes
    where that one landed. `Note.needsSaveAs` carries it, and `SessionTab` writes it only where it is owed. `FormatDetector` is the
    guess: a pure, deliberately shy look at the characters, `nil` under three lines or sixty characters and `nil`
    for prose with a colon, a list of dashes, or three paragraphs. `FormatOfferPill` puts it to the reader in the
    reload offer's corner — `JSON detected` · Preview in JSON · Not now — non-modal, one debounce after the typing
    stops, once per tab per reading, and **untitled notes only**: a file has a name, and a name is its author
    saying what it is. A paste or a drop is the other half and asks properly: `FormatOfferAlert` is a sheet on the
    window, *Preview this tab in Markdown?* with the change-it-later line under it, **Preview in Markdown** on
    Return and **Not now** beside it. Nothing is interrupted there — the typing an alert would have stopped is not
    happening — and one question stands at a time, the pill going down as the sheet comes up. Either word does what
    the pill's does, "Not now" included. A `Format` row in Settings › Status bar switches the badge off, and
    the badge is the region that gives way in a narrow window rather than widening it. `FormatDetectorTests` (30)
    and `FormatOfferTests` (42).
42. **Settings apply as you change them (done 2026-09-07).** The window had one shared Save button and every
    control staged a draft behind it, so a setting was two gestures and a greyed button said whether the second
    one was owed. The button is gone: each control writes its own preference on the change, and the app follows
    at once. Language and theme rebuild the dialog afterwards, as Save used to. A shortcut is the one thing that
    can still be refused — a combination two commands would share, or one the Mac has spoken for, is not written,
    the field snaps back to the stored key and the red line says which two commands would have shared it. Pinned by
    `NotaTests.testSettingsHasNoSaveButtonOnAnyPage`, `NotaTests.testFlippingHighlightCurrentLineAppliesWithNoSave`
    and `ShortcutsTests.testATakenComboWarnsAndIsNeverWritten`.
41. **The cursorline at the end of the document (done 2026-09-07).** With the caret after the last character the
    band lit every line: `lineBand` had no glyph to ask about at that index and fell back to the whole view. It
    now takes the extra line fragment when the text ends in a newline or is empty, and the last glyph's line
    otherwise. Pinned by `NotaTests.testTheCursorlineBandAtTheEndOfTheDocumentIsOneLine`.
40. **Less air at the top of the tree (done 2026-09-07).** The tree pane started a whole corner-slot band (44pt)
    down; it starts at the editor's padding (14pt) now. The CSV bar was moved up the same way with its pager pulled
    in clear of the capsule, and put back under the band the same evening — the pager belongs at the edge; later that day the CSV bar's top came up from the band's 44pt to 36pt, 8pt under the control's bottom edge, since the whole band read as a hole (the SQL pane keeps the band). Refresh
    on the CSV and SQL bars no longer folds into two lines or shrinks to its icon: it is the last control to give way. The tree's list also read a shade off the editor in the dark (27 to the editor's 30, measured off a
    screenshot) though every part of it was given `textBackgroundColor`: an `NSOutlineView` paints that colour its
    own way. So nothing in the scroll view paints a background any more — the outline is `.clear`, the scroll view
    does not draw — and the pane's own layer, which already matched the editor, is the one background. Pinned in
    `CSVPreviewTests` and `StructuredPreviewTests`.
39. **The contents column owns the hover (done 2026-09-07).** A contents row tracked the pointer itself and kept its
    wash after the list scrolled under a still pointer — every row that passed under it was entered and none
    exited, so a whole column read as hovered. `ContentsSidebarView` has the one tracking area now, works out the
    row under the pointer from its position, and works it out again on every scroll of its clip view; the page
    cards and gallery cards never had a hover wash. Pinned by
    `MarkdownPreviewTests.testScrollingUnderAStillPointerWashesOnlyTheRowUnderIt`.
38. **The picker keeps the keyboard (done 2026-09-07).** The ⇧⌘J / ⇧⌘D / ⇧⌘F panel is a non-activating
    floating panel that hides with Nota and comes back with it; on the way back key went to the main window,
    so the field had no caret and Esc closed nothing until the field was clicked. `TabPickerPanel` now
    listens for the app becoming active and for the panel becoming key, and if the panel is showing makes it
    key and puts the caret back in the field (`refocusIfShowing`). Pinned by
    `NotaTests.testThePickerTakesTheKeyboardBackWhenNotaReturns`.
37. **⇧⌘F searches documents and books too (done 2026-09-07).** The dialog was a search of open *notes*; it is a
    search of open *tabs* now, and it says so — "Search all tabs", "Type to search all tabs", in all four languages.
    `NoteSearch` takes a `NoteSearchSource` per tab rather than a title and a string: `.text` for a note, `.pages`
    for a document, `.chapters` for a book, each part searched on its own so a hit can say where it lives.
    `NoteSearchMatch.location` is that answer — `.text(NSRange)`, `.pdf(page:range:)`, `.book(chapter:range:)` —
    and `rangeInText` is still the range inside whatever run it was found in, so nothing that only ever had text
    had to change. `Note.searchSource` builds one: a note's storage string, a document's pages through
    `PDFPage.string`, a book's chapters through `EPUBBook.words(ofChapter:)`, which walks the XHTML and keeps
    block elements on lines of their own. Whatever the file had to be read for is held on the note and dropped by
    `discardLoadedContent`, so it is one read per tab and not one per keystroke. Revealing a hit is per kind:
    `PDFPreviewView.reveal(page:range:query:)` goes to the page and hands `PDFFindSession.reveal` the
    `PDFSelection` that range maps to (the pill stays down; the query is adopted so ⌘G walks on), and
    `EPUBPreviewView.reveal(chapter:query:)` turns to the chapter and calls `HTMLFindSession.find`, which puts the
    query in the pill and searches the page as it lands — the reader gets the chapter's first occurrence, the two
    ends counting in different text. A page's row wears its number, "Page 2 · …". Pinned in `NotaTests` (the
    locations and the snippets), `PDFTests` (a word on the second page found, chosen, and selected there) and
    `EPUBTests` (a chapter's words, and a hit in the second chapter turning to it with the query put to its page).
36. **Highlight current line (done 2026-09-07).** A Settings › Editor toggle for the quiet band vim's
    `:set cursorline` already drew. `NotaTextView` takes two inputs now, `highlightsCurrentLine` (the
    preference) and `vimCursorLine` (vim's own), and derives the drawn `showsCursorLine` as either one being
    on — so `:set nocursorline` never dims a band the preference asked for, and the preference going off
    never touches vim's. `Preferences.highlightsCurrentLine`, default off; `MainWindowController` pushes it to
    the text view alongside the gutter separator. Pinned in `NotaTests` (the Settings draft and Save reaching
    an open window) and `VimStage3Tests` (the two inputs not fighting).
35. **Keys and chrome (done 2026-09-07).** Jump to Line… ⌘J (was Go to Line… ⌘L), Jump to Tab… ⇧⌘J (was Tabs
    Dialog ⌘P), Mode Toggle ⌘P, Reading Mode ⇧⌘P, Find and Replace… ⌘R; Minimize keeps ⌘M (it was briefly given
    to Mode Toggle, then put back). "Go to" reads "Jump to" in every title and translation; the code keeps
    `goToLine` / `goToTab` / `GoToLine.swift`. The Shortcuts row for ⌘B is "Sidebar" and
    ⇧⌘F's is "Search All Tabs…" (`ShortcutAction.titleKey`; the View item's per-tab name is untouched). The
    three Settings footnotes are gone. In the find bar the glass wore a chevron where there was anything to
    replace, pointing down and muted whether the pill was away or out, and the replace pill's arrows were a
    button with a chevron up in the label colour that folded the pill away (`ReplaceBarView.onCollapse`); both
    were drawn by `PillView.symbolWithChevron`. Superseded by Done 53 — the glyphs are words now, and
    `symbolWithChevron` is gone with them.
34. **Settings tidy-ups (done 2026-09-07).** The About page's update line is a plain wrapping label with a
    360pt `preferredMaxLayoutWidth`, not a `WrappingLabel`: that class hugs and resists at low priority so a
    stretched page can size it, and the centred About stack stretches nothing, so it folded to a word a line
    in every language. Pinned by `NotaTests.testTheUpdateLineIsOneLineNotAColumn`. The Shortcuts page's Summon
    footnote moved behind a `?` — `SettingsRowView` takes an `accessory` after its label, `row(help:)` makes the
    `helpButton`, and `showHelp` opens one transient `NSPopover` with the sentence. Pinned in `ShortcutsTests`.
33. **A count beside every sidebar title (done 2026-09-07).** `SidebarCountBadge` in `SidebarCards.swift`, worn by
    `SidebarSectionHeader` after its word: the gallery sets it to its pictures, the page list to its pages, the
    contents to every line it lists. Zero shows as `0`; only a header never
    given a count goes without one. Pinned in `PDFTests`, `EPUBTests` and the gallery's own title test.
32. **"Check for Updates" on the About page (done 2026-09-06).** Nota ships as a GitHub Release and a Homebrew
    cask, and a reader who installed it once had no way to learn a newer one existed short of visiting the repo.
    The About page asks now: one button, one anonymous request to the releases API, one line of answer, and
    nothing kept between launches. `UpdateCheck.swift` is the whole of it — the request, the parse of `tag_name` /
    `html_url` / `name` / `published_at`, the dotted-integer comparison that puts `1.0.18` below `1.0.19` below
    `1.1.0`, and a `Reason` per failure so the page can word a rate limit differently from a 500. The transport is
    a closure defaulting to `URLSession.shared`, so every test answers it in-process and the suite never reaches
    the network.
    Stage one only: it checks and points, it does not install. A self-updater was rejected because Nota is
    ad-hoc signed — a copy that replaced itself would hand the reader a bundle macOS distrusts, and the honest
    fix is signing, not a downloader. Sparkle was rejected because the project carries no packages at all and one
    update button is not the thing to break that for. What the button offers therefore depends on where the copy
    came from: a Download button to the release page, or, for a cask, `brew upgrade --cask nota` as selectable
    text — because a cask install updated by hand would leave Homebrew's metadata behind and stale. Homebrew is
    detected by the Caskroom *directory*, not the bundle path: a cask moves `Nota.app` into `/Applications` and
    leaves only a symlink behind, so the app itself looks hand-copied.
31. **The zoom pill (done 2026-09-06).** ⌘+ / ⌘- / ⌘0 zoom a document or a picture, but the keys had no visible
    counterpart, so a reader who did not know them had no way to find the feature at all. `ZoomPillOverlay` puts a
    small pill — `−  100%  +` — in the bottom-leading corner of the column, the mode control's own bezel at the
    other end of the diagonal, fading in on a zoom and holding a second and a half or for as long as the pointer is
    in the band along the bottom, whichever is longer. It asks the content in front for `zoomPercent`
    (`PreviewContent.swift`) rather than knowing what is being zoomed, so a render, a dump and a table simply have
    no pill, and a document arriving in front of another takes the old number away at once instead of fading it out.
30. **A `.json`, `.yaml`, `.toml` or `.xml` is read as the tree it is, and the corner slot grew a fourth option
    (done 2026-09-06).** Four of the commonest files a developer opens were bare text notes: a compact
    `Settings.json` was one 900-character line, and the only thing Nota offered it was a lone Beautify button in
    the corner. They are tabs with a preview beside them now — the tenth content view the column holds — and the
    preview is the document as a collapsible tree. `StructuredDocument.swift` is the shape all four parsers hand
    back, which is what lets one `TreePreviewView` serve four grammars: named parts, numbered parts, leaves, and
    the 1-based line every node starts on. `JSONTree` is Nota's own recursive descent over the bytes and a second
    walker beside `JSONFormat` on purpose — that one keeps tokens verbatim so beautify and compact are lossless,
    this one unescapes them so a row can be read — and `XMLTree` is Foundation's `XMLParser`, taken for the one
    thing it already knows and a scanner would have to earn: the line every event happened on. `YAMLTree` and
    `TOMLTree` are their own files with their own rules, written alongside — each in its own parallel worktree,
    merged the same day.
    The view is an `NSOutlineView` rather than a render, because a tree is opened and closed rather than read: the
    triangles, ⌥-click and the arrow keys all come with it. It opens whole below 400 nodes and two levels deep
    above that, re-parses on the render's own debounce keeping what was open by node path and where the reader had
    scrolled to, colours values by type in system colours that read in both appearances, and carries both halves of
    the block sync — a click selects the whole node, key and value, without taking the keyboard, and the caret lights the
    deepest node whose span it is standing in, so a one-line export is walked the same way a pretty-printed one is.
    Because a `.json` now has a render, the corner could no longer offer it a lone button beside a mode control it
    had just earned. So the slot holds one capsule with a fourth segment on the end: the three modes, then the
    file's own Beautify / Compact, `.selectOne` still, the click firing the action and the selection going straight
    back to the mode it was on. `.html` joins it with Beautify / Minify through `HTMLFormat`, so `ModeControlOverlay`
    lost `.jsonFormat` and its button and gained `.modeControlWithFormat(FormatKind)`, and the window's
    `refreshJSONSlotState` / `applyJSONFormat` became `refreshFormatSlotState` / `applyFormat` over a format kind —
    one path, two formatters, both columns kept in step. `HTMLFormat` was written in a parallel worktree and merged
    the same day.
29. **A PDF's sidebar lists its pages, and the outline it listed before is dropped (done 2026-09-06).** Done 22, a
    day earlier, gave the column a PDF's own outline. It was the wrong list: most PDFs carry no bookmarks at all, so
    the commonest document of all had an empty column and a `No contents` hint, and even where there was an outline
    it was a table of contents for a thing the reader navigates by page. The outline is gone from the column —
    `PDFOutlineContents` and the pane's `contentsEntries` / `currentContentsLine` / `goToContentsLine` with it — and
    a PDF now lists its pages: one card per page in the shape the gallery already draws a picture in, `Page N` under
    it, a click going to the top of that page, and the card for the page in front wearing the accent wash and
    following the reader through the document. Every document has pages, so the column comes up on its own for every
    PDF and the hint is only an outline-less EPUB's. The column now holds three siblings rather than two —
    `ImageSidebarView`, `ContentsSidebarView`, `PageListSidebarView` — picked by the tab's kind through
    `MainWindowController.SidebarList`, and the card and the section title they share live in `SidebarCards.swift`
    so the gallery and the page list cannot drift apart. `PreviewContent` grew `pageList`, a `PageListSource`
    answering for a count, the page in front, going to one and drawing one, so the window still asks the content
    view rather than switching on a kind; the source carries an identity of its own, since one pane shows every PDF
    tab in turn and two documents of the same length would otherwise look like the same list. Thumbnails are the
    cost that had to be designed around: drawn on one serial queue from a second `PDFDocument` of the file (PDFKit
    is not safe from two threads at once), only for the cards being looked at and a screenful either side, at 2× the
    card, cached per document for as long as the tab is open. Above each list is one word in the shape of Finder's
    sections — `Images`, `Contents`, `Pages` — outside the scroll view, so the column says what it is however far
    the list has been scrolled; the View item keeps the longer "Image Gallery" / "Table of Contents" / "Page List",
    from `sidebarListTitle` on the window rather than a flag on the menu.
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
    Sharpened to the cell (2026-09-06): the scanner also writes down where every *field* is written, quotes
    included, so a click selects that field's own text in the editor rather than the record it is in, with the whole
    record kept as the fallback for a ragged row that never wrote the field or a click with no column under it.

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
   Sharpened to the cell (2026-09-06): `SQLSourceMap` also locates the nth value inside a tuple — one walk honouring
   strings with their `''` escapes, blobs, `NULL`, negative numbers, a parenthesised expression and the commas at
   depth zero — and the column is placed by name, through the list an insert named or the table's own columns, so a
   click selects that value's own text (quotes included) and only an unplaceable cell falls back to the tuple.
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
   2026-09-05).** A book's contents were reachable only through `@` in the ⇧⌘J switcher — a list that closed the
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
   what the ⇧⌘J panel already does. It is now that panel's third mode: `TabPickerPanel.showSearch(notes:…)` alongside
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
3. **Go to line (done 2026-09-04).** ⌘J opens a pill in the find bar's own corner — the same `PillView` chrome, one
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
9. **Headings outline (done 2026-09-04).** `@` in the ⇧⌘J switcher lists the front `.md` tab's headings; choosing one puts the caret there
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
    tab shows a leading icon, per file kind (done 2026-09-04; custom art added 2026-09-04, redrawn 2026-09-07 —
    see Done 48): `FileKindIcon` maps the name's extension to a lettered badge, embedded by
    `Icon/make-file-icons.py` into `FileKindArt.swift` — and the same icon in the ⇧⌘J rows. Then, in this order:
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
