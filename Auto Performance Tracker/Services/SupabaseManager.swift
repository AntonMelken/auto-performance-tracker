import Foundation
import SwiftUI
import SwiftData
import Combine
import AuthenticationServices
import CryptoKit
import GoogleSignIn
import Supabase

// ============================================================
// SupabaseManager.swift
// Auto Performance Tracker · Auth (E-Mail, Apple, Google, Anonym) + Cloud-Sync
//
// Swift Package hinzufügen:
//   https://github.com/supabase/supabase-swift  (Branch: main)
//
// WICHTIG: Ersetze die beiden Konstanten unten mit deinen
//          Supabase-Projektdaten (Dashboard → Settings → API)
// ============================================================

import Supabase

// ─────────────────────────────────────────────
// MARK: - Konfiguration
// ─────────────────────────────────────────────
// Supabase Anon-Key ist per Design ein öffentlicher Schlüssel (kein Secret).
// Zugriffskontrolle erfolgt über Row Level Security (RLS) in Supabase.
// Werte kommen aus Debug.xcconfig / Release.xcconfig → Info.plist (nie hardcoden!)
private enum SupabaseConfig {
    // Die URL ist kein Secret – sie ist öffentlich sichtbar und ohne den Anon-Key nutzlos.
    // xcconfig-Werte mit "https://" werden durch das "//" (Kommentar-Syntax) abgeschnitten,
    // daher wird die URL direkt hier hinterlegt.
    static let url = URL(string: "https://qdscsjdklnrtlowvtnnb.supabase.co")!

    // Der Anon-Key kommt aus Debug.xcconfig / Release.xcconfig → Info.plist.
    // Wichtig: den "anon public" Key verwenden, NICHT den "service_role" Key!
    // Fallback: leerer String → Supabase-Client wird initialisiert, aber alle API-Calls schlagen
    // mit einem Auth-Fehler fehl (kein App-Crash). In Debug wird zusätzlich eine Assertion ausgelöst.
    static let anonKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !key.isEmpty, !key.hasPrefix("$(") else {
            assertionFailure("[Supabase] SupabaseAnonKey fehlt in Info.plist / xcconfig – xcconfig korrekt eingebunden?")
            return ""
        }
        return key
    }()
}

// ─────────────────────────────────────────────
// MARK: - DTO-Typen  (Datenbank ↔ Swift)
// ─────────────────────────────────────────────

/// Spiegelt die `trips`-Tabelle wider
struct TripDTO: Codable, Identifiable {
    let id:                 UUID
    let userId:             UUID
    var vehicleProfileId:   UUID?
    var title:              String
    var startDate:          Date
    var endDate:            Date?
    var distanceKm:         Double
    var durationSeconds:    Double
    var avgSpeedKmh:        Double
    var maxSpeedKmh:        Double
    var efficiencyScore:    Int
    var estimatedFuelL:     Double
    var estimatedCostEur:   Double
    var notes:              String
    var fuelPriceAtTrip:    Double
    var fuelPriceSource:    String
    var pointsData:         [TripPointDTO]
    var updatedAt:          Date

    enum CodingKeys: String, CodingKey {
        case id, title, notes
        case userId             = "user_id"
        case vehicleProfileId   = "vehicle_profile_id"
        case startDate          = "start_date"
        case endDate            = "end_date"
        case distanceKm         = "distance_km"
        case durationSeconds    = "duration_seconds"
        case avgSpeedKmh        = "avg_speed_kmh"
        case maxSpeedKmh        = "max_speed_kmh"
        case efficiencyScore    = "efficiency_score"
        case estimatedFuelL     = "estimated_fuel_l"
        case estimatedCostEur   = "estimated_cost_eur"
        case fuelPriceAtTrip    = "fuel_price_at_trip"
        case fuelPriceSource    = "fuel_price_source"
        case pointsData         = "points_data"
        case updatedAt          = "updated_at"
    }

    /// Erstellt DTO aus lokalem SwiftData-Trip
    @MainActor static func from(_ trip: Trip, userId: UUID) -> TripDTO {
        TripDTO(
            id:               trip.id,
            userId:           userId,
            vehicleProfileId: trip.vehicleProfileId,
            title:            trip.title,
            startDate:        trip.startDate,
            endDate:          trip.endDate,
            distanceKm:       trip.distanceKm,
            durationSeconds:  trip.durationSeconds,
            avgSpeedKmh:      trip.avgSpeedKmh,
            maxSpeedKmh:      trip.maxSpeedKmh,
            efficiencyScore:  trip.efficiencyScore,
            estimatedFuelL:   trip.estimatedFuelL,
            estimatedCostEur: trip.estimatedCostEur,
            notes:            trip.notes,
            fuelPriceAtTrip:  trip.fuelPriceAtTrip,
            fuelPriceSource:  trip.fuelPriceSource,
            pointsData:       trip.points.map(TripPointDTO.from),
            updatedAt:        Date()
        )
    }
}

