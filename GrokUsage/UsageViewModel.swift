import AppKit
import Foundation
import ServiceManagement
import SwiftUI

enum SignInPhase: Equatable {
    case idle
    case waiting(userCode: String)
    case failed(String)
}

enum BotSignInPhase: Equatable {
    case idle
    case waiting
    case failed(String)
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var state: UsageLoadState = .idle
    @Published private(set) var botSnapshot: BotUsageSnapshot?
    @Published private(set) var botError: String?
    @Published private(set) var identity: AuthIdentity?
    @Published private(set) var lastError: String?
    /// True only while a background fetch is actively running.
    @Published private(set) var isRefreshing = false
    /// Browser / device-code sign-in progress for SuperGrok.
    @Published private(set) var signInPhase: SignInPhase = .idle
    /// Cursor PKCE browser sign-in for Grok Bot (independent of SuperGrok).
    @Published private(set) var botSignInPhase: BotSignInPhase = .idle
    /// Launch at login (SMAppService / LaunchAgent).
    @Published var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?

    private var fetchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var botSignInTask: Task<Void, Never>?
    private var didStart = false
    private var lastFetchAttemptAt: Date?

    var isSignedIn: Bool {
        AuthStore.hasStoredCredential
    }

    /// Manual refresh is useful whenever SuperGrok or Bot can be fetched.
    var canRefresh: Bool {
        AuthStore.hasStoredCredential || BotAuthStore.hasAnyCredential
    }

    var isSigningIn: Bool {
        if case .waiting = signInPhase { return true }
        return false
    }

    var isBotSigningIn: Bool {
        if case .waiting = botSignInPhase { return true }
        return false
    }

    /// This app holds its own Bot tokens (browser login), vs local Grok Bot only.
    var hasOwnBotCredential: Bool {
        BotAuthStore.hasOwnCredential
    }

    /// Minimum gap between network fetches for panel-open / opportunistic refresh.
    /// Manual refresh and the 20-minute background tick bypass this.
    private let staleAfter: TimeInterval = 15 * 60

    /// Background poll while the Mac is awake. ~72 requests/day if never sleeps.
    /// Suspended during lid-close sleep — no traffic while the machine is asleep.
    private let backgroundPollInterval: TimeInterval = 20 * 60

    /// SF Symbol for the status item (template image only — no title text).
    var menuBarSymbolName: String {
        switch state {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .signedOut:
            return "person.crop.circle.badge.questionmark"
        case .loaded(let snap):
            let bot = botSnapshot?.usedPercent ?? 0
            let peak = max(snap.usedPercent, bot)
            if peak >= 90 { return "flame.fill" }
            if peak >= 70 { return "bolt.fill" }
            return "sparkles"
        default:
            return "sparkles"
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
        case .signedOut:
            return L10n.a11ySignedOut
        case .failed(let message):
            return L10n.a11yFailed(message)
        default:
            return L10n.a11yLoading
        }
    }

    /// Idempotent. Auth gate first — never show cached usage while signed out.
    func start() {
        guard !didStart else { return }
        didStart = true
        refreshLoginItemState()
        bootstrapSession()
        scheduleBackgroundPoll()
    }

    /// Called when the dropdown panel opens — refresh only if last data is old.
    func panelDidOpen() {
        start()
        refreshLoginItemState()
        if AuthStore.hasStoredCredential {
            refreshIfStale()
        } else {
            refreshBotIfNeeded()
        }
    }

    /// Decide signed-out vs cached+network based on whether a SuperGrok session exists.
    /// Bot login is independent — still hydrate Bot when SuperGrok is signed out.
    private func bootstrapSession() {
        guard AuthStore.hasStoredCredential else {
            // Drop SuperGrok cache residue; keep Bot session if any.
            enterSignedOut(clearDisk: true)
            refreshBotIfNeeded()
            return
        }
        loadCacheIntoState()
        refreshIfStale()
    }

    /// Wipe SuperGrok UI. Bot snapshot stays unless the caller clears Bot separately.
    private func enterSignedOut(clearDisk: Bool) {
        fetchTask?.cancel()
        fetchTask = nil
        isRefreshing = false
        identity = nil
        lastError = nil
        lastFetchAttemptAt = nil
        state = .signedOut
        if clearDisk {
            UsageCache.clear()
            UsageAlerts.clear()
        }
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
        signInTask?.cancel()
        signInTask = nil
        botSignInTask?.cancel()
        botSignInTask = nil
        isRefreshing = false
        if case .waiting = signInPhase {
            signInPhase = .idle
        }
        if case .waiting = botSignInPhase {
            botSignInPhase = .idle
        }
    }

