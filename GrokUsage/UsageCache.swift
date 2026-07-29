import Foundation

/// Persists the last successful snapshot so the menu stays useful offline / after timeouts.
enum UsageCache {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("GrokUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-snapshot.json")
    }

    static func save(_ snapshot: UsageSnapshot, email: String?) {
        var payload: [String: Any] = [
            "usedPercent": snapshot.usedPercent,
            "productUsage": snapshot.productUsage.map { [
                "product": $0.product,
                "usagePercent": $0.usagePercent,
            ] as [String: Any] },
            "isUnifiedBilling": snapshot.isUnifiedBilling,
            "fetchedAt": iso(snapshot.fetchedAt),
            "source": snapshot.source,
        ]
        if let periodType = snapshot.periodType {
            payload["periodType"] = periodType
        }
        if let periodStart = snapshot.periodStart {
            payload["periodStart"] = iso(periodStart)
        }
        if let periodEnd = snapshot.periodEnd {
            payload["periodEnd"] = iso(periodEnd)
        }
        if let prepaid = snapshot.prepaidBalanceCents {
            payload["prepaidBalanceCents"] = prepaid
        }
        if let email {
            payload["email"] = email
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> (snapshot: UsageSnapshot, email: String?)? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let used: Double
        if let p = root["usedPercent"] as? Double {
            used = p
        } else if let p = root["usedPercent"] as? Int {
            used = Double(p)
        } else {
            return nil
        }

        var products: [ProductUsage] = []
        if let raw = root["productUsage"] as? [[String: Any]] {
            products = raw.compactMap { item in
                guard let product = item["product"] as? String else { return nil }
                let percent: Double
                if let p = item["usagePercent"] as? Double { percent = p }
                else if let p = item["usagePercent"] as? Int { percent = Double(p) }
                else { return nil }
                return ProductUsage(product: product, usagePercent: percent)
            }
        }

        let snapshot = UsageSnapshot(
            usedPercent: used,
            periodType: root["periodType"] as? String,
            periodStart: parseDate(root["periodStart"] as? String),
            periodEnd: parseDate(root["periodEnd"] as? String),
            productUsage: products,
            prepaidBalanceCents: root["prepaidBalanceCents"] as? Int,
            isUnifiedBilling: (root["isUnifiedBilling"] as? Bool) ?? false,
            fetchedAt: parseDate(root["fetchedAt"] as? String) ?? Date.distantPast,
            source: (root["source"] as? String).map { "\($0)+cache" } ?? "cache"
        )
        return (snapshot, root["email"] as? String)
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
