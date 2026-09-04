import AppKit

/// Every open Nota window, and everything the app does with more than one of
/// them: which is in front, where a new one comes from, and where a closing
/// window's tabs go.
///
/// It is deliberately not the app delegate — nothing in here needs an app to
/// be running, so the multi-window rules can be exercised head-on.
final class WindowRegistry {
    private let store: SessionStore
    /// In the order they were opened, which is the order the session file
    /// keeps and the order they come back in.
    private(set) var controllers: [MainWindowController] = []
    /// Most recently key first. A window that is gone is dropped from it, so
    /// the head is always a window that still exists.
    private var keyOrder: [MainWindowController] = []
    /// True while the launch is still building windows: each one flushes as
    /// it restores, and a save then would write the windows built so far
    /// over the session file that is still being read.
    var isRestoring = false

    init(store: SessionStore) {
        self.store = store
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The window every menu action means: the one with the keyboard, else
    /// the one that had it last, else the first one opened.
    var activeController: MainWindowController? {
        if let key = controllers.first(where: { $0.window?.isKeyWindow == true }) { return key }
        if let recent = keyOrder.first { return recent }
        return controllers.first
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        markKey(window)
    }

    /// Remembers which window was in front. Called for every window in the
    /// app, including Settings — one that is not a Nota window changes
    /// nothing, so ⌘S with the Settings window key still means the note.
    func markKey(_ window: NSWindow) {
        guard let controller = controllers.first(where: { $0.window === window }) else { return }
        keyOrder.removeAll { $0 === controller }
        keyOrder.insert(controller, at: 0)
    }

    // MARK: - Opening and closing

    /// A window with one untitled tab — ⇧⌘N, and the fallback when an action
    /// needs a window and there is none.
    @discardableResult
    func newWindow(frame: NSRect? = nil) -> MainWindowController {
        makeWindow(adopting: [], frame: frame)
    }

    /// A window built around a note taken out of another one.
    @discardableResult
    func newWindow(with note: Note, frame: NSRect? = nil) -> MainWindowController {
        makeWindow(adopting: [note], frame: frame)
    }

    private func makeWindow(adopting notes: [Note], frame: NSRect?) -> MainWindowController {
        let previous = activeController?.window
        let controller = MainWindowController(
            store: store,
            restoring: SessionWindow(tabs: []),
            adopting: notes,
            sessionWriter: { [weak self] in self?.saveSession() }
        )
        if let frame {
            controller.window?.setFrame(frame, display: false)
        } else if let previous, let window = controller.window {
            // Offset from the window it came from, the way documents
            // cascade, rather than exactly on top of it. Asking the previous
            // window to cascade from nothing does not move it; it only says
            // where the next one goes.
            _ = window.cascadeTopLeft(from: previous.cascadeTopLeft(from: .zero))
        }
        add(controller)
        saveSession()
        return controller
    }

    /// A window as the session file left it. It is given the registry's
    /// writer before it restores, so the flush that finishes a restore
    /// cannot write itself over the windows that are still to be built.
    @discardableResult
    func restoreWindow(_ sessionWindow: SessionWindow) -> MainWindowController {
        let controller = MainWindowController(
            store: store,
            restoring: sessionWindow,
            sessionWriter: { [weak self] in self?.saveSession() }
        )
        add(controller)
        return controller
    }

    /// Puts a controller under the same rules as one the registry opened.
    func add(_ controller: MainWindowController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controller.sessionWriter = { [weak self] in self?.saveSession() }
        controller.windowCloseHandler = { [weak self] in self?.windowShouldClose($0) ?? false }
        // Everything a tab dragged out of this window's strip needs: a
        // window to land in, the strip it is dropped on, and a way for the
        // window nobody wants at the end of it to go.
        controller.tearOffHandler = { [weak self] note, frame in
            self?.newWindow(with: note, frame: frame)
        }
        controller.dockTargetFinder = { [weak self] point, window in
            self?.controller(under: point, below: window)
        }
        controller.windowCloser = { [weak self] in self?.removeWindow($0) }
        controllers.append(controller)
    }

    /// The window a point on screen falls in, ignoring the one being
    /// dragged and everything above it — the drop target of a tear-off.
    func controller(under screenPoint: NSPoint, below window: NSWindow) -> MainWindowController? {
        controller(forWindowNumber: NSWindow.windowNumber(
            at: screenPoint, belowWindowWithWindowNumber: window.windowNumber
        ))
    }

    func controller(forWindowNumber number: Int) -> MainWindowController? {
        guard number != 0 else { return nil }
        return controllers.first { $0.window?.windowNumber == number }
    }

    func removeWindow(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        keyOrder.removeAll { $0 === controller }
        // A window AppKit is already closing must not be closed a second
        // time from under it; every other one goes here and now.
        if !controller.isClosingWindow { controller.window?.close() }
        saveSession()
        // The window is mid-close and AppKit is still inside the
        // controller's own delegate method: let the last reference go on the
        // next turn of the run loop rather than out from under its feet.
        DispatchQueue.main.async { withExtendedLifetime(controller) {} }
    }

    /// ⌘W on a window rather than a tab. The last window only hides — the
    /// app stays alive so summoning it back is instant. Any other window
    /// closes for real, and its tabs go to the end of the window that was in
    /// front before it, so no note is lost and nothing is asked.
    func windowShouldClose(_ controller: MainWindowController) -> Bool {
        guard controllers.count > 1,
              let destination = mostRecentOther(than: controller)
        else { return false }

        while let note = controller.detachNote(at: 0, keepingOneTab: false) {
            destination.attach(note, at: nil, select: false)
        }
        removeWindow(controller)
        saveSession()
        return true
    }

    private func mostRecentOther(than controller: MainWindowController) -> MainWindowController? {
        keyOrder.first { $0 !== controller }
            ?? controllers.first { $0 !== controller }
    }

    // MARK: - Session

    /// Every window's tabs, in one file.
    func saveSession() {
        guard !isRestoring else { return }
        store.save(SessionState(
            windows: controllers.map(\.sessionWindow),
            fontSize: Double(Preferences.shared.fontSize)
        ))
    }

    /// Cache files for tabs no window holds any more. Only ever done once
    /// the whole session is open: pruning for one window's tabs would delete
    /// the text behind every other window.
    func pruneCache() {
        store.pruneCache(keeping: controllers.flatMap { $0.sessionWindow.tabs.map(\.id) })
    }

    func flushAll() {
        for controller in controllers { controller.flushAll() }
    }
}
