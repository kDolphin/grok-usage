import Foundation

/// Localized strings via `String(localized:)` and `GrokUsage/*/lproj/Localizable.strings`.
/// Language follows macOS system / per-app language settings (same pattern as PowerTop).
enum L10n {
    // MARK: - App chrome

    static var appTitle: String { String(localized: "Grok Usage") }
    static var errorBadge: String { String(localized: "Error") }
    static var authFileHint: String { String(localized: "Auth file: ~/.grok/auth.json") }
    static var loadingUsage: String { String(localized: "Loading usage…") }
    static var usedPrefix: String { String(localized: "Used") }

    static func remaining(_ pct: Int) -> String {
        String(format: String(localized: "Remaining %d%%"), pct)
    }

    static var nextReset: String { String(localized: "Next reset") }
    static var resetAt: String { String(localized: "Resets at") }
    static var extraCredits: String { String(localized: "Extra credits") }
    static var refreshedAt: String { String(localized: "Refreshed") }
    static var updating: String { String(localized: "Updating…") }
    static var offlineCache: String { String(localized: "Offline cache · updates when online") }
    static var productBreakdown: String { String(localized: "By product") }
    static var refreshNow: String { String(localized: "Refresh now") }
    static var refreshing: String { String(localized: "Refreshing…") }
    static var openGrokUsage: String { String(localized: "Open Grok Usage") }
    static var openBilling: String { String(localized: "Open Billing") }
    static var launchAtLogin: String { String(localized: "Launch at Login") }
    static var quitApp: String { String(localized: "Quit Grok Usage") }
    static var unknown: String { String(localized: "Unknown") }

    static var statusOK: String { String(localized: "OK") }
    static var statusElevated: String { String(localized: "High") }
    static var statusCritical: String { String(localized: "Tight") }

    static var weeklyQuota: String { String(localized: "Weekly") }
    static var monthlyQuota: String { String(localized: "Monthly") }
    static var quota: String { String(localized: "Quota") }

    static var supergrokSection: String { String(localized: "SuperGrok") }
    static var botSection: String { String(localized: "Grok Bot") }
    static var openBotUsage: String { String(localized: "Open Grok Bot Usage") }

    static var plan: String { String(localized: "Plan") }
    static var cursorPlan: String { String(localized: "Cursor plan") }
    static var onDemand: String { String(localized: "On-demand") }
    static var onDemandOff: String { String(localized: "Off") }
    static var onDemandOn: String { String(localized: "On") }
    static var botAccess: String { String(localized: "Access") }
    static var botAccessGranted: String { String(localized: "Granted") }
    static var botAccessDenied: String { String(localized: "Denied") }
    static var botAccessPending: String { String(localized: "Pending") }
    static var botQuotaExhausted: String {
        String(localized: "Weekly Bot allowance is exhausted.")
    }

    static func thresholdLabel(_ percent: Double) -> String {
        if percent >= 90 { return statusCritical }
        if percent >= 70 { return statusElevated }
        return statusOK
    }

    // MARK: - Countdown

    static var resetsSoon: String { String(localized: "soon") }

    static func countdown(days: Int, hours: Int, minutes: Int, compact: Bool) -> String {
        if compact {
            if days > 0 {
                return String(format: String(localized: "%1$dd%2$dh"), days, hours)
            }
            if hours > 0 {
                return String(format: String(localized: "%1$dh%2$dm"), hours, minutes)
            }
            return String(format: String(localized: "%dm"), max(minutes, 1))
        }
        if days > 0 {
            return String(format: String(localized: "%1$d d %2$d h"), days, hours)
        }
        if hours > 0 {
            return String(format: String(localized: "%1$d h %2$d m"), hours, minutes)
        }
        return String(format: String(localized: "%d min"), max(minutes, 1))
    }

    // MARK: - Accessibility

    static func a11yLoaded(used: Int, cycle: String, reset: String) -> String {
        String(
            format: String(localized: "Grok usage %1$d%%, %2$@ resets in %3$@"),
            used,
            cycle,
            reset
        )
    }

    static func a11yBot(used: Int) -> String {
        String(format: String(localized: "Grok Bot %d%%"), used)
    }

    static func a11yFailed(_ message: String) -> String {
        String(format: String(localized: "Grok usage failed: %@"), message)
    }

