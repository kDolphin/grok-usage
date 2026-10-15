import SwiftUI

struct MenuContentView: View {
    static let preferredWidth: CGFloat = 300

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
        .frame(width: Self.preferredWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // Menu bar popovers: no blue keyboard/click focus rings (same as PowerTop).
        .withoutFocusRing()
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
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
            case .signedOut:
                Text(L10n.signedOutBadge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
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

        case .signedOut:
            signedOutContent

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                if case .waiting(let userCode) = model.signInPhase {
                    signInWaitingView(userCode: userCode)
                } else {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    signInActions
                }
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

        // Re-auth progress while still showing live usage (rare).
        if case .waiting(let userCode) = model.signInPhase, case .loaded = model.state {
            Divider().padding(.vertical, 2)
            signInWaitingView(userCode: userCode)
        }

        // Bot meter / Bot browser login — independent of SuperGrok session.
        botSection
    }

    @ViewBuilder
    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .waiting(let userCode) = model.signInPhase {
                signInWaitingView(userCode: userCode)
            } else {
                Text(L10n.signedOutMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.signInHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = model.signInPhase {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = model.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                signInActions
            }
        }
    }

    private var signInActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.startSignIn()
            } label: {
                FooterActionRow(
                    title: L10n.signInSuperGrokWithBrowser,
                    systemImage: "person.crop.circle.badge.arrow.right"
                )
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .disabled(model.isSigningIn)

            Text(L10n.authFileHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func signInWaitingView(userCode: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.signInWaiting)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L10n.signInCode)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(userCode)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            .font(.callout)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.signInBrowserOpened)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.cancelSignIn()
            } label: {
                Text(L10n.cancelSignIn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
        }
    }

    private func loadedContent(_ snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            meterHeader(
                title: L10n.supergrokSection,
                percent: snap.usedPercent,
                subtitle: grokSubtitle(snap),
                remaining: L10n.remaining(Int(snap.remainingPercent.rounded()))
            )

            ProgressView(value: min(max(snap.usedPercent, 0), 100), total: 100)
                .progressViewStyle(UsageProgressStyle(color: thresholdColor(snap.usedPercent)))

            VStack(alignment: .leading, spacing: 4) {
                if let plan = snap.planDisplayName {
                    labeledRow(L10n.plan, plan)
                }
                labeledRow(L10n.nextReset, formatCountdown(snap.resetsIn) ?? L10n.unknown)
                if let end = snap.periodEnd {
                    labeledRow(L10n.resetAt, Formatters.shortDateTime.string(from: end))
                }
                // Prepaid balance is the post-weekly overflow for SuperGrok (not Cursor-style on-demand).
                if let cents = snap.prepaidBalanceCents {
                    labeledRow(L10n.extraCredits, formatUSD(cents))
                }
                // Only show SuperGrok on-demand when a positive spend cap is configured.
                if let onDemand = superGrokOnDemandLabel(used: snap.onDemandUsedCents, cap: snap.onDemandCapCents) {
                    labeledRow(L10n.onDemand, onDemand)
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

            // Last row of the SuperGrok module (after product breakdown).
            Button {
                model.signOut()
            } label: {
                FooterActionRow(
                    title: L10n.signOutSuperGrok,
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .disabled(model.isSigningIn)
        }
    }

    @ViewBuilder
    private var botSection: some View {
        Divider().padding(.vertical, 2)

        if let bot = model.botSnapshot {
            meterHeader(
                title: L10n.botSection,
                percent: bot.usedPercent,
                subtitle: botSubtitle(bot),
                remaining: L10n.remaining(Int(bot.remainingPercent.rounded()))
            )
            ProgressView(value: min(max(bot.usedPercent, 0), 100), total: 100)
                .progressViewStyle(UsageProgressStyle(color: thresholdColor(bot.usedPercent)))
            VStack(alignment: .leading, spacing: 4) {
                if let plan = bot.planLabel, !plan.isEmpty {
                    labeledRow(L10n.plan, plan)
                }
                if let cursorPlan = bot.cursorPlanName, !cursorPlan.isEmpty {
                    labeledRow(L10n.cursorPlan, cursorPlan)
                }
                if let access = bot.accessDisplayName {
                    labeledRow(L10n.botAccess, access)
                }
                labeledRow(L10n.nextReset, formatCountdown(bot.resetsIn) ?? L10n.unknown)
                if let end = bot.periodEnd {
                    labeledRow(L10n.resetAt, Formatters.shortDateTime.string(from: end))
                }
                if let onDemand = botOnDemandLabel(bot) {
                    labeledRow(L10n.onDemand, onDemand)
                }
                if bot.hasAvailableUsage == false {
                    Text(L10n.botQuotaExhausted)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.hasOwnBotCredential {
                    Text(L10n.botUsingLocalLogin)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(L10n.botSection)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if case .waiting = model.botSignInPhase {
                EmptyView()
            } else if let error = model.botError, !model.isRefreshing {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.isRefreshing {
                Text(L10n.botSignInHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // Auth controls always visible so local Grok Bot fallback cannot hide them.
        botAuthActions
    }

    @ViewBuilder
    private var botAuthActions: some View {
        if case .waiting = model.botSignInPhase {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.botSignInWaiting)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.cancelBotSignIn()
            } label: {
                FooterActionRow(title: L10n.cancelSignIn, systemImage: "xmark.circle")
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
        } else if model.hasOwnBotCredential {
            Button {
                model.signOutBot()
            } label: {
                FooterActionRow(
                    title: L10n.signOutBot,
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .disabled(model.isBotSigningIn)
        } else {
            Button {
                model.startBotSignIn()
            } label: {
                FooterActionRow(
                    title: L10n.signInBotWithBrowser,
                    systemImage: "person.crop.circle.badge.arrow.right"
                )
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .disabled(model.isBotSigningIn)
        }
    }

    private func grokSubtitle(_ snap: UsageSnapshot) -> String {
        if let plan = snap.planDisplayName {
            return "\(L10n.usedPrefix) · \(snap.cycleLabel) · \(plan)"
        }
        return "\(L10n.usedPrefix) · \(snap.cycleLabel)"
    }

    private func botSubtitle(_ bot: BotUsageSnapshot) -> String {
        if let label = bot.planLabel, !label.isEmpty {
            return "\(L10n.usedPrefix) · \(bot.cycleLabel) · \(label)"
        }
        return "\(L10n.usedPrefix) · \(bot.cycleLabel)"
    }

    /// SuperGrok `onDemandCap` — hide when 0/off; prepaid "Extra credits" covers weekly overflow.
    private func superGrokOnDemandLabel(used: Int?, cap: Int?) -> String? {
        guard let cap, cap > 0 else { return nil }
        let usedCents = used ?? 0
        return "\(formatUSD(usedCents)) / \(formatUSD(cap))"
    }

    /// Bot on-demand must use the real enabled flag (`usage-summary` / `GetHardLimit`),
    /// not sand `eligible` (that only means the account *can* turn it on).
    private func botOnDemandLabel(_ bot: BotUsageSnapshot) -> String? {
        guard let enabled = bot.onDemandEnabled else { return nil }
        if !enabled {
            return L10n.onDemandOff
        }
        if let limit = bot.onDemandLimitCents, limit > 0 {
            let used = bot.onDemandUsedCents ?? 0
            return "\(formatUSD(used)) / \(formatUSD(limit))"
        }
        if let used = bot.onDemandUsedCents {
            return "\(formatUSD(used)) · \(L10n.onDemandOn)"
        }
        return L10n.onDemandOn
    }

    private func meterHeader(
        title: String,
        percent: Double,
        subtitle: String,
        remaining: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(thresholdColor(percent))
                VStack(alignment: .leading, spacing: 1) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.refresh()
            } label: {
                FooterActionRow(
                    title: model.isRefreshing ? L10n.refreshing : L10n.refreshNow,
                    systemImage: "arrow.clockwise",
                    isBusy: model.isRefreshing
                )
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .keyboardShortcut("r")
            .disabled(model.isRefreshing || !model.canRefresh)

            Divider().padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                FooterActionRow(title: L10n.launchAtLogin, systemImage: "power.circle")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .withoutFocusRing()

            if let msg = model.loginItemMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, FooterActionRow.iconColumnWidth + FooterActionRow.iconTextSpacing)
            }

            Divider().padding(.vertical, 4)

            Button(role: .destructive) {
                model.quit()
            } label: {
                FooterActionRow(title: L10n.quitApp, systemImage: "power")
            }
            .buttonStyle(.plain)
            .withoutFocusRing()
            .keyboardShortcut("q")

            Text(AppInfo.versionLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
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

// MARK: - Footer action row

/// Fixed-width icon column so action titles share one left edge (SF Symbols vary in width).
private struct FooterActionRow: View {
    static let iconColumnWidth: CGFloat = 16
    static let iconTextSpacing: CGFloat = 8

    let title: String
    var systemImage: String? = nil
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: Self.iconTextSpacing) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body)
                }
            }
            .frame(width: Self.iconColumnWidth, height: Self.iconColumnWidth)
            .foregroundStyle(.secondary)

            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
