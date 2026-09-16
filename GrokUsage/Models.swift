import Foundation

struct AuthIdentity: Equatable {
    var email: String?
    var teamID: String?
    var principalType: String?
    var authMode: String?
    var accessToken: String
    var expiresAt: Date?
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

struct ProductUsage: Identifiable, Equatable {
    var id: String { product }
    var product: String
    var usagePercent: Double

    var displayName: String {
        switch product {
        case "GrokBuild": return "Build"
        case "GrokChat": return "Chat"
        case "GrokImagine": return "Imagine"
        case "GrokVoice": return "Voice"
        case "GrokAPI", "API", "Api": return "API"
        default: return product.replacingOccurrences(of: "Grok", with: "")
        }
    }
}

struct UsageSnapshot: Equatable {
    var usedPercent: Double
    var periodType: String?
    var periodStart: Date?
    var periodEnd: Date?
    var productUsage: [ProductUsage]
    var prepaidBalanceCents: Int?
    var isUnifiedBilling: Bool
    /// e.g. `GrokPro` from `/v1/user?include=subscription`.
    var planTier: String?
    var onDemandUsedCents: Int?
    var onDemandCapCents: Int?
    var fetchedAt: Date
    var source: String

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var resetsIn: TimeInterval? {
        guard let periodEnd else { return nil }
        return periodEnd.timeIntervalSinceNow
    }

    /// Localized quota cycle label (weekly / monthly / generic).
    var cycleLabel: String {
        switch periodType {
        case "USAGE_PERIOD_TYPE_WEEKLY": return L10n.weeklyQuota
        case "USAGE_PERIOD_TYPE_MONTHLY": return L10n.monthlyQuota
        default:
            if let start = periodStart, let end = periodEnd {
                let days = end.timeIntervalSince(start) / 86_400
                if days >= 6 && days <= 8 { return L10n.weeklyQuota }
                if days >= 27 && days <= 32 { return L10n.monthlyQuota }
            }
            return L10n.quota
        }
    }

    var planDisplayName: String? {
        guard let planTier, !planTier.isEmpty else { return nil }
        switch planTier {
        case "GrokPro": return "SuperGrok"
        case "GrokProPlus", "GrokPlus": return "SuperGrok Plus"
        case "GrokHeavy": return "SuperGrok Heavy"
        case "GrokLite": return "SuperGrok Lite"
        default:
            return planTier
                .replacingOccurrences(of: "Grok", with: "Grok ")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Nil when the API omitted on-demand fields entirely.
    var onDemandEnabled: Bool? {
        guard let cap = onDemandCapCents else { return nil }
        return cap > 0
    }
}

/// Grok Bot weekly pool — separate from SuperGrok / Build credits.
struct BotUsageSnapshot: Equatable {
    var usedPercent: Double
    var periodStart: Date?
    var periodEnd: Date?
    /// Included Bot pool label, e.g. `SuperGrok`.
    var planLabel: String?
    /// Cursor plan name reported alongside Bot, e.g. `Free`.
    var cursorPlanName: String?
    var hasAvailableUsage: Bool?
    /// Whether usage-based / on-demand spend is actually enabled (not merely "eligible").
    var onDemandEnabled: Bool?
    var onDemandUsedCents: Int?
    var onDemandLimitCents: Int?
    /// Raw access state from GetSandAccessStatus, e.g. `SAND_ACCESS_STATE_GRANTED`.
    var accessState: String?
    var accessBlockReason: String?
    var fetchedAt: Date
    var source: String

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var resetsIn: TimeInterval? {
        guard let periodEnd else { return nil }
        return periodEnd.timeIntervalSinceNow
    }

    var cycleLabel: String { L10n.weeklyQuota }

    var accessGranted: Bool? {
        guard let accessState else { return nil }
        return accessState == "SAND_ACCESS_STATE_GRANTED"
    }

    var accessDisplayName: String? {
        guard let accessState else { return nil }
        switch accessState {
        case "SAND_ACCESS_STATE_GRANTED": return L10n.botAccessGranted
        case "SAND_ACCESS_STATE_DENIED", "SAND_ACCESS_STATE_BLOCKED": return L10n.botAccessDenied
        case "SAND_ACCESS_STATE_PENDING": return L10n.botAccessPending
        default:
            return accessState
                .replacingOccurrences(of: "SAND_ACCESS_STATE_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }
}

enum UsageLoadState: Equatable {
    case idle
    case loading
    case loaded(UsageSnapshot)
    case failed(String)
}