    static var a11yLoading: String { String(localized: "Grok usage loading") }

    // MARK: - Login item

    static var loginItemNeedsApproval: String {
        String(localized: "Launch at login requested. Allow Grok Usage in System Settings → General → Login Items.")
    }

    static var loginItemEnableFailed: String {
        String(localized: "Could not enable launch at login. Keep the app in the Applications folder.")
    }

    static func loginItemError(_ detail: String) -> String {
        String(format: String(localized: "Launch at login failed: %@"), detail)
    }

    static var loginItemEnabled: String { String(localized: "Login item: enabled") }
    static var loginItemNotRegistered: String { String(localized: "Login item: not registered") }
    static var loginItemNotFound: String {
        String(localized: "Login item: app not found (install to Applications)")
    }
    static var loginItemRequiresApproval: String {
        String(localized: "Login item: pending approval in System Settings → General → Login Items")
    }
    static var loginItemUnknown: String { String(localized: "Login item: unknown status") }

    // MARK: - Auth

    static func authMissingFile(_ path: String) -> String {
        String(format: String(localized: "Missing %@. Run `grok` once to sign in."), path)
    }

    static var authInvalidJSON: String { String(localized: "Invalid auth.json format.") }
    static var authNoToken: String {
        String(localized: "No token in auth.json. Run `grok` once to sign in.")
    }
    static var authNoRefreshToken: String {
        String(localized: "No refresh_token; cannot renew silently. Run `grok` to sign in.")
    }

    static func authRefreshFailed(_ detail: String) -> String {
        String(
            format: String(localized: "Token refresh failed: %@. Try running `grok` once (usually no full `grok login`)."),
            detail
        )
    }

    static var authInvalidResponse: String { String(localized: "Invalid response") }
    static var authMissingAccessToken: String { String(localized: "Response missing access_token") }

    // MARK: - Fetch

    static var fetchUnauthorized: String {
        String(localized: "Unauthorized. Auto-refresh will be tried; if it still fails, run `grok` once (usually no `grok login`).")
    }
    static var fetchBadPayload: String { String(localized: "Could not parse usage response.") }
    static var fetchTimedOut: String {
        String(localized: "Request timed out. Check the network and try again.")
    }

    // MARK: - Grok Bot auth / fetch

    static var botAuthMissing: String {
        String(localized: "Grok Bot not signed in. Open Grok Bot once, then refresh.")
    }
    static var botAuthInvalid: String {
        String(localized: "Could not read Grok Bot login data.")
    }
    static var botAuthNoAccount: String {
        String(localized: "No Grok Bot account found. Sign in inside Grok Bot, then refresh.")
    }
    static var botAuthKeychain: String {
        String(localized: "Could not unlock Grok Bot credentials from Keychain. Allow access when prompted, or open Grok Bot once.")
    }
    static var botAuthDecryptFailed: String {
        String(localized: "Could not decrypt Grok Bot credentials. Open Grok Bot once, then refresh.")
    }
    static var botAuthNoToken: String {
        String(localized: "Grok Bot session token missing. Open Grok Bot once, then refresh.")
    }
    static var botFetchUnauthorized: String {
        String(localized: "Grok Bot session expired. Open Grok Bot once, then refresh.")
    }

    // MARK: - Notifications

    static func alertTitle(_ threshold: Int) -> String {
        String(format: String(localized: "Grok usage %d%%"), threshold)
    }

    static func alertBody(used: Int, cycle: String, countdown: String?) -> String {
        var body = String(format: String(localized: "About %1$d%% used (%2$@)"), used, cycle)
        if let countdown {
            body += String(format: String(localized: "; resets in %@"), countdown)
        }
        body += "."
        return body
    }

    static func botAlertTitle(_ threshold: Int) -> String {
        String(format: String(localized: "Grok Bot usage %d%%"), threshold)
    }

    static func botAlertBody(used: Int, countdown: String?) -> String {
        var body = String(format: String(localized: "Grok Bot about %d%% used"), used)
        if let countdown {
            body += String(format: String(localized: "; resets in %@"), countdown)
        }
        body += "."
        return body
    }

    static var alertTightSuffix: String {
        String(localized: " Quota is tight — pace your usage.")
    }
}
