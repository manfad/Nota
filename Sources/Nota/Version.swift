import Foundation

/// The version Nota calls itself. One string, bumped by `.githooks/pre-commit`
/// on every commit (the patch number, by one) and copied into `Info.plist`
/// by the same hook, so the About page, the Finder and the bundle never
/// disagree. Set it by hand only to start a new minor or major.
enum AppVersion {
    static let current = "1.0.7"
}
