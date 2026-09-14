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

/// Fetches **Grok Bot weekly usage metadata only**
/// (`POST …/DashboardService/GetSandUsageStatus`).
/// Separate from the SuperGrok / Grok Build credits pool.
enum BotUsageFetcher {
    private static let endpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!
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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        let requestToSend = request

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTimeout(seconds: overallTimeout) {
                try await session.data(for: requestToSend)
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

        return try parse(data: data)
    }

    private static func parse(data: Data) throws -> BotUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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

        return BotUsageSnapshot(
            usedPercent: usedPercent,
            periodStart: parseDate(root["currentPeriodStart"]),
            periodEnd: parseDate(root["nextResetTimestampUtc"]),
            planLabel: root["grokPlanLabel"] as? String,
            hasAvailableUsage: root["hasAvailableUsage"] as? Bool,
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