struct TripPointDTO: Codable {
    let timestamp:  Date
    let latitude:   Double
    let longitude:  Double
    let altitude:   Double
    let speedKmh:   Double
    let accuracy:   Double
    let course:     Double

    static func from(_ p: TripPoint) -> TripPointDTO {
        TripPointDTO(
            timestamp: p.timestamp, latitude: p.latitude,
            longitude: p.longitude, altitude: p.altitude,
            speedKmh:  p.speedKmh, accuracy:  p.accuracy,
            course:    p.course
        )
    }
}

/// Spiegelt `vehicle_profiles`-Tabelle
struct VehicleDTO: Codable, Identifiable {
    let id:                   UUID
    let userId:               UUID
    var name:                 String
    var fuelType:             String
    var consumptionPer100km:  Double
    var fuelPricePerLiter:    Double
    var isDefault:            Bool
    var sortOrder:            Int
    /// colorHex ist optional-resilient: falls die Spalte `color_hex` in Supabase
    /// noch nicht existiert, wird ein leerer String als Fallback verwendet.
    /// VehicleProfile.profileColor greift dann automatisch auf fuelColorHex zurück.
    var colorHex:             String
    var updatedAt:            Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case userId              = "user_id"
        case fuelType            = "fuel_type"
        case consumptionPer100km = "consumption_per_100km"
        case fuelPricePerLiter   = "fuel_price_per_liter"
        case isDefault           = "is_default"
        case sortOrder           = "sort_order"
        case colorHex            = "color_hex"
        case updatedAt           = "updated_at"
    }

    // Robuster Decoder: fehlende Spalten (color_hex noch nicht in DB)
    // brechen den gesamten Fetch NICHT ab — Fallback auf leeren String.
    init(from decoder: Decoder) throws {
        let c                = try decoder.container(keyedBy: CodingKeys.self)
        id                   = try c.decode(UUID.self,   forKey: .id)
        userId               = try c.decode(UUID.self,   forKey: .userId)
        name                 = try c.decode(String.self, forKey: .name)
        fuelType             = try c.decode(String.self, forKey: .fuelType)
        consumptionPer100km  = try c.decode(Double.self, forKey: .consumptionPer100km)
        fuelPricePerLiter    = try c.decode(Double.self, forKey: .fuelPricePerLiter)
        isDefault            = try c.decode(Bool.self,   forKey: .isDefault)
        sortOrder            = try c.decode(Int.self,    forKey: .sortOrder)
        updatedAt            = try c.decode(Date.self,   forKey: .updatedAt)
        // decodeIfPresent: kein Crash wenn Spalte fehlt
        colorHex             = (try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? ""
    }

    // Memberwise init für VehicleDTO.from(_:userId:)
    init(id: UUID, userId: UUID, name: String, fuelType: String,
         consumptionPer100km: Double, fuelPricePerLiter: Double,
         isDefault: Bool, sortOrder: Int, colorHex: String, updatedAt: Date) {
        self.id                   = id
        self.userId               = userId
        self.name                 = name
        self.fuelType             = fuelType
        self.consumptionPer100km  = consumptionPer100km
        self.fuelPricePerLiter    = fuelPricePerLiter
        self.isDefault            = isDefault
        self.sortOrder            = sortOrder
        self.colorHex             = colorHex
        self.updatedAt            = updatedAt
    }

    // FIX 4: @MainActor hinzugefügt — VehicleProfile ist ein SwiftData @Model,
    // Zugriff auf Properties ist nur auf dem Main Actor sicher (analog zu TripDTO.from).
    @MainActor static func from(_ v: VehicleProfile, userId: UUID) -> VehicleDTO {
        VehicleDTO(
            id:                   v.id,
            userId:               userId,
            name:                 v.name,
            fuelType:             v.fuelType,
            consumptionPer100km:  v.consumptionPer100km,
            fuelPricePerLiter:    v.fuelPricePerLiter,
            isDefault:            v.isDefault,
            sortOrder:            v.sortOrder,
            colorHex:             v.colorHex,
            updatedAt:            Date()
        )
    }
}

// ─────────────────────────────────────────────
// MARK: - Auth-Status
// ─────────────────────────────────────────────
enum AuthState: Equatable, Hashable {
    case unknown
    case signedOut
    case anonymous
    case signedIn(userId: String, provider: String)
}

// ─────────────────────────────────────────────
// MARK: - Sync-Status
// ─────────────────────────────────────────────
enum SyncState: Equatable {
    case idle
    case syncing
    case success(lastSync: Date)
    case error(String)
}

