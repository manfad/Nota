import AppKit

/// Which vim mode the editor is in.
///
/// The footer badge is the only thing that reads this so far — the engine
/// drives everything else — so all it carries is how the mode presents
/// itself: a word, and whether that word sits in a capsule.
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
        case .normal, .operatorPending: "Normal"
        case .insert: "Insert"
        case .visual: "Visual"
        case .visualLine: "Visual line"
        case .replace: "Replace"
        case .commandLine: "Command"
        }
    }

    /// Every mode wears the same quiet capsule except insert, which is the
    /// state you spend most of your time in and so shows the bare word.
    var showsCapsule: Bool { self != .insert }
}
