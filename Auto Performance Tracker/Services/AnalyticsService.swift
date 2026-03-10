import Foundation
import SwiftUI

// MARK: - Analytics Service (Privacy by Design)
// Alle Daten: anonym, gebucketed, kein GPS, kein User-Fingerprint
// Opt-In: User muss explizit zustimmen

final class AnalyticsService {

    static let shared = AnalyticsService()

    // FIX BUG-002: Statischer Formatter – wird nur einmal erzeugt statt bei jedem Event.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // API-Key wird zur Laufzeit aus der Info.plist gelesen.
    // In Xcode: Build Settings → User-Defined → POSTHOG_API_KEY setzen,
    // dann in Info.plist: PostHogAPIKey = $(POSTHOG_API_KEY)
    // So bleibt der echte Schlüssel NIEMALS im Git-Repository.
    private let posthogAPIKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String,
              !key.isEmpty,
              key != "REPLACE_VIA_XCCONFIG" else {
            #if DEBUG
            print("⚠️ [Analytics] PostHog API Key nicht konfiguriert. Bitte POSTHOG_API_KEY in Build Settings setzen.")
            #endif
            return ""
        }
        return key
    }()
    private let posthogHost = "https://eu.posthog.com"

    /// Direkt aus UserDefaults lesen
    var isOptIn: Bool {
        UserDefaults.standard.bool(forKey: "analyticsOptIn")
    }

    /// Persistente anonyme Geräte-ID — einmalig generiert, kein Nutzerbezug.
    /// DSGVO: ID wird erst nach explizitem Opt-In erzeugt und gespeichert (Art. 25 – Privacy by Default).
    /// Vor dem Consent existiert keine persistente ID. Bei Opt-Out wird die ID gelöscht.
    private var deviceID: String {
        let key = "analyticsAnonymousDeviceID"
        // Nur wenn Opt-In aktiv: ID lesen oder erstmalig erzeugen
        guard isOptIn else { return "" }
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }

    private init() {}

    // MARK: - Opt-In/Out
    func setOptIn(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "analyticsOptIn")
        if value {
            // Direkt nach Opt-In ein identify-Event senden damit PostHog den User registriert
            trackAppOpened()
        } else {
            // DSGVO Art. 25 – Privacy by Default:
            // Bei Opt-Out wird die gespeicherte anonyme Geräte-ID sofort gelöscht.
            // Beim nächsten Opt-In wird eine neue, nicht mit der alten verknüpfbare ID erzeugt.
            UserDefaults.standard.removeObject(forKey: "analyticsAnonymousDeviceID")
        }
    }

    // MARK: - App Lifecycle

    /// Muss bei jedem App-Start und Foreground-Wechsel aufgerufen werden.
    /// Ist die Grundlage für DAU/WAU in PostHog.
    func trackAppOpened() {
        guard isOptIn else { return }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        sendEvent(event: "app_opened", properties: [
            "app_version": appVersion,
            "build": buildNumber,
            "platform": "iOS",
            "os_version": UIDevice.current.systemVersion
        ])
    }

    // MARK: - Track Trip (anonym, gebucketed)
    func trackTrip(distanceKm: Double, fuelL: Double, efficiencyScore: Int) {
        guard isOptIn else {
            #if DEBUG
            print("📊 [Analytics] trackTrip SKIPPED — isOptIn: \(isOptIn)")
            #endif
            return
        }
        sendEvent(event: "trip_completed", properties: [
            "distance_bucket": distanceBucket(km: distanceKm),
            "fuel_bucket":     fuelBucket(liter: fuelL),
            "score_bucket":    scoreBucket(score: efficiencyScore),
        ])
    }

    func trackFeatureUsed(_ feature: String) {
        guard isOptIn else { return }
        sendEvent(event: "feature_used", properties: ["feature": feature])
    }

    // MARK: - PostHog API

    private func sendEvent(event: String, properties: [String: Any]) {
        guard !posthogAPIKey.isEmpty else {
            #if DEBUG
            print("📊 [Analytics] SKIP '\(event)' — kein API-Key konfiguriert")
            #endif
            return
        }
        guard let url = URL(string: "\(posthogHost)/capture/") else {
            #if DEBUG
            print("📊 [Analytics] ERROR: Invalid PostHog URL")
            #endif
            return
        }

        let id = deviceID
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

        // Korrektes PostHog Capture-Format
        let body: [String: Any] = [
            "api_key":     posthogAPIKey,
            "event":       event,
            "distinct_id": id,
            "timestamp":   AnalyticsService.iso8601.string(from: Date()),
            "properties":  properties.merging([
                "$lib":          "AutoPerformanceTracker-iOS",
                "$lib_version":  appVersion,
                "$os":           "iOS",
                "$os_version":   UIDevice.current.systemVersion,
                "$app_version":  appVersion,
            ]) { existing, _ in existing }
        ]

        do {
            let data    = try JSONSerialization.data(withJSONObject: body, options: [])
            var request = URLRequest(url: url)
            request.httpMethod  = "POST"
            request.httpBody    = data
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15

            URLSession.shared.dataTask(with: request) { responseData, response, error in
                #if DEBUG
                if let httpResponse = response as? HTTPURLResponse {
                    let status = httpResponse.statusCode == 200 ? "✅" : "❌"
                    print("📊 [Analytics] \(status) '\(event)' → HTTP \(httpResponse.statusCode) | id: \(id.prefix(8))…")
                    if httpResponse.statusCode != 200, let d = responseData, let body = String(data: d, encoding: .utf8) {
                        print("📊 [Analytics] Response body: \(body)")
                    }
                }
                if let error = error {
                    print("📊 [Analytics] NETWORK ERROR '\(event)': \(error.localizedDescription)")
                }
                #endif
            }.resume()

            #if DEBUG
            let propSummary = properties
                .filter { !["$lib", "$lib_version", "$os", "$os_version", "$app_version"].contains($0.key) }
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            let propStr = propSummary.isEmpty ? "" : " | \(propSummary)"
            print("📊 [Analytics] Sending '\(event)'\(propStr) | device: \(id.prefix(8))…")
            #endif

        } catch {
            #if DEBUG
            print("📊 [Analytics] JSON SERIALIZATION ERROR: \(error)")
            #endif
        }
    }

    // MARK: - Bucketing

    private func distanceBucket(km: Double) -> String {
        switch km {
        case ..<2:      return "0-2km"
        case 2..<10:    return "2-10km"
        case 10..<50:   return "10-50km"
        case 50..<100:  return "50-100km"
        default:        return "100km+"
        }
    }

    private func fuelBucket(liter: Double) -> String {
        switch liter {
        case ..<1:   return "0-1L"
        case 1..<3:  return "1-3L"
        case 3..<6:  return "3-6L"
        case 6..<10: return "6-10L"
        default:     return "10L+"
        }
    }

    private func scoreBucket(score: Int) -> String {
        switch score {
        case ..<40:   return "0-39"
        case 40..<60: return "40-59"
        case 60..<80: return "60-79"
        default:      return "80-100"
        }
    }
}

