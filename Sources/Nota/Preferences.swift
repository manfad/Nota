import AppKit

// MARK: - Options

enum EditorFontFamily: String, CaseIterable {
    case system, serif, rounded, monospaced, custom

    var design: NSFontDescriptor.SystemDesign? {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        case .custom: nil
        }
    }

    var title: String {
        switch self {
        case .system: L10n.text("System")
        case .serif: L10n.text("Serif")
        case .rounded: L10n.text("Rounded")
        case .monospaced: L10n.text("Monospaced")
        case .custom: L10n.text("Other…")
        }
    }
}

enum LineSpacingOption: String, CaseIterable {
    case tight, normal, relaxed

    var multiple: CGFloat {
        switch self {
        case .tight: 1.15
        case .normal: 1.3
        case .relaxed: 1.5
        }
    }

    var title: String {
        switch self {
        case .tight: L10n.text("Tight")
        case .normal: L10n.text("Normal")
        case .relaxed: L10n.text("Relaxed")
        }
    }
}

/// Which side of the window the image sidebar lives on.
enum SidebarSide: String, CaseIterable {
    case left, right

    var title: String {
        switch self {
        case .left: L10n.text("Left")
        case .right: L10n.text("Right")
        }
    }
}

/// How an image token reads on the plain-text pasteboard flavor — the one a
/// terminal or chat box actually receives.
enum PlainTextImageStyle: String, CaseIterable {
    case path, marker

    var title: String {
        switch self {
        case .path: L10n.text("File path")
        case .marker: L10n.text("Placeholder character")
        }
    }
}

enum EditorPaddingOption: String, CaseIterable {
    case compact, normal, wide

    var inset: CGFloat {
        switch self {
        case .compact: 12
        case .normal: 20
        case .wide: 40
        }
    }

    var title: String {
        switch self {
        case .compact: L10n.text("Compact")
        case .normal: L10n.text("Normal")
        case .wide: L10n.text("Wide")
        }
    }
}

/// Light, dark, or whatever the Mac is doing. Applied to the app as a whole
/// through `NSApp.appearance`, so every window, panel and menu follows.
enum AppTheme: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: L10n.text("System Default", chinese: "跟随系统")
        case .light: L10n.text("Light")
        case .dark: L10n.text("Dark")
        }
    }

    /// Puts this theme on the app as a whole, every window, panel and menu
    /// with it. Done here, by the setting itself, rather than by a listener
    /// somewhere else, so the value and what is on screen cannot drift.
    func apply() {
        let appearance = appearance
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
    }

    /// The appearance to force, or `nil` to let the system decide.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The interface language. The order the cases are written in is the order
/// the Settings popup lists them; the raw values are stored in `UserDefaults`,
/// so they never change once shipped.
enum AppLanguage: String, CaseIterable {
    case system, english, simplifiedChinese, traditionalChinese, malay

    /// Each language names itself in its own script — the one label a reader
    /// who cannot read the current interface can still recognise.
    var title: String {
        switch self {
        case .system: L10n.text("System Default", chinese: "跟随系统")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .malay: "Bahasa Melayu"
        }
    }

    /// The language the interface is actually drawn in: itself, or, for
    /// `.system`, whatever the Mac's own preferred language asks for. Never
    /// returns `.system`.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        return Self.resolving(preferredLanguage: Locale.preferredLanguages.first)
    }

    /// What a preferred-language identifier (`zh-Hant-TW`, `ms-MY`, `en-GB`)
    /// means to us. Written as a pure function of the string so the tests can
    /// ask without touching the Mac's own settings.
    static func resolving(preferredLanguage identifier: String?) -> AppLanguage {
        guard let identifier else { return .english }
        let code = identifier.lowercased()
        if code.hasPrefix("zh") {
            let traditional = ["hant", "tw", "hk", "mo"].contains { code.contains("-\($0)") }
            return traditional ? .traditionalChinese : .simplifiedChinese
        }
        if code == "ms" || code.hasPrefix("ms-") || code.hasPrefix("ms_") { return .malay }
        return .english
    }
}

// MARK: - Preferences