// ─────────────────────────────────────────────
// MARK: - Auth-Fehler (außerhalb @MainActor — errorDescription muss nonisolated sein)
// ─────────────────────────────────────────────
enum SupabaseLoginError: LocalizedError {
    case invalidCredentials

    var errorDescription: String? {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "de"
        if lang == "en" {
            return "Email or password is incorrect. If you just registered, please open the confirmation email first."
        }
        return "E-Mail oder Passwort ist falsch. Falls du dich gerade registriert hast, bitte zuerst die Bestätigungs-E-Mail öffnen."
    }
}

enum SupabaseAuthError: LocalizedError {
    case emailAlreadyRegistered

    var errorDescription: String? {
        switch self {
        case .emailAlreadyRegistered:
            // Direkter Dictionary-Zugriff ohne @MainActor (L() ist @MainActor-gebunden)
            let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "de"
            if lang == "en" { return "This email address is already registered." }
            return "Diese E-Mail-Adresse ist bereits registriert."
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - SupabaseManager
// ─────────────────────────────────────────────
@MainActor
final class SupabaseManager: NSObject, ObservableObject {

    // Singleton
    static let shared = SupabaseManager()

    // Supabase-Client
    let client = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.anonKey,
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                emitLocalSessionAsInitialSession: true
            )
        )
    )

    // MARK: Published
    @Published var authState:     AuthState  = .unknown
    @Published var syncState:     SyncState  = .idle
    @Published var currentUserId: UUID?
    @Published var displayName:   String     = ""
    @Published var errorMessage:  String?
    @Published var userEmail:      String     = ""
    /// Wird true wenn E-Mail-Registrierung erfolgreich aber Bestätigung aussteht
    @Published var needsEmailConfirmation: Bool = false

    // Apple Sign-In Nonce (Sicherheit)
    private var currentNonce: String?

    // MARK: - Init
    override private init() {
        super.init()
        Task { await restoreSession() }
    }

    // ─────────────────────────────────────────────
    // MARK: Session wiederherstellen
    // ─────────────────────────────────────────────
    func restoreSession() async {
        do {
            let session = try await client.auth.session
            await handleSession(session)
        } catch {
            authState = .signedOut
        }
    }

    private func handleSession(_ session: Session) async {
        currentUserId = UUID(uuidString: session.user.id.uuidString)
        CrashlyticsManager.setUser(id: session.user.id.uuidString)

        // UserDefaults-Schlüssel für SwiftData-Filter in Views
        UserDefaults.standard.set(session.user.id.uuidString, forKey: "currentOwnerUserId")

        let provider = session.user.appMetadata["provider"]?.stringValue ?? "email"
        let isAnon   = session.user.isAnonymous
        userEmail    = session.user.email ?? ""

        if isAnon {
            authState = .anonymous
        } else {
            authState = .signedIn(userId: session.user.id.uuidString, provider: provider)
        }

        // FIX CON-003: fetchProfile() und checkPro() waren sequenziell (Gesamtdauer = A + B).
        // Beide sind voneinander unabhängig → async let startet sie gleichzeitig (Dauer = max(A,B)).
        // Typische Verbesserung: Login-UI erscheint ~400–800 ms früher.
        async let profileFetch: Void = fetchProfile()
        async let proCheck: Void     = SubscriptionManager.shared.checkPro()
        _ = await (profileFetch, proCheck)
    }

    // ─────────────────────────────────────────────
    // MARK: E-Mail Registrierung
    // ─────────────────────────────────────────────
    func signUpWithEmail(email: String, password: String, name: String) async throws {
        needsEmailConfirmation = false

        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["full_name": .string(name)]
            )

            // Wenn identities leer ist, existiert die E-Mail bereits (Supabase-Verhalten
            // bei aktivierter E-Mail-Bestätigung: kein Fehler, aber leere identities)
            if let identities = response.user.identities, identities.isEmpty {
                throw SupabaseAuthError.emailAlreadyRegistered
            }

