# Nota code map

Where things live, so a change starts in the right file. One line per file; the
file's own header comment says the rest. Line counts are rough and dated
2026-09-07. `SPEC.md` is the behaviour spec and the Todo/Done ledger; this file
is only the index.

Build: `swift build` · tests: `swift test --filter <Name>` (never the whole
suite while working) · app: `./build.sh` → `Nota.app` · icon:
`swift Icon/make-icon.swift` from `Icon/logo.png` · file-kind icons:
`python3 Icon/make-file-icons.py` from `file-icon/icons` and
`file-icon/icons-filled`.

## "I want to change…" → start here

| Change | File(s) |
|---|---|
| A menu item, its key, or app launch / windows / summon | `AppDelegate.swift`, keys in `Shortcuts.swift` |
| Anything in the main window: footer, split, modes, tabs, opening files, saving | `MainWindowController.swift` (see its sections below) |
| The Save dialog: its rows, its Format popup, or the extensions it offers | `SaveDialog.swift` (the dialog itself), `SaveNameComposer.swift` (pure logic), `MainWindowController.presentSavePanel` (which puts it up) |
| File › Export…: what a tab can be exported to, the sheet that asks, the pages themselves | `Export.swift` (the targets and the hooks other exporters plug into), `ExportDialog.swift` (the sheet), `PDFPaginator.swift` (text and plates onto pages), `MainWindowController` "Export" |
| The tab strip (drawing, drag, close, +, tear-off) | `TabBarView.swift`, geometry in `TabStripLayout.swift` |
| ⇧⌘J switcher, `@` headings (text notes only), bookmarks dialog, ⇧⌘F search dialog, hover/arrow selection | `TabPickerPanel.swift` (also `refocusIfShowing`: the caret back in the field when Nota returns from another app or space), ranking in `FuzzyMatch.swift` |
| Settings window (live apply, no Save; sidebar pages) | `SettingsWindowController.swift`, values in `Preferences.swift` |
| "Check for Updates" on the About page | `UpdateCheck.swift` (the request, the comparison, Homebrew detection), the button and its line in `SettingsWindowController.aboutPage` |
| A new preference | `Preferences.swift` (key + property + `announce()`), then Settings UI |
| A user-visible string or its translation | `Localization.swift` (`L10n.text`), the languages themselves in `Preferences.swift` (`AppLanguage`) |
| Editor typing, paste, drop, images in the text | `NotaTextView.swift`, tokens ↔ chips in `NoteText.swift` |
| What a file *is* (sniff), encodings, line endings | `TextFile.swift` (`FileSniff`, `TextFile`) |
| A tab's model: kind, dirty, file, session record | `Note.swift`, `Session.swift` |
| Markdown render look | `MarkdownRenderer.swift`, `RenderStyle.swift`; maths `MarkdownMath.swift` |
| A ```` ```mermaid ```` fence's diagram | `Mermaid.swift` (which grammar, and the one door), `MermaidFlowchart.swift` / `MermaidSequence.swift` (a grammar each: parser, layout, drawing), `MermaidAttachment.swift` (the block it becomes); the fence is lifted out of the source in `MarkdownMath.swift` |
| LaTeX render | `LaTeXParser.swift` → `LaTeXRenderer.swift`; formulas `MathParser.swift` + `MathLayout.swift` |
| Preview column plumbing (which view shows, zoom, scroll memory) | `PreviewPaneView.swift`, `PreviewContent.swift`, `RenderedPreviewView.swift` |
| PDF / picture / HTML / EPUB / RTF viewer tabs | `PDFPreviewView.swift`, `ImagePreviewView.swift`, `HTMLPreviewView.swift`, `EPUBPreviewView.swift` + `EPUBBook.swift`, `RTFPreviewView.swift` |
| A `.sql` dump's grid: running it, paging it, sorting it, picking cells out of it, ⌘F over it | `SQLPreviewView.swift` (the pane), `SQLGridView.swift` (the grid, its header and its cells), `SQLQueryBox.swift` (the query editor), `SQLDump.swift` (the database), `SQLDumpDialect.swift` (a MySQL or Postgres dump made SQLite's), `SQLSourceMap.swift` (which line of the file a row was written on, and where in it a cell's own value is), `SQLQueryRewrite.swift` (the rowid spliced into a query so its rows point at the file too), `GridFindSession.swift` (⌘F over the grid; `SQLDump.hits` is the one statement that answers it) |
| A `.csv` / `.tsv` file's grid: reading it, paging it, sorting it, ⌘F over it | `CSVPreviewView.swift` (the pane, over `SQLGridView`), `CSVTable.swift` (the RFC 4180 reader, `ordering` — the order the grid and its ⌘F walk — and where each record and each field of it is written) |
| ⌘F find bar and its match bands (incl. dark-mode colours) | `FindBar.swift` (chrome), `FindSession.swift` (editor; the fallback every column hands an unwanted Find item back to is `MainWindowController.performTextFinderAction`), `HTMLFindSession.swift` (`find(_:)` puts a ⇧⌘F hit's query to the page), `PDFFindSession.swift` (`reveal(_:for:)` lands on a ⇧⌘F hit), `TreeFindSession.swift` (a tree preview's rows), `GridFindSession.swift` (a `.csv` or `.sql` grid) |
| ⌘J go to line | `GoToLine.swift`, line table `LineIndex.swift` |
| Floating pill chrome shared by find / go-to-line / external-change / the format offer | `Pill.swift`, `ExternalChangePill.swift`, `FormatOfferPill.swift` |
| The corner slot (Editor · Split · Reading, plus a `.json`/`.html` tab's Beautify / Compact) | `ModeControlOverlay.swift` |
| The footer's format badge and its menu / what a tab is read as / the Save As it owes | `Note.swift` (`NoteFormat`, `Note.formatOverride`, `Note.needsSaveAs`), `MainWindowController` "The format badge" and `save(note:forcePanel:)` |
| The detector that reads a note's text / the pill after a typing pause / the sheet after a paste | `FormatDetector.swift` (pure), `FormatOfferPill.swift` (the pill and `FormatOfferAlert`), wiring in `MainWindowController` "The format offer" |
| Laying a `.json` file out or pulling it together | `JSONFormat.swift`; a page, `HTMLFormat.swift` |
| A `.json` / `.yaml` / `.toml` / `.xml` tab's tree beside its source | `TreePreviewView.swift` (the pane), the shape they all hand back `StructuredDocument.swift`, the parsers `JSONTree.swift` / `YAMLTree.swift` / `TOMLTree.swift` / `XMLTree.swift` |
| Reading a `.yaml`/`.toml` into the tree | `YAMLTree.swift`, `TOMLTree.swift` |
| Beautify / Minify a `.html` | `HTMLFormat.swift` |
| Which tag in the source a press in an HTML page points at | `HTMLSourceMap.swift`, the script and the wiring in `HTMLPreviewView.swift` |
| The zoom pill (`−  100%  +`) in the preview column's bottom-left | `ZoomPillOverlay.swift`, the percentage per content in `PreviewContent.swift` |
| Gutter / line numbers | `LineNumberRulerView.swift` |
| The sidebar column: a note's thumbnails, a book's contents, a PDF's pages, the title over each and the count badge beside it | `ImageSidebarView.swift`, `ContentsSidebarView.swift`, `PageListSidebarView.swift`, the card and the title they share `SidebarCards.swift`, which chips light up `ChipHighlight.swift` |
| Tab / picker / bookmark-menu icons, and the filled one a bookmark wears | `FileKindIcon.swift`, art in `FileKindArt.swift` (generated from `file-icon/`) |
| Bookmarks | `Bookmarks.swift` (store), `BookmarksMenu.swift` (File › Bookmarks) |
| Open Recent | `RecentDocumentsMenu.swift` |
| File changed on disk | `FileWatcher.swift`, handling in `MainWindowController` "External changes" |
| Search all tabs (⇧⌘F): text, a PDF's pages, a book's chapters | `NoteSearch.swift` (the search itself), what each tab hands it `Note.searchSource`, dialog in `TabPickerPanel.swift`, revealing a hit `MainWindowController` "Search across tabs" |
| Global summon hotkey | `GlobalHotKey.swift`, recorder `ShortcutRecorderField.swift` |
| Vim | `Vim/` (see below) |
| Big files, spell check | `BigFile.swift`, `SpellCheckPolicy.swift` |
| Task lists `- [ ]` | `TaskList.swift` |
| Return continuing a list (`1.` → `2.`, `a.` → `b.`, `- [ ]`) | `ListContinuation.swift` |
| Line ops (move/duplicate/comment/indent) | `LineOperations.swift` |
| Copying HTML in from browsers | `HTMLClipboard.swift` |
| Attachments (`Image N` chips, asset store) | `Assets.swift`; pictures beside a saved file `Sidecar.swift` |
| Many windows | `WindowRegistry.swift` |

## Sources/Nota — by area

### App shell
- `main.swift` (7) — entry point.
- `AppDelegate.swift` (~500) — menu bar (`buildMenu`, rebuilt on language or shortcut change), launch, theme apply, summon, window registry, `application(_:open:)`.
- `WindowRegistry.swift` (~210) — every open window, which is in front, where closing tabs go.
- `Preferences.swift` (~570) — every setting (`UserDefaults` + `Preferences.didChange`), enums `EditorFontFamily`, `LineSpacingOption`, `SidebarSide`, `PlainTextImageStyle`, `EditorPaddingOption`, `AppLanguage`, `AppTheme`; `shortcuts` table, `hotKey`; window chrome (`hidesTabBar`, `autoHidesTabBar`, `hidesTrafficLights`, `hidesBookmarkToggleButton`, `hidesBookmarkButton` — the older key, which means the *dialog* button, `hidesSettingsButton`); `highlightsCurrentLine` (the cursorline band, default off).
- `Shortcuts.swift` (~200) — `KeyCombo`, `ShortcutAction` (every adjustable menu key, defaults, groups, reserved combos), `NSMenuItem.applyShortcut`. ⌘D bookmarks the tab, ⇧⌘D shows the bookmarks; Jump to Tab… ⇧⌘J, Mode Toggle ⌘P, Reading Mode ⇧⌘P, Find and Replace ⌘R (fixed); duplicating a line is ⇧⌥↓ only. Export… is ⇧⌘E (⌘E stays the Mac's Use Selection for Find).
- `LaunchTiming.swift` (~80) — where a launch's time goes: `mark(_:)` at each phase from `main` to the window becoming key, printed to stderr a second after launch when the binary runs with `NOTA_LAUNCH_TIMING=1` (the binary itself, not `open`, which drops the environment); the first line is the kernel's exec time, so dyld and the runtime show as the gap to `main`. A `Bool` read and nothing else without the variable.
- `Version.swift` — `AppVersion.current`; bumped with `Info.plist` by `.githooks/pre-commit` on every commit (`git config core.hooksPath .githooks`).
- `UpdateCheck.swift` (~190) — the About page's "Check for Updates": one anonymous request to GitHub's `releases/latest`, `Release` (tag without its `v`, page URL, name, date), `compare` over dotted integers, `Result` / `Reason` (offline, rate-limited, another status, unreadable, a tag that is not a version), and `installedWithHomebrew` — a `/Caskroom/` in the bundle path, or a `Caskroom/nota` under a Homebrew prefix. The transport is a closure, so no test reaches the network.
- `Localization.swift` (~545) — `L10n.text` and one table per language, all keyed by the English string: 简体中文, 繁體中文, Bahasa Melayu. `AppLanguage.resolved` (in `Preferences.swift`) says which one, resolving `.system` against the Mac's preferred language.
- `SettingsWindowController.swift` (~1460) — Settings: a sidebar source list over eight pages (General, Appearance, Editor, Preview, Tab bar, Status bar, Shortcuts, About), each page's controls in inset rounded groups of 44pt rows (`SettingsRowView`: label, optional `accessory` such as the `?` a row's help sits behind, control at the trailing edge); `row(help:)` + `showHelp` put a sentence in one transient `NSPopover`; no Save button — every control writes its own preference on the change (`apply {}` guards the notification coming back), language and theme `refresh()` afterwards, and a clashing shortcut is refused rather than written. Version shown on About comes from `Version.swift`; the update line there is a plain wrapping label with a fixed `preferredMaxLayoutWidth`, since the centred About stack gives a `WrappingLabel` no width.
- `ShortcutRecorderField.swift` (~150) — press-a-key field; records a global hotkey (key code) or an app `KeyCombo` (character).
- `GlobalHotKey.swift` (~170) — Carbon hotkey; `KeyCodeNames` (key code / key-equivalent display names).

### Main window
- `MainWindowController.swift` (~5500) — the whole window. Sections by `MARK`:
  Setup (358) · The format offer (824, the debounce, `runFormatDetection()` and who is offered anything at all) · Text attributes (1229) · Auto-hidden tab strip (1539) · Session restore (1662) · Tabs (1817) · The format badge (1966, the badge's menu and `setFormat` — the one path a tab's format ever changes by, which a Save As under a new name shares) · Encoding and line endings (2035) · Vim footer (2290) · Files (2654, open/save/close, sniff → viewer kinds) · External changes (3004) · Persistence (3155) · Font size and zoom (3263) · Menu actions (3346) · Zen mode (3448) · Tab picker (3926, `@` headings, text notes only) · Markdown preview (4036, modes, split, footer status of viewers; the sidebar side is recorded when the split is built) · The action in the corner (4531, the corner slot's segments and what a click on a tree, cell or block selects) · Images and book contents: chips and sidebar (4841) · Search across tabs (5090, `beginSearchAllNotes` opens the picker in `.search` over every tab's `searchSource`; `reveal` takes a hit to where it lives — the editor's selection, the document's page, the book's chapter) · Delegates / Vim's window (5141) · Background (5468) · Quick Look (5481).
  Also here: `DocumentSplitViewController` + `DocumentSplitView` (the editor/preview split; the divider is not drawn outside split mode), `VimCommandPane`, `DragRegionView`, `BackgroundView`.
  Footer regions: `statusLabel` (counts, `updateCountsLabel` / `availableCountsWidth`), `footerTrailingStack` (format · encoding · line ending · cursor — the format badge is the one that gives way in a narrow window, so four badges never put a floor under the window itself), `modeBadge` (vim).
- `TabBarView.swift` (~1650) — the strip: `TabBarItem`, `TabItemView` (icon, dot, ✕, bookmark badge), drag/reorder, tear-off, + button, the three trailing buttons (`BookmarkToggleButton` — ⌘D on the front tab, filled once it is bookmarked, greyed with no file; `BookmarksButton` — the ⇧⌘D picker, `book.closed`; `SettingsButton`), context menu.
- `TabStripLayout.swift` (~240) — pure width arithmetic for the strip, the three trailing slots included (`TrailingControls`, `bookmarkToggleX` / `bookmarkX` / `settingsX`).
- `TabPickerPanel.swift` (~1200) — ⇧⌘J panel: modes `.tabs` / `.headings` (`@`, text notes only — a book's contents are in the sidebar) / `.bookmarks` / `.search` (⇧⌘F over `[NoteSearchSource]`, two-line hit rows, no top row); top fixed row; arrow keys and hover selection (`HoverTrackingTableView`); `TabPickerRowView`.
- `FuzzyMatch.swift` (~80) — subsequence scoring for the picker.
- `ModeControlOverlay.swift` (~540) — the corner slot: the hover band per column, and the one capsule the
  front tab puts in it (`Content` — the Editor · Split · Reading segments, those same three plus a fourth
  carrying a `.json` or `.html` tab's Beautify / Compact, or nothing). `FormatKind` names the two formats and
  their words; the action is a segment of the same `.selectOne` control, and a click on it fires the reformat and
  puts the selection back on the mode. The band, the fade, the hit testing and the drop under ⌘F know nothing of
  which.
- `ZoomPillOverlay.swift` (~355) — the zoom pill in the preview column's bottom-leading corner: the hover band along
  the bottom, the `−  100%  +` control in the corner slot's own bezel, the hold after the last zoom and the hover
  that outlives it, and the three commands it hands the window. Knows nothing of what is being zoomed — the column
  asks the content in front for `zoomPercent` and a `nil` takes the pill away.
- `ImageSidebarView.swift` (~210) — thumbnail column, under its own `Images` title; the cards are the shared ones, and what it adds is the asset store, the context menu and the double click that opens the file.
- `ContentsSidebarView.swift` (~330; the column owns the hover — one tracking area, the row under the pointer recomputed on scroll) — the same column for a book: its table of contents, indented by nesting, the line naming what is on screen rung, under `Contents`. Knows nothing of the kind — it lists `ContentsEntry` values and hands a chosen line back.
- `PageListSidebarView.swift` (~225) — and the same column for a document: its pages under `Pages`, one shared card each, the page in front washed and followed, thumbnails asked of a `PageListSource` only as the cards come into view.
- `SidebarCards.swift` (~245) — what the three columns are made of: `SidebarCard` (the metrics), `SidebarSectionHeader` (the Finder-shaped title at the top of a column, with a `SidebarCountBadge` after it — a capsule wearing how many the list holds, `0` included, hidden only when never set) and `SidebarCardItemView` (the white card, its shadow, its selection wash and its caption).
- `ChipHighlight.swift` (~50) — which thumbnails match the caret/selection.
- `NoteSearch.swift` (~195) — the search itself. `NoteSearchSource` is what one tab hands it (`.text` for a note,
  `.pages` for a document, `.chapters` for a book, each part searched on its own); `NoteSearchMatch` is one hit and
  its `location` — `.text` / `.pdf(page:)` / `.book(chapter:)` — is where the window takes the reader. A page's
  snippet wears its number. Pure; the panel's `.search` mode draws what it returns.

### Notes, files, session
- `Note.swift` (~810) — `PreviewMode`, `RenderedPreviewKind` (`.tree(StructuredFormat)` among them), `NoteFormat` (the same list with plain text put back: the word in the footer's badge, the one spelling that means it, and the way back from a session file), `NoteKind` (`text`/`pdf`/`image`/`epub`/`rtf`), `Note` (storage, file, dirty, watcher, `formatOverride` — the reader's own word about what the tab is, which `previewKind` / `isJSON` / `isHTML` / `iconSymbolName` all read first — cached PDF/image/book/rich text, `searchSource` — what the tab hands ⇧⌘F, its viewer parts cached beside the rest — `sessionTab()`).
- `NoteText.swift` (~380) — `![](nota://id)` tokens ↔ attachments, and, given a closure for each direction, a
  saved file's own relative image links too: `serialize(_:sidecar:)` and `render(_:…:importing:)`. Touches no disk.
- `Sidecar.swift` (~215) — the pictures a saved note keeps beside it in `<basename>.assets/`: folder naming,
  percent-encoded links, which link targets are relative paths, the identical-bytes check, `Writer` (save) and
  `importer(forFileAt:assets:)` (open).
- `Assets.swift` (~250) — `NotaImageAttachment` chips, `AssetStore` on disk.
- `FormatDetector.swift` (~290) — what a note's text reads as, when its name has nothing to say: `detect(_:)` and
  nothing else. Signals asked in a fixed order, first hit wins — JSON that parses, an `<?xml` prolog (with the root
  element deciding XML from SVG), a page's tags, `\documentclass`, two SQL statements, a `[section]` with keys, three
  mapping lines, three even records, two different Markdown signals — and `nil` under three non-blank lines or sixty
  characters. Deliberately shy: prose with a colon, a list of dashes and three paragraphs are all `nil`. Pure; knows
  nothing of AppKit, of a file, or of a note.
- `TextFile.swift` (~430) — `LineEnding`, `TextFileFormat`, encoding detection, `FileSniff.classify` (PDF, image, EPUB, RTF, text, binary), `FileClass`, `isDrawing` (an `.svg` is text, not a picture — `Note.isImageFile` and the exclusions ask it).
- `Session.swift` (~580) — `TextStats` (footer count phrases incl. pages/chapters/tables, a table's rows and columns, and a row range), `SessionTab` / `SessionWindow` codables (`sqlTable` / `sqlQuery` for a dump's tab, `formatOverride` for a tab the footer was told what to be), `SessionStore`.
- `SaveNameComposer.swift` (~80) — pure logic for the Save dialog's Format popup: known extensions, the list one
  the popup does not know is put in front of (`formatOptions(including:)`), splitting a name from its extension,
  composing the final name.
- `SaveDialog.swift` (~380) — Nota's own Save dialog in place of `NSSavePanel`: the sheet's two rows (name with the
  Format popup at its end, read-only location with `Choose…`), Cancel and a default Save, `runSheet(on:)` pumping
  `NSApp.runModal` so the window still sees one synchronous `URL?`, the replace question handed back to the window,
  the `Preferences.didChange` relabelling that lets a language change land while it is open, and the popup's
  `None` and `Other…` tail (a field for an extension the list does not carry).
- `Export.swift` (~360) — File › Export…'s core (SPEC "## Export"): `ExportTarget` (what a tab can be
  exported to) and `Exporter` — the targets each kind offers in the sheet's own order, the two PDFs Nota
  writes itself (the render, the document or the picture as shown; the editor's source listing, with its
  gutter's numbers and its pictures inline or as plates), and the empty hooks the other exporters plug into
  (`bookPDF`, `pdfToEPUB`, `csv`, `texPDF`, and `htmlPagePDF` for a page as WebKit draws it — a target whose
  hook is nil is never listed). A hook is `(Note, URL, Context)`, and the context carries the live pane for an
  exporter whose answer is on screen rather than in the note. `ExportImagePlacement` is the sheet's second row
  and `Preferences.exportEditorImages`.
- `ExportDialog.swift` (~280) — the export sheet: `SaveDialog`'s form with one row of targets and, only while
  `Editor as PDF` is selected, a second row of `Inline` / `Plates at the end`; run the same synchronous way,
  and it hands back an `ExportChoice`. `MainWindowController.exportSheetProvider` is the seam a test answers
  it through, as `savePanelProvider` is for the dialog after it.
- `PDFPaginator.swift` (~310) — the only place Nota makes a PDF: an attributed string paginated by a silent
  `NSPrintOperation` (`jobDisposition = .save`, the file in `jobSavingURL`), plates drawn one picture to a
  page (`knowsPageRange`) and joined onto the text with PDFKit, Letter or A4 from `NSPrintInfo.shared`,
  margins from the render's inset, and the whole run under the light appearance with the text's dynamic
  colours resolved first.
- `FileWatcher.swift` (~230) — `FileStamp`, watching a path for change.
- `Bookmarks.swift` (~120) — pinned paths store. `BookmarksMenu.swift` (~130) — the File submenu + ⇧⌘D toggle.
- `RecentDocumentsMenu.swift` (~55) — File › Open Recent.
- `BigFile.swift` (12) — the "big" threshold. `SpellCheckPolicy.swift` (~30).
- `LineIndex.swift` (~200) — hard-line start table (gutter, footer, ⌘J, vim).

### Editor
- `NotaTextView.swift` (~940) — the text view: paste/drop of images and HTML, vim hooks, `setSearchHighlights`, chips; the cursorline band's two inputs, `highlightsCurrentLine` (the preference) and `vimCursorLine` (vim's `:set cursorline`), derive the drawn `showsCursorLine`.
- `LineNumberRulerView.swift` (~220) — gutter.
- `LineOperations.swift` (~380) — move/duplicate/comment/indent as pure functions.
- `JSONFormat.swift` (~330) — Nota's own JSON walker, for the `.json` tab's corner action: `reformat(_:as:)`
  (pretty / compact, every token re-emitted as it was written), `isPretty(_:)`, `errorLine(in:)`. Pure; no
  `JSONSerialization`, so key order, number spelling and escapes all survive.
