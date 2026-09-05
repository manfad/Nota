# Nota code map

Where things live, so a change starts in the right file. One line per file; the
file's own header comment says the rest. Line counts are rough and dated
2026-09-04. `SPEC.md` is the behaviour spec and the Todo/Done ledger; this file
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
| ⌘P switcher, `@` headings (text notes only), bookmarks dialog, ⇧⌘F search dialog, hover/arrow selection | `TabPickerPanel.swift`, ranking in `FuzzyMatch.swift` |
| Settings window (draft + Save, sidebar pages) | `SettingsWindowController.swift`, values in `Preferences.swift` |
| A new preference | `Preferences.swift` (key + property + `announce()`), then Settings UI |
| A user-visible string / Chinese translation | `Localization.swift` (`L10n.text`) |
| Editor typing, paste, drop, images in the text | `NotaTextView.swift`, tokens ↔ chips in `NoteText.swift` |
| What a file *is* (sniff), encodings, line endings | `TextFile.swift` (`FileSniff`, `TextFile`) |
| A tab's model: kind, dirty, file, session record | `Note.swift`, `Session.swift` |
| Markdown render look | `MarkdownRenderer.swift`, `RenderStyle.swift`; maths `MarkdownMath.swift` |
| LaTeX render | `LaTeXParser.swift` → `LaTeXRenderer.swift`; formulas `MathParser.swift` + `MathLayout.swift` |
| Preview column plumbing (which view shows, zoom, scroll memory) | `PreviewPaneView.swift`, `PreviewContent.swift`, `RenderedPreviewView.swift` |
| PDF / picture / HTML / EPUB viewer tabs | `PDFPreviewView.swift`, `ImagePreviewView.swift`, `HTMLPreviewView.swift`, `EPUBPreviewView.swift` + `EPUBBook.swift` |
| ⌘F find bar and its match bands (incl. dark-mode colours) | `FindBar.swift` (chrome), `FindSession.swift` (editor), `HTMLFindSession.swift`, `PDFFindSession.swift` |
| ⌘L go to line | `GoToLine.swift`, line table `LineIndex.swift` |
| Floating pill chrome shared by find / go-to-line / external-change | `Pill.swift`, `ExternalChangePill.swift` |
| Editor · Split · Reading control | `ModeControlOverlay.swift` |
| Gutter / line numbers | `LineNumberRulerView.swift` |
| The sidebar column: a note's thumbnails, a book's or PDF's contents | `ImageSidebarView.swift`, `ContentsSidebarView.swift`, which chips light up `ChipHighlight.swift` |
| Tab / picker / bookmark-menu icons | `FileKindIcon.swift`, art in `FileKindArt.swift` (generated) |
| Bookmarks | `Bookmarks.swift` (store), `BookmarksMenu.swift` (File › Bookmarks) |
| Open Recent | `RecentDocumentsMenu.swift` |
| File changed on disk | `FileWatcher.swift`, handling in `MainWindowController` "External changes" |
| Search all notes (⇧⌘F) | `NoteSearch.swift` (the search itself), dialog in `TabPickerPanel.swift` |
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
- `Preferences.swift` (~570) — every setting (`UserDefaults` + `Preferences.didChange`), enums `EditorFontFamily`, `LineSpacingOption`, `SidebarSide`, `PlainTextImageStyle`, `EditorPaddingOption`, `AppLanguage`, `AppTheme`; `shortcuts` table, `hotKey`; window chrome (`hidesTabBar`, `autoHidesTabBar`, `hidesTrafficLights`, `hidesBookmarkButton`, `hidesSettingsButton`).
- `Shortcuts.swift` (~200) — `KeyCombo`, `ShortcutAction` (every adjustable menu key, defaults, groups, reserved combos), `NSMenuItem.applyShortcut`. ⌘D bookmarks the tab, ⇧⌘D shows the bookmarks; duplicating a line is ⇧⌥↓ only.
- `Version.swift` — `AppVersion.current`; bumped with `Info.plist` by `.githooks/pre-commit` on every commit (`git config core.hooksPath .githooks`).
- `Localization.swift` (~130) — `L10n.text`, the English→Chinese table.
- `SettingsWindowController.swift` (~900) — Settings: a sidebar source list over eight pages (General, Appearance, Editor, Preview, Tab bar, Status bar, Shortcuts, About), each page's controls in inset rounded groups of 44pt rows; draft-and-Save. Version shown on About comes from `Version.swift`.
- `ShortcutRecorderField.swift` (~150) — press-a-key field; records a global hotkey (key code) or an app `KeyCombo` (character).
- `GlobalHotKey.swift` (~170) — Carbon hotkey; `KeyCodeNames` (key code / key-equivalent display names).

