import Foundation
import FirebaseCrashlytics

// MARK: - CrashlyticsManager
// Zentraler Helper für strukturiertes Fehler-Logging via Firebase Crashlytics.
// Verwendung:
//   CrashlyticsManager.log("Trip recording failed")
//   CrashlyticsManager.record(error)
//   CrashlyticsManager.setUser(id: "abc123")
//
// DSGVO (Art. 6, 13, 44 DSGVO / Schrems-II):
// Firebase Crashlytics überträgt Daten an Google LLC (USA) auf Basis von SCCs.
// Der Nutzer kann die Datenerfassung per Opt-Out in den Einstellungen deaktivieren.

final class CrashlyticsManager {

    static let shared = CrashlyticsManager()
    private init() {}

    // MARK: - DSGVO Opt-Out
    // UserDefaults-Key: "crashlyticsOptIn" (default: true — Bestandsschutz für bestehende User)
    // Neuen Usern wird beim ersten Start kein Opt-In abgefragt (Crashlytics ist kein Tracking,
    // sondern technisch notwendige Fehlerdiagnose). Nutzer können in den Einstellungen abmelden.
    static var isOptIn: Bool {
        get {
            // Wurde der Key noch nie gesetzt → Default true (keine Breaking-Änderung)
            if UserDefaults.standard.object(forKey: "crashlyticsOptIn") == nil { return true }
            return UserDefaults.standard.bool(forKey: "crashlyticsOptIn")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "crashlyticsOptIn")
            // Crashlytics Collection sofort aktivieren/deaktivieren
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(newValue)
            if !newValue {
                // User-ID entfernen wenn Opt-Out
                Crashlytics.crashlytics().setUserID("")
            }
        }
    }

    // MARK: - User Identity (nach Login setzen)
    static func setUser(id: String) {
        guard isOptIn else { return }
        Crashlytics.crashlytics().setUserID(id)
    }

    static func clearUser() {
        Crashlytics.crashlytics().setUserID("")
    }

    // MARK: - Custom Key/Value (erscheint im Crashlytics-Report)
    static func set(key: String, value: String) {
        guard isOptIn else { return }
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    // MARK: - Non-fatal Error (z.B. Netzwerkfehler, StoreKit-Fehler)
    static func record(_ error: Error, context: String? = nil) {
        guard isOptIn else { return }
        if let context {
            Crashlytics.crashlytics().setCustomValue(context, forKey: "error_context")
        }
        Crashlytics.crashlytics().record(error: error)
    }

    // MARK: - Custom Log Message (erscheint in Crashlytics Log-Stream)
    static func log(_ message: String) {
        guard isOptIn else { return }
        Crashlytics.crashlytics().log(message)
    }
}