- `HTMLFormat.swift` (~700) — Beautify and Minify for `.html`, and `sourceTags(of:)` — every element in document
  order with its start tag's range, for `HTMLSourceMap`. Nota's own byte tokeniser over a page (doctype,
  comments, start and end tags with every attribute form, void and self-closing tags, and the raw-text elements
  `script`/`style`/`pre`/`textarea`/`title`), the tree it builds from it, and the two writers over that tree.
  `JSONFormat`'s three questions — `reformat(_:as:)`, `isPretty(_:)`, `errorLine(in:)` — asked of a page.
- `HTMLClipboard.swift` (~290) — reading `public.html` / web archives on paste.
- `TaskList.swift` (~200) — `- [ ]` boxes in render and source.
- `ListContinuation.swift` (~365) — what Return means on a list item, as pure functions: `ListMarker.parse(line:above:)`, `.next()`, `.prefix`, and `ListContinuation.edit(forReturnIn:at:)`. The header explains how a lone `i.` is read.

### Find, go-to-line, pills
- `Pill.swift` (~400) — `PillView` chrome (`symbol`, `glyphButton`, `quietLabel`), the leading word every pill now opens with (`PillWord`, `PillWordButton`, `PillWordLabel`, `leadWordButton`, `leadWordLabel`, and the one colour rule: muted until the pill's own field has the keyboard, `labelColor` while it does), `PillTextField` (which notices the field editor arriving and leaving and tells its pill), `PillFieldEditor`, `PillActionResponder`, `floatBottom`. `width` is a `class var` so the one pill carrying a sentence and two words can be wider; every other is the same 300.
- `FindBar.swift` (~340) — `FindBarView` (query pill; the word `Find` toggles the replace pill where there is anything to replace and is inert where there is not), `ReplaceBarView` (the replace pill; its word `Replace` folds it away through `onCollapse`), no placeholders in either field, tooltips from the shortcut table.
- `FindSession.swift` (~545) — `TextFindSession` for the editor and rendered panes; ⌘F and ⌘R both toggle the replace row (`show`, `showReplace`, `hideReplace`) and `hide` takes it down with the bar; `NSTextView.setFindHighlights` and `quietFindBand` (light: label wash, dark: dimmed find yellow).
- `HTMLFindSession.swift` (~525) — same for WebKit pages (CSS highlights).
- `PDFFindSession.swift` (~380) — same for PDFKit.
- `TreeFindSession.swift` (~400) — same for a tree preview's rows: the keys and the values as the rows spell
  them, the branches a match opens on the way to it, the bands laid on the row's own attributed string (there
  is no storage here to lay a temporary attribute on), and the source range it hands the editor's caret — the
  value alone for a value match, the whole member for a key match.
