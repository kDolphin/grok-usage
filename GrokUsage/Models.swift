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
}

enum UsageLoadState: Equatable {
    case idle
    case loading
    case loaded(UsageSnapshot)
    case failed(String)
}
