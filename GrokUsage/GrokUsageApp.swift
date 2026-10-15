import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageViewModel()
    private var statusItemController: StatusItemController?
    private var didStart = false

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        NSApp.setActivationPolicy(.accessory)
        UsageAlerts.requestAuthorizationIfNeeded()
        statusItemController = StatusItemController(model: model)
        model.start()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            startIfNeeded()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            statusItemController?.invalidate()
            statusItemController = nil
            model.stop()
        }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct GrokUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires a Scene. A real MenuBarExtra `.window` caused content/frame
        // misalignment; the live status item is AppKit (see StatusItemController).
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            EmptyView()
        }
    }
}
