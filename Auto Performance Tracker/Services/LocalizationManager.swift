import SwiftUI
import Combine

// ═══════════════════════════════════════════════════════════════
// LocalizationManager.swift
// Zentrale Sprachverwaltung — unterstützt: Deutsch, Englisch
// Neue Sprachen: einfach neues Strings_xx.swift hinzufügen
// ═══════════════════════════════════════════════════════════════

/// Supported languages
enum AppLanguage: String, CaseIterable, Identifiable {
    case de = "de"
    case en = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .de: return "🇩🇪 Deutsch"
        case .en: return "🇬🇧 English"
        }
    }

    var flag: String {
        switch self {
        case .de: return "🇩🇪"
        case .en: return "🇬🇧"
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Language Manager (Singleton)
// ─────────────────────────────────────────────

final class LanguageManager: ObservableObject {

    static let shared = LanguageManager()

    @Published var current: AppLanguage {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "appLanguage")
        }
    }

    /// All registered language dictionaries
    private(set) var dictionaries: [String: [String: String]] = [:]

    private init() {
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "de"
        self.current = AppLanguage(rawValue: stored) ?? .de

        // Register language packs
        registerLanguage("de", strings: Strings_de.all)
        registerLanguage("en", strings: Strings_en.all)
    }

    /// Register a new language pack (for future expansion)
    func registerLanguage(_ code: String, strings: [String: String]) {
        dictionaries[code] = strings
    }

    /// Look up a localized string
    func localized(_ key: String) -> String {
        // Try current language first
        if let value = dictionaries[current.rawValue]?[key] {
            return value
        }
        // Fallback to German
        if let value = dictionaries["de"]?[key] {
            return value
        }
        // Last resort: return key
        #if DEBUG
        print("⚠️ Missing localization key: \"\(key)\" for language: \(current.rawValue)")
        #endif
        return key
    }

    /// Look up with string interpolation support
    func localized(_ key: String, _ args: CVarArg...) -> String {
        let template = localized(key)
        return String(format: template, arguments: args)
    }
}

// ─────────────────────────────────────────────
// MARK: - Global Shorthand Function
// ─────────────────────────────────────────────

/// Global localization function — use L("key") everywhere.
///
/// FIX CON-002: @MainActor isolation macht L() thread-sicher.
/// LanguageManager.dictionaries ist ein Swift-Dictionary — concurrent reads
/// bei gleichzeitigem Schreiben (registerLanguage) sind Data Races.
/// Da registerLanguage() nur im init() aufgerufen wird, sind concurrent reads
/// nach dem Start sicher. @MainActor macht die Intention explizit und
/// verhindert zukünftige Background-Thread-Schreibzugriffe.
/// Aufrufer auf Background-Threads (DrivingScoreEngine, DrivingTipsEngine)
/// müssen L() via await MainActor.run { L("key") } aufrufen.
@MainActor
func L(_ key: String) -> String {
    LanguageManager.shared.localized(key)
}

/// Global localization with format arguments — use L("key", arg1, arg2)
@MainActor
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = LanguageManager.shared.localized(key)
    return String(format: template, arguments: args)
}

// ─────────────────────────────────────────────
// MARK: - Localized DateFormatter Helper
// ─────────────────────────────────────────────

extension LanguageManager {
    /// Returns the correct Locale for date formatting
    var locale: Locale {
        switch current {
        case .de: return Locale(identifier: "de_DE")
        case .en: return Locale(identifier: "en_US")
        }
    }

    /// Returns a localized DateFormatter
    func dateFormatter(dateStyle: DateFormatter.Style = .medium,
                       timeStyle: DateFormatter.Style = .short) -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = dateStyle
        f.timeStyle = timeStyle
        f.locale = locale
        return f
    }
}