// MARK: - Analytics Consent View (beim ersten Start)

struct AnalyticsConsentView: View {
    @AppStorage("analyticsConsentShown") private var shown = false
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color(hex: "080C14").ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 40, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 28)

                ZStack {
                    Circle()
                        .fill(Color(hex: "818CF8").opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 30))
                        .foregroundStyle(Color(hex: "818CF8"))
                }
                .padding(.bottom, 20)

                Text(L("consent.title"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 10) {
                    consentRow(icon: "checkmark.shield.fill", color: "22C55E", text: L("consent.p1"))
                    consentRow(icon: "lock.fill",             color: "818CF8", text: L("consent.p2"))
                    consentRow(icon: "server.rack",           color: "3B82F6", text: L("consent.p3"))
                    consentRow(icon: "arrow.uturn.backward",  color: "F59E0B", text: L("consent.p4"))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

                Button(action: {
                    AnalyticsService.shared.setOptIn(true)   // sendet sofort app_opened
                    shown = true
                    onDismiss()
                }) {
                    Text(L("consent.accept"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "818CF8"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Button(action: {
                    AnalyticsService.shared.setOptIn(false)
                    shown = true
                    onDismiss()
                }) {
                    Text(L("consent.decline"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "0F1A2E"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .presentationDetents([.height(520)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .presentationBackground(Color(hex: "080C14"))
    }

    private func consentRow(icon: String, color: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: color).opacity(0.12)).frame(width: 32, height: 32)
                Image(systemName: icon).foregroundStyle(Color(hex: color)).font(.system(size: 13))
            }
            Text(text).font(.system(size: 13)).foregroundStyle(Color(hex: "8A9BB5"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
