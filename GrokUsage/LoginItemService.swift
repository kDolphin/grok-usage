import Foundation
import ServiceManagement

/// Enables / disables launch-at-login.
/// Prefers `SMAppService` (macOS 13+); falls back to a user LaunchAgent if register fails
/// (common for some ad-hoc local builds).
enum LoginItemService {
    static let bundleID = "com.kdolphin.grok-usage"
    private static let launchAgentLabel = "com.kdolphin.grok-usage.login"

    /// True when either SMAppService or our LaunchAgent is enabled.
    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    /// Human-readable status for debugging (optional UI).
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return L10n.loginItemEnabled
        case .notRegistered: return L10n.loginItemNotRegistered
        case .notFound: return L10n.loginItemNotFound
        case .requiresApproval: return L10n.loginItemRequiresApproval
        @unknown default: return L10n.loginItemUnknown
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    private static func enable() throws {
        // Prefer official login-item API.
        do {
            try SMAppService.mainApp.register()
            // Clean up any leftover agent so we don't double-launch.
            try? removeLaunchAgent()
            return
        } catch {
            // Fall back to LaunchAgent (open the installed .app at login).
            try installLaunchAgent()
        }
    }

    private static func disable() throws {
        var errors: [Error] = []

        if SMAppService.mainApp.status == .enabled
            || SMAppService.mainApp.status == .requiresApproval
        {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                errors.append(error)
            }
        }

        do {
            try removeLaunchAgent()
        } catch {
            errors.append(error)
        }

        if !errors.isEmpty, !isEnabled {
            // Successfully disabled despite intermediate errors.
            return
        }
        if let first = errors.first, isEnabled {
            throw first
        }
    }

    // MARK: - LaunchAgent fallback

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private static func preferredAppPath() -> String {
        // Running from a .app bundle → use that path; else default Applications install.
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return bundlePath
        }
        return "/Applications/Grok Usage.app"
    }

    private static func installLaunchAgent() throws {
        let fm = FileManager.default
        let agentsDir = launchAgentURL.deletingLastPathComponent()
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let appPath = preferredAppPath()
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [
                "/usr/bin/open",
                "-a",
                appPath,
            ],
            "RunAtLoad": true,
            // Don't keep restarting if the user quits the menu bar app.
            "KeepAlive": false,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)

        // Best-effort load (may fail in sandboxed or restricted contexts; file alone is enough for next login).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["load", "-w", launchAgentURL.path]
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func removeLaunchAgent() throws {
        let url = launchAgentURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["unload", "-w", url.path]
        try? proc.run()
        proc.waitUntilExit()

        try FileManager.default.removeItem(at: url)
    }
}
