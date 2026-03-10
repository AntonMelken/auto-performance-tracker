import Foundation
import Combine
import UserNotifications
import UIKit

// ═══════════════════════════════════════════════════════════════
// NotificationService.swift
// Zentrale Verwaltung aller lokalen Benachrichtigungen
// ═══════════════════════════════════════════════════════════════

// MARK: - Pro Upsell Context

enum ProUpsellContext {
    case tripMilestone(Int)   // jede 5. Fahrt
    case paywallDismissed     // nach Schließen des Paywalls
}

// MARK: - NotificationService

@MainActor
final class NotificationService: NSObject, ObservableObject {

    static let shared = NotificationService()

    @Published var isPermissionGranted: Bool = false

    // UserDefaults-Key für den globalen Toggle
    private let enabledKey = "notificationsEnabled"

    var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { cancelAllNotifications() }
        }
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Permission
    // ─────────────────────────────────────────────────────────────

    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            isPermissionGranted = granted
        } catch {
            isPermissionGranted = false
            CrashlyticsManager.record(error, context: "NotificationService.requestPermission")
        }
    }

    func refreshPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isPermissionGranted = settings.authorizationStatus == .authorized ||
                               settings.authorizationStatus == .provisional
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Statistics Reports (weekly / monthly / yearly)
    // ─────────────────────────────────────────────────────────────

    func scheduleStatisticsReports(trips: [Trip]) {
        guard notificationsEnabled, isPermissionGranted else { return }

        scheduleWeeklyReport(trips: trips)
        scheduleMonthlyReport(trips: trips)
        scheduleYearlyReport(trips: trips)
    }

    private func scheduleWeeklyReport(trips: [Trip]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["stats.weekly"])

        let content = UNMutableNotificationContent()
        content.title = L("notif.weekly.title")
        content.sound = .default
        content.userInfo = ["tab": 2]

        // Echte Daten der letzten Woche berechnen
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let weekTrips = trips.filter { $0.startDate >= weekAgo }
        let avgScore = weekTrips.isEmpty ? 0 :
            weekTrips.map { $0.efficiencyScore }.reduce(0, +) / weekTrips.count

        if weekTrips.isEmpty {
            content.body = L("notif.weekly.none")
        } else if avgScore >= 80 {
            content.body = String(format: L("notif.weekly.good"), weekTrips.count, avgScore)
        } else if avgScore >= 60 {
            content.body = String(format: L("notif.weekly.average"), weekTrips.count, avgScore)
        } else {
            content.body = String(format: L("notif.weekly.poor"), avgScore)
        }

        // Jeden Montag um 09:00 Uhr
        var components = DateComponents()
        components.weekday = 2   // 1 = Sonntag, 2 = Montag
        components.hour = 9
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "stats.weekly",
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService weekly: \(error)") }
        }
    }

    private func scheduleMonthlyReport(trips: [Trip]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["stats.monthly"])

        let content = UNMutableNotificationContent()
        content.title = L("notif.monthly.title")
        content.sound = .default
        content.userInfo = ["tab": 2]

        // Letzter Monat
        let now = Date()
        let cal = Calendar.current
        let monthAgo = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let lastMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: monthAgo)) ?? monthAgo
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        let monthTrips = trips.filter { $0.startDate >= lastMonthStart && $0.startDate < thisMonthStart }
        let totalKm = monthTrips.reduce(0.0) { $0 + $1.distanceKm }
        let avgScore = monthTrips.isEmpty ? 0 :
            monthTrips.map { $0.efficiencyScore }.reduce(0, +) / monthTrips.count

        content.body = String(format: L("notif.monthly.body"),
                              monthTrips.count, totalKm, avgScore)

        // 1. des Monats um 09:00
        var components = DateComponents()
        components.day = 1
        components.hour = 9
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "stats.monthly",
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService monthly: \(error)") }
        }
    }

    private func scheduleYearlyReport(trips: [Trip]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["stats.yearly"])

        let content = UNMutableNotificationContent()
        content.title = L("notif.yearly.title")
        content.sound = .default
        content.userInfo = ["tab": 2]

        let year = Calendar.current.component(.year, from: Date()) - 1
        let yearStart = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        let yearEnd   = Calendar.current.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? Date()

        let yearTrips = trips.filter { $0.startDate >= yearStart && $0.startDate < yearEnd }
        let totalKm = yearTrips.reduce(0.0) { $0 + $1.distanceKm }
        let avgScore = yearTrips.isEmpty ? 0 :
            yearTrips.map { $0.efficiencyScore }.reduce(0, +) / yearTrips.count

        content.body = String(format: L("notif.yearly.body"),
                              year, yearTrips.count, totalKm, avgScore)

        // 1. Januar um 10:00
        var components = DateComponents()
        components.month = 1
        components.day = 1
        components.hour = 10
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "stats.yearly",
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService yearly: \(error)") }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - App Update Notification
    // ─────────────────────────────────────────────────────────────

    func scheduleUpdateNotification() {
        guard notificationsEnabled, isPermissionGranted else { return }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["update.available"])

        let content = UNMutableNotificationContent()
        content.title = L("notif.update.title")
        content.body  = L("notif.update.body")
        content.sound = .default
        content.userInfo = ["tab": 3, "action": "changelog"]

        // 2 Stunden nach App-Start
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2 * 60 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: "update.available",
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService update: \(error)") }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Engagement Reminders (3 / 7 / 14 Tage)
    // ─────────────────────────────────────────────────────────────

    func recordAppOpen() {
        UserDefaults.standard.set(Date(), forKey: "lastAppOpenDate")
    }

    func rescheduleEngagementReminders() {
        guard notificationsEnabled, isPermissionGranted else { return }

        let center = UNUserNotificationCenter.current()
        let ids = ["engage.day3", "engage.day7", "engage.day14"]
        center.removePendingNotificationRequests(withIdentifiers: ids)

        let from = UserDefaults.standard.object(forKey: "lastAppOpenDate") as? Date ?? Date()

        let reminders: [(id: String, days: Double, title: String, body: String)] = [
            ("engage.day3",  3,  L("notif.engage.day3.title"),  L("notif.engage.day3.body")),
            ("engage.day7",  7,  L("notif.engage.day7.title"),  L("notif.engage.day7.body")),
            ("engage.day14", 14, L("notif.engage.day14.title"), L("notif.engage.day14.body")),
        ]

        for reminder in reminders {
            let fireDate = from.addingTimeInterval(reminder.days * 24 * 60 * 60)
            guard fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body  = reminder.body
            content.sound = .default
            content.userInfo = ["tab": 0]

            let interval = fireDate.timeIntervalSince(Date())
            let trigger  = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval),
                                                             repeats: false)
            let request  = UNNotificationRequest(identifier: reminder.id,
                                                 content: content,
                                                 trigger: trigger)
            center.add(request) { error in
                if let error { CrashlyticsManager.log("NotificationService engage \(reminder.id): \(error)") }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Driving Detection
    // ─────────────────────────────────────────────────────────────

    func scheduleDrivingDetectionNotification() {
        guard notificationsEnabled, isPermissionGranted else { return }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["driving.detect"])

        let content = UNMutableNotificationContent()
        content.title = L("notif.driving.title")
        content.body  = L("notif.driving.body")
        content.sound = .default
        content.userInfo = ["tab": 0]

        // 5 Minuten nachdem die App in den Hintergrund gewechselt hat
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: "driving.detect",
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService driving: \(error)") }
        }
    }

    func cancelDrivingDetectionNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["driving.detect"])
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Post-Trip Tip
    // ─────────────────────────────────────────────────────────────

    func schedulePostTripTip(for trip: Trip) {
        guard notificationsEnabled, isPermissionGranted else { return }

        // Ältere Post-Trip-Benachrichtigungen entfernen
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let oldIds = requests
                .filter { $0.identifier.hasPrefix("posttrip.") }
                .map { $0.identifier }
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: oldIds)
        }

        let content = UNMutableNotificationContent()
        content.title = L("notif.posttrip.title")
        content.sound = .default
        content.userInfo = ["tab": 1, "tripId": trip.id.uuidString]

        // Fahrtipp aus DrivingTipsEngine holen
        let tips = DrivingTipsEngine.shared.analyze(trip: trip)
        if let firstTip = tips.first {
            content.body = firstTip.text
        } else {
            content.body = L("notif.driving.body")
        }

        // 30 Minuten nach Fahrtende
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false)
        let id      = "posttrip.\(trip.id.uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService posttrip: \(error)") }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Pro Upsell
    // ─────────────────────────────────────────────────────────────

    func scheduleProUpsell(context: ProUpsellContext) {
        guard notificationsEnabled, isPermissionGranted else { return }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["pro.upsell"])

        let content = UNMutableNotificationContent()
        content.title = L("notif.pro.title")
        content.sound = .default
        content.userInfo = ["tab": 3, "action": "paywall"]

        switch context {
        case .tripMilestone(let count):
            content.body = String(format: L("notif.pro.trip5.body"), count)
        case .paywallDismissed:
            content.body = L("notif.pro.paywall.body")
        }

        // 2 Stunden nach Auslöser
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2 * 60 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: "pro.upsell",
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService proUpsell: \(error)") }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Share Prompt (ausgezeichnete Fahrt)
    // ─────────────────────────────────────────────────────────────

    /// Sendet eine Share-Einladung wenn die Fahrt einen Score ≥ 80 hat.
    /// Anti-Spam: Maximal einmal pro 24 Stunden.
    func scheduleSharePromptIfExcellent(for trip: Trip) {
        guard notificationsEnabled, isPermissionGranted else { return }
        guard trip.efficiencyScore >= 80 else { return }

        // 24h-Cooldown prüfen
        let lastKey = "lastSharePromptDate"
        if let last = UserDefaults.standard.object(forKey: lastKey) as? Date,
           Date().timeIntervalSince(last) < 86_400 { return }
        UserDefaults.standard.set(Date(), forKey: lastKey)

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["share.excellent"])

        let content = UNMutableNotificationContent()
        content.title = L("notif.share.title")
        content.body  = String(format: L("notif.share.body"), trip.efficiencyScore)
        content.sound = .default
        // Deep Link: Tab 1 (Trips) + tripId zum direkten Öffnen dieser Fahrt
        content.userInfo = ["tab": 1, "tripId": trip.id.uuidString, "action": "share_last_trip"]

        // 2 Minuten nach Fahrtende – Nutzer ist noch "im Modus"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: "share.excellent",
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error { CrashlyticsManager.log("NotificationService share: \(error)") }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Cancel All
    // ─────────────────────────────────────────────────────────────

    func cancelAllNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Deep Link Handling
    // ─────────────────────────────────────────────────────────────

    private func handleNotificationTap(tab: Int, action: String?, tripId: String?) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .notificationDeepLink,
                object: nil,
                userInfo: ["tab": tab, "action": action as Any, "tripId": tripId as Any]
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - UNUserNotificationCenterDelegate
// ─────────────────────────────────────────────────────────────

extension NotificationService: UNUserNotificationCenterDelegate {

    /// Benachrichtigung im Vordergrund anzeigen
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tap auf Benachrichtigung
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let tab    = userInfo["tab"] as? Int ?? 0
        let action = userInfo["action"] as? String
        let tripId = userInfo["tripId"] as? String
        Task { @MainActor in
            self.handleNotificationTap(tab: tab, action: action, tripId: tripId)
        }
        completionHandler()
    }
}