### Main window
- `MainWindowController.swift` (~4730) — the whole window. Sections by `MARK`:
  Setup (332) · Text attributes (1029) · Auto-hidden tab strip (1338) · Session restore (1461) · Tabs (1602) · Encoding and line endings (1739) · Vim footer (1994) · Files (2316, open/save/close, sniff → viewer kinds, `importRTF` for `.rtf`/RTFD) · External changes (2646) · Persistence (2787) · Font size and zoom (2895) · Menu actions (2976) · Zen mode (3059) · Tab picker (3496, `@` headings, text notes only) · Markdown preview (3610, modes, split, footer status of viewers) · Images and book contents: chips and sidebar (4242) · Search across tabs (4345, `beginSearchAllNotes` opens the picker in `.search`) · Delegates / Vim's window (4383) · Background (4698) · Quick Look (4711).
  Footer regions: `statusLabel` (counts, `updateCountsLabel` / `availableCountsWidth`), `footerTrailingStack` (encoding · line ending · cursor), `modeBadge` (vim).
- `TabBarView.swift` (~1600) — the strip: `TabBarItem`, `TabItemView` (icon, dot, ✕, bookmark badge), drag/reorder, tear-off, + button, bookmark and Settings-gear buttons at the trailing edge, context menu.
- `TabStripLayout.swift` (~200) — pure width arithmetic for the strip.
- `TabPickerPanel.swift` (~1200) — ⌘P panel: modes `.tabs` / `.headings` (`@`, text notes only — a book's contents are in the sidebar) / `.bookmarks` / `.search` (⇧⌘F, two-line hit rows, no top row); top fixed row; arrow keys and hover selection (`HoverTrackingTableView`); `TabPickerRowView`.
- `FuzzyMatch.swift` (~80) — subsequence scoring for the picker.
- `ModeControlOverlay.swift` (~260) — Editor · Split · Reading floating control.
- `ImageSidebarView.swift` (~330) — thumbnail column (no utility strip any more).
- `ContentsSidebarView.swift` (~255) — the same column for a tab that is read: the table of contents (a book's chapters, a PDF's outline), indented by nesting, the line naming what is on screen rung. Knows nothing of either kind — it lists `ContentsEntry` values and hands a chosen line back.
- `ChipHighlight.swift` (~50) — which thumbnails match the caret/selection.
- `NoteSearch.swift` (~100) — the search itself, `NoteSearchMatch`; the panel's `.search` mode draws what it returns.

### Notes, files, session
- `Note.swift` (~530) — `PreviewMode`, `RenderedPreviewKind`, `NoteKind` (`text`/`pdf`/`image`/`epub`), `Note` (storage, file, dirty, watcher, cached PDF/image/book, `sessionTab()`).
- `NoteText.swift` (~380) — `![](nota://id)` tokens ↔ attachments, and, given a closure for each direction, a
  saved file's own relative image links too: `serialize(_:sidecar:)` and `render(_:…:importing:)`. Touches no disk.
- `Sidecar.swift` (~215) — the pictures a saved note keeps beside it in `<basename>.assets/`: folder naming,
  percent-encoded links, which link targets are relative paths, the identical-bytes check, `Writer` (save) and
  `importer(forFileAt:assets:)` (open).
- `Assets.swift` (~250) — `NotaImageAttachment` chips, `AssetStore` on disk.
- `TextFile.swift` (~430) — `LineEnding`, `TextFileFormat`, encoding detection, `FileSniff.classify` (PDF, image, EPUB, text, binary), `FileClass`, `rtfPlainText` (RTF/RTFD import), `isDrawing` (an `.svg` is text, not a picture — `Note.isImageFile` and the exclusions ask it).
- `Session.swift` (~520) — `TextStats` (footer count phrases incl. pages/chapters), `SessionTab` / `SessionWindow` codables, `SessionStore`.
- `SaveNameComposer.swift` (~55) — pure logic for the save panel's Format combo: known extensions, splitting a name from its extension, composing the final name.
- `FileWatcher.swift` (~230) — `FileStamp`, watching a path for change.
- `Bookmarks.swift` (~120) — pinned paths store. `BookmarksMenu.swift` (~130) — the File submenu + ⇧⌘D toggle.
- `RecentDocumentsMenu.swift` (~55) — File › Open Recent.
- `BigFile.swift` (12) — the "big" threshold. `SpellCheckPolicy.swift` (~30).
- `LineIndex.swift` (~200) — hard-line start table (gutter, footer, ⌘L, vim).

### Editor
- `NotaTextView.swift` (~940) — the text view: paste/drop of images and HTML, vim hooks, `setSearchHighlights`, chips.
- `LineNumberRulerView.swift` (~220) — gutter.
- `LineOperations.swift` (~380) — move/duplicate/comment/indent as pure functions.
- `HTMLClipboard.swift` (~290) — reading `public.html` / web archives on paste.
- `TaskList.swift` (~200) — `- [ ]` boxes in render and source.
- `ListContinuation.swift` (~365) — what Return means on a list item, as pure functions: `ListMarker.parse(line:above:)`, `.next()`, `.prefix`, and `ListContinuation.edit(forReturnIn:at:)`. The header explains how a lone `i.` is read.

### Find, go-to-line, pills
- `Pill.swift` (~300) — `PillView` chrome, `PillFieldEditor`, `PillActionResponder`, `floatBottom`.
- `FindBar.swift` (~340) — `FindBarView` (query pill, replace pill, tooltips from the shortcut table).
- `FindSession.swift` (~530) — `TextFindSession` for the editor and rendered panes; `NSTextView.setFindHighlights` and `quietFindBand` (light: label wash, dark: dimmed find yellow).
- `HTMLFindSession.swift` (~525) — same for WebKit pages (CSS highlights).
- `PDFFindSession.swift` (~380) — same for PDFKit.
- `GoToLine.swift` (~290) — ⌘L pill.
- `ExternalChangePill.swift` (~90) — "Changed on disk · Reload / Keep mine".

### Preview column and renderers
- `PreviewContent.swift` (~350) — `PreviewContentKind` (markdown/latex/html/pdf/image/epub), `ContentsEntry` (one line of a table of contents), the `PreviewContent` protocol every content view adopts (`show`, zoom, find, `rememberedPosition`, `rememberedScroll`, `footerStatus`, `contentsEntries` / `currentContentsLine` / `goToContentsLine`, `onDropFiles`), and `PreviewFileDrop` — the drop from the Finder every view in the column answers the same way.
- `PreviewPaneView.swift` (~280) — holds one content view at a time; `panes` for tests; `onDropFiles` goes to every content view and to zen's drag band, so the whole column is a tab target.
- `RenderedPreviewView.swift` (~670) — base class for rendered text panes (blocks, band, click-back, find, frozen wrap width).
- `MarkdownPreviewView.swift` (17) / `LaTeXPreviewView.swift` (21) — the two subclasses.
- `RenderStyle.swift` (~190) — `RenderedDocument`, block styles shared by both renderers.
- `MarkdownRenderer.swift` (~590) — Markdown → attributed string, `MarkdownImageAttachment`.
- `MarkdownSourceMap.swift` (~330) — rendered block → source range.
- `MarkdownHeadings.swift` (~130) — headings for `@` in ⌘P.
- `MarkdownMath.swift` (~400) — `$…$` lifted out before parsing. `MathParser.swift` (~575), `MathLayout.swift` (~720), `MathAttachment.swift` (~40) — Nota's own formula layout.
- `LaTeXParser.swift` (~1360) — `.tex` → blocks. `LaTeXRenderer.swift` (~480) — blocks → attributed string.
- `HTMLPreviewView.swift` (~775) — WebKit page under `nota-file://`, scroll memory (pixels and fraction), `showPage(ofTab:at:…)` for EPUB chapters, chapter-key script.
- `PDFPreviewView.swift` (~540) — PDFKit viewer tab, and `PDFOutlineContents` (`outlineRoot` walked depth first into `ContentsEntry` lines). `ImagePreviewView.swift` (~240) — picture tab.
- `EPUBBook.swift` (~425) — unpack (ditto), container/OPF/spine/nav/NCX parsing, `contentsEntries`, `contentsLine(ofChapter:)`. `EPUBPreviewView.swift` (~300) — chapter viewer; no floating chapter bar.
- `FileKindIcon.swift` (~160) — extension → icon name; `image(named:pointSize:)` (drawn art at 1.5× point size, SF Symbol fallback). `FileKindArt.swift` (generated) — the SVGs.

### Vim (`Sources/Nota/Vim/`)
- `VimEngine.swift` (~960) — the state machine and `VimEngineHost` (what it needs from the window).
- `VimKey.swift` — a key press in vim terms. `VimMode.swift` — modes. `VimCursorDrawing.swift` — caret shapes.
- `VimMotions.swift`, `VimOperators.swift`, `VimTextObjects.swift`, `VimVisual.swift` — motions, operators, `iw`/`ip`/…, visual mode.
- `VimSearch.swift` — `/` `?` `n` `N`. `VimMarks.swift`, `VimRegisters.swift`, `VimRepeat.swift` (`.`), `VimMacros.swift` (`q`/`@`).
- `VimCommandLine.swift` — the `:` / `/` prompt line. `VimEx.swift` — ex address/range parsing. `VimExCommands.swift` — running `:` commands. `VimHelp.swift` — `:help`. `VimScratch.swift` — `:reg` / `:marks` tabs.

## Tests (`Tests/NotaTests/`)
`swift test --filter <ClassName>` or `--filter <testName>`.

- `NotaTests.swift` (~100) — the grab bag: editor, footer, Settings window, find bands, ⌘P hover, session.
- `MarkdownPreviewTests.swift` (~140) — preview modes, split, picker rows, the ⇧⌘F search dialog, sidebar.
- `HTMLPreviewTests.swift`, `PDFTests.swift`, `ImageTests.swift`, `EPUBTests.swift` — the viewer tabs, including the contents sidebar each of them fills.
- `LaTeXTests.swift`, `MathTests.swift`, `MarkdownMathTests.swift`, `MarkdownHeadingsTests.swift`, `TaskListTests.swift` — renderers.
- `TextFileTests.swift`, `FileSniffTests.swift`, `FileKindIconTests.swift`, `LineIndexTests.swift`, `LineOperationsTests.swift`, `ListContinuationTests.swift` — files and editor logic.
- `BookmarksTests.swift` (also the ⌘P picker tests), `OpenRecentTests.swift`, `ShortcutsTests.swift`, `MultiWindowTests.swift`, `ExternalChangeTests.swift`, `ZoomTests.swift`, `TabStripLayoutTests.swift`, `DropOnStripTests.swift`, `SidecarTests.swift`, `BigFileTests.swift`, `NoteBigFileTests.swift`, `SpellCheckPolicyTests.swift`.
- `VimTests.swift`, `VimStage2Tests.swift`, `VimStage3Tests.swift`.
- Helpers: `OffscreenWindow.swift` (`makeKeyAndOrderFrontOffscreen()` — tests never launch the app), `DirtyProbe.swift`.
- Gotcha: a hanging test is a modal alert; stub `confirmDiscardOverrideForTesting` / `savePanelProvider`.

## Other
- `website/` — independent, static Astro promo page; commands, asset provenance, and deployment notes in `website/README.md`.
- `SPEC.md` — behaviour spec, Todo list, Done ledger (numbers reused; "Todo 3" is both Go to line and EPUB).
- `build.sh` — release build + hand-assembled `Nota.app` (binary + `Info.plist` + `Icon/Nota.icns`; no resource bundle, so assets are embedded in Swift).
- `Icon/` — `logo.png` (source art) → `make-icon.swift` → `Nota.icns`; `make-file-icons.py` → `Sources/Nota/FileKindArt.swift`.
- `Info.plist` — document types Nota registers for.
