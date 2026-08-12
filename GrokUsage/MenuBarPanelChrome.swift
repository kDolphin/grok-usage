import AppKit
import SwiftUI

/// Light touch on MenuBarExtra `.window` panels.
///
/// Keep the panel **opaque** with the system window fill. Transparent windows +
/// visual-effect backdrops previously wiped content to blank white.
enum MenuBarPanelChrome {
    /// Slightly rounder than the stock panel; not as aggressive as custom materials.
    static let cornerRadius: CGFloat = 10

    static func applyIfNeeded() {
        DispatchQueue.main.async {
            applyToVisiblePanels()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            applyToVisiblePanels()
        }
    }

    private static func applyToVisiblePanels() {
        for window in NSApp.windows where isLikelyMenuBarPanel(window) {
            style(window)
        }
    }

    private static func isLikelyMenuBarPanel(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let frame = window.frame
        guard frame.width > 200, frame.width < 420 else { return false }
        guard frame.height > 80, frame.height < 900 else { return false }
        if !window.title.isEmpty, window.styleMask.contains(.titled) {
            return false
        }
        return true
    }

    private static func style(_ window: NSWindow) {
        // Restore a normal solid panel — do not clear the background.
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.hasShadow = true

        // Remove any previously injected effect views that blanked the UI.
        if let content = window.contentView {
            for sub in content.subviews {
                if let effect = sub as? NSVisualEffectView,
                   effect.identifier?.rawValue == "GrokUsage.MenuBarPanelChrome.effect"
                {
                    effect.removeFromSuperview()
                }
            }
            content.wantsLayer = true
            content.layer?.backgroundColor = nil
            applyCorners(to: content.layer)
        }

        if let container = window.contentView?.superview {
            container.wantsLayer = true
            container.layer?.backgroundColor = nil
            applyCorners(to: container.layer)
        }

        window.invalidateShadow()
    }

    private static func applyCorners(to layer: CALayer?) {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        if #available(macOS 11.0, *) {
            layer.cornerCurve = .continuous
        }
        layer.masksToBounds = true
    }
}

extension View {
    /// Safe panel chrome: system window background, optional continuous corners.
    func menuBarPanelChrome() -> some View {
        self
            // Ensure SwiftUI content has a solid backdrop if the host is odd.
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                MenuBarPanelChrome.applyIfNeeded()
            }
    }
}