- `GridFindSession.swift` (~330) — same for a `.csv` or `.sql` grid, over `SQLGridView`: `GridMatch` (a row of the
  *whole* table in the order on screen, and a data column), the `GridFindSource` both panes adopt (the matches, where
  the page on screen starts, how many columns it has, what a cell says, and "turn to this row"), the anchor, the
  wrap, the `2000+` cap, and the band a cell is asked for as it draws. Knows nothing of what is under it — one pane
  walks a table in memory and the other asks SQLite.
- `GoToLine.swift` (~285) — ⌘J pill; it leads with the word `Jump`, a label rather than a button.
- `ExternalChangePill.swift` (~90) — "Changed on disk · Reload / Keep mine".
- `FormatOfferPill.swift` (~175) — the same corner and the same chrome, for the other thing Nota says without being
  asked: "JSON detected · Preview in JSON / Not now". The format's name is filled into one localized sentence, and
  the two pills are never up together — the file's own news is the louder of them. `FormatOfferAlert` at the foot of
  the file is the other half: the sheet a paste or a drop gets, same two words, asked properly because nothing is
  being interrupted.

### Preview column and renderers
- `PreviewContent.swift` (~430) — `PreviewContentKind` (markdown/latex/html/pdf/image/epub/sql/csv/rtf/tree), `ContentsEntry` (one line of a table of contents), `PageListSource` (a document read page by page: count, page in front, go to one, draw one), the `PreviewContent` protocol every content view adopts (`show`, zoom, find, `rememberedPosition`, `rememberedScroll`, `footerStatus`, `contentsEntries` / `currentContentsLine` / `goToContentsLine`, `pageList`, `onStateChange`, `onBlockClick` and `onSourceReveal` — a click that takes the caret with it and one that only moves it, one range per row of a rectangle picked out of a grid and one range otherwise — `onDropFiles`), and `PreviewFileDrop` — the drop from the Finder every view in the column answers the same way.
- `PreviewPaneView.swift` (~315) — holds one content view at a time; `panes` for tests; `onDropFiles` goes to every content view and to zen's drag band, so the whole column is a tab target.
- `RenderedPreviewView.swift` (~710) — base class for rendered text panes (blocks, band, click-back, find, frozen
  wrap width). `PreviewTextView.mouseDown` is where a press is told from a drag: `super` runs AppKit's tracking loop
  and the block click is reported after it, only for a press that neither moved nor swept anything.
