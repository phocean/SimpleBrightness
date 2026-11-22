import Foundation

/// When the menu-bar icon is shown. Persisted; `.always` by default.
enum MenuBarIconMode: String, CaseIterable {
    case always
    /// Shown only while an external display (supported or not) is connected.
    case externalDisplayOnly
    /// Never shown, except briefly when the app is opened again (Finder,
    /// Spotlight): that is how a hidden icon is found back.
    case hidden

    /// Pure decision, unit-tested.
    func isVisible(hasExternalDisplay: Bool, revealed: Bool) -> Bool {
        switch self {
        case .always: true
        case .externalDisplayOnly: hasExternalDisplay || revealed
        case .hidden: revealed
        }
    }
}
