import os

enum Log {
    static let subsystem = "com.jcbaptiste.SimpleBrightness"
    static let app = Logger(subsystem: subsystem, category: "App")
    static let keys = Logger(subsystem: subsystem, category: "Keys")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let displays = Logger(subsystem: subsystem, category: "Displays")
}
