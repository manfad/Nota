import AppKit
import AVFoundation
import AVKit

/// The preview column holding a film — an `.mp4`, `.mov` or `.m4v` (SPEC
/// "## Office documents and video") — in the system's own player, with its
/// own controls floating over the picture.
///
/// A video tab is a viewer like a picture: nothing to edit and nothing to save.
/// The player is the column's whole content and nothing is drawn around it.
/// It plays only when asked, pauses the moment its tab stops being the one in
/// front, and the session keeps the second it was left at, so coming back to
/// the tab — or to Nota — comes back to the same frame.
final class VideoPreviewView: NSView, PreviewContent {

    private let playerView = AVPlayerView()
    private let missingLabel = NSTextField(labelWithString: "")
    private var player: AVPlayer?
    private var shownNoteID: UUID?
    private var shownPath: String?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    /// The film's own size and length, once the item has read them.
    private var presentationSize: NSSize = .zero
    private var duration: Double = 0

    var onPositionChange: ((Int) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(PreviewFileDrop.types)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        playerView.videoGravity = .resizeAspect
        addSubview(playerView)

        missingLabel.translatesAutoresizingMaskIntoConstraints = false
        missingLabel.alignment = .center
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.isHidden = true
        addSubview(missingLabel)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            missingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            missingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            missingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    func show(_ note: Note, in context: PreviewContext) {
        let path = note.fileURL?.path
        guard note.id != shownNoteID || path != shownPath else { return }
        // The tab being left keeps the second it was paused on.
        pause()
        shownNoteID = note.id
        shownPath = path
        presentationSize = .zero
        duration = 0
        statusObservation = nil
        rateObservation = nil

        guard let url = note.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            player = nil
            playerView.player = nil
            playerView.isHidden = true
            missingLabel.font = Preferences.shared.font()
            missingLabel.stringValue = "Couldn’t open “\(note.title)”."
            missingLabel.isHidden = false
            return
        }
        missingLabel.isHidden = true
        playerView.isHidden = false

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playerView.player = player
        let resumeAt = note.selectionLocation
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item, resumeAt: resumeAt) }
        }
        // A pause is where the session takes note of the second.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard player.rate == 0 else { return }
            DispatchQueue.main.async { self?.reportPosition() }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem, resumeAt seconds: Int) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            presentationSize = item.presentationSize
            let length = item.duration.seconds
            duration = length.isFinite ? length : 0
            if seconds > 0, Double(seconds) < duration {
                player?.seek(to: CMTime(seconds: Double(seconds), preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            reportPosition()
        case .failed:
            playerView.isHidden = true
            missingLabel.font = Preferences.shared.font()
            missingLabel.stringValue = "Couldn’t play this video."
            missingLabel.isHidden = false
        default:
            break
        }
    }

    private func reportPosition() {
        onPositionChange?(currentSecond)
    }

    private var currentSecond: Int {
        guard let time = player?.currentTime().seconds, time.isFinite else { return 0 }
        return Int(time)
    }

    private func pause() {
        guard let player, player.rate != 0 else { return }
        player.pause()
    }

    func invalidateRender() {
        pause()
        shownPath = nil
    }

    /// A tab switch hides the pane rather than taking it away: the film stops
    /// with it, rather than going on talking behind another tab.
    override func viewDidHide() {
        super.viewDidHide()
        pause()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pause() }
    }

    // MARK: - Where the tab is left

    /// The second the film is at.
    var rememberedPosition: Int? { player == nil ? nil : currentSecond }

    /// `"1920 × 1080 · 4:56"`, and where the playhead is on the right.
    var footerStatus: PreviewFooterStatus? {
        guard player != nil else { return nil }
        var summary: [String] = []
        if presentationSize.width > 0 { summary.append(TextStats.pixelSize(of: presentationSize)) }
        if duration > 0 { summary.append(Self.clock(duration)) }
        return PreviewFooterStatus(
            summary: summary.joined(separator: " · "),
            position: duration > 0 ? "\(Self.clock(Double(currentSecond))) / \(Self.clock(duration))"
                : nil
        )
    }

    /// `4:56`, or `1:02:03` past the hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    // MARK: - The keyboard

    /// Space plays and pauses, the arrows step — the player's own keys, once
    /// it has the keyboard, which is reading mode and nothing else.
    var takesKeyboard = false

    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(playerView) ?? false
    }

    // MARK: - Files let go on the film

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles)
    }

    // MARK: - Background

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
    }

    // MARK: - Tests

    var playerForTesting: AVPlayer? { player }
    var missingMessage: String? { missingLabel.isHidden ? nil : missingLabel.stringValue }
}
