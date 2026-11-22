import Foundation

/// Persisted preferences. Brightness values themselves are never stored:
/// the displays keep their own, so nothing is re-applied at launch.
enum Preferences {
    private static let syncKey = "syncEnabled"

    static var isSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: syncKey) }   // false by default
        set { UserDefaults.standard.set(newValue, forKey: syncKey) }
    }

    private static let offsetKey = "syncOffset"

    /// External displays relative to the built-in one while synced (0 by default).
    static var syncOffset: Double {
        get {
            let value = UserDefaults.standard.double(forKey: offsetKey)
            return value.isFinite ? value : 0   // a hand-edited NaN must not disable sync
        }
        set { UserDefaults.standard.set(newValue, forKey: offsetKey) }
    }
}
