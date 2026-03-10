import Foundation
import Combine
import MetricKit

// ─────────────────────────────────────────────
// MetricsManager.swift
// Auto Performance Tracker
//
// Empfängt täglich von iOS gesammelte Performance- und Diagnostikdaten.
// Apple wertet diese AUTOMATISCH aus und zeigt sie in Xcode Organizer +
// App Store Connect unter "Diagnostics" an:
//   • Launch Time       (wie schnell startet die App)
//   • Hang Rate         (wie oft friert die UI ein)
//   • Energy Usage      (Akku-Verbrauch)
//   • Memory            (RAM-Nutzung, Crashes durch OOM)
//   • Disk Writes       (I/O-Last)
//   • Crash Logs        (ergänzend zu Crashlytics)
//
// KEINE zusätzliche Konfiguration nötig – nur registrieren reicht.
// Daten kommen einmal täglich (nach 24h Nutzung) als Batch.
// ─────────────────────────────────────────────

final class MetricsManager: NSObject {

    static let shared = MetricsManager()
    private override init() {}

    // Subscriber beim MetricKit-System anmelden.
    // Muss einmalig beim App-Start aufgerufen werden.
    func register() {
        MXMetricManager.shared.add(self)
    }

    func unregister() {
        MXMetricManager.shared.remove(self)
    }
}

// MARK: - MXMetricManagerSubscriber

extension MetricsManager: MXMetricManagerSubscriber {

    // Wird täglich von iOS aufgerufen mit gesammelten Performance-Metriken.
    // FIX CON-004: MetricKit ruft didReceive() auf einem Background-Thread auf.
    // Crashlytics ist zwar thread-safe, aber zur Klarheit (und Swift-6-Bereitschaft)
    // werden die Logging-Calls explizit auf den Main Actor dispatched.
    func didReceive(_ payloads: [MXMetricPayload]) {
        Task { @MainActor in
            for payload in payloads {
                let json = payload.jsonRepresentation()
                if let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                    if let launchMetrics = dict["applicationLaunchMetrics"] as? [String: Any],
                       let resumeTime = launchMetrics["histogrammedResumeTime"] as? [String: Any] {
                        CrashlyticsManager.log("MetricKit - Resume Time: \(resumeTime)")
                    }
                    if let hangMetrics = dict["applicationResponsivenessMetrics"] as? [String: Any] {
                        CrashlyticsManager.log("MetricKit - Hang Metrics: \(hangMetrics)")
                    }
                }
                CrashlyticsManager.set(
                    key: "metrickit_period",
                    value: "\(payload.timeStampBegin) – \(payload.timeStampEnd)"
                )
            }
        }
    }

    // Wird aufgerufen wenn Diagnostik-Daten vorliegen (Crashes, Hangs, Disk Writes)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in
            for payload in payloads {
                if !payload.crashDiagnostics.isNilOrEmpty {
                    CrashlyticsManager.log("MetricKit - Crash Diagnostics erhalten: \(payload.crashDiagnostics?.count ?? 0) Einträge")
                }
                if !payload.hangDiagnostics.isNilOrEmpty {
                    CrashlyticsManager.log("MetricKit - Hang Diagnostics: \(payload.hangDiagnostics?.count ?? 0) Einträge")
                }
                if !payload.cpuExceptionDiagnostics.isNilOrEmpty {
                    CrashlyticsManager.log("MetricKit - CPU Exceptions: \(payload.cpuExceptionDiagnostics?.count ?? 0) Einträge")
                }
                if !payload.diskWriteExceptionDiagnostics.isNilOrEmpty {
                    CrashlyticsManager.log("MetricKit - Disk Write Exceptions: \(payload.diskWriteExceptionDiagnostics?.count ?? 0) Einträge")
                }
            }
        }
    }
}

// MARK: - Helper

private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}
