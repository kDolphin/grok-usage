import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var state: UsageLoadState = .idle
    @Published private(set) var botSnapshot: BotUsageSnapshot?
    @Published private(set) var botError: String?
    @Published private(set) var identity: AuthIdentity?
    @Published private(set) var lastError: String?
    /// True only while a background fetch is actively running.
    @Published private(set) var isRefreshing = false
    /// Launch at login (SMAppService / LaunchAgent).
    @Published var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?

    private var fetchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var didStart = false
    private var lastFetchAttemptAt: Date?

    /// Minimum gap between network fetches for panel-open / opportunistic refresh.
    /// Manual refresh and the 20-minute background tick bypass this.
    private let staleAfter: TimeInterval = 15 * 60

    /// Background poll while the Mac is awake. ~72 requests/day if never sleeps.
    /// Suspended during lid-close sleep — no traffic while the machine is asleep.
    private let backgroundPollInterval: TimeInterval = 20 * 60

    var menuBarTitle: String {
        switch state {
        case .loaded(let snap):
            return formatBar(snap, bot: botSnapshot)
        case .failed:
            return "Grok · !"
        case .idle, .loading:
            return "Grok · …"
        }
    }

    var menuBarAccessibilityLabel: String {
        switch state {
        case .loaded(let snap):
            let reset = formatCountdown(snap.resetsIn) ?? L10n.unknown
            var label = L10n.a11yLoaded(
                used: Int(snap.usedPercent.rounded()),
                cycle: snap.cycleLabel,
                reset: reset
            )
            if let bot = botSnapshot {
                label += " · " + L10n.a11yBot(used: Int(bot.usedPercent.rounded()))
            }
            return label
        case .failed(let message):
            return L10n.a11yFailed(message)
        default:
            return L10n.a11yLoading
        }
    }

    /// Idempotent. Loads disk cache immediately; network only if data is missing or stale.
    func start() {
        guard !didStart else { return }
        didStart = true
        refreshLoginItemState()
        loadCacheIntoState()
        refreshIfStale()
        scheduleBackgroundPoll()
    }

    /// Called when the dropdown panel opens — refresh only if last data is old.
    func panelDidOpen() {
        start()
        refreshLoginItemState()
        refreshIfStale()
    }

    func refreshLoginItemState() {
        launchAtLogin = LoginItemService.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            launchAtLogin = LoginItemService.isEnabled
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                loginItemMessage = L10n.loginItemNeedsApproval
            } else if enabled, !launchAtLogin {
                loginItemMessage = L10n.loginItemEnableFailed
            } else {
                loginItemMessage = nil
            }
        } catch {
            launchAtLogin = LoginItemService.isEnabled
            loginItemMessage = L10n.loginItemError(error.localizedDescription)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        isRefreshing = false
    }

    /// Manual refresh from the UI — always hits the network (user intent).
    func refresh() {
        refresh(force: true)
    }

    /// Auto path: skip network when we already fetched recently.
    func refreshIfStale() {
        if !isStale {
            return
        }
        refresh(force: false)
    }

    private var isStale: Bool {
        // Prefer snapshot age when we have live data.
        if case .loaded(let snap) = state {
            if Date().timeIntervalSince(snap.fetchedAt) < staleAfter {
                // Also refresh if bot is missing and might become available.
                if botSnapshot == nil, botError == nil {
                    return true
                }
                if let bot = botSnapshot, Date().timeIntervalSince(bot.fetchedAt) >= staleAfter {
                    return true
                }
                return false
            }
        }
        if let last = lastFetchAttemptAt, Date().timeIntervalSince(last) < staleAfter {
            return false
        }
        // No successful/recent data → consider stale.
        if case .loaded = state { return true }
        return true
    }

    /// Fire-and-forget. Never blanks existing content; always clears `isRefreshing` when done.
    private func refresh(force: Bool) {
        if isRefreshing { return }
        if !force, !isStale { return }

        let hadLoadedData: Bool = {
            if case .loaded = state { return true }
            return false
        }()

        if !hadLoadedData {
            state = .loading
        }

        isRefreshing = true
        lastFetchAttemptAt = Date()

        fetchTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRefreshing = false
                    self.fetchTask = nil
                }
            }

            let result = await Task.detached(priority: .utility) {
                await Self.fetchInBackground()
            }.value

            guard let self, !Task.isCancelled else { return }
            await self.apply(result: result, hadLoadedData: hadLoadedData)
        }
    }

    private func loadCacheIntoState() {
        guard let cached = UsageCache.load() else { return }
        if identity == nil, let email = cached.email {
            identity = AuthIdentity(
                email: email,
                teamID: nil,
                principalType: nil,
                authMode: nil,
                accessToken: "",
                expiresAt: nil
            )
        }
        // Only adopt cache when we have nothing better on screen.
        if case .loaded = state { return }
        state = .loaded(cached.snapshot)
        if let bot = cached.bot {
            botSnapshot = bot
            botError = nil
        }
    }

    private struct FetchBundle {
        var identity: AuthIdentity
        var snapshot: UsageSnapshot
        var bot: Result<BotUsageSnapshot, Error>
    }

    private func apply(
        result: Result<FetchBundle, Error>,
        hadLoadedData: Bool
    ) async {
        switch result {
        case .success(let bundle):
            self.identity = bundle.identity
            self.state = .loaded(bundle.snapshot)
            self.lastError = nil
            UsageAlerts.evaluate(snapshot: bundle.snapshot)

            switch bundle.bot {
            case .success(let bot):
                self.botSnapshot = bot
                self.botError = nil
                UsageAlerts.evaluateBot(snapshot: bot)
            case .failure(let error):
                // Fail-open: keep previous bot snapshot if any; surface soft error.
                self.botError = friendlyBotMessage(for: error)
            }

            UsageCache.save(bundle.snapshot, bot: botSnapshot, email: bundle.identity.email)

        case .failure(let error):
            let message = friendlyMessage(for: error)
            self.lastError = message
            if !hadLoadedData {
                if case .loaded = state {
                    // keep cache
                } else {
                    state = .failed(message)
                }
            }
        }
    }

    private nonisolated static func fetchInBackground() async -> Result<FetchBundle, Error> {
        do {
            // Silently renew OIDC access token via refresh_token when near/past expiry
            // (same mechanism as running `grok` — no interactive `grok login` needed).
            var identity = try await AuthStore.loadValidIdentity()

            var snapshot: UsageSnapshot
            do {
                let token = identity.accessToken
                async let billing = UsageFetcher.fetch(token: token)
                async let plan = UsageFetcher.fetchPlanTier(token: token)
                snapshot = try await billing
                if let planTier = await plan {
                    snapshot.planTier = planTier
                }
            } catch let fetch as UsageFetcherError {
                // One retry after forced refresh on auth failures.
                if case .unauthorized = fetch {
                    let cred = try AuthStore.loadCredential()
                    let refreshed = try await AuthStore.refreshCredential(cred)
                    identity = refreshed.identity
                    let token = identity.accessToken
                    async let billing = UsageFetcher.fetch(token: token)
                    async let plan = UsageFetcher.fetchPlanTier(token: token)
                    snapshot = try await billing
                    if let planTier = await plan {
                        snapshot.planTier = planTier
                    }
                } else {
                    throw fetch
                }
            }

            let bot = await fetchBotInBackground()
            return .success(FetchBundle(identity: identity, snapshot: snapshot, bot: bot))
        } catch {
            return .failure(error)
        }
    }

    /// Independent of SuperGrok — errors become soft UI state, not a hard failure.
    private nonisolated static func fetchBotInBackground() async -> Result<BotUsageSnapshot, Error> {
        do {
            let token = try BotAuthStore.loadAccessToken()
            let snapshot = try await BotUsageFetcher.fetch(accessToken: token)
            return .success(snapshot)
        } catch {
            return .failure(error)
        }
    }

    func openUsagePage() {
        if let url = URL(string: "https://grok.com/?_s=usage") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBillingPage() {
        if let url = URL(string: "https://grok.com/?_s=billing") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBotUsagePage() {
        if let url = URL(string: "https://cursor.com/dashboard/spending") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        stop()
        NSApp.terminate(nil)
    }

    /// Fires every `backgroundPollInterval` while the process is running and the Mac is awake.
    /// During sleep the task is frozen; after wake it continues (at most one catch-up fetch).
    private func scheduleBackgroundPoll() {
        pollTask?.cancel()
        let interval = backgroundPollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // Scheduled tick always pulls fresh billing metadata (still not a model call).
                self.refresh(force: true)
            }
        }
    }

    private func formatBar(_ snap: UsageSnapshot, bot: BotUsageSnapshot?) -> String {
        let pct = Int(snap.usedPercent.rounded())
        var parts = ["Grok \(pct)%"]
        if let bot {
            parts.append("Bot \(Int(bot.usedPercent.rounded()))%")
        }
        if let countdown = formatCountdown(snap.resetsIn, compact: true) {
            parts.append(countdown)
        }
        return parts.joined(separator: " · ")
    }

    private func friendlyMessage(for error: Error) -> String {
        if let auth = error as? AuthStoreError {
            return auth.localizedDescription
        }
        if let fetch = error as? UsageFetcherError {
            return fetch.localizedDescription
        }
        return error.localizedDescription
    }

    private func friendlyBotMessage(for error: Error) -> String {
        if let auth = error as? BotAuthStoreError {
            return auth.localizedDescription
        }
        if let fetch = error as? BotUsageFetcherError {
            return fetch.localizedDescription
        }
        return error.localizedDescription
    }
}

enum Formatters {
    /// Medium date + short time using the system locale (follows macOS language/region).
    static var shortDateTime: DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    static var currency: NumberFormatter {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }
}

func formatCountdown(_ interval: TimeInterval?, compact: Bool = false) -> String? {
    guard let interval else { return nil }
    if interval <= 0 {
        return compact ? "soon" : L10n.resetsSoon
    }

    let total = Int(interval.rounded())
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    return L10n.countdown(days: days, hours: hours, minutes: minutes, compact: compact)
}
