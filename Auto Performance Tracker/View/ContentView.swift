import SwiftUI
import SwiftData

// ─────────────────────────────────────────────────────────────
// ContentView.swift
// App-Flow: Splash → Auth → Onboarding → Haupt-App
// ─────────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var tripRecorder: TripRecorder

    @AppStorage("hasChosenLanguage")     private var hasChosenLanguage = false
    @AppStorage("hasSeenOnboarding")     private var hasSeenOnboarding = false
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false
    @AppStorage("ageGatePassed")         private var ageGatePassed = false
    @Environment(\.colorScheme) private var cs

    @EnvironmentObject private var supabase: SupabaseManager
    @EnvironmentObject private var lang: LanguageManager

    var body: some View {
        ZStack {
            // ── 0. Sprachauswahl: absolut erster Screen ───────────────
            if !hasChosenLanguage {
                LanguagePickerView()
                    .transition(.opacity)
            // ── 1. Age Gate ───────────────────────────────────────────
            } else if !ageGatePassed {
                AgeGateView()
                    .id(lang.current)
                    .transition(.opacity)
            // ── 2. Disclaimer ─────────────────────────────────────────
            } else if !hasAcceptedDisclaimer {
                DisclaimerView()
                    .id(lang.current)
                    .transition(.opacity)
            } else {
                switch supabase.authState {

                // ── 1. Unbekannt: Supabase stellt Session wieder her ──
                case .unknown:
                    Theme.bg(cs).ignoresSafeArea()
                    ProgressView()
                        .tint(.cyan)
                        .scaleEffect(1.4)

                // ── 2. Nicht angemeldet: Auth-Screen ──
                case .signedOut:
                    AuthFlowView()
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))

                // ── 3. Angemeldet (auch anonym): Onboarding oder Haupt-App ──
                case .anonymous, .signedIn:
                    if !hasSeenOnboarding {
                        OnboardingView()
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    } else {
                        MainTabView()
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: hasChosenLanguage)
        .animation(.easeInOut(duration: 0.35), value: ageGatePassed)
        .animation(.easeInOut(duration: 0.35), value: hasAcceptedDisclaimer)
        .animation(.easeInOut(duration: 0.35), value: supabase.authState)
        .animation(.easeInOut(duration: 0.35), value: hasSeenOnboarding)
        // Auto-Sync bei Login — längeres Delay damit SwiftData sicher geladen ist
        .onChange(of: supabase.authState) { _, newState in
            if case .signedIn = newState {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    NotificationCenter.default.post(name: .autoSyncTriggered, object: nil)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Notification Name
// ─────────────────────────────────────────────────────────────
extension Notification.Name {
    static let autoSyncTriggered   = Notification.Name("autoSyncTriggered")
    static let notificationDeepLink = Notification.Name("notificationDeepLink")
}

// ─────────────────────────────────────────────────────────────
// MARK: - Auth-Flow-Wrapper (eigenständige Seite, nicht Sheet)
// ─────────────────────────────────────────────────────────────

struct AuthFlowView: View {
    @State private var selectedTab: AccountTab = .login
    @Environment(\.colorScheme) private var cs

    var body: some View {
        ZStack {
            Theme.bg(cs).ignoresSafeArea()
            AuthView(selectedTab: $selectedTab)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Haupt-Tab-View (ausgelagert für Übersichtlichkeit)
// ─────────────────────────────────────────────────────────────

struct MainTabView: View {
    // SwiftData Zugriff für Auto-Sync
    @Query(sort: \Trip.startDate, order: .reverse) private var trips:    [Trip]
    @Query private var vehicles: [VehicleProfile]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var cs

    @EnvironmentObject private var supabase: SupabaseManager
    @EnvironmentObject private var lang: LanguageManager
    @AppStorage("currentOwnerUserId") private var currentOwnerUserId: String = ""
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @AppStorage("shouldOpenPaywall") private var shouldOpenPaywall: Bool = false
    @AppStorage("deepLinkTripId") private var deepLinkTripId: String = ""
    @State private var isSyncing = false
    @State private var showSyncError = false
    @State private var syncErrorMessage = ""

    /// Nur eigene Trips syncen (RLS-Schutz: nie fremde Daten hochladen)
    private var myTrips: [Trip] {
        guard !currentOwnerUserId.isEmpty else { return [] }
        return trips.filter { $0.ownerUserId == currentOwnerUserId }
    }

    private var myVehicles: [VehicleProfile] {
        guard !currentOwnerUserId.isEmpty else { return [] }
        return vehicles.filter { $0.ownerUserId == currentOwnerUserId }
    }

    /// Verwaiste Einträge (vor Account-System erstellt) dem aktuellen User zuordnen
    private func claimOrphanedData(userId: String) {
        guard !userId.isEmpty else { return }
        let orphanedTrips    = trips.filter    { $0.ownerUserId.isEmpty }
        let orphanedVehicles = vehicles.filter { $0.ownerUserId.isEmpty }
        guard !orphanedTrips.isEmpty || !orphanedVehicles.isEmpty else { return }
        orphanedTrips.forEach    { $0.ownerUserId = userId }
        orphanedVehicles.forEach { $0.ownerUserId = userId }
        try? modelContext.save()
        print("[Account] \(orphanedTrips.count) Fahrten + \(orphanedVehicles.count) Fahrzeuge → userId \(userId) zugeordnet")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            RecordingView()
                .tabItem { Label(L("tab.recording"), systemImage: "record.circle") }
                .tag(0)

            TripListView()
                .tabItem { Label(L("tab.trips"), systemImage: "list.bullet.rectangle") }
                .tag(1)

            StatisticsView()
                .tabItem { Label(L("tab.statistics"), systemImage: "chart.bar.xaxis") }
                .tag(2)

            SettingsView()
                .tabItem { Label(L("tab.settings"), systemImage: "gearshape") }
                .tag(3)
        }
        .tint(.cyan)
        .background(Theme.bg(cs))
        .toolbarBackground(Theme.bg(cs), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        // Auto-Sync empfangen
        .onReceive(NotificationCenter.default.publisher(for: .autoSyncTriggered)) { _ in
            guard !isSyncing else { return }
            isSyncing = true
            Task {
                // FIX 1 + FIX 2: Trips und Fahrzeuge UNABHÄNGIG prüfen.
                // Vorher: `trips.isEmpty && vehicles.isEmpty` → Fahrzeuge wurden nie
                // wiederhergestellt wenn Fahrten bereits lokal existierten.
                // Jetzt: Restore läuft wenn EINE der beiden Kategorien leer ist.
                let localTripsCount    = myTrips.count
                let localVehicleCount  = myVehicles.count
                let needsRestore       = localTripsCount == 0 || localVehicleCount == 0

                if needsRestore {
                    await supabase.restoreFromCloud(
                        into: modelContext,
                        existingTripCount:    localTripsCount,
                        existingVehicleCount: localVehicleCount
                    )
                }

                // Lokale Daten hochladen (nur wenn angemeldet, nicht anonym)
                // Snapshot NACH dem Restore: @Query-Werte wurden durch context.save()
                // bereits aktualisiert, da wir auf dem MainActor sind.
                if case .signedIn = supabase.authState {
                    await supabase.syncTrips(myTrips)
                    await supabase.syncVehicles(myVehicles)
                }
                isSyncing = false
                // Sync-Fehler dem User anzeigen
                if case .error(let msg) = supabase.syncState {
                    syncErrorMessage = msg
                    showSyncError = true
                }
                #if DEBUG
                print("[AutoSync] Fertig: \(myTrips.count) Fahrten, \(myVehicles.count) Fahrzeuge")
                #endif
            }
        }
        // Deep Link aus Notification-Tap
        .onReceive(NotificationCenter.default.publisher(for: .notificationDeepLink)) { notif in
            if let tab = notif.userInfo?["tab"] as? Int {
                selectedTab = tab
            }
            if let tripId = notif.userInfo?["tripId"] as? String, !tripId.isEmpty {
                deepLinkTripId = tripId
            }
            if let action = notif.userInfo?["action"] as? String {
                if action == "paywall" {
                    shouldOpenPaywall = true
                }
            }
        }
        // Verwaiste Daten beim Login beanspruchen
        .onChange(of: currentOwnerUserId) { _, uid in
            if !uid.isEmpty { claimOrphanedData(userId: uid) }
        }
        .onAppear {
            if !currentOwnerUserId.isEmpty { claimOrphanedData(userId: currentOwnerUserId) }
            // Statistik-Benachrichtigungen mit echten Daten planen
            NotificationService.shared.scheduleStatisticsReports(trips: myTrips)
        }
        .alert(L("sync.error.title"), isPresented: $showSyncError) {
            Button(L("common.ok"), role: .cancel) { showSyncError = false }
            Button(L("sync.error.retry")) {
                showSyncError = false
                NotificationCenter.default.post(name: .autoSyncTriggered, object: nil)
            }
        } message: {
            Text(L("sync.error.message"))
        }
    }
}
