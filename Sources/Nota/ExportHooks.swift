import AppKit

/// The five exporters plugged into `Exporter` — SPEC "## Export".
///
/// `Export.swift` says what a target *is* and writes the two PDFs Nota makes
/// out of a note by itself; the other four live in modules of their own that
/// know nothing about tabs, panes or windows (`EPUBToPDF`, `PDFToEPUB`,
/// `WebPDF`, `TeXExport`, and the two grids' own `exportCSV`). This file is
/// the only place the two halves are introduced, and it is one call: what a
/// note is, where the pane in front of it is, what the module wants instead.
///
/// Installed once at launch by `AppDelegate`, and by any test that needs the
/// targets those hooks unlock — `Exporter.targets(for:)` lists a target only
/// once its hook is there, so a suite that forgets this sees the two PDFs and
/// nothing else.
extension Exporter {

    /// Who asks the reader about installing a TeX, and what a TeX export
    /// finds and runs. Both are the real thing; a test replaces them so no
    /// alert is ever raised and no engine is ever looked for, whatever
    /// happens to be installed on the Mac the suite runs on.
    static var texInstallPresenter: (NSWindow?) -> TeXInstallPrompting = {
        TeXInstallAlert(window: $0)
    }
    static var texSeams = TeXExport.Seams()

    /// Plugs every exporter in. Idempotent: called twice, the second call
    /// simply writes the same closures over the first ones.
    static func installDefaultHooks() {
        bookPDF = { note, url, _, completion in
            // The book the tab already holds, or the file opened for the
            // first time here — the same lazy read the EPUB pane does.
            guard let book = note.epubBook else {
                completion(.failure(Failure.nothingToExport))
                return
            }
            EPUBToPDF.export(book: book, to: url, completion: completion)
        }

        pdfToEPUB = { note, url, _, completion in
            guard let source = note.fileURL else {
                completion(.failure(Failure.nothingToExport))
                return
            }
            // Synchronous — PDFKit reads the document on this thread — so the
            // completion follows the call rather than a run loop.
            completion(Result {
                try PDFToEPUB.export(
                    pdfAt: source,
                    title: source.deletingPathExtension().lastPathComponent,
                    to: url
                )
            })
        }

        csv = { _, url, context, completion in
            // What the grid is showing, not what the file holds: the query
            // the reader typed and the column they sorted by live on the
            // pane, and the pane is the one thing `Context` carries for it.
            completion(Result {
                switch context.previewContent {
                case let sql as SQLPreviewView: try sql.exportCSV(to: url)
                case let table as CSVPreviewView: try table.exportCSV(to: url)
                default: throw Failure.nothingToExport
                }
            })
        }

        texPDF = { note, url, context, completion in
            TeXExport.export(
                source: note.text,
                sourceURL: note.fileURL,
                to: url,
                presenter: texInstallPresenter(context.window),
                progress: context.progress,
                using: texSeams
            ) { result in
                switch result {
                case .success:
                    completion(.success(()))
                case .failure(TeXExportError.useNativeRender):
                    // The reader was asked and said Nota's own render will
                    // do, so that is what lands at the same destination —
                    // and its result, not TeX's, is the export's answer.
                    Exporter.export(
                        note, to: .previewPDF, at: url, context: context,
                        completion: completion
                    )
                case let .failure(error):
                    // `.cancelled` included, unchanged: the window knows to
                    // say nothing about it.
                    completion(.failure(error))
                }
            }
        }

        htmlPagePDF = { note, url, _, completion in
            // The export is what the preview shows, and the preview shows the
            // buffer: a saved page with no edits prints from its file, a page
            // with unsaved edits prints the editor's text against the file's
            // own folder, so its stylesheet and its pictures still resolve the
            // way they do on screen. An untitled one has no folder to resolve
            // anything against, so it prints the text and stands alone.
            if let fileURL = note.fileURL, !note.isDirty {
                WebPDF.export(pageAt: fileURL, to: url, completion: completion)
            } else {
                WebPDF.export(
                    html: note.text, baseURL: note.fileURL,
                    to: url, completion: completion
                )
            }
        }
    }
}
