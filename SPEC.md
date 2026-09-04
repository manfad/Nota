# Nota — product spec (decided 2026-09-01)

"Notepad++ in a Notes.app body." Native macOS, AppKit, SwiftPM, no dependencies.

## Model
- **Tabs are the notes.** An open tab is the unit; the cache dir is the truth until ⌘S.
  Closed tabs are gone (after the Save / Don't Save / Cancel prompt; Don't Save = ⌘D).
- Files are plain text of any kind — .md .txt .xml .json .css .js .html .yaml .toml .csv .log .ini .sh .py .swift and
  anything else that is text (Notepad++ model). Nota registers as an editor for text/source types (Finder "Open With",
  drag onto the Dock icon, drop onto the window). No syntax highlighting. Not .docx / .rtf / binaries —
  except PDF, the one binary Nota opens, and it opens it as a viewer (see PDF).
- Editing a named file only updates the cache; disk changes on ⌘S only. A named file keeps its extension, encoding
  (UTF-8 / UTF-16 / Latin-1 / Windows-1252 detected on open) and line endings (LF / CRLF) on save.
- What a file *is* is read from its bytes first, not its name: `%PDF-` magic makes it a PDF, and otherwise whether
  it decodes as text makes it a note, whatever it is called — a `report` or `config` with no extension opens
  correctly, and a PDF named `notes` opens as a PDF. A file's name is only consulted when its bytes cannot say
  (missing, unreadable, or a real binary). What a file is *rendered as* (Markdown vs. LaTeX vs. HTML) is the one
  exception — that stays by extension, since it is the author's own word for it (see Markdown preview).
- ⌘S default for a new note: `.md`, opens in the last-used folder; any extension typed in the panel is kept.
- Multi-window: ⇧⌘N opens another window, ⌘N and ⌘T stay new tabs, and every menu action means the window in front.
  `session.json` keeps `windows: [{tabs, selectedTabID, frame}]` — one entry per window, in order, each with its own
  frame; a file written before that (a flat tab list) comes back as one window, and the first window is still mirrored
  flat for a release so an older build opens the session it finds.
- Closing the last window = hide (app stays alive). Closing any other window really closes it, and its tabs go to the
  end of the window that was in front before it, so nothing is lost and nothing is asked. Quit never prompts;
  everything restores.
- Search: ⌘F opens Nota's own find bar (in note), ⌥⌘F opens it with the replace pill too; ⇧⌘F across all open tabs.
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
- Settings (⌘,): font family, size, line spacing, editor padding, word wrap, vim mode, hotkey.
- Status bar: `[MODE]` bottom-left when vim mode is on · `N words · N characters` · `N pt` beside gear.

## Markdown preview — three modes (⇧⌘P cycles, View menu; per tab, remembered in the session)
- **Editor** (default), **Split**, **Reading**. ⇧⌘P cycles editor → split → reading → editor; ⌥⇧⌘P jumps to reading and
  back out to the editor. The View menu keeps "Markdown Preview" (checkmarked in split and reading) and adds
  "Reading Mode" (checkmarked in reading). Both checkmarks are the front tab's.
- Rendered files only: a note whose file is spelled `.md`, saved — or `.tex` (`.latex`, `.ltx`), which gets the LaTeX
  render below instead, or `.html` (`.htm`), which gets the HTML preview, and everything else here unchanged. Every
  other tab — an untitled note, a `.txt`, a `.css`, anything not yet saved — has no render, no mode control, and both
  View items are disabled there, so ⇧⌘P and ⌥⇧⌘P do nothing.
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
  own, so both take the same 28pt drop clear of the traffic-light zone, both carry a drag strip there, and both use zen's
  wider 40pt margin, so the two bodies of text line up. Coming out of zen brings the chrome back and nothing else.
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
- ⌘F searches the document (done 2026-09-04): the same pill in the same corner, "Find in document", over PDFKit's own
  selections rather than a text storage. Every match wears a quiet band drawn over the page, the one you are on wears
  `findHighlightColor` and is the page's selection, and the count reads the same `3 of 12` / `12 matches` /
  `No matches` (`2000+` past the same cap the editor stops at). Typing searches from the page you are reading; ⌘G,
  ⇧⌘G, Return and ⇧Return walk and wrap; ⌘E seeds from what is selected on the page; Esc puts the bands down, leaves
  the match selected and hands the keyboard back to the document. A document cannot be typed into, so the glass is
  only a glass and Find and Replace… is greyed out — the one Find item a PDF turns down. PDFKit's own find bar never
  appears: `NotaPDFView` takes `performTextFinderAction:` off it.
