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
| The Save dialog: its rows, its Format popup, or the extensions it offers | `SaveDialog.swift` (the dialog itself), `LocationRow.swift` (the `Location:` row it shares with the export sheet), `SaveNameComposer.swift` (pure logic), `MainWindowController.presentSavePanel` (which puts it up) |
| File › Export…: what a tab can be exported to, the one sheet that asks (shape, pictures, name, folder), the pages themselves | `Export.swift` (the targets and the hooks other exporters plug into), `ExportHooks.swift` (the six exporters plugged in, one call), `ExportDialog.swift` (the sheet), `LocationRow.swift` (its `Location:` row), `PDFPaginator.swift` (text and plates onto pages), `SnapshotPNG.swift` (the same text as one tall picture of the screen), `TablePDF.swift` (a grid onto pages), `MainWindowController` "Export" |
| File › Print… (⌥⌘P): the PDF the tab's first target makes, handed to the system dialog | `MainWindowController` "Print" (`canPrintCurrentTab`, `printCurrentTab`, `printOperationRunner`), the key in `Shortcuts.swift` (`ShortcutAction.printTab`) |
| The tab strip (drawing, drag, close, +, tear-off) | `TabBarView.swift`, geometry in `TabStripLayout.swift` |
| ⇧⌘J switcher, `@` headings (text notes only), bookmarks dialog, ⇧⌘F search dialog, hover/arrow selection | `TabPickerPanel.swift` (also `refocusIfShowing`: the caret back in the field when Nota returns from another app or space), ranking in `FuzzyMatch.swift` |
| Settings window (live apply, no Save; sidebar pages) | `SettingsWindowController.swift`, the File types list in `SettingsOutlineView.swift`, values in `Preferences.swift` |
| Settings › File types: which extensions Nota is the default app for | the list and the Launch Services door `DefaultApp.swift`, the page `SettingsWindowController.fileTypesPage`, what was default before `Preferences.previousDefaultApps` |
| "Check for Updates" on the About page | `UpdateCheck.swift` (the request, the comparison, Homebrew detection), the button and its line in `SettingsWindowController.aboutPage` |
| A new preference | `Preferences.swift` (key + property + `announce()`), then Settings UI |
| A user-visible string or its translation | `Localization.swift` (`L10n.text`), the languages themselves in `Preferences.swift` (`AppLanguage`) |
| Editor typing, paste, drop, images in the text | `NotaTextView.swift`, tokens ↔ chips in `NoteText.swift` |
| What a file *is* (sniff), encodings, line endings | `TextFile.swift` (`FileSniff`, `TextFile`) |
| A tab's model: kind, dirty, file, session record | `Note.swift`, `Session.swift` |
| Markdown render look | `MarkdownRenderer.swift`, `RenderStyle.swift`; maths `MarkdownMath.swift` |
| A ```` ```mermaid ```` fence's diagram | `Mermaid.swift` (which grammar, and the one door), `MermaidFlowchart.swift` / `MermaidSequence.swift` (a grammar each: parser, layout, drawing), `MermaidAttachment.swift` (the block it becomes); the fence is lifted out of the source in `MarkdownMath.swift` |
| LaTeX render | `LaTeXParser.swift` → `LaTeXRenderer.swift`; formulas `MathParser.swift` + `MathLayout.swift` |
| Exporting a `.tex` through a real TeX (finding one, installing Tectonic, compiling) | `TeXEngine.swift`, `TectonicInstaller.swift`, the prompt and the one call `TeXExport.swift` |
| Preview column plumbing (which view shows, zoom, scroll memory) | `PreviewPaneView.swift`, `PreviewContent.swift`, `RenderedPreviewView.swift` |
| PDF / picture / HTML / EPUB / RTF viewer tabs | `PDFPreviewView.swift`, `ImagePreviewView.swift`, `HTMLPreviewView.swift`, `EPUBPreviewView.swift` + `EPUBBook.swift`, `RTFPreviewView.swift` |
| Converting between the things Nota reads: a book or a page printed as a PDF, a PDF read back as a book | `WebPDF.swift` (WebKit's print operation, headless), `EPUBToPDF.swift` (chapters printed and bound), `PDFToEPUB.swift` (a text layer reflowed into EPUB 3) |
| A `.sql` dump's grid: running it, paging it, sorting it, picking cells out of it, ⌘F over it | `SQLPreviewView.swift` (the pane), `SQLGridView.swift` (the grid, its header and its cells), `SQLQueryBox.swift` (the query editor; its dropdown is `SQLCompletionPopup.swift` over `SQLCompletion.swift`, which also colours the keywords), `SQLDump.swift` (the database), `SQLDumpDialect.swift` (a MySQL, MariaDB, Postgres, SQL Server or Oracle dump made SQLite's), `SQLSourceMap.swift` (which line of the file a row was written on, and where in it a cell's own value is), `SQLQueryRewrite.swift` (the rowid spliced into a query so its rows point at the file too), `GridFindSession.swift` (⌘F over the grid; `SQLDump.hits` is the one statement that answers it) |
| A `.csv` / `.tsv` file's grid: reading it, paging it, sorting it, ⌘F over it | `CSVPreviewView.swift` (the pane, over `SQLGridView`), `CSVTable.swift` (the RFC 4180 reader, `ordering` — the order the grid and its ⌘F walk — and where each record and each field of it is written) |
| The Export CSV button on a `.sql` or `.csv` grid, its sheet, or the CSV a table writes out | `CSVExportDialog.swift` (the sheet: `Export with` over the grid's columns ticked or not, Save As pinned to `csv`, the shared `LocationRow`, `CSVExportChoice` back), `CSVWriter.swift` (the RFC 4180 writer, in-memory and streaming), `SQLDump.forEachRow` / `CSVTable.exportRows` (every row, in the grid's sort order, no page cut out of it), `SQLPreviewView.exportCSV(to:columns:)` / `CSVPreviewView.exportCSV(to:columns:)` (the plain functions behind the button, the chosen columns only) and `exportTable()` beside each (the same rows handed back rather than written, for `TablePDF`), `MainWindowController.runCSVExportDialog(suggestedName:columns:existingFileURL:)` / `csvExportDialogProvider` (the sheet on the window, and its test seam). File › Export… no longer offers a CSV: the button is the one way to one. |
| ⌘F find bar and its match bands (incl. dark-mode colours) | `FindBar.swift` (chrome), `FindSession.swift` (editor; the fallback every column hands an unwanted Find item back to is `MainWindowController.performTextFinderAction`), `HTMLFindSession.swift` (`find(_:)` puts a ⇧⌘F hit's query to the page), `PDFFindSession.swift` (`reveal(_:for:)` lands on a ⇧⌘F hit), `TreeFindSession.swift` (a tree preview's rows), `GridFindSession.swift` (a `.csv` or `.sql` grid) |
| ⌘J go to line | `GoToLine.swift`, line table `LineIndex.swift` |
| Floating pill chrome shared by find / go-to-line / external-change / the format offer | `Pill.swift`, `ExternalChangePill.swift`, `FormatOfferPill.swift` |
| The corner slot (Editor · Split · Reading, plus the editor's Beautify / Compact on a `.json`/`.html` tab and the preview's own Expand All / Collapse All on a tree or Reload on a page) | `ModeControlOverlay.swift` |
| The footer's format badge and its menu / what a tab is read as / the Save As it owes | `Note.swift` (`NoteFormat`, `Note.formatOverride`, `Note.needsSaveAs`), `MainWindowController` "The format badge" and `save(note:forcePanel:)` |
| The detector that reads a note's text / the pill after a typing pause / the sheet after a paste | `FormatDetector.swift` (pure), `FormatOfferPill.swift` (the pill and `FormatOfferAlert`), wiring in `MainWindowController` "The format offer" |
| Laying a `.json` file out or pulling it together | `JSONFormat.swift`; a page, `HTMLFormat.swift` |
| A `.json` / `.yaml` / `.toml` / `.xml` tab's tree beside its source | `TreePreviewView.swift` (the pane), the shape they all hand back `StructuredDocument.swift`, the parsers `JSONTree.swift` / `YAMLTree.swift` / `TOMLTree.swift` / `XMLTree.swift` |
| Reading a `.yaml`/`.toml` into the tree | `YAMLTree.swift`, `TOMLTree.swift` |
| Beautify / Minify a `.html` | `HTMLFormat.swift`, the CSS and JavaScript inside it `InlineCodeMinify.swift` |
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
| Vim (engine only; the Settings switch is shelved for 2.0, `defaults write com.manfad.nota vimMode -bool YES` turns it on) | `Vim/` (see below) |
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
- `Preferences.swift` (~570) — every setting (`UserDefaults` + `Preferences.didChange`), enums `EditorFontFamily`, `LineSpacingOption`, `SidebarSide`, `PlainTextImageStyle`, `AppLanguage`, `AppTheme`; `shortcuts` table, `hotKey`; window chrome (`hidesTabBar`, `autoHidesTabBar`, `hidesTrafficLights`, `hidesBookmarkToggleButton`, `hidesBookmarkButton` — the older key, which means the *dialog* button, `hidesSettingsButton`); `highlightsCurrentLine` (the cursorline band, default off); `zenShowsLineNumbers` / `zenShowsGutterSeparator` / `zenHighlightsCurrentLine` (the gutter trio zen consults instead of the everyday one, all default off).
- `Shortcuts.swift` (~200) — `KeyCombo`, `ShortcutAction` (every adjustable menu key, defaults, groups, reserved combos), `NSMenuItem.applyShortcut`. ⌘D bookmarks the tab, ⇧⌘D shows the bookmarks; Jump to Tab… ⇧⌘J, Mode Toggle ⌘P, Reading Mode ⇧⌘P, Find and Replace ⌘R (fixed); duplicating a line is ⇧⌥↓ only. Export… is ⇧⌘E (⌘E stays the Mac's Use Selection for Find) and Print… is ⌥⌘P (⌘P is the mode toggle).
- `LaunchTiming.swift` (~80) — where a launch's time goes: `mark(_:)` at each phase from `main` to the window becoming key, printed to stderr a second after launch when the binary runs with `NOTA_LAUNCH_TIMING=1` (the binary itself, not `open`, which drops the environment); the first line is the kernel's exec time, so dyld and the runtime show as the gap to `main`. A `Bool` read and nothing else without the variable.
- `Version.swift` — `AppVersion.current`; bumped with `Info.plist` by `.githooks/pre-commit` on every commit (`git config core.hooksPath .githooks`).
- `UpdateCheck.swift` (~190) — the About page's "Check for Updates": one anonymous request to GitHub's `releases/latest`, `Release` (tag without its `v`, page URL, name, date), `compare` over dotted integers, `Result` / `Reason` (offline, rate-limited, another status, unreadable, a tag that is not a version), and `installedWithHomebrew` — a `/Caskroom/` in the bundle path, or a `Caskroom/nota` under a Homebrew prefix. The transport is a closure, so no test reaches the network.
- `Localization.swift` (~545) — `L10n.text` and one table per language, all keyed by the English string: 简体中文, 繁體中文, Bahasa Melayu. `AppLanguage.resolved` (in `Preferences.swift`) says which one, resolving `.system` against the Mac's preferred language.
- `SettingsWindowController.swift` (~1700) — Settings: a sidebar source list over eight pages (General, Appearance, Editor, Tab bar, Status bar, Shortcuts, File types, About), each page's controls in inset rounded groups of 44pt rows (`SettingsRowView`: label, optional `accessory` such as the `?` a row's help sits behind, control at the trailing edge) — except File types, which is one `SettingsOutlineView` (it says a Launch Services refusal on the row rather than swallowing it, and carries a Restore previous apps button beside the claim-them-all one); `row(help:)` + `showHelp` put a sentence in one transient `NSPopover`; no Save button — every control writes its own preference on the change (`apply {}` guards the notification coming back), language and theme `refresh()` afterwards, and a clashing shortcut is refused rather than written. General's third row, `openingModeControl`, is the Editor / Split / Preview segmented control for `Preferences.openingMode`. The Editor page ends in its own Zen block (`sectionHeading("Zen")` over a second group box) — line numbers, gutter separator, highlight current line for `Preferences.zenShowsLineNumbers` / `zenShowsGutterSeparator` / `zenHighlightsCurrentLine`, consulted only while the window is in zen mode. Version shown on About comes from `Version.swift`; the update line there is a plain wrapping label with a fixed `preferredMaxLayoutWidth`, since the centred About stack gives a `WrappingLabel` no width.
- `DefaultApp.swift` (~180) — Settings › File types, everything but the page: `DefaultAppTypes.groups` (the four
  groups and their forty extensions, the one place to add one), `extensions(sharingTypeWith:)` (Launch Services keeps
  one default per *type*, so `.md` and `.markdown` are one setting wearing two rows), `DefaultAppBundle` (an app's
  URL, name and identifier), the `DefaultAppRegistry` protocol — the one door to Launch Services — and
  `SystemDefaultAppRegistry` over `NSWorkspace`, which refuses to set anything under XCTest, since a machine's
  default apps are the clipboard rule one shelf up.
- `SettingsOutlineView.swift` (~360) — the folding list Settings › File types is made of: `SettingsOutlineItem` (tick box, title, optional `?`, trailing text, children), `SettingsOutlineCellView`, banded `SettingsOutlineRowView`, and the `NSOutlineView` in its rounded card. Every row's controls belong to the item and every cell is built with the page, so a page can write a row that has never been drawn.
- `ShortcutRecorderField.swift` (~150) — press-a-key field; records a global hotkey (key code) or an app `KeyCombo` (character).
- `GlobalHotKey.swift` (~170) — Carbon hotkey; `KeyCodeNames` (key code / key-equivalent display names).

### Main window
- `MainWindowController.swift` (~5500) — the whole window. Sections by `MARK`:
  Setup (358) · The format offer (824, the debounce, `runFormatDetection()` and who is offered anything at all) · Text attributes (1229) · Auto-hidden tab strip (1539) · Session restore (1662) · Tabs (1817) · The format badge (1966, the badge's menu and `setFormat` — the one path a tab's format ever changes by, which a Save As under a new name shares) · Encoding and line endings (2035) · Vim footer (2290) · Files (2654, open/save/close, sniff → viewer kinds) · Export (the sheet, the one export dialog behind File › Export… and both grids' buttons, `isExporting`, the footer's running commentary) · Print (⌥⌘P: the tab's first target into a temp PDF, then `PDFDocument.printOperation` as a sheet; a PDF tab prints itself) · External changes (3004) · Persistence (3155) · Font size and zoom (3263) · Menu actions (3346) · Zen mode (3448) · Tab picker (3926, `@` headings, text notes only) · Markdown preview (4036, modes, split, footer status of viewers; the sidebar side is recorded when the split is built) · The action in the corner (4531, the corner slot's segments — the editor's Beautify / Compact and the preview's own Expand All / Collapse All or Reload — and what a click on a tree, cell or block selects) · Images and book contents: chips and sidebar (4841) · Search across tabs (5090, `beginSearchAllNotes` opens the picker in `.search` over every tab's `searchSource`; `reveal` takes a hit to where it lives — the editor's selection, the document's page, the book's chapter) · Delegates / Vim's window (5141) · Background (5468) · Quick Look (5481).
  Also here: `DocumentSplitViewController` + `DocumentSplitView` (the editor/preview split; the divider is not drawn outside split mode), `VimCommandPane`, `DragRegionView`, `BackgroundView`.
  Footer regions: `statusLabel` (counts, `updateCountsLabel` / `availableCountsWidth`), `footerTrailingStack` (format · encoding · line ending · cursor — the format badge is the one that gives way in a narrow window, so four badges never put a floor under the window itself), `modeBadge` (vim).
- `TabBarView.swift` (~1650) — the strip: `TabBarItem`, `TabItemView` (icon, dot, ✕, bookmark badge), drag/reorder, tear-off, + button, the three trailing buttons (`BookmarkToggleButton` — ⌘D on the front tab, filled once it is bookmarked, greyed with no file; `BookmarksButton` — the ⇧⌘D picker, `book.closed`; `SettingsButton`), context menu.
- `TabStripLayout.swift` (~240) — pure width arithmetic for the strip, the three trailing slots included (`TrailingControls`, `bookmarkToggleX` / `bookmarkX` / `settingsX`).
- `TabPickerPanel.swift` (~1200) — ⇧⌘J panel: modes `.tabs` / `.headings` (`@`, text notes only — a book's contents are in the sidebar) / `.bookmarks` / `.search` (⇧⌘F over `[NoteSearchSource]`, two-line hit rows, no top row); top fixed row; arrow keys and hover selection (`HoverTrackingTableView`); `TabPickerRowView`.
- `FuzzyMatch.swift` (~80) — subsequence scoring for the picker.
- `ModeControlOverlay.swift` (~620) — the corner slot: the hover band per column, and the one capsule the
  front tab puts in it (`Content` — the Editor · Split · Reading segments, those same three plus a fourth, or
  nothing). The fourth segment is the *column's* own action, not the tab's: in the editor it is a `.json` or
  `.html` tab's Beautify / Compact (`FormatKind` names the two formats and their words, `FormatState` which way
  round it points or the line the parse gave up on), and in the preview it is what can be done to the view
  (`PreviewActionKind` — a tree or a page — and `PreviewAction` — Expand All, Collapse All, Reload). Either way it
  is a segment of the same `.selectOne` control, a click on it fires the action and puts the selection back on the
  mode, and every index goes through `Content.hasActionSegment`. The band, the fade, the hit testing and the drop
  under ⌘F know nothing of which.
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
- `SaveNameComposer.swift` (~100) — pure logic for the Save dialog's Format popup: known extensions, the list one
  the popup does not know is put in front of (`formatOptions(including:)`), splitting a name from its extension,
  composing the final name — and `composedName(name:pinnedExtension:)`, the export sheet's own rule, where the
  extension is the target's and the name never talks it out of one.
- `LocationRow.swift` (~115) — the `Location:` row both of Nota's own file dialogs wear: the read-only field with
  the folder's own icon and name and the whole path behind its tooltip, the `Choose…` button and the `NSOpenPanel`
  it runs inside the dialog's own modal session, `openingURL(existingFileURL:lastDirectory:)` — the file's folder,
  else the remembered one, else Documents — and the `onChange` a dialog whose buttons depend on the folder hangs
  off it.
- `SaveDialog.swift` (~440) — Nota's own Save dialog in place of `NSSavePanel`: the sheet's two rows (name with the
  Format popup at its end, the shared `LocationRow`), Cancel and a default Save, `runSheet(on:)` pumping
  `NSApp.runModal` so the window still sees one synchronous `URL?`, the replace question handed back to the window,
  the `Preferences.didChange` relabelling that lets a language change land while it is open, and the popup's
  `None` and `Other…` tail (a field for an extension the list does not carry).
- `Export.swift` (~360) — File › Export…'s core (SPEC "## Export"): `ExportTarget` (what a tab can be
  exported to) and `Exporter` — the targets each kind offers in the sheet's own order, the two PDFs Nota
  writes itself (the render, the document or the picture as shown; the editor's source listing, with its
  gutter's numbers and its pictures inline or as plates), the two PNGs it also writes itself through
  `SnapshotPNG` (the same two, as the screen has them rather than as paper — `snapshotsRender` decides which
  tabs have a preview worth photographing, and `Context.screenWidth` / `pictureAppearance` say at what measure
  and under which appearance), and the empty hooks the other exporters plug into
  (`bookPDF`, `pdfToEPUB`, `csv`, `texPDF`, `htmlPagePDF` for a page as WebKit draws it, and `tablePDF` for a
  grid as the grid, whose `nothingToExport` — a pane that has not read its tab — falls back to the listing at the
  same destination — a target whose hook is nil is never listed). A hook is
  `(Note, URL, Context, @escaping (Result<Void, Error>) -> Void)`:
  asynchronous throughout, since three of them go through WebKit or a download and none may be waited on
  with a semaphore. The context carries the live pane for an exporter whose answer is on screen rather than in
  the note, the window a prompt would be a sheet on, and the `progress` closure a long export talks to the
  footer through. `ExportImagePlacement` is the sheet's `Image` row and `Preferences.exportEditorImages`;
  `gatherPlates` is the one way pictures are ever moved to the back — the `[n] name` tag left on the line, the
  plate and its `Figure n · name · line n` caption at the end — and both the listing and the Markdown render
  come through it, so a note's pictures are gathered the same way whichever half of the tab is being written.
- `ExportHooks.swift` (~130) — the one place the six exporters are introduced to `Exporter`:
  `installDefaultHooks()`, called by `AppDelegate` at launch and by the tests that need those targets listed.
  A book through `EPUBToPDF`, a document through `PDFToEPUB`, a grid through the pane's own `exportCSV(to:)`
  and, onto pages, through its `exportTable()` and `TablePDF`,
  a `.tex` through `TeXExport` (falling back to the `.previewPDF` render at the same destination on
  `useNativeRender`, and passing `.cancelled` through untouched), a page through `WebPDF`. `texInstallPresenter`
  and `texSeams` are the seams a test replaces so no alert is raised and no engine is looked for.
- `CSVExportDialog.swift` (~600) — the grid's own Export CSV sheet: `Export with` over a banded list of the grid's columns (a tick each, the declared type dimmed at the right, eight rows visible then a scroll, Save off with none ticked), Save As with a muted `.csv` after the name, the shared `LocationRow` opening on the file's folder or `Preferences.lastExportDirectory`, the window's `confirmReplace` for an existing file; `runSheet(on:)` hands back a `CSVExportChoice` (url and ticked indices) or nil. `CSVExportColumnListView` at its foot draws the list in the Settings › File types shape.
- `ExportDialog.swift` (~540) — the export sheet, the whole question asked once (SPEC Done 62): `SaveDialog`'s form
  with an `Export as` row of segments — one per extension the tab's targets write, `PDF`, `PNG`, `EPUB` — a
  `View` row of segments under it (`ExportViewChoice`: `Editor`, `Preview`, `TeX`), an `Image` row of
  `Inline` / `End` radios, a
  `Save As:` row of the base name with the target's extension after it as a label rather than a popup — the target
  *is* the format — and the shared `LocationRow`. The two segment rows resolve to one `ExportTarget`
  (`chosenTarget`); the View row is hidden while PNG is selected (a picture is always the source) and wherever
  the extension has a single view, and the Image row shows for `.editorPDF` and for `.previewPDF` on a note with
  chips (`hasImageChips`). A hidden row keeps its place — its controls hide inside a stack that does not let go
  of them, its grid row's `height` is pinned — and the panel is sized once at build, so the sheet never grows or
  shrinks under the reader. The name follows the target's own default (`suggestedNames`,
  the window's `exportName(for:target:)` per target, a grid's CSV among them) until `hasTypedName`; Export greys
  out on an empty name; an existing file goes to the window's `confirmReplace` and a `no` leaves the sheet up. Run
  the same synchronous way, and it hands back an `ExportChoice` — the target, the pictures and the destination.
  `MainWindowController.exportSheetProvider` is the one seam a test answers all of it through.
- `TablePDF.swift` (~380) — a grid onto pages, which is what a `.sql` or `.csv` tab's `Preview as PDF` is:
  `write(header:rows:font:to:)` and nothing else, knowing nothing of notes, tabs or panes. The font (the grid's
  family and weight, the size capped at 10 pt), the paper (turned on its side where the columns want more than a
  portrait page, on this job's own copy of the print info), the column widths (widest cell on one line, capped at
  half the page, and what will not fit taken off the *widest* columns alone down to one shared threshold, so a
  narrow column keeps its width and never wraps — an equal proportional share only where nothing else fits at
  all), the row heights (the tallest wrapped cell; a row taller than a page clipped to one), the break between
  rows, the header repeated at the top of every page, the rule around every cell and the `nil` that draws as
  nothing. Every cell is measured on one line once, while the columns are sized, and one that fits its column is
  one line tall without a `boundingRect` of its own — only the cells that wrap are laid out. The paper, the margins, the silent print job and the light appearance are all `PDFPaginator`'s
  (`printInfo(savingTo:)`, `run`, `light`), and the view paginates itself with `knowsPageRange` as the plates do.
- `PDFPaginator.swift` (~310) — the only place Nota makes a PDF: an attributed string paginated by a silent
  `NSPrintOperation` (`jobDisposition = .save`, the file in `jobSavingURL`), plates drawn one picture to a
  page (`knowsPageRange`) and joined onto the text with PDFKit, Letter or A4 from `NSPrintInfo.shared`,
  margins from the render's inset, and the whole run under the light appearance with the text's dynamic
  colours resolved first.
- `SnapshotPNG.swift` (~150) — the only place Nota makes a picture of a document, and `PDFPaginator`'s opposite
  in every way (SPEC "## Export", Snapshots): an attributed string laid into an offscreen `NSTextView` at the
  screen's own measure and the preview pane's own insets, wearing the window's appearance and painting the
  pane's background behind its whole height, then `cacheDisplay(in:to:)` into an `NSBitmapImageRep` — 2x while
  the long side stays inside 16,384px, 1x past it — and written as PNG. Nothing is lightened and nothing is
  paginated. A document over 30,000pt tall throws `Exporter.Failure.tooLongForAnImage`. It knows nothing of
  notes: `Export.swift` decides whether the picture is the render or the listing.
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
  `JSONFormat`'s three questions — `reformat(_:as:)`, `isPretty(_:)`, `errorLine(in:)` — asked of a page. Minify also
  hands a `<style>`'s CSS and a JavaScript `<script>`'s program to `InlineCodeMinify` (which scripts count as
  JavaScript is `inlineCodeKind(of:bytes:)`, reading the `type` back out of the open tag's own bytes); Beautify
  re-indents no raw content, ever.
- `InlineCodeMinify.swift` (~500) — the two byte-level minifiers Minify runs over what a page carries inside it:
  `css(_:)` (whitespace collapsed and dropped around `{ } ; ,` and after `:` but never before one, the `;` before a
  `}` gone, comments dropped but `/*!` kept, strings and the inside of `url(…)` verbatim) and `javascript(_:)`
  (strings, template literals with `${ … }` nesting, and regular expressions verbatim; comments dropped unless `/*!`,
  `@license` or `@preserve`; a newline dropped only where the language could not have inserted a semicolon). Neither
  is a parser: nothing is renamed, reordered or dropped, and anything either cannot follow — an unterminated string,
  template, regex or comment — hands the block back untouched. Both are idempotent, which is what lets
  `HTMLFormat.isPretty` ask them whether the page has anything left to minify.
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
- `PreviewContent.swift` (~430) — `PreviewContentKind` (markdown/latex/html/pdf/image/epub/sql/csv/rtf/tree), `ContentsEntry` (one line of a table of contents), `PageListSource` (a document read page by page: count, page in front, go to one, draw one), the `PreviewContent` protocol every content view adopts (`show`, zoom, find, `rememberedPosition`, `rememberedScroll`, `footerStatus`, `contentsEntries` / `currentContentsLine` / `goToContentsLine`, `pageList`, `onStateChange`, `onBlockClick` and `onSourceReveal` — a click that takes the caret with it and one that only moves it, one range per row of a rectangle picked out of a grid and one range otherwise — `onExpansionChange`, which only the tree ever fires, `onDropFiles`), and `PreviewFileDrop` — the drop from the Finder every view in the column answers the same way.
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
- `TeXEngine.swift` (~385) — a real TeX found and run: `TeXEngineKind` (tectonic, pdflatex, xelatex), the search
  order and the paths (Nota's own bin, `$PATH`, the three fixed), `arguments(for:tectonicVersion:…)` for both Tectonic
  command lines and the two TeX Live ones, `compile` (the source and its folder copied into a temp directory, the
  second pass a log asks for, a 120 s limit), `firstError(inLog:)` / `failureMessage(inLog:)` — the `! ` line and its
  `l.N` — and `TeXExportError`. Foundation only; the search paths and the file check are injectable.
- `TectonicInstaller.swift` (~305) — Nota's own copy of a TeX for a Mac with none: the release's assets, the build for
  this machine (`hw.machine` with `sysctl.proc_translated` over it), `SHA256SUMS` or the byte count, `/usr/bin/tar`
  into a scratch directory, the binary into `~/Library/Application Support/Nota/bin`, `chmod`, the quarantine
  attribute, and `tectonic --version` as the proof. The transport is a closure, as `UpdateCheck`'s is.
- `TeXExport.swift` (~130) — the one call `ExportHooks`'s `texPDF` makes: `TeXInstallChoice`, `TeXInstallPrompting` and the
  `NSAlert` that asks, and `export(source:sourceURL:to:presenter:progress:completion:)` — detect, prompt, install,
  compile — with the three seams (`Seams`) the tests replace. No menu item and no panel.
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
- `WebPDF.swift` (~410) — a page printed to a PDF file, headless: `NSPrintOperation` from `WKWebView` (never
  `createPDF`, which renders one viewport-sized sheet), both panels off, the job saved to `jobSavingURL`, the view
  in a transparent borderless window parked off every display at the paper's printable width, `readyState` polled
  and a short settle for pictures, a timeout that fails with a sentence, and one job at a time through its own
  queue. Three doors: a file, a string of HTML with a base URL, and a web view that already holds the page.
- `EPUBToPDF.swift` (~170) — a book as a PDF: each spine chapter loaded under `nota-file://` and printed by
  `WebPDF`, the sheets merged by PDFKit in spine order, `contentsEntries` rebuilt as the document's `PDFOutline`
  and the book's title as its title. A chapter that will not print is left out; only a book where nothing printed
  fails.
- `PDFToEPUB.swift` (~560) — a PDF as a reflowable EPUB 3: chapters from `outlineRoot` (or a chapter per page
  where there is none), paragraphs rebuilt out of `PDFPage.string`'s lines (blank line, indent, or a short line
  that ends a sentence), hyphens healed conservatively, CJK joined without a space, a scan refused, `dc:language`
  from `/Lang` or `NLLanguageRecognizer`, and `mimetype` / `container.xml` / `content.opf` / `nav.xhtml` /
  `toc.ncx` / one XHTML per chapter zipped by `/usr/bin/zip` with the stored `mimetype` first. Pure; no AppKit.
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
  parser takes, via `SQLDumpDialect`. `forEachRow(ofTable:sort:onColumns:onRow:)` / `forEachRow(ofQuery:…)` are a
  page's read with the `LIMIT`/`OFFSET` and the rowid dance both taken out — the whole table or query, in sort
  order, `onColumns` once and `onRow` per row — for the Export button's `CSVWriter` to stream straight to a file.
  Knows nothing of AppKit.
- `SQLDumpDialect.swift` (~2400) — the MySQL, Postgres, SQL Server (SSMS) and Oracle (SQL Developer / SQL*Plus) spellings a dump carries, turned into SQLite's before
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
  `SQLDump.hits` on the pane's own queue; and the Export button (leading side of the pager), `exportCSV(to:)` — the
  picked table or the query's own result, every row through `SQLDump.forEachRow` and `CSVWriter`, asked of the
  window through `exportDestination`.
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
  the editor to its `INSERT` the way a table's does. An `[INNER]` / `LEFT [OUTER] JOIN` chain is one table's rows
  too — the first `FROM` table's — so it carries that table's rowid (`hasDisallowedJoin` refuses `RIGHT` / `FULL` /
  `CROSS` / `NATURAL` and a join onto a sub-select). What else it refuses — a `GROUP BY`, an aggregate, a
  sub-select — and what SQLite refuses are both answered by running the reader's own query untouched. Pure text and
  no SQLite; it borrows `SQLSourceMap`'s scanner.
- `SQLQueryBox.swift` (~500) — the five-row query editor: rounded bezel, `SELECT …` placeholder, Return a newline,
  ⌘↩ the run, Esc the cancel, no rich text and no substitutions, and the Find menu handed to the grid's session in
  reading mode and back up the responder chain out of it, so AppKit's own find bar never opens over five lines of
  SQL. Also the two helps that change no character: the keyword / string / number / comment colours (temporary
  attributes over the layout manager, `refreshHighlighting`) and the completion dropdown — `insertText` opens it
  on a name character or a `.`, `keyDown` routes ↑↓ / Tab / ↩ / Esc to it while it is up, `didChangeText` narrows
  it, `setSelectedRanges` closes it when the caret leaves the word; `completionSchema` is the snapshot the pane
  hands it.
- `SQLCompletion.swift` (~420) — pure logic behind both helps: `Schema` (tables → ordered columns, case-insensitive
  lookup), `suggestions(in:caret:schema:)` (the word under the caret, or the `alias.` before it, against the
  grammar's keywords, the tables and the columns — the named tables' columns first), `references(in:)` (the `FROM`
  / `JOIN` / comma-list scan that says what `o` stands for), `highlights(in:)` (the coloured runs). No AppKit, no
  SQLite; `SQLSourceMap.nextToken` for the alias scan.
- `SQLCompletionPopup.swift` (~300) — the list under the caret: a borderless non-activating child `NSPanel` that
  never becomes key, a rounded frame view in the box's own bezel, a hand-drawn flipped list (eight rows visible, the
  hint word at the right, the accent behind the pick), `show(_:font:under:in:)` placing it under the caret's line
  and flipping above when there is no room, a click on a row the one thing it does itself.
- `CSVTable.swift` (~330) — a `.csv` or `.tsv` read as the table it is: Nota's own RFC 4180 scanner (quoted fields,
  `""` escapes, newlines inside quotes, CRLF / CR / LF, a trailing newline, a BOM, blank lines skipped), the first
  record as the header with blanks named `Column 3`, ragged rows padded and widened, the `NSRange` of the lines each
  record is written on and of every *field* of it as written (`fieldSources`, quotes included — what a clicked cell
  selects), and `page(offset:sort:)` — a hundred rows, sorted numerically where the whole column parses as numbers
  and by the reader's own collation where it does not. `exportRows(sort:)` is the same order over every row and no
  page cut out of it, a trailing field a ragged row never wrote coming back `nil` off `fieldSources`' own count
  rather than the `""` `rows` padded it to. Pure; knows nothing of AppKit.
- `CSVPreviewView.swift` (~810) — the pane that draws it: the dump's pane with the database taken out — one bar of
  `Refresh` and the page arrows under the corner slot's hover band, `SQLGridView` below it unchanged, the sort a
  header click asks for, the `onSourceReveal` a click, a gutter click or a drag sends (`sourceRanges(of:)` — the
  grid's `Selection` as an array of ranges: one span of records for whole rows, one span of fields per row for a
  rectangle, so a column is that column and not the lines between its rows), `GridFindSource` — ⌘F over the
  whole table in `CSVTable.ordering`'s order, with the bar row dropping while the pill is up — and the read it runs
  on its own queue with a token (a big file only ever on the button). The Export button (leading side of the
  pager), `exportCSV(to:)`, writes `CSVTable.exportRows` through `CSVWriter`.
- `CSVWriter.swift` (~75) — an RFC 4180 writer, the mirror of `CSVTable`'s own reader and shared by both grids'
  Export button: `write(header:rows:) -> String` in memory, and the streaming pair `write(header:to:)` /
  `write(row:to:)` straight to a `FileHandle` so a big export is never held twice over. Quotes a field only on a
  comma, a quote, a CR/LF or a leading/trailing space; doubles an inner quote; a `nil` — `NULL`, or a ragged row's
  own unwritten field — is nothing rather than a word. Pure; knows nothing of AppKit.
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
  outline given it came out a shade off in the dark — the editor's margin, starting 14pt down like the source, the
  column held to the pane's own width in `layout()` — moved through a width it is not already at, or the
  outline is never told — and every row on screen given the rest of its row again in
  `TreeOutlineView.layout()`, since AppKit frames a row's field once and the tree is built before the split
  slides open, so a long value truncates at the pane's edge instead of running off or being squeezed to
  nothing),
  a row's key then its value coloured by type, `{3}` / `[12]` after a closed branch, expansion seeded by the
  document's size and then remembered by node path across re-renders, the scroll kept, a click selecting the
  node's source (a leaf its value, a branch its whole span, key and value) without taking the keyboard, the
  caret's line lighting the node that line begins, `expandAll()` / `collapseAll()` / `isFullyExpanded` and the
  `onExpansionChange` that keeps the corner slot's own segment in step, and — in reading mode, where the outline has the keyboard — its
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
- `CornerSlotTests.swift` (17) — which capsule the corner slot shows per tab kind, that a `.json` tab gets a
  fourth segment in each column and that the two are not the same one (the editor's Beautify, the preview's
  Collapse All), that a `.yaml` gets none in the editor, that clicking the editor's reformats and puts the mode
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
- `TreeLayoutTests.swift` (5) — the tree's geometry in the window: a big JSON and a big XML put in split from
  an untitled tab have their column the width of the pane and every row's field the width of the column, with
  the whole of its key in it and no part of it under the scroller — the squeeze a document got from being
  rendered before the divider slid open — the same after the split is closed and opened again and after the
  window is resized either way under a tree already on screen, and a tab told what it is by the footer's badge
  has its rows the moment the split opens.
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
- `HTMLFormatTests.swift` (75) — the tokeniser and both writers: every tag and attribute form kept byte for byte,
  raw-text elements never re-indented, block/inline line-breaking, whitespace collapsing, stray and left-out end
  tags, and the disabled cases (unterminated comment, unclosed tag or quote, unclosed raw element, nesting past 256).
  Also `InlineCodeMinify` under Minify: a real page's stylesheet, what CSS and JavaScript each keep (a space before a
  `:`, `calc`, `url(…)`, licences, strings, templates, regexes, the newlines a program keeps), which `type` makes a
  script JavaScript, and that minifying twice is minifying once.
- `HTMLPreviewTests.swift` (which also covers a press in the page revealing its tag, and a page the tokeniser will
  not read having no map), `PDFTests.swift`, `ImageTests.swift`, `EPUBTests.swift`, `RTFTests.swift` — the viewer tabs, including the sidebar each of them fills (an RTF has none) and the ⇧⌘F hit each of a document and a book answers with (`PDFTests`, `EPUBTests`). `PDFTests` covers the page list: the title over it, the cards and their captions, a click going to a page, the ring following the pages, the thumbnails landing off a background queue, two documents of the same length not sharing a list, and a document with bookmarks listing pages just the same.
- `BookExportTests.swift` (8) — the three conversions, over the real files in `Examples/`: `Book.epub` printed to a
  PDF with a sheet per chapter, the contents as its outline and chapter one on page one; `燈籠.epub` keeping its
  characters; `Demo.pdf` and `Demo-zh.pdf` read back as books Nota's own `EPUBBook.open` opens, with a chapter per
  bookmark and the document's own words in them; `fake.pdf` and a blank page refused with their sentences;
  `HTML.html` printed and a page taller than a sheet broken across two; and a page whose script never returns
  failing on the clock, with the limit handed in so the test does not wait a minute for it.
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
- `CSVExportTests.swift` — the Export button on both grids and what is behind it: `CSVWriter`'s own quoting rules
  and its streaming pair against its in-memory one, `SQLDump.forEachRow` over `Shop.sql` / `Examples/sql/MySQL.sql`
  / `Examples/sql/PostgreSQL.sql` (row count, header, sort order, a table past `SQLDump.pageSize`, a query with
  fewer rows than its table), `CSVTable.exportRows` (`Examples/Products.csv` round-tripped, a `.tsv` fixture
  exporting comma-separated), and the button itself — its place before the pager, and a click through the stubbed
  `exportDestination` seam writing the file. Last, the two doors agreeing: the pane's button and
  `Exporter.export(…, to: .csv, …)` over the same pane write byte-for-byte the same file, query and sort
  included, and the sheet opens on the name the button would have used. And one for the other export a grid has:
  `Exporter.export(…, to: .previewPDF, …)` over a `.csv` pane draws the cells onto a page and not the source's
  comma-joined line, in the order a header click left the grid in — and over a pane shown with the column hidden,
  which has read nothing, it is the source listing that lands instead.
- `TablePDFTests.swift` (11) — `TablePDF` on its own, every PDF read back with PDFKit: a small table on one page
  with every header and cell on it, 400 rows over more than one page with the header repeated on the last, a
  `nil` cell drawing neither `nil` nor `NULL`, twelve columns of long values fitted onto the paper with every
  header still there, a row taller than a page clipped rather than looping, 5,000 short rows written well inside
  a loose wall-clock bound (the guard on measuring every cell twice), no columns refused as `nothingToDraw`, and
  a header with no rows as one page. Then the three fitting rules: a narrow column left at its natural width
  while the long one beside it wraps (a value that comes back whole from the page's text was never broken), a
  fourteen-column table on a page wider than it is tall with `NSPrintInfo.shared` left as it was found, and a
  three-column one on the paper as it stands.
- `TeXEngineTests.swift` (40) — the TeX export: the search order and paths, the four command lines, the log's `! ` and
  `l.N` lines, the folder copied in beside the source, the build picked per Mac (Rosetta included), the sha256 and the
  byte count passing and failing on a tarball the test makes, unpack/chmod/version on that fake binary in a temp bin,
  the install end to end over a fake network, and the export's three answers to a fake prompt. The one test that runs
  a real TeX skips where the Mac has none.
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
- `ExportTests.swift` (21) — File › Export… and File › Print…: the targets each kind offers with every hook
  installed and the same list shrinking when a hook is taken out, a Markdown note's heading on its first page, a
  long note over more than one page, the listing's line numbers with the gutter on and off, plates after the
  last page of text against the same pictures inline, an `.rtf` and a picture (one page, exactly), the sheet's
  Images row showing only for the listing, and the whole path through the window — sheet and export dialog
  answered through their seams — opening the written PDF in a tab. Then one end to end of every hook over the
  real files in `Examples/`: `Book.epub` onto pages, `Demo.pdf` into a book Nota can reopen, `HTML.html` as
  WebKit draws it (no tags on the page), and a `.tex` with a fake prompt answering "use Nota's render" landing
  the native render at TeX's own destination — and Cancel landing nothing at all. Print: the item enabled where
  the tab makes a PDF, a note's dialog built over exactly the pages the export would have written, and a
  document printing its own, all through `printOperationRunner` so no panel appears.
- `SnapshotPNGTests.swift` (12) — the two PNG targets: where they are listed and where they are not (a tree and a
  plain note have no preview to photograph; a picture, a document and a book have none at all), the file read
  back with `NSBitmapImageRep` — as wide as the measure asked for plus the pane's margins, times the scale it
  chose; taller with more paragraphs — the corner pixel light under Aqua and dark under `darkAqua`, a formula's
  ink following the same appearance (darkest and brightest pixel, as in `MathTests`), the gutter's numbers as
  extra ink with the text moved right to make their column, the Images row never offered for a picture and its
  answer making no difference, the 30,000pt refusal leaving no file behind, and the 2x/1x rule at its boundary.
- `TabHoverTests.swift` (3) — the strip's three greys: selected fill, the pointer's wash on an unselected tab, nothing at rest.
- `FileTypesTests.swift` (15) — Settings › File types, all of it against a fake `DefaultAppRegistry`: the page's
  place in the sidebar, the rows in the table's order under their group titles, a row ticked when the registry says
  Nota and naming the app beside it, ticking remembering the previous app, unticking putting it back and forgetting
  it, two rows naming one type moving together, a row Nota already owned ticked and disabled, the all button
  claiming the first three groups and leaving the fourth, a refused set saying why on the row (and
  `permErr` worded for the reader, since `public.html` refuses everyone), the restore button putting
  back what was remembered and skipping what was not, asking once per type, and greying with an empty
  table, the table itself, and the page's words in all three languages. Nothing here touches the real Launch Services.
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
