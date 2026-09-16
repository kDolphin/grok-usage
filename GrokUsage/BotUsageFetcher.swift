import Foundation

enum BotUsageFetcherError: LocalizedError {
    case unauthorized
    case httpStatus(Int, String)
    case badPayload
    case transport(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L10n.botFetchUnauthorized
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body)"
        case .badPayload:
            return L10n.fetchBadPayload
        case .transport(let message):
            return message
        case .timedOut:
            return L10n.fetchTimedOut
        }
    }
}

/// Fetches **Grok Bot weekly usage + access / on-demand metadata**.
/// Separate from the SuperGrok / Grok Build credits pool.
enum BotUsageFetcher {
    private static let usageEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!
    private static let accessEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandAccessStatus"
    )!
    private static let hardLimitEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetHardLimit"
    )!
    private static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let overallTimeout: TimeInterval = 12

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func fetch(accessToken: String) async throws -> BotUsageSnapshot {
        async let usageData = postJSON(url: usageEndpoint, accessToken: accessToken)
        async let accessData = postJSONOptional(url: accessEndpoint, accessToken: accessToken)
        async let hardLimitData = postJSONOptional(url: hardLimitEndpoint, accessToken: accessToken)
        async let summaryData = getUsageSummaryOptional(accessToken: accessToken)

        let usage = try await usageData
        return try parse(
            usageData: usage,
            accessData: await accessData,
            hardLimitData: await hardLimitData,
            summaryData: await summaryData
        )
    }

    private static func postJSON(url: URL, accessToken: String) async throws -> Data {
        let request = makeConnectRequest(url: url, accessToken: accessToken)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTimeout(seconds: overallTimeout) {
                try await session.data(for: request)
            }
        } catch is TimeoutError {
            throw BotUsageFetcherError.timedOut
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw BotUsageFetcherError.timedOut
        } catch {
            throw BotUsageFetcherError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BotUsageFetcherError.transport(L10n.authInvalidResponse)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw BotUsageFetcherError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = String(body.prefix(180))
            throw BotUsageFetcherError.httpStatus(http.statusCode, snippet)
        }
        return data
    }

    /// Enrichment endpoints soft-fail so usage still returns.
    private static func postJSONOptional(url: URL, accessToken: String) async -> Data? {
        try? await postJSON(url: url, accessToken: accessToken)
    }

    private static func getUsageSummaryOptional(accessToken: String) async -> Data? {
        guard let cookie = sessionCookieValue(fromJWT: accessToken) else { return nil }
        var request = URLRequest(url: usageSummaryURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")
        let requestToSend = request
        do {
            let (data, response) = try await withThrowingTimeout(seconds: overallTimeout) {
                try await session.data(for: requestToSend)
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func makeConnectRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// `WorkosCursorSessionToken` value: `<sub-after-pipe>%3A%3A<jwt>`.
    private static func sessionCookieValue(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              !sub.isEmpty
        else { return nil }
        let userPart = sub.split(separator: "|").last.map(String.init) ?? sub
        return "\(userPart)%3A%3A\(token)"
    }

    private static func parse(
        usageData: Data,
        accessData: Data?,
        hardLimitData: Data?,
        summaryData: Data?
    ) throws -> BotUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: usageData) as? [String: Any] else {
            throw BotUsageFetcherError.badPayload
        }

        let usedPercent: Double
        if let percent = doubleValue(root["usagePercent"]) {
            usedPercent = percent
        } else if root["currentPeriodStart"] != nil || root["nextResetTimestampUtc"] != nil {
            usedPercent = 0
        } else {
            throw BotUsageFetcherError.badPayload
        }

        var accessState: String?
        var accessBlockReason: String?
        if let accessData,
           let accessRoot = try? JSONSerialization.jsonObject(with: accessData) as? [String: Any]
        {
            accessState = accessRoot["state"] as? String
            accessBlockReason = accessRoot["blockReason"] as? String
            if accessBlockReason == "SAND_ACCESS_BLOCK_REASON_NONE" {
                accessBlockReason = nil
            }
        }

        // Prefer definitive enabled flags over sand `eligible` (which only means "can turn on").
        var onDemandEnabled: Bool?
        var onDemandUsedCents: Int?
        var onDemandLimitCents: Int?

        if let hardLimitData,
           let hardRoot = try? JSONSerialization.jsonObject(with: hardLimitData) as? [String: Any],
           let noUsageBased = hardRoot["noUsageBasedAllowed"] as? Bool
        {
            onDemandEnabled = !noUsageBased
        }

        if let summaryData,
           let summaryRoot = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
           let individual = summaryRoot["individualUsage"] as? [String: Any],
           let onDemand = individual["onDemand"] as? [String: Any]
        {
            if let enabled = onDemand["enabled"] as? Bool {
                onDemandEnabled = enabled
            }
            onDemandUsedCents = intValue(onDemand["used"])
            // `limit: null` means no cap when disabled; ignore.
            if onDemand["limit"] is NSNull {
                onDemandLimitCents = nil
            } else {
                onDemandLimitCents = intValue(onDemand["limit"])
            }
        }

        return BotUsageSnapshot(
            usedPercent: usedPercent,
            periodStart: parseDate(root["currentPeriodStart"]),
            periodEnd: parseDate(root["nextResetTimestampUtc"]),
            planLabel: root["grokPlanLabel"] as? String,
            cursorPlanName: root["cursorPlanName"] as? String,
            hasAvailableUsage: root["hasAvailableUsage"] as? Bool,
            onDemandEnabled: onDemandEnabled,
            onDemandUsedCents: onDemandUsedCents,
            onDemandLimitCents: onDemandLimitCents,
            accessState: accessState,
            accessBlockReason: accessBlockReason,
            fetchedAt: Date(),
            source: "cursor-sand"
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let n = Double(s) { return n }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let n = Int(s) { return n }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// Local timeout helper (mirrors UsageFetcher; kept file-private to avoid symbol clash).
private struct TimeoutError: Error {}

private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let ns = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
