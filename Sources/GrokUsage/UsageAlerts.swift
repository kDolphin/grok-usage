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

    /// Evaluate `snapshot` and post notifications for any newly crossed thresholds.
    @MainActor
    static func evaluate(snapshot: UsageSnapshot) {
        let periodKey = periodKey(for: snapshot)
        var state = loadState()

        if state.periodKey != periodKey {
            state = AlertState(periodKey: periodKey, fired: [])
        }

        let percent = snapshot.usedPercent
        var newly: [Int] = []
        for t in thresholds {
            guard percent + 0.0001 >= Double(t) else { continue }
            if state.fired.contains(t) { continue }
            state.fired.insert(t)
            newly.append(t)
        }

        guard !newly.isEmpty else {
            // Still persist period key if it was empty/new.
            saveState(state)
            return
        }

        saveState(state)

        for (index, t) in newly.enumerated() {
            let delay = Double(index) * 0.35
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                postNotification(threshold: t, snapshot: snapshot)
            }
        }
    }

    private static func postNotification(threshold: Int, snapshot: UsageSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = L10n.alertTitle(threshold)
        let used = Int(snapshot.usedPercent.rounded())
        var body = L10n.alertBody(
            used: used,
            cycle: snapshot.cycleLabel,
            countdown: formatCountdown(snapshot.resetsIn)
        )
        if threshold >= 90 {
            body += L10n.alertTightSuffix
        }
        content.body = body
        content.sound = .default

        let id = "grok-usage-threshold-\(threshold)-\(periodKey(for: snapshot))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    private static func periodKey(for snapshot: UsageSnapshot) -> String {
        if let end = snapshot.periodEnd {
            return iso(end)
        }
        if let start = snapshot.periodStart {
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

    private static func loadState() -> AlertState {
        guard
            let data = try? Data(contentsOf: stateURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let key = root["periodKey"] as? String
        else {
            return AlertState(periodKey: "", fired: [])
        }
        let firedArr = root["fired"] as? [Int] ?? []
        return AlertState(periodKey: key, fired: Set(firedArr))
    }

    private static func saveState(_ state: AlertState) {
        let payload: [String: Any] = [
            "periodKey": state.periodKey,
            "fired": Array(state.fired).sorted(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: stateURL, options: .atomic)
    }
}
