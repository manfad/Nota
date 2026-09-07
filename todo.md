# Nota — todo

Ideas queued on 2026-09-07, kept apart from `SPEC.md`'s ledger until each one is designed and started. Rough priority order. File pointers follow `CODEMAP.md`.

## 1. Footer format selector: preview an unsaved note

**What.** Paste JSON, Markdown, HTML, CSV, YAML, TOML, XML, SQL or LaTeX into a fresh tab and inspect it straight away, without saving it as `.md` first. Today a tab's preview kind is decided by its file extension and nothing else (`RenderedPreviewKind.init(fileExtension:)` in `Note.swift`), so an unsaved note is always plain text.

**How it looks.** A third footer item beside the existing encoding · line ending pair (`formatEncodingLabel` in `MainWindowController.swift`, "Encoding and line endings" section): a `FooterMenuLabel` reading `Plain Text`, `Markdown`, `JSON`, … Clicking it pops the same kind of footer menu the encoding label uses (`popUpFooterMenu`). It is visible for every tab; for a saved file it shows the sniffed kind and lets the reader override it (a `.txt` that is really Markdown).

**Behaviour.**
- Picking a format on an unsaved note switches the tab to that preview kind at once: the corner slot's Editor · Split · Reading segments appear, ⌘P works, tree/grid/render as if the file had the extension.
- The choice becomes the default in the save panel's Format combo (`SaveNameComposer.swift`), so Save writes `note.md` / `note.json` without a second decision.
- Sniffing could pre-select on paste (a leading `{`/`[` that parses → JSON, `\documentclass` → LaTeX, a `CREATE TABLE` → SQL) but never silently: the label changes, the reader can put it back.
- Stored on `Note` as a format override (session-restored with the tab, `Session.swift`); the extension stays the authority once the file is saved unless the override says otherwise.
- A Settings row under Status bar: show / hide the format item, like `footerShowsEncoding`.

**Tests.** `RenderedPreviewKind` from an override; footer menu contents; the save panel default follows the override; session round-trip.

## 2. SQL query box: ghost text and a suggestion popover

**Where.** `SQLQueryBox.swift` (the editor), table and column names from `SQLDump.swift` (`tables`, plus a per-table column list via `PRAGMA table_info`).

**Two mechanisms, one at a time.**
- **Ghost text for keywords.** Typing `sel` shows `ect` in a dimmed run after the caret; `joi` → `n`, `wh` → `ere`, `gro` → `up by`, `ord` → `er by` only where a keyword is the likely completion (after `SELECT … FROM t`), not where a table is. Tab accepts; any other key keeps typing and the ghost re-computes or disappears. Keyword list: SELECT, FROM, WHERE, JOIN, LEFT JOIN, INNER JOIN, ON, GROUP BY, ORDER BY, HAVING, LIMIT, OFFSET, AS, AND, OR, NOT, IN, LIKE, IS NULL, DISTINCT, COUNT, SUM, AVG, MIN, MAX, ASC, DESC, UNION, CASE WHEN THEN ELSE END, INSERT INTO, VALUES, UPDATE, SET, DELETE.
- **Popover for identifiers.** After `FROM `, `JOIN `, `UPDATE `, `INTO ` a typed prefix opens a small list of matching tables under the caret (`ord` → `order`, `order_item`). After `SELECT `, `WHERE `, `ON `, `BY `, and after `alias.` / `table.`, the list is columns of the tables already named in the query, each row showing `column  ·  table`. Also `o.` where `o` is an alias declared in the FROM clause.

