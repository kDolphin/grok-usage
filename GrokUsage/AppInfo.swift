import Foundation

/// App version from the bundled Info.plist (PowerTop-style).
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// e.g. "v0.2.0 (20)"
    static var versionLabel: String {
        "v\(version) (\(build))"
    }
}