/// Every editor setting, in one place, backed by `UserDefaults`.
///
/// This is the single source of truth: the Settings window, ⌘+/⌘-/⌘0 and the
/// session file all read and write through it. Any change posts `didChange`,
/// which is what makes the editor update live.
final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("NotaPreferencesDidChange")

    static let minimumFontSize: CGFloat = 9
    static let maximumFontSize: CGFloat = 48
    static let standardFontSize: CGFloat = 13

    private enum Key {
        static let fontFamily = "fontFamily"
        static let customFontName = "customFontName"
        static let fontSize = "fontSize"
        static let lineSpacing = "lineSpacing"
        static let padding = "editorPadding"
        static let lineNumbers = "showsLineNumbers"
        static let gutterSeparator = "showsGutterSeparator"
        static let highlightsCurrentLine = "highlightsCurrentLine"
        static let wordWrap = "wrapsLines"
        static let sidebarSide = "sidebarSide"
        static let plainTextImageStyle = "plainTextImageStyle"
        static let markdownReadingMode = "opensMarkdownInReadingMode"
        static let vimMode = "vimMode"
        static let footerWords = "footerShowsWords"
        static let footerCharacters = "footerShowsCharacters"
        static let footerImages = "footerShowsImages"
        static let footerLines = "footerShowsLines"
        static let footerFormat = "footerShowsFormat"
        static let footerEncoding = "footerShowsEncoding"
        static let footerLineEndings = "footerShowsLineEndings"
        static let footerCursorPosition = "footerShowsCursorPosition"
        static let statusBar = "showsStatusBar"
        static let hidesTabBar = "hidesTabBar"
        static let autoHidesTabBar = "autoHidesTabBar"
        static let hidesTrafficLights = "hidesTrafficLights"
        static let hidesBookmarkToggleButton = "hidesBookmarkToggleButton"
        static let hidesBookmarkButton = "hidesBookmarkButton"
        static let hidesSettingsButton = "hidesSettingsButton"
        static let language = "appLanguage"
        static let theme = "appTheme"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyDisabled = "hotKeyDisabled"
        static let shortcuts = "shortcuts"
        static let lastSaveDirectory = "lastSaveDirectory"
        static let lastSaveExtension = "lastSaveExtension"
        static let exportEditorImages = "exportEditorImages"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Carrying the old settings over

    /// The defaults domain the app used when it was called Jot.
    static let legacyDefaultsDomain = "com.manfad.jot"

    /// Set once the copy below has run, so it never runs twice — and so a
    /// setting the user has since turned off is not resurrected.
    private static let migrationMarker = "migratedFromJot"

    /// `UserDefaults` is keyed by bundle identifier, and the rename changed
    /// it, so a renamed build would otherwise start with every setting back
    /// at its default. Every key from the old domain is copied across once,
    /// before anything reads a setting.
    ///
    /// Returns whether anything was actually carried over — the tests read
    /// it, nothing else does.
    @discardableResult
    static func migrateFromJotIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomain: String = legacyDefaultsDomain
    ) -> Bool {
        guard defaults.object(forKey: migrationMarker) == nil else { return false }
        defer { defaults.set(true, forKey: migrationMarker) }

        guard let old = defaults.persistentDomain(forName: legacyDomain), !old.isEmpty else {
            return false
        }
        for (key, value) in old where key != migrationMarker {
            defaults.set(value, forKey: key)
        }
        return true
    }

    static func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), minimumFontSize), maximumFontSize)
    }

    // MARK: Stored settings

    var fontFamily: EditorFontFamily {
        get { defaults.string(forKey: Key.fontFamily).flatMap(EditorFontFamily.init) ?? .system }
        set {
            guard newValue != fontFamily else { return }
            defaults.set(newValue.rawValue, forKey: Key.fontFamily)
            announce()
        }
    }

    /// Family name of a font picked through the font panel.
    var customFontName: String? {
        get { defaults.string(forKey: Key.customFontName) }
        set {
            guard newValue != customFontName else { return }
            defaults.set(newValue, forKey: Key.customFontName)
            announce()
        }
    }

    var fontSize: CGFloat {
        get {
            guard let stored = defaults.object(forKey: Key.fontSize) as? Double else {
                return Self.standardFontSize
            }
            return Self.clampFontSize(CGFloat(stored))
        }
        set {
            let clamped = Self.clampFontSize(newValue)
            guard clamped != fontSize else { return }
            defaults.set(Double(clamped), forKey: Key.fontSize)
            announce()
        }
    }

    var lineSpacing: LineSpacingOption {
        get { defaults.string(forKey: Key.lineSpacing).flatMap(LineSpacingOption.init) ?? .normal }
        set {
            guard newValue != lineSpacing else { return }
            defaults.set(newValue.rawValue, forKey: Key.lineSpacing)
            announce()
        }
    }

    var padding: EditorPaddingOption {
        get { defaults.string(forKey: Key.padding).flatMap(EditorPaddingOption.init) ?? .normal }
        set {
            guard newValue != padding else { return }
            defaults.set(newValue.rawValue, forKey: Key.padding)
            announce()
        }
    }

    /// Line numbers in the left gutter. On unless turned off.
    var showsLineNumbers: Bool {
        get { defaults.object(forKey: Key.lineNumbers) as? Bool ?? true }
        set {
            guard newValue != showsLineNumbers else { return }
            defaults.set(newValue, forKey: Key.lineNumbers)
            announce()
        }
    }

    /// A hairline down the gutter's inner edge. Off: the bare gutter is the
    /// quieter default, and the numbers already mark the margin.
    var showsGutterSeparator: Bool {
        get { defaults.object(forKey: Key.gutterSeparator) as? Bool ?? false }
        set {
            guard newValue != showsGutterSeparator else { return }
            defaults.set(newValue, forKey: Key.gutterSeparator)
            announce()
        }
    }

    /// A quiet band under the caret's line. Off by default; vim's own
    /// `:set cursorline` is independent and can light the same band without
    /// touching this.
    var highlightsCurrentLine: Bool {
        get { defaults.object(forKey: Key.highlightsCurrentLine) as? Bool ?? false }
        set {
            guard newValue != highlightsCurrentLine else { return }
            defaults.set(newValue, forKey: Key.highlightsCurrentLine)
            announce()
        }
    }

    /// Whether long lines fold at the right margin. On: the default an editor
    /// with no line-width cap wants. Off: a line runs as far as it likes and
    /// the editor scrolls sideways to follow it.
    var wrapsLines: Bool {
        get { defaults.object(forKey: Key.wordWrap) as? Bool ?? true }
        set {
            guard newValue != wrapsLines else { return }
            defaults.set(newValue, forKey: Key.wordWrap)
            announce()
        }
    }

    /// Which edge the image sidebar sits against.
    var sidebarSide: SidebarSide {
        get { defaults.string(forKey: Key.sidebarSide).flatMap(SidebarSide.init) ?? .right }
        set {
            guard newValue != sidebarSide else { return }
            defaults.set(newValue.rawValue, forKey: Key.sidebarSide)
            announce()
        }
    }

    /// How an image reads on the plain-text pasteboard flavor. A file path
    /// lets an agent in a terminal find the picture; the marker matches what
    /// a stock text view would have left.
    var plainTextImageStyle: PlainTextImageStyle {
        get {
            defaults.string(forKey: Key.plainTextImageStyle)
                .flatMap(PlainTextImageStyle.init) ?? .path
        }
        set {
            guard newValue != plainTextImageStyle else { return }
            defaults.set(newValue.rawValue, forKey: Key.plainTextImageStyle)
            announce()
        }
    }

    /// Whether a `.md` file opens as the render rather than as text. Off:
    /// opening a file is opening it to edit unless you say otherwise.
    /// Restoring a session ignores this — the tab's own mode wins.
    var opensMarkdownInReadingMode: Bool {
        get { defaults.object(forKey: Key.markdownReadingMode) as? Bool ?? false }
        set {
            guard newValue != opensMarkdownInReadingMode else { return }
            defaults.set(newValue, forKey: Key.markdownReadingMode)
            announce()
        }
    }

    /// What the middle of the footer counts. Words and characters are the
    /// ones worth having open by default; images and lines are there for
    /// people who want them.
    var footerShowsWords: Bool {
        get { defaults.object(forKey: Key.footerWords) as? Bool ?? true }
        set { setFooterSegment(newValue, current: footerShowsWords, key: Key.footerWords) }
    }

    var footerShowsCharacters: Bool {
        get { defaults.object(forKey: Key.footerCharacters) as? Bool ?? true }
        set {
            setFooterSegment(
                newValue, current: footerShowsCharacters, key: Key.footerCharacters
            )
        }
    }

    var footerShowsImages: Bool {
        get { defaults.object(forKey: Key.footerImages) as? Bool ?? false }
        set { setFooterSegment(newValue, current: footerShowsImages, key: Key.footerImages) }
    }

    var footerShowsLines: Bool {
        get { defaults.object(forKey: Key.footerLines) as? Bool ?? false }
        set { setFooterSegment(newValue, current: footerShowsLines, key: Key.footerLines) }
    }

    var footerShowsFormat: Bool {
        get { defaults.object(forKey: Key.footerFormat) as? Bool ?? true }
        set { setBoolean(newValue, current: footerShowsFormat, key: Key.footerFormat) }
    }

    var footerShowsEncoding: Bool {
        get { defaults.object(forKey: Key.footerEncoding) as? Bool ?? true }
        set { setBoolean(newValue, current: footerShowsEncoding, key: Key.footerEncoding) }
    }

    var footerShowsLineEndings: Bool {
        get { defaults.object(forKey: Key.footerLineEndings) as? Bool ?? true }
        set { setBoolean(newValue, current: footerShowsLineEndings, key: Key.footerLineEndings) }
    }

    var footerShowsCursorPosition: Bool {
        get { defaults.object(forKey: Key.footerCursorPosition) as? Bool ?? true }
        set { setBoolean(newValue, current: footerShowsCursorPosition, key: Key.footerCursorPosition) }
    }

    var showsStatusBar: Bool {
        get { defaults.object(forKey: Key.statusBar) as? Bool ?? true }
        set { setBoolean(newValue, current: showsStatusBar, key: Key.statusBar) }
    }

    // MARK: Window chrome (Settings › Appearance › Window)

    /// The tab strip across the title bar goes, the way zen mode takes it —
    /// the editor starts at the top, under a slim band the window can still
    /// be dragged by — and the traffic lights go with it, zen's way too.
    /// ⌘T, ⌘P and the rest keep working.
    var hidesTabBar: Bool {
        get { defaults.bool(forKey: Key.hidesTabBar) }
        set { setBoolean(newValue, current: hidesTabBar, key: Key.hidesTabBar) }
    }

    /// The strip and the lights are off the window the same way, but the top
    /// edge is watching: the pointer reaching it slides the whole top bar —
    /// strip and lights together, unless "Hide traffic lights" keeps the
    /// lights off — in over the document, and leaving it slides them away
    /// again. Zen mode and "Hide tab bar" both win — either of those means
    /// gone for good.
    var autoHidesTabBar: Bool {
        get { defaults.bool(forKey: Key.autoHidesTabBar) }
        set { setBoolean(newValue, current: autoHidesTabBar, key: Key.autoHidesTabBar) }
    }

    /// The three window buttons at the top-left. ⌘W and ⌘M still do their jobs.
    var hidesTrafficLights: Bool {
        get { defaults.bool(forKey: Key.hidesTrafficLights) }
        set { setBoolean(newValue, current: hidesTrafficLights, key: Key.hidesTrafficLights) }
    }

    /// The Bookmark button at the strip's trailing edge, the one that
    /// bookmarks the tab in front; ⌘D still does it.
    var hidesBookmarkToggleButton: Bool {
        get { defaults.bool(forKey: Key.hidesBookmarkToggleButton) }
        set {
            setBoolean(newValue, current: hidesBookmarkToggleButton,
                       key: Key.hidesBookmarkToggleButton)
        }
    }

    /// The Bookmarks button beside it, the one that opens the picker; ⇧⌘D
    /// still opens it. The key is the older `hidesBookmarkButton`, from when
    /// this was the only bookmark button in the strip, so a session that
    /// switched it off keeps it off.
    var hidesBookmarkButton: Bool {
        get { defaults.bool(forKey: Key.hidesBookmarkButton) }
        set { setBoolean(newValue, current: hidesBookmarkButton, key: Key.hidesBookmarkButton) }
    }

    /// The Settings gear beside it; ⌘, still opens Settings.
    var hidesSettingsButton: Bool {
        get { defaults.bool(forKey: Key.hidesSettingsButton) }
        set { setBoolean(newValue, current: hidesSettingsButton, key: Key.hidesSettingsButton) }
    }

    private func setFooterSegment(_ newValue: Bool, current: Bool, key: String) {
        guard newValue != current else { return }
        defaults.set(newValue, forKey: key)
        announce()
    }

    /// The enabled segments, in the order the footer shows them.
    var footerSegments: [TextStats.Segment] {
        TextStats.Segment.allCases.filter { segment in
            switch segment {
            case .words: footerShowsWords
            case .characters: footerShowsCharacters
            case .images: footerShowsImages
            case .lines: footerShowsLines
            }
        }
    }

    /// Vim keys in the editor. Off unless asked for.
    var vimMode: Bool {
        get { defaults.object(forKey: Key.vimMode) as? Bool ?? false }
        set {
            guard newValue != vimMode else { return }
            defaults.set(newValue, forKey: Key.vimMode)
            announce()
        }
    }

    var language: AppLanguage {
        get { defaults.string(forKey: Key.language).flatMap(AppLanguage.init) ?? .system }
        set {
            guard newValue != language else { return }
            defaults.set(newValue.rawValue, forKey: Key.language)
            announce()
        }
    }

    var theme: AppTheme {
        get { defaults.string(forKey: Key.theme).flatMap(AppTheme.init) ?? .system }
        set {
            guard newValue != theme else { return }
            defaults.set(newValue.rawValue, forKey: Key.theme)
            newValue.apply()
            announce()
        }
    }

    private func setBoolean(_ newValue: Bool, current: Bool, key: String) {
        guard newValue != current else { return }
        defaults.set(newValue, forKey: key)
        announce()
    }

    /// The summon shortcut. `nil` means the user cleared it.
    var hotKey: GlobalHotKey.Shortcut? {
        get {
            if defaults.bool(forKey: Key.hotKeyDisabled) { return nil }
            guard let code = defaults.object(forKey: Key.hotKeyCode) as? Int,
                  let modifiers = defaults.object(forKey: Key.hotKeyModifiers) as? Int
            else { return .optionSpace }
            return GlobalHotKey.Shortcut(keyCode: UInt32(code), modifiers: UInt(modifiers))
        }
        set {
            guard newValue != hotKey else { return }
            if let newValue {
                defaults.set(false, forKey: Key.hotKeyDisabled)
                defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyCode)
                defaults.set(Int(newValue.modifiers), forKey: Key.hotKeyModifiers)
            } else {
                defaults.set(true, forKey: Key.hotKeyDisabled)
            }
            announce()
        }
    }

    /// The keys the user has moved — only the ones that differ from what the
    /// command ships with, so a default Nota changes later moves with it
    /// instead of being pinned by an old copy.
    ///
    /// One defaults key holding JSON, rather than one key per command: the
    /// table is read and written whole, and a menu rebuild wants all of it.
    var shortcuts: [ShortcutAction: KeyCombo] {
        get {
            guard let data = defaults.data(forKey: Key.shortcuts),
                  let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data)
            else { return [:] }
            return stored.reduce(into: [:]) { table, entry in
                guard let action = ShortcutAction(rawValue: entry.key) else { return }
                table[action] = entry.value
            }
        }
        set {
            guard newValue != shortcuts else { return }
            let stored = newValue.reduce(into: [String: KeyCombo]()) { table, entry in
                table[entry.key.rawValue] = entry.value
            }
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: Key.shortcuts)
            }
            announce()
        }
    }

    /// The key a command answers to: the user's, or the one it ships with.
    func combo(for action: ShortcutAction) -> KeyCombo {
        shortcuts[action] ?? action.defaultCombo
    }

    /// Where the last ⌘S landed, so the next save opens in the same place.
    var lastSaveDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastSaveDirectory) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue?.path, forKey: Key.lastSaveDirectory) }
    }

    /// The extension last chosen in the save panel's Format combo, offered
    /// again next time a note has none of its own to keep.
    var lastSaveExtension: String {
        get { defaults.string(forKey: Key.lastSaveExtension) ?? SuggestedName.defaultExtension }
        set { defaults.set(newValue, forKey: Key.lastSaveExtension) }
    }

    /// Where an exported listing puts the note's pictures — in the text, or
    /// as plates at the end (SPEC "## Export"). Asked in the export sheet and
    /// remembered here, so the reader answers it once. Inline until they say
    /// otherwise: that is where the note itself put them.
    var exportEditorImages: ExportImagePlacement {
        get {
            defaults.string(forKey: Key.exportEditorImages)
                .flatMap(ExportImagePlacement.init) ?? .inline
        }
        set {
            guard newValue != exportEditorImages else { return }
            defaults.set(newValue.rawValue, forKey: Key.exportEditorImages)
            announce()
        }
    }

    /// Picking a font in the font panel changes family and name together, so
    /// they are set as one edit rather than two notifications.
    func selectCustomFont(familyName: String) {
        guard familyName != customFontName || fontFamily != .custom else { return }
        defaults.set(familyName, forKey: Key.customFontName)
        defaults.set(EditorFontFamily.custom.rawValue, forKey: Key.fontFamily)
        announce()
    }

    // MARK: Derived

    /// What the font popup shows: a design name, or the chosen family.
    var fontDisplayName: String {
        if fontFamily == .custom, let customFontName { return customFontName }
        return fontFamily.title
    }

    func font() -> NSFont {
        let size = fontSize
        if fontFamily == .custom, let name = customFontName {
            if let font = NSFont(name: name, size: size) { return font }
            if let font = NSFontManager.shared.font(
                withFamily: name, traits: [], weight: 5, size: size
            ) { return font }
            return .systemFont(ofSize: size)
        }
        let base = NSFont.systemFont(ofSize: size)
        guard let design = fontFamily.design, design != .default,
              let descriptor = base.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: size)
        else { return base }
        return font
    }

    func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineSpacing.multiple
        return style
    }

    func textAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: font(),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle(),
        ]
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
