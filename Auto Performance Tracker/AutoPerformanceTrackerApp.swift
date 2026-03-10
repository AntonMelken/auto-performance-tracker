import SwiftUI
import SwiftData
import FirebaseCore
import GoogleSignIn
import UserMessagingPlatform
import UserNotifications

@main
struct AutoPerformanceTrackerApp: App {

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationService: LocationService
    @StateObject private var recorder: TripRecorder

    @AppStorage("analyticsConsentShown") private var consentShown = false
    @AppStorage("hasSeenOnboarding")     private var hasSeenOnboarding = false
    @AppStorage("attRequested")          private var attRequested = false
    @AppStorage("appColorScheme")        private var appColorScheme = "dark"

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark":  return .dark
        case "light": return .light
        default:      return nil
        }
    }

    @State private var showAnalyticsConsent = false
    @State private var showSplash = true
    @State private var showChangelog = false

    init() {
        FirebaseApp.configure()
        MetricsManager.shared.register()

        UserDefaults.standard.register(defaults: ["cloudSyncEnabled": false])

        let ls = LocationService()
        _locationService = StateObject(wrappedValue: ls)
        _recorder        = StateObject(wrappedValue: TripRecorder(locationService: ls))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                (appColorScheme == "light" ? Color(hex: "F2F4F8") : Color(hex: "080C14"))
                    .ignoresSafeArea()
                ContentView()
                    .environmentObject(locationService)
                    .environmentObject(recorder)
                    .environmentObject(SupabaseManager.shared)
                    // FIX ARCH-003: Alle Singleton-ObservableObjects über den Environment-Tree
                    // injiziert statt @ObservedObject = .shared in jeder View.
                    // Vorteile: testbar (Mocks injizierbar), kein duplizierter Besitz,
                    // SwiftUI-idiomatisch.
                    .environmentObject(SubscriptionManager.shared)
                    .environmentObject(LanguageManager.shared)
                    .environmentObject(ChangelogService.shared)
                    .environmentObject(SpeedLimitService.shared)
                    .environmentObject(NearbyStationsService.shared)
                    .environmentObject(NotificationService.shared)
                    .modelContainer(for: [Trip.self, VehicleProfile.self, FuelPriceEntry.self])
                    .preferredColorScheme(preferredScheme)
                    .sheet(isPresented: $showAnalyticsConsent) {
                        AnalyticsConsentView { showAnalyticsConsent = false }
                    }
                    .sheet(isPresented: $showChangelog) {
                        ChangelogView()
                            .environmentObject(ChangelogService.shared)
                    }
                    .onChange(of: showSplash) { _, visible in
                        // Wenn Splash verschwindet und Nutzer Onboarding gesehen hat →
                        // Changelog nur anzeigen wenn ungelesen (nicht beim ersten App-Start)
                        guard !visible, hasSeenOnboarding else { return }
                        if ChangelogService.shared.hasUnread {
                            // Kleines Delay, damit der Splash-Übergang abgeschlossen ist
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showChangelog = true
                            }
                            // Update-Benachrichtigung für später planen
                            NotificationService.shared.scheduleUpdateNotification()
                        }
                    }
                    .onAppear {
                        AdMobManager.shared.initialize {
                            if self.hasSeenOnboarding && !self.attRequested {
                                self.attRequested = true
                                AdMobManager.shared.requestTrackingPermission()
                            }
                        }

                        if !consentShown {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                                showAnalyticsConsent = true
                            }
                        }

                        // Delegate setzen damit Benachrichtigungen im Vordergrund angezeigt werden
                        UNUserNotificationCenter.current().delegate = NotificationService.shared

                        // Erlaubnisstatus aktualisieren; falls noch nie angefragt → Permission-Dialog zeigen
                        Task {
                            await NotificationService.shared.refreshPermissionStatus()
                            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                            if status == .notDetermined && self.hasSeenOnboarding {
                                await NotificationService.shared.requestPermission()
                            }
                        }
                    }
                    .onChange(of: hasSeenOnboarding) { _, seen in
                        if seen && !attRequested {
                            attRequested = true
                            AdMobManager.shared.requestTrackingPermission()
                        }
                        // Benachrichtigungs-Erlaubnis nach Onboarding anfragen
                        if seen {
                            Task {
                                await NotificationService.shared.requestPermission()
                            }
                        }
                    }
                    .onOpenURL { url in
                        if GIDSignIn.sharedInstance.handle(url) { return }
                        SupabaseManager.shared.handleDeepLink(url)
                    }

                if showSplash {
                    SplashView(isVisible: $showSplash)
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSplash)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                AnalyticsService.shared.trackAppOpened()
                Task { await SubscriptionManager.shared.loadProducts() }
                // App-Öffnung festhalten und Engagement-Erinnerungen neu planen
                NotificationService.shared.recordAppOpen()
                NotificationService.shared.rescheduleEngagementReminders()
                // Fahr-Erkennungsbenachrichtigung abbrechen (App ist wieder aktiv)
                NotificationService.shared.cancelDrivingDetectionNotification()
                // Location-Berechtigung aktualisieren — falls User in iOS-Einstellungen
                // die Berechtigung nachträglich erteilt oder widerrufen hat
                locationService.refreshAuthorizationStatus()
                // Erlaubnisstatus nach Einstellungen-Öffnung aktualisieren
                Task {
                    await NotificationService.shared.refreshPermissionStatus()
                }
            } else if phase == .background {
                // Fahr-Erkennung planen wenn Geschwindigkeit > 15 km/h und keine aktive Aufnahme
                if locationService.currentSpeed > 15 && !recorder.isRecording {
                    NotificationService.shared.scheduleDrivingDetectionNotification()
                }
            }
        }
    }
}