- `MarkdownPreviewView.swift` (17) / `LaTeXPreviewView.swift` (21) — the two subclasses.
- `RenderStyle.swift` (~190) — `RenderedDocument`, block styles shared by both renderers.
- `MarkdownRenderer.swift` (~590) — Markdown → attributed string, `MarkdownImageAttachment`.
- `MarkdownSourceMap.swift` (~330) — rendered block → source range.
- `MarkdownHeadings.swift` (~130) — headings for `@` in ⌘P.
- `MarkdownMath.swift` (~455) — `$…$` and a ```` ```mermaid ```` fence lifted out before parsing, each riding through as its own image token. `MathParser.swift` (~575), `MathLayout.swift` (~720), `MathAttachment.swift` (~40) — Nota's own formula layout.
- `Mermaid.swift` (~100) — the one door a ```` ```mermaid ```` fence comes through: `Mermaid.kind` names the grammar
  off the first meaningful line, `layout` hands the source to that grammar's own file, `canDraw` answers the
  question the Markdown pass asks *before* it lifts a fence out. Also `MermaidDiagram` (a box of `size` that draws
  itself into a flipped context) and `MermaidPalette` (five semantic colours, resolved at draw time). No WebView and
  no dependency.
- `MermaidFlowchart.swift` (~1640) — `flowchart` / `graph`: the whole grammar (every bracket pair, every arrow and
  end cap, the four label forms, chains, `&` fans, nested `subgraph`s, and the styling directives it parses only to
  ignore), then a Sugiyama layout over it — cycles broken by reversing back edges, longest-path ranks, barycenter
  sweeps for the order, a dummy node in every rank a long edge crosses — and the drawing. `parse` is pure and takes
  no font; anything it cannot read comes back `nil` and the fence stays code.