- Footer: the middle counts pages (`12 pages`, `1 page`), the right says which one (`Page 3 of 12`), and it is empty
  when there is no document to be in. Everything else in the chrome — the strip, the vim badge, zen — is unchanged.

## Image tabs (decided 2026-09-04)
- A picture opens in a tab of its own and is looked at there, the way a PDF is read in one: PNG, JPEG, GIF, TIFF,
  WebP and HEIC, each known by the bytes it starts with, so a screenshot named `report` opens as a picture and a
  `.png` that is really a log opens as text (see Model). A bitmap is the one exception, known by its name instead:
  `BM` is two bytes, and two bytes is not enough to tell a picture from the first line of a sentence.
- Where it lands is the drop target's business, not the file's. Through ⌘O, the Finder, the Dock, the command line,
  `:e path` and the session it is a tab; dropped into the text of a note it is still what it has always been, a
  picture imported into that note as a chip (see Images). The same `.png` does both, depending only on where it went.
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
- Export as PDF… on a `.tex` tab is a Todo (see Todo 6).
- Out for now: `\input` `\include`, theorem environments, `\newcommand` expansion, bibliographies from `.bib`.

## HTML preview (decided 2026-09-03)
- A `.html` (`.htm`) file is a tab with a preview beside it, the way a `.md` is: the same three modes, the same
  floating mode control in each column's corner, ⇧⌘P / ⌥⇧⌘P and the View items, per tab and remembered in the session.
  The View item is named "HTML Preview" on that tab. The setting is "Open Markdown, LaTeX and HTML files in reading mode".
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
  open). ⌘F over the page is a Todo (see Todo 12): WebKit's own find is a page away in its own process, so it is
  nothing like the pill over a note or over a PDF.
- Untitled notes and every other extension have no HTML preview. Save As to `.html` is what turns a note into one.
- An `.svg` is the same arrangement (decided 2026-09-04): text you edit, a drawing beside it, the same pane and the
  same three modes, and the View item says "SVG Preview". It is handed to WebKit as `image/svg+xml`, so the root
  `<svg>` is the document rather than a tag inside a page the file never had. It is never one of the picture tabs
  below — its bytes are text, and the system filing it under images does not make it one.
- Shipped: `HTMLPreviewView` is the column's third content view. The editor's text is loaded under `nota-file://`, whose
  path is the file's own, and `PageFiles` hands WebKit the bytes for everything the page draws. A `file://` base URL does
  not work: WebKit's page process is given permission to read a folder only by `loadFileURL`, so text loaded against a
  file URL renders with every stylesheet and picture beside it silently missing. A link the reader clicks becomes a
  `file://` URL again on its way to the browser. The page reports its own scroll on each frame, so a reload puts the
  reader back where they were.

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
- One width for every tab, `clamp((viewport − plus − gaps) / n, 40, 180)`, shrinking as tabs are added; the strip never scrolls. The selected tab is raised to 60pt so its ✕ fits and the others shrink evenly to pay for it. Titles clip with a fade rather than an ellipsis; under 60pt the trailing slot goes and the unsaved dot rides on the icon. A separator hairline shows only between two plain tabs. The + rides after the last tab and pins at the trailing edge once the strip is full; it opens a new tab (same as ⌘T). ⌘P fuzzy tab switcher by title.
- The selected tab is always fully in view: at 40pt the strip stops shrinking and becomes a sliding window over the tabs, anchored on the selected one. Closing with the ✕ freezes the widths until the pointer leaves the strip, so a run of closes keeps each next ✕ under it; ⌘W does not freeze.
- Tabs reorder by drag: the dragged tab rides the pointer and its neighbours slide into the gap; the order is the session's order.
- Middle-click closes. ⌘T new, ⌘W close, ⌘1–9, ⌃Tab/⌃⇧Tab.
- A tab can move to another window: the note keeps its id, text, unsaved edits, caret and undo history, its cached
  text is never deleted on the way, and the window it left selects the neighbour (or keeps one untitled tab if it was
  the last). Dragging a tab out of the strip is that same move by hand: 40pt clear of the strip the tab becomes a
  window of its own that follows the pointer, another window's strip shows a caret where it would land, mouse-up
  docks it there or leaves the new window standing, and Esc puts it back.

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

## Known issues (later)
- The split slide can feel laggy with word wrap on: every frame narrows the editor, and the text view re-wraps the
  whole note to the new width as it goes. Fix candidates: freeze the editor's container width for the slide the way the
  render's is frozen, or slide a snapshot of the editor and re-wrap once on landing.

