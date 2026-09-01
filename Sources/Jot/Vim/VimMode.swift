import AppKit

/// Which vim mode the editor is in.
///
/// The footer badge is the only thing that reads this so far — the engine
/// drives everything else — so all it carries is the name and the colour.
enum VimMode: Equatable {
    case normal
    case insert
    case visual
    case visualLine
    case replace
    /// Waiting for the motion an operator applies to (`d`, `c`, `y`, …).
    case operatorPending
    /// `:`, `/` or `?` is open.
    case commandLine

    /// What the badge says. Operator-pending is still normal mode as far as
    /// the badge is concerned; the keys typed so far show beside it instead.
    var badgeTitle: String {
        switch self {
        case .normal, .operatorPending: "NORMAL"
        case .insert: "INSERT"
        case .visual: "VISUAL"
        case .visualLine: "V-LINE"
        case .replace: "REPLACE"
        case .commandLine: "COMMAND"
        }
    }

    /// The badge fill. `nil` for the command line, which keeps the colour of
    /// whichever mode it was opened from.
    var badgeColor: NSColor? {
        switch self {
        case .normal, .operatorPending: .controlAccentColor
        case .insert: .systemGreen
        case .visual, .visualLine: .systemOrange
        case .replace: .systemRed
        case .commandLine: nil
        }
    }
}