            if let session = response.session {
                // E-Mail-Bestätigung deaktiviert → sofort angemeldet
                await handleSession(session)
            } else {
                // E-Mail-Bestätigung aktiv → User muss Postfach prüfen
                needsEmailConfirmation = true
            }
            await logDsgvoAction("consent_given", details: ["method": "email_signup"])

        } catch let error as SupabaseAuthError {
            throw error
        } catch {
            // Fange Supabase-Serverfehler mit "already registered" Wortlaut ab
            let msg = error.localizedDescription.lowercased()
            if msg.contains("already registered") || msg.contains("already been registered")
               || msg.contains("email address is already") || msg.contains("user already exists") {
                throw SupabaseAuthError.emailAlreadyRegistered
            }
            CrashlyticsManager.record(error, context: "SupabaseManager - signUpWithEmail")
            throw error
        }
    }

    // ─────────────────────────────────────────────
    // MARK: E-Mail Login
    // ─────────────────────────────────────────────
    func signInWithEmail(email: String, password: String) async throws {
        do {
            let session = try await client.auth.signIn(
                email: email,
                password: password
            )
            await handleSession(session)
            await logDsgvoAction("login", details: ["provider": "email"])
        } catch {
            CrashlyticsManager.record(error, context: "SupabaseManager - signInWithEmail")
            // "invalid login credentials" can mean wrong password OR unconfirmed email.
            // Map to a helpful localized message instead of the raw Supabase error.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("invalid login credentials") || msg.contains("invalid_credentials") {
                throw SupabaseLoginError.invalidCredentials
            }
            throw error
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Apple Sign-In  (Schritt 1: Nonce vorbereiten)
    // ─────────────────────────────────────────────
    func startAppleSignIn() -> ASAuthorizationAppleIDRequest {
        let nonce  = randomNonceString()
        currentNonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request  = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        return request
    }

    /// Schritt 2: Callback nach erfolgreichem Apple Sign-In
    func handleAppleSignIn(result: Result<ASAuthorization, Error>) async {
        // Fehler explizit prüfen und verständlich anzeigen
        if case .failure(let error) = result {
            let nsErr = error as NSError
            // Code=1001 (ASAuthorizationError.canceled) = User hat abgebrochen → still ignorieren
            if nsErr.code == 1001 { return }
            // Code=1000 (ASAuthorizationError.unknown) = Apple ID Problem am Gerät
            // Lösung: Einstellungen → Apple ID → Abmelden & neu anmelden
            if nsErr.code == 1000 {
                errorMessage = L("account.error.apple_device")
            } else if !error.localizedDescription.lowercased().contains("cancel") {
                errorMessage = error.localizedDescription
            }
            return
        }
        guard case .success(let auth) = result,
              let credential = auth.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken,
              let tokenString   = String(data: identityToken, encoding: .utf8),
              let nonce = currentNonce else {
            errorMessage = L("account.error.apple_generic")
            return
        }

        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken:  tokenString,
                    nonce:    nonce
                )
            )
            await handleSession(session)
            await logDsgvoAction("login", details: ["provider": "apple"])
        } catch {
            CrashlyticsManager.record(error, context: "SupabaseManager - handleAppleSignIn")
            errorMessage = error.localizedDescription
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Google Sign-In
    // ─────────────────────────────────────────────
    func signInWithGoogle(presenting viewController: UIViewController) async {
        // CLIENT_ID wird aus der Info.plist gelesen (bereits dort als Xcode-Standard eingetragen).
        // Niemals als String-Literal im Source Code — Info.plist ist die einzige Quelle.
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "CLIENT_ID") as? String,
              !clientID.isEmpty else {
            errorMessage = "Google Sign-In ist nicht konfiguriert. CLIENT_ID fehlt in Info.plist."
            return
        }

        // Nonce generieren: SHA256-Hash → Google, Original → Supabase
        let rawNonce    = randomNonceString()
        let hashedNonce = sha256(rawNonce)

        do {
            let config = GIDConfiguration(clientID: clientID)
            GIDSignIn.sharedInstance.configuration = config

            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: viewController,
                hint: nil,
                additionalScopes: [],
                nonce: hashedNonce          // ← SHA256-Hash an Google
            )

            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Google ID-Token konnte nicht abgerufen werden."
                return
            }

            let session = try await client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .google,
                    idToken:  idToken,
                    nonce:    rawNonce       // ← Original-Nonce (unhashed!) an Supabase
                )
            )
            await handleSession(session)
            await logDsgvoAction("login", details: ["provider": "google"])
        } catch {
            let msg = error.localizedDescription
            if !msg.contains("cancel") && !msg.contains("Cancel") {
                CrashlyticsManager.record(error, context: "SupabaseManager - signInWithGoogle")
                errorMessage = msg
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Anonym / Gast-Login
    // ─────────────────────────────────────────────
    func signInAnonymously() async throws {
        let session = try await client.auth.signInAnonymously()
        await handleSession(session)
    }

    /// Anonymen Account mit E-Mail verknüpfen (Upgrade)
    func linkEmailToAnonymousAccount(email: String, password: String) async throws {
        try await client.auth.update(
            user: UserAttributes(email: email, password: password)
        )
        await restoreSession()
        await logDsgvoAction("account_linked", details: ["method": "email"])
    }

    // ─────────────────────────────────────────────
    // MARK: Passwort zurücksetzen
    // ─────────────────────────────────────────────
    func resetPassword(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
    }

    // ─────────────────────────────────────────────
    // MARK: Abmelden
    // ─────────────────────────────────────────────
    func signOut() async {
        do {
            await logDsgvoAction("logout", details: [:])
            try await client.auth.signOut()
            authState     = .signedOut
            currentUserId = nil
            displayName   = ""
            userEmail     = ""
            CrashlyticsManager.clearUser()
            // currentOwnerUserId löschen → Views zeigen keine Daten mehr
            UserDefaults.standard.removeObject(forKey: "currentOwnerUserId")
            // Pro- und Admin-Status zurücksetzen (Cache leeren)
            SubscriptionManager.shared.setAdminFromServer(false)
            SubscriptionManager.shared.setProFromServer(false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Profil abrufen
    // ─────────────────────────────────────────────
    func fetchProfile() async {
        guard let uid = currentUserId else { return }
        do {
            // Schritt 1: Profil aus DB lesen
            let profiles: [UserProfile] = try await client
                .from("user_profiles")
                .select("id, display_name, email, is_pro, is_admin")
                .eq("id", value: uid.uuidString)
                .execute()
                .value

            if let profile = profiles.first {
                // Profil gefunden → Werte übernehmen
                displayName = profile.displayName ?? profile.email ?? "Nutzer"
                // WICHTIG: Admin ZUERST setzen, dann Pro (Admin überschreibt Pro-Logik)
                let isAdmin = profile.isAdmin ?? false
                SubscriptionManager.shared.setAdminFromServer(isAdmin)
                let isPro = profile.isPro ?? false
                SubscriptionManager.shared.setProFromServer(isPro)
                #if DEBUG
                print("[Supabase] fetchProfile ✓ is_pro=\(isPro) is_admin=\(isAdmin)")
                #endif
            } else {
                // Kein Profil → manuell anlegen (Trigger hat nicht gefeuert)
                #if DEBUG
                print("[Supabase] fetchProfile: kein Profil gefunden, lege an...")
                #endif
                let authUser = try await client.auth.user()
                let email    = authUser.email ?? ""
                let name     = authUser.userMetadata["full_name"]?.stringValue
                            ?? authUser.userMetadata["name"]?.stringValue
                            ?? email
                struct NewProfile: Encodable {
                    let id: String; let email: String
                    let display_name: String; let is_pro: Bool
                }
                try await client
                    .from("user_profiles")
                    .insert(NewProfile(id: uid.uuidString, email: email, display_name: name, is_pro: false))
                    .select("*")
                    .execute()
                displayName = name.isEmpty ? email : name
                // Neuer User → explizit KEIN Pro (verhindert Race Conditions mit Cache)
                SubscriptionManager.shared.setProFromServer(false)
                #if DEBUG
                print("[Supabase] fetchProfile: Profil angelegt, isPro=false")
                #endif
            }
        } catch {
            #if DEBUG
            print("[Supabase] fetchProfile fehlgeschlagen:", error)
            #endif
        }
    }

    // Profil-DTO
    private struct UserProfile: Decodable {
        let displayName: String?
        let email:       String?
        let isPro:       Bool?
        let isAdmin:     Bool?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case email
            case isPro       = "is_pro"
            case isAdmin     = "is_admin"
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Pro-Status in Supabase speichern
    // ─────────────────────────────────────────────
    func setProStatus(_ isPro: Bool) async {
        guard let uid = currentUserId else { return }
        do {
            try await client
                .from("user_profiles")
                .update(["is_pro": isPro])
                .eq("id", value: uid.uuidString)
                .select("*")
                .execute()
        } catch {
            CrashlyticsManager.record(error, context: "SupabaseManager - setProStatus")
            #if DEBUG
            print("[Supabase] setProStatus fehlgeschlagen:", error)
            #endif
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Display Name aktualisieren
    // ─────────────────────────────────────────────
    func updateDisplayName(_ name: String) async throws {
        guard let uid = currentUserId else { return }
        try await client
            .from("user_profiles")
            .update(["display_name": name, "updated_at": ISO8601DateFormatter().string(from: Date())])
            .eq("id", value: uid.uuidString)
            .select("*")
            .execute()
        displayName = name
    }

    // ─────────────────────────────────────────────
    // MARK: CLOUD SYNC — Trips hochladen
    // ─────────────────────────────────────────────
    func syncTrips(_ trips: [Trip]) async {
        guard let userId = currentUserId else { return }
        syncState = .syncing

        do {
            let dtos = trips.map { TripDTO.from($0, userId: userId) }

            // Guard: kein leerer Request nötig
            guard !dtos.isEmpty else {
                syncState = .success(lastSync: Date())
                return
            }

            // .select("*") ist zwingend: ohne es sendet das SDK intern
            // Prefer: return=representation ohne columns-Parameter
            // → PostgREST-Fehler "failed to parse columns parameter ()"
            try await client
                .from("trips")
                .upsert(dtos, onConflict: "id")
                .select("*")
                .execute()

            syncState = .success(lastSync: Date())
        } catch {
            CrashlyticsManager.record(error, context: "SupabaseManager - syncTrips")
            syncState = .error(error.localizedDescription)
        }
    }

    // ─────────────────────────────────────────────
    // MARK: CLOUD SYNC — Trips abrufen
    // ─────────────────────────────────────────────
    func fetchTripsFromCloud() async -> [TripDTO] {
        guard let userId = currentUserId else { return [] }
        do {
            let trips: [TripDTO] = try await client
                .from("trips")
                .select("*")
                .eq("user_id",     value: userId.uuidString)
                .is("deleted_at",  value: nil)
                .order("start_date", ascending: false)
                .execute()
                .value

            return trips
        } catch {
            CrashlyticsManager.record(error, context: "SupabaseManager - fetchTripsFromCloud")
            #if DEBUG
            print("[Supabase] fetchTripsFromCloud fehlgeschlagen:", error)
            #endif
            return []
        }
    }

    // ─────────────────────────────────────────────
    // MARK: CLOUD SYNC — Fahrzeuge hochladen
    //
    // FIX 3: syncState wird jetzt korrekt aktualisiert (vorher stille Fehler).
    // ─────────────────────────────────────────────
    func syncVehicles(_ vehicles: [VehicleProfile]) async {
        guard let userId = currentUserId else { return }
        syncState = .syncing
        do {
            let dtos = vehicles.map { VehicleDTO.from($0, userId: userId) }
            guard !dtos.isEmpty else {
                syncState = .success(lastSync: Date())
                return
            }
            try await client
                .from("vehicle_profiles")
                .upsert(dtos, onConflict: "id")
                .select("*")
                .execute()
            syncState = .success(lastSync: Date())
        } catch {
            CrashlyticsManager.record(error, context: "SupabaseManager - syncVehicles")
            syncState = .error(error.localizedDescription)
            #if DEBUG
            print("[Supabase] syncVehicles fehlgeschlagen:", error)
            #endif
        }
    }

    // ─────────────────────────────────────────────
    // MARK: CLOUD SYNC — Fahrzeuge abrufen
    //
    // HINWEIS: vehicle_profiles hat KEINE deleted_at-Spalte (nur trips hat diese).
    // Daher kein Soft-Delete-Filter hier — alle Fahrzeuge des Users werden geladen.
    // ─────────────────────────────────────────────
    func fetchVehiclesFromCloud() async -> [VehicleDTO] {
        guard let userId = currentUserId else { return [] }
        do {
            let vehicles: [VehicleDTO] = try await client
                .from("vehicle_profiles")
                .select("*")
                .eq("user_id", value: userId.uuidString)
                .order("sort_order", ascending: true)
                .execute()
                .value
            return vehicles
        } catch {
            #if DEBUG
            print("[Supabase] fetchVehiclesFromCloud fehlgeschlagen:", error)
            #endif
            return []
        }
    }

    // ─────────────────────────────────────────────
    // MARK: CLOUD RESTORE — Daten aus Supabase in lokale SwiftData-DB laden
    //
    // FIX 1 + FIX 2: Die Funktion akzeptiert jetzt existingTripCount UND
    // existingVehicleCount und prüft beide unabhängig voneinander.
    // Vorher: guard existingTripCount == 0 → gesamte Funktion wurde
    // übersprungen wenn Fahrten existierten, auch wenn Fahrzeuge fehlten.
    // Jetzt: Fahrten und Fahrzeuge werden unabhängig wiederhergestellt.
    // ─────────────────────────────────────────────
    func restoreFromCloud(into context: ModelContext,
                          existingTripCount: Int,
                          existingVehicleCount: Int) async {
        guard let userId = currentUserId else {
            #if DEBUG
            print("[CloudRestore] Übersprungen: userId=nil")
            #endif
            return
        }

        // Mindestens eine Kategorie muss leer sein damit Restore sinnvoll ist
        let needsTrips    = existingTripCount    == 0
        let needsVehicles = existingVehicleCount == 0

        guard needsTrips || needsVehicles else {
            #if DEBUG
            print("[CloudRestore] Übersprungen: Fahrten=\(existingTripCount), Fahrzeuge=\(existingVehicleCount) – alle lokal vorhanden")
            #endif
            return
        }

        syncState = .syncing
        #if DEBUG
        print("[CloudRestore] Starte Wiederherstellung – needsTrips=\(needsTrips), needsVehicles=\(needsVehicles)")
        #endif

        // 1. Fahrzeuge wiederherstellen (nur wenn lokal keine vorhanden)
        if needsVehicles {
            let vehicleDTOs = await fetchVehiclesFromCloud()

            // Duplikat-Check: bestehende Fahrzeug-IDs aus SwiftData laden
            let existingVehicleIds: Set<UUID> = {
                let descriptor = FetchDescriptor<VehicleProfile>()
                let all = (try? context.fetch(descriptor)) ?? []
                return Set(all.map { $0.id })
            }()

            var insertedVehicles = 0
            for dto in vehicleDTOs {
                guard !existingVehicleIds.contains(dto.id) else {
                    #if DEBUG
                    print("[CloudRestore] Fahrzeug übersprungen (Duplikat): \(dto.id)")
                    #endif
                    continue
                }
                let profile = VehicleProfile(
                    name:         dto.name,
                    fuelType:     dto.fuelType,
                    consumption:  dto.consumptionPer100km,
                    pricePerLiter: dto.fuelPricePerLiter,
                    sortOrder:    dto.sortOrder,
                    colorHex:     dto.colorHex
                )
                profile.id            = dto.id
                profile.isDefault     = dto.isDefault
                profile.ownerUserId   = userId.uuidString
                context.insert(profile)
                insertedVehicles += 1
            }
            #if DEBUG
            print("[CloudRestore] \(insertedVehicles) Fahrzeuge wiederhergestellt (\(vehicleDTOs.count - insertedVehicles) Duplikate übersprungen)")
            #endif
        } else {
            #if DEBUG
            print("[CloudRestore] Fahrzeuge übersprungen: \(existingVehicleCount) lokal vorhanden")
            #endif
        }

        // 2. Trips wiederherstellen (nur wenn lokal keine vorhanden)
        if needsTrips {
            let tripDTOs = await fetchTripsFromCloud()

            // Duplikat-Check: bestehende Trip-IDs aus SwiftData laden
            let existingTripIds: Set<UUID> = {
                let descriptor = FetchDescriptor<Trip>()
                let all = (try? context.fetch(descriptor)) ?? []
                return Set(all.map { $0.id })
            }()

            var insertedTrips = 0
            for dto in tripDTOs {
                guard !existingTripIds.contains(dto.id) else {
                    #if DEBUG
                    print("[CloudRestore] Fahrt übersprungen (Duplikat): \(dto.id)")
                    #endif
                    continue
                }
                let trip = Trip(title: dto.title)
                trip.id               = dto.id
                trip.startDate        = dto.startDate
                trip.endDate          = dto.endDate
                trip.distanceKm       = dto.distanceKm
                trip.durationSeconds  = dto.durationSeconds
                trip.avgSpeedKmh      = dto.avgSpeedKmh
                trip.maxSpeedKmh      = dto.maxSpeedKmh
                trip.efficiencyScore  = dto.efficiencyScore
                trip.estimatedFuelL   = dto.estimatedFuelL
                trip.estimatedCostEur = dto.estimatedCostEur
                trip.notes            = dto.notes
                trip.fuelPriceAtTrip  = dto.fuelPriceAtTrip
                trip.fuelPriceSource  = dto.fuelPriceSource
                trip.vehicleProfileId = dto.vehicleProfileId
                trip.ownerUserId      = userId.uuidString
                // GPS-Punkte aus DTO wiederherstellen
                trip.points = dto.pointsData.map {
                    TripPoint(
                        timestamp: $0.timestamp,
                        latitude:  $0.latitude,
                        longitude: $0.longitude,
                        altitude:  $0.altitude,
                        speedKmh:  $0.speedKmh,
                        accuracy:  $0.accuracy,
                        course:    $0.course
                    )
                }
                context.insert(trip)
                insertedTrips += 1
            }
            #if DEBUG
            print("[CloudRestore] \(insertedTrips) Fahrten wiederhergestellt (\(tripDTOs.count - insertedTrips) Duplikate übersprungen)")
            #endif
        } else {
            #if DEBUG
            print("[CloudRestore] Fahrten übersprungen: \(existingTripCount) lokal vorhanden")
            #endif
        }

        do {
            try context.save()
            syncState = .success(lastSync: Date())
            #if DEBUG
            print("[CloudRestore] ✓ Wiederherstellung abgeschlossen")
            #endif
        } catch {
            syncState = .error(String(format: L("sync.error.save"), error.localizedDescription))
            #if DEBUG
            print("[CloudRestore] ✗ Speichern fehlgeschlagen:", error)
            #endif
        }
    }

    // ─────────────────────────────────────────────
    // MARK: CLOUD SYNC — Einzelnen Trip löschen (Soft)
    //
    // DSGVO Art. 17 (Recht auf Löschung / "Recht auf Vergessenwerden"):
    // Soft-Delete: Das Feld `deleted_at` wird gesetzt. Die Daten verbleiben
    // zunächst in der Datenbank für eine Aufbewahrungsfrist von 90 Tagen,
    // um versehentliche Löschungen rückgängig machen zu können.
    // Nach Ablauf dieser Frist müssen die Daten physisch gelöscht werden.
    //
    // PFLICHT: In Supabase muss ein Cron-Job oder scheduled function eingerichtet sein,
    // der Datensätze mit `deleted_at < NOW() - INTERVAL '90 days'` permanent löscht.
    // Die 90-Tage-Frist ist in der Datenschutzerklärung (Abschnitt 13, Speicherdauer)
    // kommuniziert und muss mit dieser Implementierung übereinstimmen.
    //
    // Für sofortige physische Löschung auf Anfrage des Nutzers: requestAccountDeletion() verwenden.
    // ─────────────────────────────────────────────
    func deleteTripFromCloud(id: UUID) async {
        guard currentUserId != nil else { return }
        do {
            try await client
                .from("trips")
                .update(["deleted_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: id.uuidString)
                .select("*")
                .execute()
            // DSGVO Art. 17: Soft-Delete protokollieren (90-Tage-Frist, danach physische Löschung via Cron-Job)
            await logDsgvoAction("trip_soft_deleted", details: ["trip_id": id.uuidString])
        } catch {
            #if DEBUG
            print("Trip-Löschung fehlgeschlagen:", error)
            #endif
        }
    }

    // ─────────────────────────────────────────────
    // MARK: DSGVO — Alle meine Daten exportieren
    // ─────────────────────────────────────────────
    func exportMyData() async -> Data? {
        do {
            let result: AnyJSON = try await client
                .rpc("export_my_data")
                .execute()
                .value

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(result)
        } catch {
            errorMessage = "\(L("export.error.title")): \(error.localizedDescription)"
            return nil
        }
    }

    // ─────────────────────────────────────────────
    // MARK: DSGVO — Account-Löschung beantragen
    //
    // DSGVO Art. 17 – Recht auf Löschung (physisch, nicht nur Soft-Delete).
    // Die Supabase-RPC-Funktion `request_account_deletion` muss auf Server-Seite:
    //   1. Alle `trips` des Users PERMANENT löschen (inkl. GPS-Punkte in `points_data`)
    //   2. Alle `vehicle_profiles` permanent löschen
    //   3. Den `user_profiles`-Eintrag löschen
    //   4. Den Auth-User in Supabase Auth löschen
    //   5. Den `dsgvo_audit_log` NICHT löschen (gesetzliche Aufbewahrungspflicht für Audit-Logs)
    //
    // Reaktionszeit: innerhalb von 30 Tagen nach Anfrage (Art. 12 Abs. 3 DSGVO).
    // ─────────────────────────────────────────────
    func requestAccountDeletion() async throws {
        try await client
            .rpc("request_account_deletion")
            .execute()

        await signOut()
    }

    // ─────────────────────────────────────────────
    // MARK: DSGVO Audit-Log
    // ─────────────────────────────────────────────
    func logDsgvoAction(_ action: String, details: [String: String]) async {
        guard let userId = currentUserId else { return }
        do {
            try await client
                .from("dsgvo_audit_log")
                .insert([
                    "user_id": userId.uuidString,
                    "action":  action,
                    "details": details.description
                ])
                .select("*")
                .execute()
        } catch {
            // DSGVO-Audit-Log Fehler werden nicht-blockierend behandelt:
            // Ein fehlgeschlagener Log-Eintrag darf keine Kernfunktionalität unterbrechen.
            #if DEBUG
            print("[Supabase] logDsgvoAction fehlgeschlagen:", error)
            #endif
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Deep Link (E-Mail-Bestätigung, Magic Link)
    // URL-Schema: autoperftracker://login-callback
    // Supabase Dashboard → Authentication → URL Configuration
    //   → Redirect URLs: autoperftracker://login-callback
    //   → Site URL:      autoperftracker://login-callback
    // ─────────────────────────────────────────────
    func handleDeepLink(_ url: URL) {
        Task {
            do {
                // Supabase extrahiert Token aus der URL automatisch
                try await client.auth.session(from: url)
                // Session wiederherstellen
                await restoreSession()
                needsEmailConfirmation = false
            } catch {
                errorMessage = "Link ungültig oder abgelaufen: \(error.localizedDescription)"
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Apple Sign-In Hilfsmethoden (Kryptografie)
    // ─────────────────────────────────────────────
    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let inputData  = Data(input.utf8)
        let hashed     = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
