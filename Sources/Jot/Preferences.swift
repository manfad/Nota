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
        case .system: "System"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .monospaced: "Monospaced"
        case .custom: "Other…"
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
        case .tight: "Tight"
        case .normal: "Normal"
        case .relaxed: "Relaxed"
        }
    }
}

/// Which side of the window the image sidebar lives on.
enum SidebarSide: String, CaseIterable {
    case left, right

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
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
        case .compact: "Compact"
        case .normal: "Normal"
        case .wide: "Wide"
        }
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
    static let didChange = Notification.Name("JotPreferencesDidChange")

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
        static let sidebarSide = "sidebarSide"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyDisabled = "hotKeyDisabled"
        static let lastSaveDirectory = "lastSaveDirectory"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    /// Which edge the image sidebar sits against.
    var sidebarSide: SidebarSide {
        get { defaults.string(forKey: Key.sidebarSide).flatMap(SidebarSide.init) ?? .right }
        set {
            guard newValue != sidebarSide else { return }
            defaults.set(newValue.rawValue, forKey: Key.sidebarSide)
            announce()
        }
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

    /// Where the last ⌘S landed, so the next save opens in the same place.
    var lastSaveDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastSaveDirectory) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue?.path, forKey: Key.lastSaveDirectory) }
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
