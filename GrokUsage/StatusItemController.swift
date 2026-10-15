import AppKit
import Combine
import SwiftUI

/// Menu bar extra as `NSStatusItem` + `NSPopover` (same approach as PowerTop).
/// System popover chrome sizes to measured SwiftUI content — avoids MenuBarExtra
/// `.window` frame/content misalignment.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: UsageViewModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var renderedSignature: String = ""
    /// Accessory apps often don't resign key, so `.transient` misses outside clicks.
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(model: UsageViewModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        startObservingModel()
        updateStatusItem()
    }

    func invalidate() {
        stopDismissMonitors()
        popover.performClose(nil)
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        // Mouse-down + deferred show: a mouse-up on a transient popover is otherwise
        // treated as an outside click and the panel flashes closed immediately.
        button.sendAction(on: [.leftMouseDown])
        button.target = self
        button.action = #selector(statusItemClicked)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = StatusPopoverContent(
            model: model,
            onMeasuredSize: { [weak self] size in
                self?.applyPopoverSize(size)
            }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: MenuContentView.preferredWidth, height: 360)
    }

    private func startObservingModel() {
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before properties update — read on next turn.
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                    if self?.popover.isShown == true {
                        self?.remeasurePopoverIfNeeded()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func statusSignature() -> String {
        "\(model.menuBarSymbolName)|\(model.menuBarAccessibilityLabel)"
    }

    private func updateStatusItem() {
        let signature = statusSignature()
        guard signature != renderedSignature else { return }
        renderedSignature = signature

        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = model.menuBarAccessibilityLabel

        let image = NSImage(systemSymbolName: model.menuBarSymbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    @objc private func statusItemClicked() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showPopover()
            }
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.panelDidOpen()
        remeasurePopoverIfNeeded()
        // Do not make the popover key: keeps status-item text from sticking highlighted.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startDismissMonitors()
    }

    private func remeasurePopoverIfNeeded() {
        guard let hosting = popover.contentViewController else { return }
        let fitted = hosting.view.fittingSize
        if fitted.width > 1, fitted.height > 1 {
            applyPopoverSize(fitted)
        }
    }

    private func startDismissMonitors() {
        stopDismissMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.dismissPopoverIfClickIsOutside()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPopoverIfClickIsOutside()
            }
        }
    }

    private func stopDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func dismissPopoverIfClickIsOutside() {
        guard popover.isShown else { return }
        let point = NSEvent.mouseLocation
        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(point)
        {
            return
        }
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonRect.contains(point) {
                return
            }
        }
        popover.performClose(nil)
    }

    private func applyPopoverSize(_ size: CGSize) {
        let width = max(size.width, MenuContentView.preferredWidth)
        let height = max(size.height, 80)
        let next = NSSize(width: width.rounded(), height: height.rounded())
        guard abs(popover.contentSize.width - next.width) > 0.5
            || abs(popover.contentSize.height - next.height) > 0.5
        else { return }
        popover.contentSize = next
    }

    func popoverDidClose(_ notification: Notification) {
        stopDismissMonitors()
        statusItem.button?.highlight(false)
    }
}

// MARK: - Measured SwiftUI root

private struct PopoverMeasuredSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct StatusPopoverContent: View {
    @ObservedObject var model: UsageViewModel
    let onMeasuredSize: (CGSize) -> Void

    var body: some View {
        MenuContentView(model: model)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PopoverMeasuredSizeKey.self, value: proxy.size)
                }
            }
            .onPreferenceChange(PopoverMeasuredSizeKey.self) { size in
                guard size.width > 1, size.height > 1 else { return }
                onMeasuredSize(size)
            }
    }
}
