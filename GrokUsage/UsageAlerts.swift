import Foundation
import UserNotifications

/// Fires a one-shot macOS notification when weekly usage first crosses each threshold.
/// Thresholds reset when the billing period changes (`periodEnd`).
enum UsageAlerts {
    static let thresholds: [Int] = [20, 40, 60, 80, 90, 95, 98]

    private static let center = UNUserNotificationCenter.current()

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("GrokUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alert-state.json")
    }

    /// Ask for notification permission (safe to call repeatedly).
    static func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// Evaluate SuperGrok / Build weekly usage and post notifications for newly crossed thresholds.
    @MainActor
    static func evaluate(snapshot: UsageSnapshot) {
        evaluateMeter(
            kind: .grok,
            percent: snapshot.usedPercent,
            periodKey: periodKey(
                end: snapshot.periodEnd,
                start: snapshot.periodStart
            ),
            title: { L10n.alertTitle($0) },
            body: { threshold in
                var text = L10n.alertBody(
                    used: Int(snapshot.usedPercent.rounded()),
                    cycle: snapshot.cycleLabel,
                    countdown: formatCountdown(snapshot.resetsIn)
                )
                if threshold >= 90 {
                    text += L10n.alertTightSuffix
                }
                return text
            }
        )
    }

    /// Evaluate Grok Bot weekly usage (independent period / thresholds).
    @MainActor
    static func evaluateBot(snapshot: BotUsageSnapshot) {
        evaluateMeter(
            kind: .bot,
            percent: snapshot.usedPercent,
            periodKey: "bot:" + periodKey(
                end: snapshot.periodEnd,
                start: snapshot.periodStart
            ),
            title: { L10n.botAlertTitle($0) },
            body: { threshold in
                var text = L10n.botAlertBody(
                    used: Int(snapshot.usedPercent.rounded()),
                    countdown: formatCountdown(snapshot.resetsIn)
                )
                if threshold >= 90 {
                    text += L10n.alertTightSuffix
                }
                return text
            }
        )
    }

    private enum MeterKind: String {
        case grok
        case bot
    }

    @MainActor
    private static func evaluateMeter(
        kind: MeterKind,
        percent: Double,
        periodKey: String,
        title: (Int) -> String,
        body: (Int) -> String
    ) {
        var state = loadState(kind: kind)

        if state.periodKey != periodKey {
            state = AlertState(periodKey: periodKey, fired: [])
        }

        var newly: [Int] = []
        for t in thresholds {
            guard percent + 0.0001 >= Double(t) else { continue }
            if state.fired.contains(t) { continue }
            state.fired.insert(t)
            newly.append(t)
        }

        guard !newly.isEmpty else {
            saveState(state, kind: kind)
            return
        }

        saveState(state, kind: kind)

        let notifications = newly.map { threshold in
            (threshold: threshold, title: title(threshold), body: body(threshold))
        }
        for (index, item) in notifications.enumerated() {
            let delay = Double(index) * 0.35
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                postNotification(
                    kind: kind,
                    threshold: item.threshold,
                    periodKey: periodKey,
                    title: item.title,
                    body: item.body
                )
            }
        }
    }

    private static func postNotification(
        kind: MeterKind,
        threshold: Int,
        periodKey: String,
        title: String,
        body: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let id = "grok-usage-\(kind.rawValue)-threshold-\(threshold)-\(periodKey)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    private static func periodKey(end: Date?, start: Date?) -> String {
        if let end {
            return iso(end)
        }
        if let start {
            return "start:" + iso(start)
        }
        // Fallback: calendar week bucket so we still reset somehow.
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return "week-\(comps.yearForWeekOfYear ?? 0)-\(comps.weekOfYear ?? 0)"
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private struct AlertState {
        var periodKey: String
        var fired: Set<Int>
    }

    private static func loadState(kind: MeterKind) -> AlertState {
        guard
            let data = try? Data(contentsOf: stateURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AlertState(periodKey: "", fired: [])
        }

        // New shape: { "grok": {...}, "bot": {...} }. Legacy flat file maps to grok.
        let section: [String: Any]?
        if let nested = root[kind.rawValue] as? [String: Any] {
            section = nested
        } else if kind == .grok, root["periodKey"] != nil {
            section = root
        } else {
            section = nil
        }

        guard let section, let key = section["periodKey"] as? String else {
            return AlertState(periodKey: "", fired: [])
        }
        let firedArr = section["fired"] as? [Int] ?? []
        return AlertState(periodKey: key, fired: Set(firedArr))
    }

    private static func saveState(_ state: AlertState, kind: MeterKind) {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: stateURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            // Migrate legacy flat file into nested `grok` once.
            if existing["periodKey"] != nil, existing["grok"] == nil {
                root["grok"] = [
                    "periodKey": existing["periodKey"] as Any,
                    "fired": existing["fired"] as Any,
                ]
                if let bot = existing["bot"] {
                    root["bot"] = bot
                }
            } else {
                root = existing
            }
        }

        root[kind.rawValue] = [
            "periodKey": state.periodKey,
            "fired": Array(state.fired).sorted(),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: stateURL, options: .atomic)
    }
}