- `MermaidSequence.swift` (~1290) — `sequenceDiagram`: `participant` / `actor` with aliases and the ones a message
  declares by using them, all eight arrow forms (solid or dotted, open, filled, cross or async head), `+` / `-`
  activation suffixes and `activate` / `deactivate` stacking bars on the lifeline, self-messages, `Note left of` /
  `right of` / `over` one or two lifelines, `loop` / `alt`-`else` / `opt` / `par`-`and` / `critical` / `break` /
  `rect` frames nested freely, `autonumber`, and `title` / `accTitle` / `box` / `link` parsed and never failed on;
  then the lane layout (headers top and bottom, lifelines spaced so every label between neighbours fits, one row per
  message) and the drawing. `parse` is pure; junk comes back `nil` and the fence stays code.
- `MermaidAttachment.swift` (~55) — one diagram as one character in the render, on `MathAttachment`'s pattern: an
  image drawn through a handler so the palette resolves at draw time, scaled down when the diagram is wider than
  the column.
- `LaTeXParser.swift` (~1360) — `.tex` → blocks. `LaTeXRenderer.swift` (~480) — blocks → attributed string.
- `HTMLPreviewView.swift` (~900) — WebKit page under `nota-file://`, scroll memory (pixels and fraction),
  `showPage(ofTab:at:…)` for EPUB chapters, chapter-key script, the element-press script (`elementReporter`, which
  reports the pressed element's place in document order and the tag names up to it) with the `HTMLSourceMap` built
  beside each load, the `focusin` / `focusout` script that says when the page holds a field — the one thing that
  makes `HTMLPageView` take the keyboard outside reading mode — and the dark-mode reader theme a book asks for
  (`appliesReaderTheme`, `readerThemeCSS`).
- `HTMLSourceMap.swift` (~120) — where in a page's source the element the reader pressed is written: `HTMLFormat`'s
  own start tags (through `HTMLFormat.sourceTags(of:)`) lined up against the DOM's element names in document order,
  skipping what one side has and the other has not, recovering within four tags, and answering `nil` rather than
  pointing at the wrong one. Pure; no WebKit.
- `PDFPreviewView.swift` (~600) — PDFKit viewer tab, `reveal(page:range:query:)` for a ⇧⌘F hit, and `PDFPageThumbnails` (pages drawn small on one serial queue, from a second `PDFDocument` of the file, cached per document for the sidebar's page list). No outline: a PDF's sidebar is its pages. `ImagePreviewView.swift` (~240) — picture tab.
- `EPUBBook.swift` (~490) — unpack (ditto), container/OPF/spine/nav/NCX parsing, `contentsEntries`, `contentsLine(ofChapter:)`, `words(ofChapter:)` (the chapter's text with the markup left behind, block elements on lines of their own — what ⇧⌘F searches a book by). `EPUBPreviewView.swift` (~300) — chapter viewer; no floating chapter bar.
- `RTFPreviewView.swift` (~430) — the rich-text viewer tab: `NSAttributedString(url:…)` into a read-only, selectable
  `NSTextView` at the editor's margin, the document's own fonts and colours kept (black body text swapped for
  `labelColor`), `TextFindSession` for ⌘F, and a zoom that scales every font, paragraph measurement and attachment.
- `SQLDump.swift` (~1120) — a `.sql` file run into an in-memory SQLite (`import SQLite3`, no dependency): the
  prepare/tail loop and the first failure's own statement, the `SQLSourceMap` it takes down as it goes (one `Span`
  per statement — a rewritten `mysqldump` insert included, through `insertRecord`, and one per row of a `COPY`
  block), `tables`,
  `page(ofTable:offset:sort:)` / `page(ofQuery:…)` (`LIMIT 100 OFFSET`, `COUNT(*)`, and the rowids a page carries
  beside its values with the table they belong to), `declaredTypes(ofTable:)`, `hasRowid(_:in:)`, and the read-only
  authorizer the query box runs under; also turns a `mysqldump`/phpMyAdmin/`pg_dump` export into something SQLite's
  parser takes, via `SQLDumpDialect`. Knows nothing of AppKit.
- `SQLDumpDialect.swift` — the MySQL and Postgres spellings a dump carries, turned into SQLite's before
  `sqlite3_prepare_v2` sees them: which statements to skip (session state, ownership, sequences, grants, psql `\`
  meta-commands), `CREATE TABLE` decoration and type mapping, MySQL backslash escapes in row strings, and a
  `pg_dump` `COPY … FROM stdin` block read into batched inserts with one source-map span per row.
- `SQLPreviewView.swift` (~1105) — the pane that draws it: the query box under the corner slot's hover band, table
  picker, the one `arrow.clockwise` button that runs the file again (and is a big dump's only way in), page bar, the grid's data source, the sort a header click asks for (`tableView(_:didClick:)`, on the
  release — see the header's own note), the alerts a failing query or a failing file put up (once per message, with
  `alertOverrideForTesting` for the tests), runs on its own queue with a token, and the per-tab table and query it
  writes onto the note, `sourceRanges(of:)` — the grid's `Selection` as an array of ranges: whole rows one span of
  tuples, a rectangle one span of values per row, so a column is that column and not the lines between its rows —
  and `GridFindSource`: ⌘F over the whole table, or over the query's result, through
  `SQLDump.hits` on the pane's own queue.
- `SQLGridView.swift` (~530) — the grid itself: the spreadsheet cell cursor (click one, drag a rectangle, arrows and
  ⇧-arrows, ⌘C as tab-separated text), whole rows from the `#` gutter, ⇧ and Space, the cell click it reports
  (`onCellClick`) and *every other* selection it makes (`onSelectionReveal` — the gutter, a ⇧-click, a drag, Space, a
  ⇧-arrow; a drag says it again only when an edge actually moved) for the pane to take back to the file,
  `span(of:)` — several ranges as one, the way a selection over three paragraphs of text is one range —
  `takesKeyboard` (reading mode, which is what decides whether ⌘F is the grid's or the editor's, since a click puts
  the first responder here in split too), the `findSession` the cells ask for their ⌘F bands and the Find menu's
  nil-targeted items are handed to, `SQLCellView` drawing the accent wash, the rectangle's hairline and the find
  bands under both (and the black it spells the current match's text in), and `SQLHeaderView` / `SQLHeaderCell` —
  the flat header with its own sort chevron.
- `SQLSourceMap.swift` (~605) — where each row of a dump is written: the statements `SQLDump` took down as it ran
  (each one's own characters, the rowids an insert made, and its `Statement.Form` — an ordinary statement, or a
  `COPY` row carrying the header's own column list), the two lookups a clicked cell is answered from — the row's
  tuple, and the one *value* inside it the clicked column stands for, quotes included — and the scanners they need:
  the table an `INSERT` names, the column list it named, the `(…)` tuples after `VALUES`, the values inside one
  tuple, and the tab-separated fields of a `COPY` line, all counted outside string literals, quoted identifiers and
  comments. `backslashEscapes` says whether a `\` inside a literal escapes what follows it, which is MySQL's rule
  and not SQLite's or a `pg_dump`'s, so `'Daniel O\'Brien'` is read as its dialect means it. Pure text and no
  SQLite.
- `SQLQueryRewrite.swift` (~175) — the loose read of a query that says whether it is plainly one table's rows, and
  the same query with that table's rowid spliced in after the `SELECT` keyword, so a cell of a query's result walks
  the editor to its `INSERT` the way a table's does. What it refuses — a join, a `GROUP BY`, an aggregate, a
  sub-select — and what SQLite refuses are both answered by running the reader's own query untouched. Pure text and
  no SQLite; it borrows `SQLSourceMap`'s scanner.
- `SQLQueryBox.swift` (~275) — the five-row query editor: rounded bezel, `SELECT …` placeholder, Return a newline,
  ⌘↩ the run, Esc the cancel, no rich text and no substitutions, and the Find menu handed to the grid's session in
  reading mode and back up the responder chain out of it, so AppKit's own find bar never opens over five lines of
  SQL.
- `CSVTable.swift` (~330) — a `.csv` or `.tsv` read as the table it is: Nota's own RFC 4180 scanner (quoted fields,
  `""` escapes, newlines inside quotes, CRLF / CR / LF, a trailing newline, a BOM, blank lines skipped), the first
  record as the header with blanks named `Column 3`, ragged rows padded and widened, the `NSRange` of the lines each
  record is written on and of every *field* of it as written (`fieldSources`, quotes included — what a clicked cell
  selects), and `page(offset:sort:)` — a hundred rows, sorted numerically where the whole column parses as numbers
  and by the reader's own collation where it does not. Pure; knows nothing of AppKit.
- `CSVPreviewView.swift` (~810) — the pane that draws it: the dump's pane with the database taken out — one bar of
  `Refresh` and the page arrows under the corner slot's hover band, `SQLGridView` below it unchanged, the sort a
  header click asks for, the `onSourceReveal` a click, a gutter click or a drag sends (`sourceRanges(of:)` — the
  grid's `Selection` as an array of ranges: one span of records for whole rows, one span of fields per row for a
  rectangle, so a column is that column and not the lines between its rows), `GridFindSource` — ⌘F over the
  whole table in `CSVTable.ordering`'s order, with the bar row dropping while the pill is up — and the read it runs
  on its own queue with a token (a big file only ever on the button).
- `StructuredDocument.swift` (~200) — what a `.json`, `.yaml`, `.toml` or `.xml` file *is* once read: one
  `StructuredNode` shape for four grammars (named parts, numbered parts, leaves, the 1-based line every node starts
  on, its `range` — the whole span of source it was made from, in the UTF-16 an `NSRange` counts in — and its
  `valueRange`, the value alone, which is what a click on a leaf row selects), `StructuredDocument`,
  `StructuredParseError`, `StructuredFormat` saying which
  parser a file's name asks for, and `SourceOffsets`, which turns a parser's own counting (UTF-8 bytes, Characters,
  Unicode scalars) into the editor's. Pure; knows nothing of AppKit.
- `JSONTree.swift` (~310) — a `.json` into that shape: Nota's own recursive descent over the UTF-8 bytes, RFC 8259
  only. A second walker beside `JSONFormat` on purpose — that one keeps every token verbatim so beautify and
  compact are lossless, this one unescapes strings and keys for display. Keys in file order, duplicates kept,
  numbers as spelled, depth capped at 256, every failure a line and a short reason.
- `XMLTree.swift` (~370) — an `.xml` into it, through Foundation's `XMLParser` (SAX), taken for the one thing it
  already knows and a hand scanner would have to earn: the line every event happened on. Elements keyed by their
  qualified name, attributes first as `@name` in the order the tag wrote them, text runs and CDATA as `.text`
  (whitespace-only dropped), comments kept, PIs and the doctype skipped. Every node's `range` is read back off the
  text, since SAX says where an event happened and never how wide it was: a start tag's `<` by looking back from
  its `>`, an attribute's `name="value"` out of that tag's text.
- `YAMLTree.swift` (~1070) — the `.yaml`/`.yml` parser: a `StructuredDocument` from a YAML 1.2 core-schema subset.
  Walks `[Character]` lines with a line/column cursor, because YAML's punctuation is indentation and a column is a
  character. Block and flow collections, five scalar styles, anchors, aliases and merge keys, `---` documents.
- `TOMLTree.swift` (~780) — the `.toml` parser: a `StructuredDocument` from TOML 1.0. Walks `[Character]` with a
  line counter, building a reference-typed intermediate tree so a `[a.b.c]` header can reach back into a table
  three levels up; converted to `StructuredNode`s at the end. Numbers and dates are kept as spelled.
- `TreePreviewView.swift` (~1050) — the pane that draws whatever any of the four hands back: an `NSOutlineView`
  (one column, no header, painting no background of its own — the pane's layer is the document colour, since an
  outline given it came out a shade off in the dark — the editor's margin, starting 14pt down like the source, and
  the column held to the pane's own width in `layout()` so a long value truncates instead of running off),
  a row's key then its value coloured by type, `{3}` / `[12]` after a closed branch, expansion seeded by the
  document's size and then remembered by node path across re-renders, the scroll kept, a click selecting the
  node's source (a leaf its value, a branch its whole span, key and value) without taking the keyboard, the
  caret's line lighting the node that line begins, and — in reading mode, where the outline has the keyboard — its
  own ⌘F pill over `TreeFindSession` (the seams the session asks of it: the flat walk `findRows`, the searchable
  parts of a row `findFields(of:)`, the ancestors it opens, the row it selects and the source it reveals).
  In place of the tree, for a file that will not parse or that is one plain value, a centred block: the headline
  naming the format, the line and the parser's reason under it, and the way out `FormatDetector` names ("It reads
  as HTML — choose that in the footer's format badge"). `TreeClipView` hands a click inside the clip view's top
  inset on to the outline, since `NSClipView` refuses it and the rows scrolled under the corner band were dead.
- `FileKindIcon.swift` (~130) — extension → icon name, every name answered by the art set (aliases folded, no
  extension `txt`, no drawing `unknown`, no file `untitled`); `image(named:pointSize:filled:)` draws it 1.35× point
  size high and 1.5× that wide, outlined or — for a bookmarked tab — filled, cached per name/size/fill.
  `FileKindArt.swift` (generated, ~400 KB) — the two SVG tables, `outline` and `filled`, 141 stems each.

### Vim (`Sources/Nota/Vim/`)
- `VimEngine.swift` (~960) — the state machine and `VimEngineHost` (what it needs from the window).
- `VimKey.swift` — a key press in vim terms. `VimMode.swift` — modes. `VimCursorDrawing.swift` — caret shapes.
- `VimMotions.swift`, `VimOperators.swift`, `VimTextObjects.swift`, `VimVisual.swift` — motions, operators, `iw`/`ip`/…, visual mode.
- `VimSearch.swift` — `/` `?` `n` `N`. `VimMarks.swift`, `VimRegisters.swift`, `VimRepeat.swift` (`.`), `VimMacros.swift` (`q`/`@`).
- `VimCommandLine.swift` — the `:` / `/` prompt line. `VimEx.swift` — ex address/range parsing. `VimExCommands.swift` — running `:` commands. `VimHelp.swift` — `:help`. `VimScratch.swift` — `:reg` / `:marks` tabs.

## Tests (`Tests/NotaTests/`)
`swift test --filter <ClassName>` or `--filter <testName>`.

- `NotaTests.swift` (~4200, 115 tests) — the grab bag: editor, footer, Settings window, find bands, ⌘P hover, session, `NoteSearch` itself.
- `MarkdownPreviewTests.swift` (~140) — preview modes, split, picker rows, the ⇧⌘F search dialog over text tabs,
  sidebar, and the press-versus-drag in the render (a still press is the block click, a sweep selects and jumps
  nowhere, a double click takes a word).
- `CornerSlotTests.swift` — which capsule the corner slot shows per tab kind, that a `.json` and an `.html` tab
  get a fourth segment in both columns and a `.yaml` does not, that clicking it reformats and puts the mode
  selection back, and that an unparseable file disables it and names the line.
- `StructuredPreviewTests.swift` (~800, 45 tests) — the tree previews: `JSONTree` (order, duplicates, numbers as spelled,
  escapes and surrogate pairs, empties, nesting, every node's line, each kind of failure with its line and reason,
  the depth cap) and `XMLTree` (attributes, text, CDATA, comments beside and inside the root, prefixes, the
  doctype skipped, lines, a failure's line); the four tabs' modes and the column's tenth content view; and the
  pane itself — the rows and what they say, a closed branch's summary, default expansion by size, a click moving
  the caret without taking the keyboard, the caret lighting a row, a re-render keeping what was open, and the
  parse-error line, and a click on a row scrolled under the corner band.
- `TreeErrorTests.swift` (6) — what the tree pane says with no tree to draw: the one column held to the pane's
  width so a long value truncates, a file that is one plain value, a parse failure's line and reason, the
  "reads as HTML" way out and the silence where there is none, and the headline's own voice.
- `TreeFindTests.swift` (11) — ⌘F over a tree: a key match and a value match, the count's wording, a match
  opening the branches above it, next and previous wrapping, the caret following the matched part, the bands
  on the row the outline actually draws, Escape leaving the row selected, Find… validating only while the
  tree is what is being read, the query surviving a re-parse, and a YAML file searched the same way.
- `YAMLTreeTests.swift` (49) — block and flow mappings and sequences, the compact forms, all five scalar styles and
  chomping, anchors/aliases/merge keys, `---` documents, the core-schema types, and every refusal with its line.
- `TOMLTreeTests.swift` (34) — keys and dotted keys, table headers and implicit super-tables, arrays of tables,
  inline tables, all four string forms, numbers and dates kept as spelled, and duplicate-key/table refusals.
- `JSONFormatTests.swift` — the walker: order, escapes, empties, unicode, pretty detection, error line.
- `HTMLSourceMapTests.swift` (9) — the map: a plain page's every element found, the whole element revealed only where
  it holds nothing but text, UTF-16 counting, an implied `tbody` and a missing `html`/`head`/`body` skipped, an
  element a script added and a drifted sequence both answered with nothing, and a page the tokeniser refuses having
  no map at all.
- `HTMLFormatTests.swift` (56) — the tokeniser and both writers: every tag and attribute form kept byte for byte,
  raw-text elements untouched, block/inline line-breaking, whitespace collapsing, stray and left-out end tags, and
  the disabled cases (unterminated comment, unclosed tag or quote, unclosed raw element, nesting past 256).
- `HTMLPreviewTests.swift` (which also covers a press in the page revealing its tag, and a page the tokeniser will
  not read having no map), `PDFTests.swift`, `ImageTests.swift`, `EPUBTests.swift`, `RTFTests.swift` — the viewer tabs, including the sidebar each of them fills (an RTF has none) and the ⇧⌘F hit each of a document and a book answers with (`PDFTests`, `EPUBTests`). `PDFTests` covers the page list: the title over it, the cards and their captions, a click going to a page, the ring following the pages, the thumbnails landing off a background queue, two documents of the same length not sharing a list, and a document with bookmarks listing pages just the same.
- `GridFindTests.swift` (22) — ⌘F over a grid, and what a selection in one shows the editor, both panes: the pill and its `canReplace`, the count and its
  wording, case and diacritics, the bands through `grid.highlight(row:column:)`, ⌘G wrapping both ways, a match on
  the second page turning the page and landing the cursor, the editor's caret following it, Escape keeping the
  cursor and handing the keyboard back, the Find items validating with the grid as first responder, ⌘E taking the
  cursor cell, a sort changing which row is first, another tab taking the search down; and over a dump — a table of
  `Shop.sql`, the display text a search of a number is against, a query's result, and ⌘F forwarded from the query
  box. Then the reveal: a gutter click on the record, a ⇧-click spanning the run, a cell drag following the
  rectangle (and saying nothing when it moved nothing), the dump's tuples and values, and both panes handing ⌘F back
  to the editor out of reading mode.
- `CSVPreviewTests.swift` (~770) — the table: what counts as one, the scanner's every case (quotes, escapes, a
  record over two lines, CRLF, ragged rows, a blank header cell, header-only and empty files, a BOM, tabs), paging,
  sorting numerically and as text, the header click through `NSTableHeaderView`, refresh keeping the sort and the
  page while typing drops the sort, the big file's one way in, the footer strings, a cell click moving the editor's
  caret without taking its keyboard, and the mode through the session.
- `SQLPreviewTests.swift` (~1680) — the dump: what counts as one, the run and its first failure, paging, the
  authorizer refusing a write and the `SELECT 1; DELETE` trick, the pane's bar and five-row query box, a real header
  click through `NSTableHeaderView` sorting the whole table, the cell cursor and its rectangle, the alerts (through
  `alertOverrideForTesting`, so no modal ever), the footer strings, the refresh button (a big file's only
  way in, and what it keeps), Space standing a row up, the source map and the tuple locator, a cell click moving the
  editor's caret without taking its keyboard — from a table's page and from a query the rowid was got into, and the
  cell cursor still answering the first click after a run, a refresh and a page turn — the query rewrite and what it
  refuses, and the table and query through the session.
- `MermaidFlowchartTests.swift` (35) — the flowchart engine: every node shape and edge form, chains and fans,
  subgraphs and nesting, comments and semicolons, the directives that are ignored, junk and a fuzz run that refuses
  without falling over; then the layout (frames that do not overlap, the direction each way round, an edge that
  starts and ends on the right borders, a labelled edge's box on its line, a cycle, a self loop) and a draw into a
  bitmap that has to leave ink.
- `MermaidSequenceTests.swift` (30) — the sequence engine: every arrow form, aliases, actors, implicit participants
  in order of first use, activations both ways, notes of each placement, every frame kind with `else` / `and` and
  nesting, `autonumber`, comments, ignored lines, junk; the layout (participants left to right as declared, messages
  descending in order, a message spanning its two lifelines, a self-message right of its own) and a draw that has
  to leave ink in both appearances.
- `MarkdownMermaidTests.swift` (15) — the seam: a fence that becomes one centred `MermaidAttachment`, one scaled to
  a narrow column, `gantt` and a malformed or half-typed flowchart staying code blocks, the source map finding each
  fence back, and the maths beside them untouched.
- `LaTeXTests.swift`, `MathTests.swift`, `MarkdownMathTests.swift`, `MarkdownHeadingsTests.swift`, `TaskListTests.swift` — renderers.
- `TextFileTests.swift`, `FileSniffTests.swift`, `FileKindIconTests.swift`, `LineIndexTests.swift`, `LineOperationsTests.swift`, `ListContinuationTests.swift` — files and editor logic.
- `LocalizationTests.swift` (~170) — the tables against each other, `.system` resolution, the Settings language popup.
- `UpdateCheckTests.swift` (18) — the update check with a stub transport: a newer release, the same version, a version ahead of the server, a tag without its `v`, malformed JSON, 403/429, another status, a transport error, a tag that is not a version, the comparison table, and the Homebrew rule. The button itself is in `NotaTests.testAboutPageChecksForUpdates`.
- `ZoomPillTests.swift` (12) — the pill: which tabs carry it, the percentage it reads, showing on a zoom and on
  hover, the hold and its restart, pressing it as the keys, and taking itself away at once for a tab with no zoom.
- `FormatDetectorTests.swift` (30) — the detector: one positive per format (JSON, XML, an SVG with and without a
  prolog, HTML by doctype and by tag variety, LaTeX both ways, a dump, TOML, YAML, CSV, TSV, Markdown three ways) and
  the negatives that matter more — prose with a colon, a shopping list, headings alone, one comma in one sentence,
  one `SELECT`, one `<div>`, keys with no section, and everything under the minimum.
- `FormatOfferTests.swift` (42) — the badge and the offer: `NoteFormat`'s words and spellings round-tripping, an
  override giving an untitled note a preview and taking one off a `.md`, the session round trip and a session
  written before the badge, the badge's text and its menu's tick, picking what the name already says putting the
  override down, the corner segments and the split following, the save rules both ways, and the pill — shown for
  JSON, taken, declined and not offered again for the same reading, offered again for another, never on a file
  (`.md` or `.txt`), taken down by a pick in the footer, silent under the minimum and arriving after the debounce —
  and the paste's sheet, driven through the `formatAlertPresenter` seam (a real sheet never opens in a test): asked
  at once with no pill beside it, taken, declined and remembered, ignored while one is already standing, never for
  a file or a megabyte, and the alert's own words checked on the `NSAlert` it builds. Every paste goes through a
  private pasteboard: a test never writes the reader's clipboard. Then the name a renamed format owes: a pick on a
  `.txt` going dirty and opening the panel on `md`, the pick put back, ⌘S asking once and not twice, the combo's
  own extension winning either way, the close confirmation, and the session round trip.
- `SaveNameComposerTests.swift` (16) — the Save dialog's name logic: splitting a known extension off, a typed name winning over the popup, dotfiles, trimming, the composed URL, what the Format popup lists, and the last extension round-tripping through Preferences.
- `SaveDialogTests.swift` (11) — the dialog itself, built and read without a modal session: what a named file and an
  untitled note open on, Documents as the last resort, a remembered extension the known list has never heard of,
  the URL composed from the name and the popup (and from a name spelling its own extension), Save unavailable on a
  blank name, the replace question asked once and not asked when the file is the note's own, and a language change
  relabelling it where it stands, and `Other…` / `None` reaching past the list.
- `ExportTests.swift` (13) — File › Export…: the targets each kind offers and the hook a target waits on, a
  Markdown note's heading on its first page, a long note over more than one page, the listing's line numbers
  with the gutter on and off, plates after the last page of text against the same pictures inline, an `.rtf`
  and a picture (one page, exactly), the sheet's Images row showing only for the listing, and the whole path
  through the window — sheet and Save dialog answered through their seams — opening the written PDF in a tab.
- `TabHoverTests.swift` (3) — the strip's three greys: selected fill, the pointer's wash on an unselected tab, nothing at rest.
- `WindowChromeTests.swift` (11) — Settings › Tab bar: the strip, the traffic lights and the strip's three trailing buttons each switched off and back.
- `BookmarksTests.swift` (also the ⇧⌘J picker tests), `OpenRecentTests.swift`, `ShortcutsTests.swift`, `MultiWindowTests.swift`, `ExternalChangeTests.swift`, `ZoomTests.swift`, `TabStripLayoutTests.swift`, `DropOnStripTests.swift`, `SidecarTests.swift`, `BigFileTests.swift`, `NoteBigFileTests.swift`, `SpellCheckPolicyTests.swift`.
- `VimTests.swift`, `VimStage2Tests.swift`, `VimStage3Tests.swift`.
- Helpers: `OffscreenWindow.swift` (`makeKeyAndOrderFrontOffscreen()` — tests never launch the app), `DirtyProbe.swift`.
- Gotcha: a hanging test is a modal alert; stub `confirmDiscardOverrideForTesting` / `savePanelProvider`.

## Other
- Promo website — lives outside the repo at `../nota-web` (moved 2026-09-05); an independent static Astro page, commands and deployment notes in its own `README.md`.
- `SPEC.md` — behaviour spec, Todo list, Done ledger (numbers reused; "Todo 3" is both Go to line and EPUB).
- `build.sh` — release build + hand-assembled `Nota.app` (binary + `Info.plist` + `Icon/Nota.icns`; no resource bundle, so assets are embedded in Swift); `--universal` builds arm64+x86_64 for release.
- `release.sh` — one-shot publisher: tags the version, `build.sh --universal`, zips it, pushes, opens the GitHub release, bumps the `manfad/homebrew-nota` tap cask.
- `Icon/` — `logo.png` (source art) → `make-icon.swift` → `Nota.icns`; `make-file-icons.py` → `Sources/Nota/FileKindArt.swift`.
- `file-icon/` — the file-kind badge art itself: `icons/` outlined and `icons-filled/` solid, one 96×64 SVG per extension in each, both in `currentColor`.
- `Info.plist` — document types Nota registers for.