    /// Open browser device-code login; no Grok Build CLI required.
    func startSignIn() {
        guard !isSigningIn else { return }
        signInTask?.cancel()
        lastError = nil

        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pending = try await AuthStore.beginDeviceLogin()
                guard !Task.isCancelled else { return }
                self.signInPhase = .waiting(userCode: pending.userCode)
                NSWorkspace.shared.open(pending.verificationURL)

                let identity = try await AuthStore.completeDeviceLogin(pending)
                guard !Task.isCancelled else {
                    self.signInPhase = .idle
                    return
                }
                self.identity = identity
                self.signInPhase = .idle
                self.refresh(force: true)
            } catch is CancellationError {
                self.signInPhase = .idle
            } catch let auth as AuthStoreError {
                if case .deviceAuthCancelled = auth {
                    self.signInPhase = .idle
                } else {
                    self.signInPhase = .failed(auth.localizedDescription)
                    self.applySignInFailure(auth.localizedDescription)
                }
            } catch {
                let message = error.localizedDescription
                self.signInPhase = .failed(message)
                self.applySignInFailure(message)
            }
            self.signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInPhase = .idle
    }

    /// Cursor browser login for Bot meter — does not require Grok Bot.app.
    func startBotSignIn() {
        guard !isBotSigningIn else { return }
        botSignInTask?.cancel()
        botError = nil

        botSignInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pending = try BotAuthStore.beginBrowserLogin()
                guard !Task.isCancelled else { return }
                self.botSignInPhase = .waiting
                NSWorkspace.shared.open(pending.loginURL)

                try await BotAuthStore.completeBrowserLogin(pending)
                guard !Task.isCancelled else {
                    self.botSignInPhase = .idle
                    return
                }
                self.botSignInPhase = .idle
                self.botError = nil
                // Re-fetch so Bot meter fills without waiting for the next poll.
                if AuthStore.hasStoredCredential {
                    self.refresh(force: true)
                } else {
                    await self.refreshBotOnly()
                }
            } catch is CancellationError {
                self.botSignInPhase = .idle
            } catch let auth as BotAuthStoreError {
                if case .loginCancelled = auth {
                    self.botSignInPhase = .idle
                } else {
                    let message = auth.localizedDescription
                    self.botSignInPhase = .failed(message)
                    self.botError = message
                }
            } catch {
                let message = error.localizedDescription
                self.botSignInPhase = .failed(message)
                self.botError = message
            }
            self.botSignInTask = nil
        }
    }

    func cancelBotSignIn() {
        botSignInTask?.cancel()
        botSignInTask = nil
        botSignInPhase = .idle
    }

    /// Clears only this app's Bot Keychain tokens (leaves Grok Bot.app secrets alone).
    func signOutBot() {
        cancelBotSignIn()
        do {
            try BotAuthStore.clearOwnCredential()
        } catch {
            botError = error.localizedDescription
            return
        }
        botSnapshot = nil
        botError = L10n.botSignedOutHint
        // Drop bot from disk cache so it does not resurrect on next launch.
        if case .loaded(let snap) = state {
            UsageCache.save(snap, bot: nil, email: identity?.email)
        }
    }

    private func applySignInFailure(_ message: String) {
        switch state {
        case .loaded:
            lastError = message
        case .signedOut:
            // Stay on the signed-out screen; show the error via signInPhase / message text.
            lastError = message
        default:
            state = .failed(message)
        }
    }

    /// Clears shared `~/.grok/auth.json` xAI session (also used by Grok Build CLI)
    /// and drops SuperGrok cache. Bot Keychain / Bot meter stay (independent login).
    func signOut() {
        cancelSignIn()
        do {
            try AuthStore.clearStoredCredential()
        } catch {
            lastError = error.localizedDescription
            return
        }
        enterSignedOut(clearDisk: true)
        refreshBotIfNeeded()
    }

    /// Manual refresh from the UI — always hits the network (user intent).
    /// SuperGrok signed out: still refreshes Bot when Bot credentials exist.
    func refresh() {
        if AuthStore.hasStoredCredential {
            refresh(force: true)
            return
        }
        state = .signedOut
        guard BotAuthStore.hasAnyCredential else { return }
        Task { [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            await self.refreshBotOnly()
        }
    }

    /// Auto path: skip network when we already fetched recently.
    func refreshIfStale() {
        guard AuthStore.hasStoredCredential else {
            enterSignedOut(clearDisk: false)
            return
        }
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
        guard AuthStore.hasStoredCredential else {
            enterSignedOut(clearDisk: false)
            return
        }
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
        guard AuthStore.hasStoredCredential else { return }
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
            if isAuthMissingError(error) {
                // Credential vanished or never existed — do not keep showing stale cache.
                enterSignedOut(clearDisk: true)
                return
            }
            let message = friendlyMessage(for: error)
            self.lastError = message
            if !hadLoadedData {
                if case .loaded = state {
                    // keep in-memory cache for transient errors
                } else {
                    state = .failed(message)
                }
            }
        }
    }

    private func isAuthMissingError(_ error: Error) -> Bool {
        guard let auth = error as? AuthStoreError else { return false }
        switch auth {
        case .missingAuthFile, .noAccessToken, .noRefreshToken, .invalidAuthJSON:
            return true
        default:
            return false
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
            let token = try await BotAuthStore.loadValidAccessToken()
            let snapshot = try await BotUsageFetcher.fetch(accessToken: token)
            return .success(snapshot)
        } catch {
            return .failure(error)
        }
    }

    /// Kick a Bot-only fetch when credentials exist (does not require SuperGrok).
    private func refreshBotIfNeeded() {
        guard BotAuthStore.hasAnyCredential else {
            // No Bot auth — keep any soft hint, but do not invent an error if none.
            return
        }
        Task { [weak self] in
            await self?.refreshBotOnly()
        }
    }

    /// Bot-only refresh when SuperGrok is signed out (after Bot browser login).
    private func refreshBotOnly() async {
        let result = await Task.detached(priority: .utility) {
            await Self.fetchBotInBackground()
        }.value
        switch result {
        case .success(let bot):
            botSnapshot = bot
            botError = nil
            UsageAlerts.evaluateBot(snapshot: bot)
        case .failure(let error):
            botError = friendlyBotMessage(for: error)
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
