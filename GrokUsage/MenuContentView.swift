import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 280)
        // Match system menu continuous corners (Dropbox / input-source style).
        .menuBarPanelChrome()
        // Menu bar panels: no blue keyboard/click focus rings (same as PowerTop).
        .withoutFocusRing()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.appTitle)
                    .font(.headline)
                Text(AppInfo.versionLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let email = model.identity?.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 6) {
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            switch model.state {
            case .loading, .idle:
                if !model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            case .loaded(let snap):
                Text(L10n.thresholdLabel(snap.usedPercent))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(thresholdColor(snap.usedPercent).opacity(0.18), in: Capsule())
                    .foregroundStyle(thresholdColor(snap.usedPercent))
            case .failed:
                Text(L10n.errorBadge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loaded(let snap):
            loadedContent(snap)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.authFileHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.loadingUsage)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }

        // Soft warning when data is shown but the last refresh failed (e.g. timeout).
        if let error = model.lastError, case .loaded = model.state, !model.isRefreshing {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadedContent(_ snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int(snap.usedPercent.rounded()))%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(thresholdColor(snap.usedPercent))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(L10n.usedPrefix) · \(snap.cycleLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.remaining(Int(snap.remainingPercent.rounded())))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ProgressView(value: min(max(snap.usedPercent, 0), 100), total: 100)
                .progressViewStyle(UsageProgressStyle(color: thresholdColor(snap.usedPercent)))

            VStack(alignment: .leading, spacing: 4) {
                labeledRow(L10n.nextReset, formatCountdown(snap.resetsIn) ?? L10n.unknown)
                if let end = snap.periodEnd {
                    labeledRow(L10n.resetAt, Formatters.shortDateTime.string(from: end))
                }
                if let cents = snap.prepaidBalanceCents {
                    labeledRow(L10n.extraCredits, formatUSD(cents))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.refreshedAt)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isRefreshing {
                        Text(L10n.updating)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Formatters.shortDateTime.string(from: snap.fetchedAt))
                    }
                }
                .font(.callout)

                if snap.source.contains("cache"), !model.isRefreshing {
                    Text(L10n.offlineCache)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !snap.productUsage.isEmpty {
                Divider().padding(.vertical, 2)
                Text(L10n.productBreakdown)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(snap.productUsage) { item in
                    HStack {
                        Text(item.displayName)
                        Spacer()
                        Text("\(Int(item.usagePercent.rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Button {
                model.refresh()
            } label: {
                HStack {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(model.isRefreshing ? L10n.refreshing : L10n.refreshNow)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .keyboardShortcut("r")
            .disabled(model.isRefreshing)

            Button {
                model.openUsagePage()
            } label: {
                Label(L10n.openGrokUsage, systemImage: "safari")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .withoutFocusRing()

            Button {
                model.openBillingPage()
            } label: {
                Label(L10n.openBilling, systemImage: "creditcard")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .withoutFocusRing()

            Divider().padding(.vertical, 2)

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                Label(L10n.launchAtLogin, systemImage: "power.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .withoutFocusRing()

            if let msg = model.loginItemMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            Button(role: .destructive) {
                model.quit()
            } label: {
                Label(L10n.quitApp, systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .keyboardShortcut("q")

            Text(AppInfo.versionLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 4)
        }
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func thresholdColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }

    private func formatUSD(_ cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        return Formatters.currency.string(from: NSNumber(value: dollars)) ?? String(format: "$%.2f", dollars)
    }
}

// MARK: - Progress bar

/// Linear bar that always uses the same color as the large percentage label.
/// System `ProgressView` + `.tint` often stays accent-blue on macOS.
private struct UsageProgressStyle: ProgressViewStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        let fraction = min(max(configuration.fractionCompleted ?? 0, 0), 1)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * CGFloat(fraction), fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 6)
        .accessibilityValue(Text("\(Int((fraction * 100).rounded()))%"))
    }
}

// MARK: - Focus ring

private extension View {
    /// Hides the system blue focus ring in menu-bar panels (macOS 14+).
    @ViewBuilder
    func withoutFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
