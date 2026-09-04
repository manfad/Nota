import Foundation

/// What a file looked like the last time Nota knew about it: how long it was,
/// and when it was last written.
///
/// Two facts rather than the bytes themselves, because the question they
/// answer is asked on every file-system event and a hundred-megabyte log
/// cannot be read again each time. It is also the whole of how Nota's own ⌘S
/// is told from somebody else's write: a save records the stamp it has just
/// made, so the event that save sets off finds nothing that has moved and
/// nothing to reload.
struct FileStamp: Equatable {
    var size: Int
    var modified: Date

    /// The file as it stands right now, or `nil` when it is not there at all.
    ///
    /// Read through a URL made here rather than the caller's: a `URL` keeps
    /// the resource values it has already been asked for, and a remembered
    /// size is exactly the wrong answer to this question.
    static func of(_ url: URL) -> FileStamp? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(
                  forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else { return nil }
        return FileStamp(size: size, modified: modified)
    }
}

/// One file, watched, so a tab can tell when the file behind it has changed
/// under it.
///
/// Two sources rather than one. The file's own descriptor says when its bytes
/// change, which is what an in-place write looks like. But most editors do not
/// write in place: they write a temporary file beside the original and rename
/// it over the top, and the descriptor is then open on an inode nobody can
/// reach any more — it will never report anything again. So the file's watch
/// is opened again by *name* whenever it reports a `.delete` or a `.rename`,
/// and the folder holding it is watched too, since a rename into place is a
/// write to the folder and is the only event a file that is briefly not there
/// can be found by.
///
/// The watcher says only "something happened near this file". Whether that is
/// a change at all is `FileStamp`'s answer, asked by the owner — which is how
/// Nota's own save, and a neighbouring file moving in the same folder, both
/// come to nothing.
final class FileWatcher {

    /// Where the sources are armed and where their events arrive. Serial, so
    /// one file's descriptors are never opened and closed from two threads at
    /// once; shared, because a window with forty tabs in it wants forty
    /// watches and not forty queues.
    private static let queue = DispatchQueue(label: "com.nota.file-watcher", qos: .utility)

    private let url: URL
    /// Run on the main queue when something happens to the file.
    private let notify: () -> Void

    /// Guards the two sources and the stopped flag: they are written on the
    /// watcher's own queue and read from wherever `stop` is called.
    private let lock = NSLock()
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var isStopped = false
    /// The file as this watcher last saw it, so an event that says nothing
    /// new never reaches the main thread at all.
    private var lastSeen: FileStamp?

    init(url: URL, notify: @escaping () -> Void) {
        self.url = url
        self.notify = notify
        self.lastSeen = FileStamp.of(url)
        Self.queue.async { [weak self] in
            self?.armDirectory()
            self?.armFile()
        }
    }

    deinit { stop() }

    /// Puts both watches down for good. Called when the tab closes, when the
    /// note is given another file, and from `deinit`.
    func stop() {
        lock.lock()
        isStopped = true
        let sources = [fileSource, directorySource].compactMap { $0 }
        fileSource = nil
        directorySource = nil
        lock.unlock()
        for source in sources { source.cancel() }
    }

    // MARK: - The two watches

    /// Opens the file by name and watches the bytes behind that name. Any
    /// previous file watch is cancelled first, so re-arming after a rename is
    /// the same call as arming for the first time.
    private func armFile() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        let previous = fileSource
        fileSource = nil
        lock.unlock()
        previous?.cancel()

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: Self.queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // The descriptor is no longer open on the file at this path — a
            // rename over it, or an unlink. Open the name again before saying
            // anything, so the next write is heard as well as this one.
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.armFile()
            }
            self.report()
        }
        source.setCancelHandler { close(descriptor) }

        lock.lock()
        let stopped = isStopped
        if !stopped { fileSource = source }
        lock.unlock()
        // Resumed either way. A dispatch source that has never been started
        // must not simply be let go of — libdispatch traps on it — so one
        // that has already been stopped out from under us is started and
        // cancelled rather than dropped.
        source.resume()
        if stopped { source.cancel() }
    }

    /// The folder the file sits in. It reports a write whenever an entry is
    /// added, removed or renamed, which is what a temp-file-and-rename save
    /// looks like from outside — and the only thing left to hear from while
    /// the file itself is momentarily not there.
    private func armDirectory() {
        lock.lock()
        guard !isStopped, directorySource == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: Self.queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Only when the file's own watch has been lost: every other entry
            // moving in a busy folder is not a reason to re-open a descriptor
            // that is working perfectly well.
            self.armFileIfLost()
            self.report()
        }
        source.setCancelHandler { close(descriptor) }

        lock.lock()
        let stopped = isStopped
        if !stopped { directorySource = source }
        lock.unlock()
        source.resume()
        if stopped { source.cancel() }
    }

    private func armFileIfLost() {
        lock.lock()
        let lost = fileSource == nil && !isStopped
        lock.unlock()
        guard lost else { return }
        armFile()
    }

    // MARK: - Saying so

    /// Hands the news to the main queue, where the tab lives. Weakly: a tab
    /// closed between the event and the hop has nothing left to be told.
    private func report() {
        // Asked here, on the watcher's own queue, rather than on the main
        // thread: the folder's watch fires for every entry that moves in it,
        // and a `stat` is a great deal cheaper than a hop to the run loop to
        // find out that nothing about *this* file has changed. It is a filter
        // and not the answer — the note asks the same question again on the
        // main thread, where its own save is the thing being told apart.
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        guard let stamp = FileStamp.of(url), stamp != lastSeen else {
            lock.unlock()
            return
        }
        lastSeen = stamp
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let gone = self.isStopped
            self.lock.unlock()
            guard !gone else { return }
            self.notify()
        }
    }

    /// The file is now exactly what Nota has just written. Keeps the filter in
    /// step with the note's own stamp, so a save does not travel to the main
    /// thread only to be dropped there.
    func settle() {
        lock.lock()
        lastSeen = FileStamp.of(url)
        lock.unlock()
    }
}