## Todo (in rough priority)
1. **External changes to an open file.** A named tab watches its file (DispatchSource on the fd); when it changes on disk
   and the tab is clean, reload silently; when dirty, mark the tab and offer Reload / Keep mine on the next focus
   (Notepad++ "file has been modified" without the modal storm). Missing file → the existing dirty behaviour.
2. **Encoding and line endings in the status bar.** `UTF-8 · LF` at the right of the counts; click either for a menu that
   converts (UTF-8 / UTF-16 / Latin-1 / Windows-1252; LF / CRLF). Conversion marks the tab dirty; ⌘S writes the new shape.
3. **Go to line (done 2026-09-04).** ⌘L opens a pill in the find bar's own corner — the same `PillView` chrome, one
   row — taking `N` or `N:M` and moving the caret as you type, off the note's `LineIndex` rather than a scan. See the
   Search section above for what it does; `:N` still does it in vim, untouched.
4. **File › Open Recent** (NSDocumentController's list, cleared from the same submenu) and tab reorder by drag in the strip.
5. **Task lists** in the render: `- [ ]` / `- [x]` as real checkboxes, ticking one rewrites the source character; counted
   `3 / 7 done` in the footer for a `.md` that has any.
6. **Print / PDF of the render.** ⌥⌘P prints the reading layout (⌘P is the tab switcher); Export as PDF… in File, same
   layout, page margins from the render's inset. Plain-text tabs print the text with line numbers if the gutter is on.
   Export a `.tex` tab as PDF via `pdflatex` / `tectonic` / `xelatex` if one is installed, showing the result in a PDF
   tab; with none installed it prints the native render, the same as the Markdown export.
7. **Line operations** the Notepad++ hands expect outside vim mode: ⌥↑ / ⌥↓ move line, ⇧⌥↓ duplicate, ⌘D duplicate/select-next,
   ⌘/ toggle a `#`/`//` comment by extension, Tab / ⇧Tab indent a selection, ⌘] ⌘[ likewise.
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
9. **Headings outline.** `@` in the ⌘P switcher lists the front `.md` tab's headings; choosing one puts the caret there
   and, in split/reading, scrolls the render to the block.
10. **Ship it.** Developer ID signing and notarization in `build.sh` (ad-hoc today), so the .app opens on another Mac
    without the Gatekeeper dance; `Nota.app.zip` as the release artifact next to the tag.
11. Fix the word-wrap re-flow lag in the split slide (Known issues above).
12. **⌘F inside a PDF (done 2026-09-04) and Print of a PDF tab.** The find half is shipped: the same `FindBarView`
    pill the editor and the render use, driven by a `PDFFindSession` over PDFKit's selections — `findString` for the
    list and for each step, `highlightedSelections` for the bands and `currentSelection` for the one being stood on —
    with `NotaPDFView` taking `performTextFinderAction:` off `PDFView` so PDFKit's own bar never appears. See the PDF
    section for what it does. Still open: ⌥⌘P printing the PDF rather than the render.
13. **Bookmarks (v0.5 or v0.6).** A tab can be bookmarked (⌘D-style toggle in File and in the tab's context menu; a
    dot or pin on the tab). A bookmark is the file's path, kept in `session.json` beside the tabs, so closing the tab
    does not lose the note: File › Bookmarks lists them and ⌘P's switcher offers them under the open tabs, and choosing
    one reopens the file where it was. Bookmarking an untitled note asks it to be saved first. A bookmark whose file has
    gone stays in the list greyed out until removed.
14. **Copying maths out of the render.** A selection over a formula copies U+FFFC today; the plain-text flavour
    should be the formula's `plainText` (`x²+α`), which the layout already keeps for accessibility.
15. **Tab strip, Chromium style (after the LaTeX preview; design agreed 2026-09-03 with a second reviewer).** Every
    tab shows a leading icon: the SF Symbol `text.page` for every kind today (done), per-kind artwork later. Then, in
    this order:
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
      time. Still to come: the overflow chevron for the tabs the window is not showing.
    - **B. The + follows the tabs (done 2026-09-03).** `plusX = min(lastVisibleTab.maxX + 4, bounds.width − 24)`: it
      rides after the last tab and pins at the trailing edge once the strip is full. The ⇧⌘F field already narrows the
      bar's bounds, and nothing subtracts it twice.
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

Order from here: v0.4 (tab drag, PDF tabs, maths in Markdown) → workspace refactor → LaTeX preview (v0.5, done) →
HTML preview → tab strip → big files (done) → find/replace and go to line as floating pills (done).
