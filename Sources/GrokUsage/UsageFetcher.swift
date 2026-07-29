import Foundation

enum UsageFetcherError: LocalizedError {
    case unauthorized
    case httpStatus(Int, String)
    case badPayload
    case transport(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L10n.fetchUnauthorized
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

/// Fetches **billing / quota metadata only** (`GET …/billing?format=credits`).
/// This is not a chat/completions inference call and should not burn model tokens.
/// We still keep request volume low (stale window + manual refresh) out of caution.
enum UsageFetcher {
    private static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let clientVersion = "0.2.111"

    /// Hard ceiling for a single billing fetch (connection + body).
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

    static func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-cli/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("grok-usage-menubar", forHTTPHeaderField: "x-grok-client-identifier")
        let requestToSend = request

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTimeout(seconds: overallTimeout) {
                try await session.data(for: requestToSend)
            }
        } catch is TimeoutError {
            throw UsageFetcherError.timedOut
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw UsageFetcherError.timedOut
        } catch {
            throw UsageFetcherError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageFetcherError.transport(L10n.authInvalidResponse)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageFetcherError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = String(body.prefix(180))
            throw UsageFetcherError.httpStatus(http.statusCode, snippet)
        }

        return try parse(data: data)
    }

    private static func parse(data: Data) throws -> UsageSnapshot {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let config = root["config"] as? [String: Any]
        else {
            throw UsageFetcherError.badPayload
        }

        let usedPercent: Double
        if let percent = config["creditUsagePercent"] as? Double {
            usedPercent = percent
        } else if let percent = config["creditUsagePercent"] as? Int {
            usedPercent = Double(percent)
        } else if
            let monthly = moneyCents(config["monthlyLimit"]),
            let used = moneyCents(config["used"] ?? (config["usage"] as? [String: Any])?["totalUsed"]),
            monthly > 0
        {
            usedPercent = min(100, Double(used) / Double(monthly) * 100)
        } else {
            throw UsageFetcherError.badPayload
        }

        var periodType: String?
        var periodStart: Date?
        var periodEnd: Date?

        if let current = config["currentPeriod"] as? [String: Any] {
            periodType = current["type"] as? String
            periodStart = parseDate(current["start"])
            periodEnd = parseDate(current["end"])
        }

        if periodStart == nil {
            periodStart = parseDate(config["billingPeriodStart"])
        }
        if periodEnd == nil {
            periodEnd = parseDate(config["billingPeriodEnd"])
        }

        var products: [ProductUsage] = []
        if let rawProducts = config["productUsage"] as? [[String: Any]] {
            products = rawProducts.compactMap { item in
                guard let product = item["product"] as? String else { return nil }
                let percent: Double
                if let p = item["usagePercent"] as? Double {
                    percent = p
                } else if let p = item["usagePercent"] as? Int {
                    percent = Double(p)
                } else {
                    return nil
                }
                return ProductUsage(product: product, usagePercent: percent)
            }
            .sorted { $0.usagePercent > $1.usagePercent }
        }

        let prepaid = moneyCents(config["prepaidBalance"])
        let unified = (config["isUnifiedBillingUser"] as? Bool) ?? false

        return UsageSnapshot(
            usedPercent: usedPercent,
            periodType: periodType,
            periodStart: periodStart,
            periodEnd: periodEnd,
            productUsage: products,
            prepaidBalanceCents: prepaid,
            isUnifiedBilling: unified,
            fetchedAt: Date(),
            source: "cli-chat-proxy"
        )
    }

    private static func moneyCents(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let obj = value as? [String: Any] {
            if let n = obj["val"] as? Int { return n }
            if let n = obj["val"] as? Double { return Int(n) }
        }
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

// MARK: - Timeout helper

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
