import AppKit
import SwiftUI

@main
struct GrokUsageApp: App {
    @StateObject private var model = UsageViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
                // Panel open: refresh only if cached data is older than the stale window.
                .onAppear { model.panelDidOpen() }
        } label: {
            Label {
                Text(model.menuBarTitle)
            } icon: {
                Image(systemName: iconName)
            }
            .help(model.menuBarAccessibilityLabel)
            // Menu bar item ready: load disk cache; network only if stale/missing.
            .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        switch model.state {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .loaded(let snap):
            let bot = model.botSnapshot?.usedPercent ?? 0
            let peak = max(snap.usedPercent, bot)
            if peak >= 90 { return "flame.fill" }
            if peak >= 70 { return "bolt.fill" }
            return "sparkles"
        default:
            return "sparkles"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, menu-bar only.
        NSApp.setActivationPolicy(.accessory)
        UsageAlerts.requestAuthorizationIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
