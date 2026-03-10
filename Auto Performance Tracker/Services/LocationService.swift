import CoreLocation
import Combine
import FirebaseCrashlytics

final class LocationService: NSObject, ObservableObject {

    // MARK: - Published
    @Published var currentSpeed: Double = 0
    @Published var currentLocation: CLLocation?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var accuracy: Double = 0
    @Published var isTracking = false

    let locationPublisher = PassthroughSubject<CLLocation, Never>()

    // MARK: - Private
    private let manager = CLLocationManager()

    /// Speed-Glättung: letzten N Werte mitteln damit kein Flackern
    private var speedBuffer: [Double] = []
    private let speedBufferSize = 3

    private static let hasBackgroundLocationCapability: Bool = {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else { return false }
        return modes.contains("location")
    }()

    override init() {
        super.init()
        manager.delegate = self
        // Wichtig: Kein startUpdatingLocation() hier.
        // GPS-Hardware bleibt komplett aus bis startTracking() aufgerufen wird.
        applyIdleConfiguration()
    }

    // MARK: - Public API

    func requestPermission() {
        // Nur Permission-Dialog anzeigen — KEIN startUpdatingLocation.
        // Verhindert, dass das Öffnen der RecordingView die GPS-Hardware aktiviert.
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Aktualisiert authStatus wenn der User aus den iOS-Einstellungen zurückkommt.
    /// CLLocationManager liefert keinen automatischen Callback wenn sich die Berechtigung
    /// außerhalb der App ändert — daher manueller Poll bei scenePhase == .active.
    func refreshAuthorizationStatus() {
        let current = manager.authorizationStatus
        if authStatus != current {
            authStatus = current
        }
        // Falls Tracking läuft und Berechtigung auf "Always" hochgestuft wurde →
        // Hintergrund-Tracking sofort aktivieren ohne Neustart der Aufnahme
        if current == .authorizedAlways && isTracking {
            applyBackgroundTracking()
        }
    }

    func startTracking() {
        guard !isTracking else { return }
        isTracking  = true
        speedBuffer = []
        applyTrackingConfiguration()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        speedBuffer = []
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        if Self.hasBackgroundLocationCapability {
            manager.allowsBackgroundLocationUpdates = false
        }
        // Zurück auf energiesparende Idle-Konfiguration
        applyIdleConfiguration()
    }

    // MARK: - Konfigurationen

    /// Idle-Modus: minimale Manager-Einstellungen, kein Update-Stream.
    /// Kein messbarer Batterieverbrauch durch Location-Hardware.
    private func applyIdleConfiguration() {
        manager.desiredAccuracy                    = kCLLocationAccuracyReduced
        manager.distanceFilter                     = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = true   // iOS darf bei Stillstand pausieren
        manager.activityType                       = .other
        manager.headingFilter                      = 15
    }

    /// Tracking-Modus: maximale Genauigkeit, kein automatisches Pausieren.
    private func applyTrackingConfiguration() {
        manager.desiredAccuracy                    = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter                     = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false  // Kein Unterbrechen während Aufnahme
        manager.activityType                       = .automotiveNavigation
        manager.headingFilter                      = 5
        applyBackgroundTracking()
    }

    private func applyBackgroundTracking() {
        guard Self.hasBackgroundLocationCapability else { return }
        guard manager.authorizationStatus == .authorizedAlways else { return }
        manager.allowsBackgroundLocationUpdates    = true
        manager.showsBackgroundLocationIndicator   = true
    }

    /// Geglättete Geschwindigkeit (Durchschnitt der letzten N Messwerte)
    private func smoothedSpeed(_ raw: Double) -> Double {
        speedBuffer.append(raw)
        if speedBuffer.count > speedBufferSize { speedBuffer.removeFirst() }
        return speedBuffer.reduce(0, +) / Double(speedBuffer.count)
    }

    var signalBars: Int {
        switch accuracy {
        case ..<10: return 4
        case ..<20: return 3
        case ..<50: return 2
        default:    return 1
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationService: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Nur während aktivem Tracking verarbeiten — kein Drain im Idle-Modus
        guard isTracking else { return }

        for loc in locations {
            guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy <= 100 else { continue }
            guard loc.timestamp.timeIntervalSinceNow > -3 else { continue }

            currentLocation = loc
            let rawSpeed    = max(0, loc.speed * 3.6)

            // Geglättete Geschwindigkeit NUR für Live-Anzeige
            currentSpeed = smoothedSpeed(rawSpeed)
            accuracy     = loc.horizontalAccuracy

            // Ungefilterte CLLocation für Score-Berechnung publishen
            locationPublisher.send(loc)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        if authStatus == .authorizedAlways && isTracking {
            applyBackgroundTracking()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let err = error as? CLError
        if err?.code == .locationUnknown { return }
        #if DEBUG
        print("[LocationService] Fehler: \(error.localizedDescription)")
        #endif
        CrashlyticsManager.record(error, context: "LocationService - didFailWithError")
    }
}
