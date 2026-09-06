# Nota code map

Where things live, so a change starts in the right file. One line per file; the
file's own header comment says the rest. Line counts are rough and dated
2026-09-07. `SPEC.md` is the behaviour spec and the Todo/Done ledger; this file
is only the index.

Build: `swift build` · tests: `swift test --filter <Name>` (never the whole
suite while working) · app: `./build.sh` → `Nota.app` · icon:
`swift Icon/make-icon.swift` from `Icon/logo.png` · file-kind icons:
`python3 Icon/make-file-icons.py` from `../favcon/svg/cropped`.

## "I want to change…" → start here

| Change | File(s) |
|---|---|
| A menu item, its key, or app launch / windows / summon | `AppDelegate.swift`, keys in `Shortcuts.swift` |
| Anything in the main window: footer, split, modes, tabs, opening files, saving | `MainWindowController.swift` (see its sections below) |
| The save panel's Format combo, or the extensions it offers | `SaveNameComposer.swift` (pure logic), `MainWindowController.presentSavePanel` (the panel itself) |
| The tab strip (drawing, drag, close, +, tear-off) | `TabBarView.swift`, geometry in `TabStripLayout.swift` |
| ⇧⌘J switcher, `@` headings (text notes only), bookmarks dialog, ⇧⌘F search dialog, hover/arrow selection | `TabPickerPanel.swift` (also `refocusIfShowing`: the caret back in the field when Nota returns from another app or space), ranking in `FuzzyMatch.swift` |
| Settings window (draft + Save, sidebar pages) | `SettingsWindowController.swift`, values in `Preferences.swift` |
| "Check for Updates" on the About page | `UpdateCheck.swift` (the request, the comparison, Homebrew detection), the button and its line in `SettingsWindowController.aboutPage` |
| A new preference | `Preferences.swift` (key + property + `announce()`), then Settings UI |
| A user-visible string or its translation | `Localization.swift` (`L10n.text`), the languages themselves in `Preferences.swift` (`AppLanguage`) |
| Editor typing, paste, drop, images in the text | `NotaTextView.swift`, tokens ↔ chips in `NoteText.swift` |
| What a file *is* (sniff), encodings, line endings | `TextFile.swift` (`FileSniff`, `TextFile`) |
| A tab's model: kind, dirty, file, session record | `Note.swift`, `Session.swift` |
| Markdown render look | `MarkdownRenderer.swift`, `RenderStyle.swift`; maths `MarkdownMath.swift` |
| LaTeX render | `LaTeXParser.swift` → `LaTeXRenderer.swift`; formulas `MathParser.swift` + `MathLayout.swift` |
| Preview column plumbing (which view shows, zoom, scroll memory) | `PreviewPaneView.swift`, `PreviewContent.swift`, `RenderedPreviewView.swift` |
| PDF / picture / HTML / EPUB / RTF viewer tabs | `PDFPreviewView.swift`, `ImagePreviewView.swift`, `HTMLPreviewView.swift`, `EPUBPreviewView.swift` + `EPUBBook.swift`, `RTFPreviewView.swift` |
| A `.sql` dump's grid: running it, paging it, sorting it, picking cells out of it | `SQLPreviewView.swift` (the pane), `SQLGridView.swift` (the grid, its header and its cells), `SQLQueryBox.swift` (the query editor), `SQLDump.swift` (the database), `SQLSourceMap.swift` (which line of the file a row was written on, and where in it a cell's own value is), `SQLQueryRewrite.swift` (the rowid spliced into a query so its rows point at the file too) |
| A `.csv` / `.tsv` file's grid: reading it, paging it, sorting it | `CSVPreviewView.swift` (the pane, over `SQLGridView`), `CSVTable.swift` (the RFC 4180 reader and where each record and each field of it is written) |
| ⌘F find bar and its match bands (incl. dark-mode colours) | `FindBar.swift` (chrome), `FindSession.swift` (editor), `HTMLFindSession.swift` (`find(_:)` puts a ⇧⌘F hit's query to the page), `PDFFindSession.swift` (`reveal(_:for:)` lands on a ⇧⌘F hit) |
| ⌘J go to line | `GoToLine.swift`, line table `LineIndex.swift` |
| Floating pill chrome shared by find / go-to-line / external-change | `Pill.swift`, `ExternalChangePill.swift` |
| The corner slot (Editor · Split · Reading, plus a `.json`/`.html` tab's Beautify / Compact) | `ModeControlOverlay.swift` |
| Laying a `.json` file out or pulling it together | `JSONFormat.swift`; a page, `HTMLFormat.swift` |
| A `.json` / `.yaml` / `.toml` / `.xml` tab's tree beside its source | `TreePreviewView.swift` (the pane), the shape they all hand back `StructuredDocument.swift`, the parsers `JSONTree.swift` / `YAMLTree.swift` / `TOMLTree.swift` / `XMLTree.swift` |
| Reading a `.yaml`/`.toml` into the tree | `YAMLTree.swift`, `TOMLTree.swift` |
| Beautify / Minify a `.html` | `HTMLFormat.swift` |
| The zoom pill (`−  100%  +`) in the preview column's bottom-left | `ZoomPillOverlay.swift`, the percentage per content in `PreviewContent.swift` |
| Gutter / line numbers | `LineNumberRulerView.swift` |
| The sidebar column: a note's thumbnails, a book's contents, a PDF's pages, the title over each and the count badge beside it | `ImageSidebarView.swift`, `ContentsSidebarView.swift`, `PageListSidebarView.swift`, the card and the title they share `SidebarCards.swift`, which chips light up `ChipHighlight.swift` |
| Tab / picker / bookmark-menu icons | `FileKindIcon.swift`, art in `FileKindArt.swift` (generated) |
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
- `Preferences.swift` (~570) — every setting (`UserDefaults` + `Preferences.didChange`), enums `EditorFontFamily`, `LineSpacingOption`, `SidebarSide`, `PlainTextImageStyle`, `EditorPaddingOption`, `AppLanguage`, `AppTheme`; `shortcuts` table, `hotKey`; window chrome (`hidesTabBar`, `autoHidesTabBar`, `hidesTrafficLights`, `hidesBookmarkButton`, `hidesSettingsButton`); `highlightsCurrentLine` (the cursorline band, default off).
- `Shortcuts.swift` (~200) — `KeyCombo`, `ShortcutAction` (every adjustable menu key, defaults, groups, reserved combos), `NSMenuItem.applyShortcut`. ⌘D bookmarks the tab, ⇧⌘D shows the bookmarks; Jump to Tab… ⇧⌘J, Mode Toggle ⌘P, Reading Mode ⇧⌘P, Find and Replace ⌘R (fixed); duplicating a line is ⇧⌥↓ only.
- `Version.swift` — `AppVersion.current`; bumped with `Info.plist` by `.githooks/pre-commit` on every commit (`git config core.hooksPath .githooks`).
- `UpdateCheck.swift` (~190) — the About page's "Check for Updates": one anonymous request to GitHub's `releases/latest`, `Release` (tag without its `v`, page URL, name, date), `compare` over dotted integers, `Result` / `Reason` (offline, rate-limited, another status, unreadable, a tag that is not a version), and `installedWithHomebrew` — a `/Caskroom/` in the bundle path, or a `Caskroom/nota` under a Homebrew prefix. The transport is a closure, so no test reaches the network.
- `Localization.swift` (~545) — `L10n.text` and one table per language, all keyed by the English string: 简体中文, 繁體中文, Bahasa Melayu. `AppLanguage.resolved` (in `Preferences.swift`) says which one, resolving `.system` against the Mac's preferred language.
- `SettingsWindowController.swift` (~1380) — Settings: a sidebar source list over eight pages (General, Appearance, Editor, Preview, Tab bar, Status bar, Shortcuts, About), each page's controls in inset rounded groups of 44pt rows (`SettingsRowView`: label, optional `accessory` such as the `?` a row's help sits behind, control at the trailing edge); `row(help:)` + `showHelp` put a sentence in one transient `NSPopover`; draft-and-Save. Version shown on About comes from `Version.swift`; the update line there is a plain wrapping label with a fixed `preferredMaxLayoutWidth`, since the centred About stack gives a `WrappingLabel` no width.
- `ShortcutRecorderField.swift` (~150) — press-a-key field; records a global hotkey (key code) or an app `KeyCombo` (character).
- `GlobalHotKey.swift` (~170) — Carbon hotkey; `KeyCodeNames` (key code / key-equivalent display names).

### Main window
- `MainWindowController.swift` (~5200) — the whole window. Sections by `MARK`:
  Setup (346) · Text attributes (1105) · Auto-hidden tab strip (1414) · Session restore (1537) · Tabs (1688) · Encoding and line endings (1827) · Vim footer (2082) · Files (2443, open/save/close, sniff → viewer kinds) · External changes (2779) · Persistence (2927) · Font size and zoom (3035) · Menu actions (3118) · Zen mode (3220) · Tab picker (3698, `@` headings, text notes only) · Markdown preview (3808, modes, split, footer status of viewers; the sidebar side is recorded when the split is built) · The action in the corner (4296, the corner slot's segments and what a click on a tree, cell or block selects) · Images and book contents: chips and sidebar (4606) · Search across tabs (4856, `beginSearchAllNotes` opens the picker in `.search` over every tab's `searchSource`; `reveal` takes a hit to where it lives — the editor's selection, the document's page, the book's chapter) · Delegates / Vim's window (4891) · Background (5216) · Quick Look (5229).
  Also here: `DocumentSplitViewController` + `DocumentSplitView` (the editor/preview split; the divider is not drawn outside split mode), `VimCommandPane`, `DragRegionView`, `BackgroundView`.
  Footer regions: `statusLabel` (counts, `updateCountsLabel` / `availableCountsWidth`), `footerTrailingStack` (encoding · line ending · cursor), `modeBadge` (vim).
- `TabBarView.swift` (~1600) — the strip: `TabBarItem`, `TabItemView` (icon, dot, ✕, bookmark badge), drag/reorder, tear-off, + button, bookmark and Settings-gear buttons at the trailing edge, context menu.
- `TabStripLayout.swift` (~200) — pure width arithmetic for the strip.
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
- `Note.swift` (~690) — `PreviewMode`, `RenderedPreviewKind` (`.tree(StructuredFormat)` among them), `NoteKind` (`text`/`pdf`/`image`/`epub`/`rtf`), `Note` (storage, file, dirty, watcher, cached PDF/image/book/rich text, `searchSource` — what the tab hands ⇧⌘F, its viewer parts cached beside the rest — `sessionTab()`).
- `NoteText.swift` (~380) — `![](nota://id)` tokens ↔ attachments, and, given a closure for each direction, a
  saved file's own relative image links too: `serialize(_:sidecar:)` and `render(_:…:importing:)`. Touches no disk.
- `Sidecar.swift` (~215) — the pictures a saved note keeps beside it in `<basename>.assets/`: folder naming,
  percent-encoded links, which link targets are relative paths, the identical-bytes check, `Writer` (save) and
  `importer(forFileAt:assets:)` (open).
- `Assets.swift` (~250) — `NotaImageAttachment` chips, `AssetStore` on disk.
- `TextFile.swift` (~430) — `LineEnding`, `TextFileFormat`, encoding detection, `FileSniff.classify` (PDF, image, EPUB, RTF, text, binary), `FileClass`, `isDrawing` (an `.svg` is text, not a picture — `Note.isImageFile` and the exclusions ask it).
- `Session.swift` (~555) — `TextStats` (footer count phrases incl. pages/chapters/tables, a table's rows and columns, and a row range), `SessionTab` / `SessionWindow` codables (`sqlTable` / `sqlQuery` for a dump's tab), `SessionStore`.
- `SaveNameComposer.swift` (~55) — pure logic for the save panel's Format combo: known extensions, splitting a name from its extension, composing the final name.
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
- `HTMLFormat.swift` (~650) — Beautify and Minify for `.html`. Nota's own byte tokeniser over a page (doctype,
  comments, start and end tags with every attribute form, void and self-closing tags, and the raw-text elements
  `script`/`style`/`pre`/`textarea`/`title`), the tree it builds from it, and the two writers over that tree.
  `JSONFormat`'s three questions — `reformat(_:as:)`, `isPretty(_:)`, `errorLine(in:)` — asked of a page.
- `HTMLClipboard.swift` (~290) — reading `public.html` / web archives on paste.
- `TaskList.swift` (~200) — `- [ ]` boxes in render and source.
- `ListContinuation.swift` (~365) — what Return means on a list item, as pure functions: `ListMarker.parse(line:above:)`, `.next()`, `.prefix`, and `ListContinuation.edit(forReturnIn:at:)`. The header explains how a lone `i.` is read.

### Find, go-to-line, pills
- `Pill.swift` (~330) — `PillView` chrome (`symbol`, `symbolWithChevron` — a glyph and a small chevron as one image, for a button that opens something), `PillFieldEditor`, `PillActionResponder`, `floatBottom`.
- `FindBar.swift` (~350) — `FindBarView` (query pill; the glass toggles the replace pill and wears a chevron while it can), `ReplaceBarView` (the replace pill; its arrows are a button with a chevron up that folds it away through `onCollapse`), tooltips from the shortcut table.
- `FindSession.swift` (~530) — `TextFindSession` for the editor and rendered panes; `NSTextView.setFindHighlights` and `quietFindBand` (light: label wash, dark: dimmed find yellow).
- `HTMLFindSession.swift` (~525) — same for WebKit pages (CSS highlights).
- `PDFFindSession.swift` (~380) — same for PDFKit.
- `GoToLine.swift` (~290) — ⌘J pill.
- `ExternalChangePill.swift` (~90) — "Changed on disk · Reload / Keep mine".

### Preview column and renderers
- `PreviewContent.swift` (~430) — `PreviewContentKind` (markdown/latex/html/pdf/image/epub/sql/csv/rtf/tree), `ContentsEntry` (one line of a table of contents), `PageListSource` (a document read page by page: count, page in front, go to one, draw one), the `PreviewContent` protocol every content view adopts (`show`, zoom, find, `rememberedPosition`, `rememberedScroll`, `footerStatus`, `contentsEntries` / `currentContentsLine` / `goToContentsLine`, `pageList`, `onStateChange`, `onBlockClick` and `onSourceReveal` — a click that takes the caret with it and one that only moves it — `onDropFiles`), and `PreviewFileDrop` — the drop from the Finder every view in the column answers the same way.
- `PreviewPaneView.swift` (~315) — holds one content view at a time; `panes` for tests; `onDropFiles` goes to every content view and to zen's drag band, so the whole column is a tab target.
- `RenderedPreviewView.swift` (~670) — base class for rendered text panes (blocks, band, click-back, find, frozen wrap width).
- `MarkdownPreviewView.swift` (17) / `LaTeXPreviewView.swift` (21) — the two subclasses.
- `RenderStyle.swift` (~190) — `RenderedDocument`, block styles shared by both renderers.
- `MarkdownRenderer.swift` (~590) — Markdown → attributed string, `MarkdownImageAttachment`.
- `MarkdownSourceMap.swift` (~330) — rendered block → source range.
- `MarkdownHeadings.swift` (~130) — headings for `@` in ⌘P.
- `MarkdownMath.swift` (~400) — `$…$` lifted out before parsing. `MathParser.swift` (~575), `MathLayout.swift` (~720), `MathAttachment.swift` (~40) — Nota's own formula layout.
- `LaTeXParser.swift` (~1360) — `.tex` → blocks. `LaTeXRenderer.swift` (~480) — blocks → attributed string.
- `HTMLPreviewView.swift` (~820) — WebKit page under `nota-file://`, scroll memory (pixels and fraction), `showPage(ofTab:at:…)` for EPUB chapters, chapter-key script, and the dark-mode reader theme a book asks for (`appliesReaderTheme`, `readerThemeCSS`).
- `PDFPreviewView.swift` (~600) — PDFKit viewer tab, `reveal(page:range:query:)` for a ⇧⌘F hit, and `PDFPageThumbnails` (pages drawn small on one serial queue, from a second `PDFDocument` of the file, cached per document for the sidebar's page list). No outline: a PDF's sidebar is its pages. `ImagePreviewView.swift` (~240) — picture tab.
- `EPUBBook.swift` (~490) — unpack (ditto), container/OPF/spine/nav/NCX parsing, `contentsEntries`, `contentsLine(ofChapter:)`, `words(ofChapter:)` (the chapter's text with the markup left behind, block elements on lines of their own — what ⇧⌘F searches a book by). `EPUBPreviewView.swift` (~300) — chapter viewer; no floating chapter bar.
- `RTFPreviewView.swift` (~430) — the rich-text viewer tab: `NSAttributedString(url:…)` into a read-only, selectable
  `NSTextView` at the editor's margin, the document's own fonts and colours kept (black body text swapped for
  `labelColor`), `TextFindSession` for ⌘F, and a zoom that scales every font, paragraph measurement and attachment.
- `SQLDump.swift` (~715) — a `.sql` file run into an in-memory SQLite (`import SQLite3`, no dependency): the
  prepare/tail loop and the first failure's own statement, the `SQLSourceMap` it takes down as it goes, `tables`,
  `page(ofTable:offset:sort:)` / `page(ofQuery:…)` (`LIMIT 100 OFFSET`, `COUNT(*)`, and the rowids a page carries
  beside its values with the table they belong to), `declaredTypes(ofTable:)`, `hasRowid(_:in:)`, and the read-only
  authorizer the query box runs under. Knows nothing of AppKit.
- `SQLPreviewView.swift` (~1105) — the pane that draws it: the query box under the corner slot's hover band, table
  picker, the one `arrow.clockwise` button that runs the file again (and is a big dump's only way in), page bar, the grid's data source, the sort a header click asks for (`tableView(_:didClick:)`, on the
  release — see the header's own note), the alerts a failing query or a failing file put up (once per message, with
  `alertOverrideForTesting` for the tests), runs on its own queue with a token, and the per-tab table and query it
  writes onto the note.
- `SQLGridView.swift` (~485) — the grid itself: the spreadsheet cell cursor (click one, drag a rectangle, arrows and
  ⇧-arrows, ⌘C as tab-separated text), whole rows from the `#` gutter, ⇧ and Space, the cell click it reports
  (`onCellClick`) for the pane to take back to the file, `SQLCellView` drawing the accent wash
  and the rectangle's hairline, and `SQLHeaderView` / `SQLHeaderCell` — the flat header with its own sort chevron.
- `SQLSourceMap.swift` (~490) — where each row of a dump is written: the statements `SQLDump` took down as it ran
  (each one's own characters, and the rowids an insert made), the two lookups a clicked cell is answered from — the
  row's tuple, and the one *value* inside it the clicked column stands for, quotes included — and the scanners they
  need: the table an `INSERT` names, the column list it named, the `(…)` tuples after `VALUES`, and the values
  inside one tuple, all counted outside string literals, quoted identifiers and comments. Pure text and no SQLite.
- `SQLQueryRewrite.swift` (~175) — the loose read of a query that says whether it is plainly one table's rows, and
  the same query with that table's rowid spliced in after the `SELECT` keyword, so a cell of a query's result walks
  the editor to its `INSERT` the way a table's does. What it refuses — a join, a `GROUP BY`, an aggregate, a
  sub-select — and what SQLite refuses are both answered by running the reader's own query untouched. Pure text and
  no SQLite; it borrows `SQLSourceMap`'s scanner.
- `SQLQueryBox.swift` (~230) — the five-row query editor: rounded bezel, `SELECT …` placeholder, Return a newline,
  ⌘↩ the run, Esc the cancel, no rich text and no substitutions.
- `CSVTable.swift` (~330) — a `.csv` or `.tsv` read as the table it is: Nota's own RFC 4180 scanner (quoted fields,
  `""` escapes, newlines inside quotes, CRLF / CR / LF, a trailing newline, a BOM, blank lines skipped), the first
  record as the header with blanks named `Column 3`, ragged rows padded and widened, the `NSRange` of the lines each
  record is written on and of every *field* of it as written (`fieldSources`, quotes included — what a clicked cell
  selects), and `page(offset:sort:)` — a hundred rows, sorted numerically where the whole column parses as numbers
  and by the reader's own collation where it does not. Pure; knows nothing of AppKit.
- `CSVPreviewView.swift` (~810) — the pane that draws it: the dump's pane with the database taken out — one bar of
  `Refresh` and the page arrows under the corner slot's hover band, `SQLGridView` below it unchanged, the sort a
  header click asks for, the `onSourceReveal` a cell click sends, and the read it runs on its own queue with a
  token (a big file only ever on the button).
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
- `TreePreviewView.swift` (~830) — the pane that draws whatever any of the four hands back: an `NSOutlineView`
  (one column, no header, painting no background of its own — the pane's layer is the document colour, since an outline given it came out a shade off in the dark — the editor's margin, starting 14pt down like the source),
  a row's key then its value coloured by type, `{3}` / `[12]` after a closed branch, expansion seeded by the
  document's size and then remembered by node path across re-renders, the scroll kept, a click selecting the
  node's source (a leaf its value, a branch its whole span, key and value) without taking the keyboard, the
  caret's line lighting the node that line begins, and one centred message in place of the tree for a file that
  will not parse. `TreeClipView` hands a click inside the clip view's top inset on to the outline, since
  `NSClipView` refuses it and the rows scrolled under the corner band were dead.
- `FileKindIcon.swift` (~160) — extension → icon name; `image(named:pointSize:)` (drawn art at 1.5× point size, SF Symbol fallback). `FileKindArt.swift` (generated) — the SVGs.

### Vim (`Sources/Nota/Vim/`)
- `VimEngine.swift` (~960) — the state machine and `VimEngineHost` (what it needs from the window).
- `VimKey.swift` — a key press in vim terms. `VimMode.swift` — modes. `VimCursorDrawing.swift` — caret shapes.
- `VimMotions.swift`, `VimOperators.swift`, `VimTextObjects.swift`, `VimVisual.swift` — motions, operators, `iw`/`ip`/…, visual mode.
- `VimSearch.swift` — `/` `?` `n` `N`. `VimMarks.swift`, `VimRegisters.swift`, `VimRepeat.swift` (`.`), `VimMacros.swift` (`q`/`@`).
- `VimCommandLine.swift` — the `:` / `/` prompt line. `VimEx.swift` — ex address/range parsing. `VimExCommands.swift` — running `:` commands. `VimHelp.swift` — `:help`. `VimScratch.swift` — `:reg` / `:marks` tabs.

## Tests (`Tests/NotaTests/`)
`swift test --filter <ClassName>` or `--filter <testName>`.

- `NotaTests.swift` (~4200, 115 tests) — the grab bag: editor, footer, Settings window, find bands, ⌘P hover, session, `NoteSearch` itself.
- `MarkdownPreviewTests.swift` (~140) — preview modes, split, picker rows, the ⇧⌘F search dialog over text tabs, sidebar.
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
- `YAMLTreeTests.swift` (49) — block and flow mappings and sequences, the compact forms, all five scalar styles and
  chomping, anchors/aliases/merge keys, `---` documents, the core-schema types, and every refusal with its line.
- `TOMLTreeTests.swift` (34) — keys and dotted keys, table headers and implicit super-tables, arrays of tables,
  inline tables, all four string forms, numbers and dates kept as spelled, and duplicate-key/table refusals.
- `JSONFormatTests.swift` — the walker: order, escapes, empties, unicode, pretty detection, error line.
- `HTMLFormatTests.swift` (56) — the tokeniser and both writers: every tag and attribute form kept byte for byte,
  raw-text elements untouched, block/inline line-breaking, whitespace collapsing, stray and left-out end tags, and
  the disabled cases (unterminated comment, unclosed tag or quote, unclosed raw element, nesting past 256).
- `HTMLPreviewTests.swift`, `PDFTests.swift`, `ImageTests.swift`, `EPUBTests.swift`, `RTFTests.swift` — the viewer tabs, including the sidebar each of them fills (an RTF has none) and the ⇧⌘F hit each of a document and a book answers with (`PDFTests`, `EPUBTests`). `PDFTests` covers the page list: the title over it, the cards and their captions, a click going to a page, the ring following the pages, the thumbnails landing off a background queue, two documents of the same length not sharing a list, and a document with bookmarks listing pages just the same.
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
- `LaTeXTests.swift`, `MathTests.swift`, `MarkdownMathTests.swift`, `MarkdownHeadingsTests.swift`, `TaskListTests.swift` — renderers.
- `TextFileTests.swift`, `FileSniffTests.swift`, `FileKindIconTests.swift`, `LineIndexTests.swift`, `LineOperationsTests.swift`, `ListContinuationTests.swift` — files and editor logic.
- `LocalizationTests.swift` (~170) — the tables against each other, `.system` resolution, the Settings language popup.
- `UpdateCheckTests.swift` (18) — the update check with a stub transport: a newer release, the same version, a version ahead of the server, a tag without its `v`, malformed JSON, 403/429, another status, a transport error, a tag that is not a version, the comparison table, and the Homebrew rule. The button itself is in `NotaTests.testAboutPageChecksForUpdates`.
- `ZoomPillTests.swift` (12) — the pill: which tabs carry it, the percentage it reads, showing on a zoom and on
  hover, the hold and its restart, pressing it as the keys, and taking itself away at once for a tab with no zoom.
- `SaveNameComposerTests.swift` (13) — the save panel's name logic: splitting a known extension off, a typed name winning over the combo, dotfiles, trimming, the composed URL, and the last extension round-tripping through Preferences.
- `TabHoverTests.swift` (3) — the strip's three greys: selected fill, the pointer's wash on an unselected tab, nothing at rest.
- `WindowChromeTests.swift` (11) — Settings › Appearance › Window: the strip, the traffic lights and the strip's two trailing buttons each switched off and back.
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
- `Info.plist` — document types Nota registers for.
