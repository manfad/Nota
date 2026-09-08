import AppKit

/// What a reader with no TeX on the Mac answers.
enum TeXInstallChoice: Equatable {
    /// Fetch Tectonic into Nota's own folder, then typeset.
    case install
    /// Skip TeX: let Nota draw its own reading layout, as it does on screen.
    case useNativeRender
    case cancel
}

/// Asking that question. One method, so the export is testable without an
/// alert: the tests hand it a fake and no modal is ever raised.
protocol TeXInstallPrompting: AnyObject {
    func promptForTeXInstall() -> TeXInstallChoice
}

/// The question as a sheet on the window the export was started from.
final class TeXInstallAlert: TeXInstallPrompting {
    private weak var window: NSWindow?

    init(window: NSWindow?) {
        self.window = window
    }

    func promptForTeXInstall() -> TeXInstallChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("Export as PDF with LaTeX needs a TeX engine.")
        alert.informativeText = L10n.text(
            "Tectonic is a small, self-contained TeX. Nota can download it (about 30 MB) into its own folder; nothing else on the Mac changes."
        )
        alert.addButton(withTitle: L10n.text("Install Tectonic"))
        alert.addButton(withTitle: L10n.text("Use Nota's render"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        guard let window else { return TeXInstallAlert.choice(for: alert.runModal()) }
        // A sheet, but the caller wants an answer rather than a callback, so
        // the modal loop is run here and stopped by the sheet's own handler.
        var response: NSApplication.ModalResponse = .alertThirdButtonReturn
        alert.beginSheetModal(for: window) { code in
            response = code
            NSApp.stopModal()
        }
        NSApp.runModal(for: alert.window)
        return TeXInstallAlert.choice(for: response)
    }

    static func choice(for response: NSApplication.ModalResponse) -> TeXInstallChoice {
        switch response {
        case .alertFirstButtonReturn: return .install
        case .alertSecondButtonReturn: return .useNativeRender
        default: return .cancel
        }
    }
}

/// Detection, the prompt, the install and the compile as one call — what
/// File › Export… asks for when the format is "PDF via LaTeX".
///
/// The module ends here on purpose: no menu item, no save panel, no PDF tab.
/// It answers with a `Result`, and a refusal that is really the reader's
/// choice (`.useNativeRender`, `.cancelled`) comes back as a distinguishable
/// error rather than a second alert, so the caller decides what a fallback
/// looks like.
enum TeXExport {
    /// The three seams the tests replace. Defaults are the real thing, so a
    /// call site never mentions them.
    struct Seams {
        var findEngine: () -> TeXEngine? = { TeXEngine.installed() }
        var install: (@escaping (String) -> Void, @escaping (Result<TeXEngine, Error>) -> Void)
            -> Void = { progress, completion in
                TectonicInstaller.install(progress: progress, completion: completion)
            }
        var compile: (TeXEngine, String, URL?, URL, (String) -> Void) throws -> Void = {
            engine, source, sourceURL, destination, progress in
            try TeXEngine.compile(
                engine: engine, source: source, sourceURL: sourceURL,
                to: destination, progress: progress
            )
        }

        init() {}
    }

    static func export(
        source: String,
        sourceURL: URL?,
        to destination: URL,
        presenter: TeXInstallPrompting,
        progress: @escaping (String) -> Void,
        using seams: Seams = Seams(),
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        func finish(_ result: Result<Void, Error>) { onMain { completion(result) } }
        func say(_ message: String) { onMain { progress(message) } }

        func typeset(with engine: TeXEngine) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try seams.compile(engine, source, sourceURL, destination, say)
                    finish(.success(()))
                } catch {
                    finish(.failure(error))
                }
            }
        }

        onMain {
            if let engine = seams.findEngine() { return typeset(with: engine) }
            // The prompt is a modal question, so it belongs on the main
            // thread and nowhere else.
            switch presenter.promptForTeXInstall() {
            case .cancel:
                finish(.failure(TeXExportError.cancelled))
            case .useNativeRender:
                finish(.failure(TeXExportError.useNativeRender))
            case .install:
                seams.install(say) { result in
                    switch result {
                    case let .success(engine): typeset(with: engine)
                    case let .failure(error): finish(.failure(error))
                    }
                }
            }
        }
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