**UX rules (the part other apps get wrong).**
- The first row of the popover is always *what was typed*, highlighted; the candidates sit under it. Return or Tab with the first row selected inserts nothing new: the reader keeps `ord` if that is what they meant. Only ↓ moves onto a candidate; ↑ from the top candidate goes back to the typed row. No candidate is ever pre-selected, so a fast typist never gets `order` glued onto `ord` by a reflexive Return.
- Esc closes the popover and does nothing else (the box's existing Esc, which puts the picked table back, fires only when no popover is up).
- The popover never steals key: it is a child panel or an overlay view inside the box, and ⌘↩ still runs the query with it open.
- Matching is prefix first, then subsequence (`oi` → `order_item`) via `FuzzyMatch.swift`; case-insensitive; identifiers that need quoting are inserted quoted.
- No suggestions inside string literals or after `--`.
- Max ~8 rows, scrollable; a row shows the kind (table / column / keyword) as a faint trailing tag.

**Tests.** Pure completion engine first (`SQLCompletion.swift`: context detection from the text before the caret, candidate list, ordering) so the rules above pin without AppKit; then a `SQLQueryBox` test for Tab accepting ghost text and for Return on the typed row inserting nothing.

## 3. Search inside tree previews

**What.** ⌘F in a `.json` / `.yaml` / `.toml` / `.xml` tab searches the tree, not just the editor (this is `SPEC.md` Todo 3). Finding a deeply nested key or value is the natural next action after opening JSON.

**Behaviour.**
- The find bar (`FindBar.swift`) gets a `TreeFindSession` beside `FindSession` / `HTMLFindSession` / `PDFFindSession`: matches over keys and leaf values in `StructuredDocument`; count and next/previous like the others.
- A match expands every ancestor branch, scrolls the row into view and selects it; non-matching branches stay as they were (no collapse-all).
- Reading mode, where there is no editor on screen, gets the tree search too.
- Matching a row also selects its source line in the editor in split mode (the existing `onSourceReveal` plumbing).

**Where.** `TreePreviewView.swift`, `StructuredDocument.swift` for a flat visit of paths, `FindBar.swift` for the session protocol.

## 4. Export the rendered result

**What.** Finish the journey from writing to using the result elsewhere. Three exports, each where its content lives:
- **Markdown / LaTeX → PDF.** File › Export as PDF…, the reading layout with page margins from the render's inset (`RenderedPreviewView.swift`; overlaps `SPEC.md` Todo 1 Print / PDF, do both together: print = the same pages to a print panel).
- **Rendered text → rich-text clipboard.** Edit › Copy as Rich Text in a Markdown/LaTeX tab (⌥⌘C): the attributed string the renderer already builds, plus HTML flavour on the same pasteboard so Mail, Notes, Slack and Pages all paste it. Never writes the clipboard from a test (`SQLGridView.pasteboard` seam pattern).
- **Selected rows → CSV.** In a SQL or CSV grid (`SQLGridView.swift`), Copy on a row selection writes CSV (RFC 4180, header row included) as well as TSV; File › Export Rows as CSV… writes the whole result or the selection to a file.

## 5. Compare two tabs

**What.** A text diff of two open tabs: two pasted API responses, two config versions, two drafts.

**Behaviour.**
- File › Compare With… (or ⇧⌘J's picker in a `.compare` mode) picks the other tab; the result opens as a new read-only tab titled `A ↔ B`.
- Side-by-side in split, unified in reading; line diff (Myers / `CollectionDifference`) with in-line character highlights on changed lines; unchanged runs folded to 3 lines of context with a "· 40 lines ·" expander.
- Live: the diff tab re-computes when either source tab changes (debounced).
- Structured comparison (JSON key-wise, SQL result set) later, on top of the same tab.

**Where.** New `DiffTab.swift` + `LineDiff.swift` (pure, tested); a new `RenderedPreviewKind`-adjacent kind so the mode control works; colours in `RenderStyle.swift` for both appearances.

---

Shipped: **6. Mermaid diagrams inside Markdown** — a ```` ```mermaid ```` fence draws natively (option (a): flowchart and sequence parsed, laid out and drawn by Nota, anything else left as code). See `SPEC.md` "Mermaid diagrams in Markdown", Done 43.

Later / unsorted: overflow chevron on the tab strip and Developer ID signing stay in `SPEC.md` Todo.
