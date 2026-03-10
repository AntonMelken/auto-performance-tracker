import Foundation
import CoreLocation
import CoreMotion
import Combine
import SwiftData
import UIKit
import FirebaseCrashlytics

final class TripRecorder: ObservableObject {

    // MARK: - Published
    @Published var isRecording   = false
    @Published var isPaused      = false
    @Published var currentTrip: Trip?
    @Published var elapsedTime: TimeInterval = 0
    @Published var distanceKm: Double  = 0
    @Published var maxSpeed: Double    = 0
    @Published var currentSpeed: Double = 0
    @Published var pointCount: Int     = 0
    @Published var harshEventCount: Int = 0   // Live: harte Brems-/Beschleunigungsmanöver

    // MARK: - Private
    private let locationService: LocationService
    private var cancellables      = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private var recordedPoints: [TripPoint] = []
    private var modelContext: ModelContext?

    // CoreMotion — 25Hz Beschleunigungs- und Gyro-Daten
    private let motionManager     = CMMotionManager()
    private var motionSamples:    [MotionSample] = []
    // Fahrtrichtungsvektor aus GPS-Heading (wird laufend aktualisiert)
    private var headingRad:       Double = 0   // Radiant, Norden = 0

    // MARK: - Memory-Cap für MotionSamples
    // Harter In-Memory-Cap bei 54.000 Samples (~36 Min. bei 25 Hz).
    // Ist er erreicht, wird das Array SOFORT auf die Hälfte ausgedünnt (Reservoir-Downsampling),
    // bevor neue Batches angehängt werden. Dadurch bleibt der RAM-Verbrauch konstant:
    //   Max. ~54.000 × 48 Bytes ≈ 2.6 MB — unabhängig von der Fahrtdauer.
    // Ohne Cap: 8h-Fahrt bei 25 Hz = 720.000 × 48 = 33 MB nur für Motion-Daten,
    //           plus bis zu ~96 MB JSON-Encoding → OOM-Kill auf älteren Geräten.
    private let maxMotionSamplesCap = 54_000

    // MARK: - GPS Precision Settings
    // 2m Mindestabstand → sehr glatte Linien, keine Kreu­zungs-Artefakte
    private let minPointDistanceM: Double = 2
    // 0.2s Mindestzeit → max 5 GPS-Punkte/Sek., verhindert Datenlawinen
    private let minPointIntervalS: Double = 0.2
    private var lastPointTime: Date = .distantPast

    // Pause-Snapshot
    private var distanceAtPause: Double = 0

    init(locationService: LocationService) {
        self.locationService = locationService
        subscribeToLocations()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        timer?.invalidate()
    }

    func setContext(_ ctx: ModelContext) {
        self.modelContext = ctx
    }

    // MARK: - Public API

    func startRecording(vehicleProfile: VehicleProfile? = nil) {
        // FIX BUG-001: Idempotenz-Guard – verhindert doppelten Aufruf (z. B. schneller
        // Doppel-Tap, Hintergrund-Resume-Race). Ohne diesen Guard würde currentTrip
        // überschrieben und die laufende Fahrt orphaned – Nutzerdaten gehen verloren.
        guard !isRecording, currentTrip == nil else {
            CrashlyticsManager.log("[TripRecorder] startRecording() ignoriert – Aufnahme bereits aktiv")
            return
        }
        let trip = Trip()
        trip.vehicleProfileId   = vehicleProfile?.id
        trip.vehicleProfileName = vehicleProfile?.name ?? ""
        // Account-Isolation: Fahrt dem aktuell eingeloggten User zuordnen
        trip.ownerUserId        = UserDefaults.standard.string(forKey: "currentOwnerUserId") ?? ""
        currentTrip    = trip
        isRecording    = true
        isPaused       = false
        elapsedTime    = 0
        distanceKm     = 0
        maxSpeed       = 0
        currentSpeed   = 0
        pointCount     = 0
        harshEventCount = 0
        recordedPoints = []
        motionSamples  = []
        headingRad     = 0
        lastLocation   = nil
        lastPointTime  = .distantPast
        distanceAtPause = 0

        if let ctx = modelContext {
            ctx.insert(trip)
            do {
                try ctx.save()
            } catch {
                CrashlyticsManager.record(error, context: "TripRecorder - startRecording - ctx.save")
            }
        }

        locationService.startTracking()
        startMotionTracking()
        startTimer()

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        distanceAtPause = distanceKm
        locationService.stopTracking()
        motionManager.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        isPaused = false
        lastLocation  = nil
        lastPointTime = .distantPast
        locationService.startTracking()
        startMotionTracking()
        startTimer()

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func stopRecording(vehicleProfile: VehicleProfile? = nil) -> Trip? {
        guard let trip = currentTrip else { return nil }

        isRecording = false
        isPaused    = false
        locationService.stopTracking()
        motionManager.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let isElectric = vehicleProfile?.isElectric == true
        let fuelL   = vehicleProfile?.estimatedFuel(forKm: distanceKm)  ?? 0
        let costEur = vehicleProfile?.estimatedCost(forKm: distanceKm)  ?? 0

        trip.finalize(points: recordedPoints,
                      distanceKm: distanceKm,
                      fuelL: fuelL,
                      costEur: costEur,
                      isElectric: isElectric,
                      vehicleName: vehicleProfile?.name ?? "",
                      vehicleFuelType: vehicleProfile?.fuelType ?? "",
                      motionSamples: downsampleMotionSamples(motionSamples))

        if let ctx = modelContext {
            do {
                try ctx.save()
            } catch {
                CrashlyticsManager.record(error, context: "TripRecorder - stopRecording - ctx.save")
            }
        }

        // Fahrt lokal festhalten BEVOR currentTrip genullt wird
        let savedTrip   = currentTrip
        currentTrip     = nil
        recordedPoints  = []

        // Cloud-Sync — erst nach lokalem Speichern
        let syncEnabled = UserDefaults.standard.bool(forKey: "cloudSyncEnabled")
        if syncEnabled, let tripToSync = savedTrip {
            Task { @MainActor in
                await SupabaseManager.shared.syncTrips([tripToSync])
                if case .error(let msg) = SupabaseManager.shared.syncState {
                    CrashlyticsManager.log("TripRecorder - Cloud-Sync fehlgeschlagen: \(msg)")
                }
            }
        }

        // Anonyme Statistik senden (Opt-In)
        AnalyticsService.shared.trackTrip(
            distanceKm: distanceKm,
            fuelL: fuelL,
            efficiencyScore: trip.efficiencyScore
        )

        // Post-Trip-Benachrichtigungen planen
        if let completedTrip = savedTrip {
            Task { @MainActor in
                NotificationService.shared.schedulePostTripTip(for: completedTrip)
                // Share-Prompt bei ausgezeichneter Fahrt (Score ≥ 80), max 1× pro Tag
                NotificationService.shared.scheduleSharePromptIfExcellent(for: completedTrip)
                let count = UserDefaults.standard.integer(forKey: "notifTripCount") + 1
                UserDefaults.standard.set(count, forKey: "notifTripCount")
                if count % 5 == 0 && !SubscriptionManager.shared.isPro {
                    NotificationService.shared.scheduleProUpsell(context: .tripMilestone(count))
                }
            }
        }

        return savedTrip
    }

    // MARK: - Location Handling

    private func subscribeToLocations() {
        locationService.locationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loc in self?.handleLocation(loc) }
            .store(in: &cancellables)
    }

    private func handleLocation(_ loc: CLLocation) {
        guard isRecording, !isPaused else { return }

        let rawSpeed = max(0, loc.speed * 3.6)
        currentSpeed = rawSpeed

        // SpeedLimit bei jedem GPS-Update aktualisieren (unabhängig vom Distanzfilter)
        SpeedLimitService.shared.update(location: loc)

        let timeSinceLast = loc.timestamp.timeIntervalSince(lastPointTime)
        guard timeSinceLast >= minPointIntervalS else { return }

        if let last = lastLocation {
            let deltaM = last.distance(from: loc)
            guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 65 else { return }
            if deltaM < minPointDistanceM && recordedPoints.count > 2 { return }
            if deltaM > 500 { return }
            distanceKm += deltaM / 1000.0
        }

        // SpeedLimit pro Punkt cachen (nur verfügbar wenn Pro + SpeedLimitService aktiv)
        let currentLimit = SpeedLimitService.shared.currentLimit

        let point = TripPoint(from: loc, speedLimit: currentLimit)

        // GPS-Heading für CoreMotion-Achsenausrichtung aktualisieren
        if loc.course >= 0 { headingRad = loc.course * .pi / 180.0 }

        // Live-Ereigniserkennung: harte Beschleunigung / Bremsung
        if let lastPt = recordedPoints.last {
            let dt = loc.timestamp.timeIntervalSince(lastPt.timestamp)
            if dt > 0.3 && dt < 10 {
                let dv = (point.speedKmh - lastPt.speedKmh) / 3.6
                let accel = dv / dt
                if accel > 3.5 || accel < -4.0 { harshEventCount += 1 }
            }
        }

        recordedPoints.append(point)
        pointCount    = recordedPoints.count
        lastPointTime = loc.timestamp

        if rawSpeed > maxSpeed { maxSpeed = rawSpeed }
        lastLocation = loc
    }

    // MARK: - CoreMotion

    private func startMotionTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 25.0  // 25 Hz – ausreichend für Score, halbe CPU-Last

        let queue = OperationQueue()
        queue.qualityOfService = .utility  // .utility statt .userInteractive: kein Main-Thread-Druck
        queue.maxConcurrentOperationCount = 1

        // Batch-Buffer: sammelt 25 Samples (= 1 Sek.) vor dem Main-Dispatch
        var batchBuffer: [MotionSample] = []
        batchBuffer.reserveCapacity(25)

        motionManager.startDeviceMotionUpdates(
            using: .xTrueNorthZVertical,  // X = Nord, Y = Ost, Z = oben → GPS-Heading direkt anwendbar
            to: queue
        ) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }

            // FIX BUG-003: isRecording / isPaused sind @Published und werden vom Main Thread
            // geschrieben. Ein direkter Read hier (OperationQueue-Thread) erzeugt einen Swift-6-
            // Data-Race. Fix: Guard wird in den Main-Thread-Dispatch verlagert (siehe unten).
            // Der Background-Callback sammelt nur Samples – er entscheidet nicht über Aktiv/Inaktiv.

            // FIX BUG-003 ERGÄNZUNG: headingRad wird ebenfalls vom Main Thread geschrieben
            // (handleLocation läuft via .receive(on: DispatchQueue.main)).
            // Snapshot via withUnsafeCurrentTask vermeiden — stattdessen atomar auf nonisolated
            // private(set) zugreifen. Einfachste Swift-5.9-sichere Lösung: Wert in den
            // lokalen Stack kopieren bevor wir rechnen (keine Synchronisation nötig da Double
            // 8-Byte-aligned und auf ARM64 atomar lesbar).
            let headingSnapshot = self.headingRad   // ← atomarer Snapshot: verhindert tearing

            let ua = motion.userAcceleration  // gravity-bereinigt, in Gerätekoordinaten

            // ── Schritt 1: Device Frame → Erd-Frame via Rotationsmatrix ──────────────
            let R = motion.attitude.rotationMatrix
            let earthX = R.m11 * ua.x + R.m12 * ua.y + R.m13 * ua.z  // Ost-Komponente
            let earthY = R.m21 * ua.x + R.m22 * ua.y + R.m23 * ua.z  // Nord-Komponente

            // ── Schritt 2: Erd-Frame → Fahrzeug-Frame via GPS-Heading ────────────────
            let cosH = cos(headingSnapshot)
            let sinH = sin(headingSnapshot)
            let longG = earthX * sinH + earthY * cosH   // Längsachse: vorwärts positiv
            let latG  = earthX * cosH - earthY * sinH   // Querachse: rechts positiv

            let sample = MotionSample(
                timestamp:  motion.timestamp > 0
                    ? Date(timeIntervalSinceNow: -(Date().timeIntervalSinceNow - motion.timestamp))
                    : Date(),
                longAccel:  longG  * 9.81,   // g → m/s²
                latAccel:   latG   * 9.81,
                vertAccel:  ua.z   * 9.81,
                yawRate:    motion.rotationRate.z
            )

            batchBuffer.append(sample)

            // Alle 25 Samples (= 1 Sekunde) gebündelt auf Main-Thread dispatchen
            if batchBuffer.count >= 25 {
                let batch = batchBuffer
                batchBuffer.removeAll(keepingCapacity: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRecording, !self.isPaused else { return }

                    // ── Memory-Cap: Echtzeit-Downsampling ─────────────────────────────
                    // Ist der Cap erreicht, wird das Array SOFORT auf die Hälfte
                    // ausgedünnt (jeden 2. Sample behalten). Danach wird der neue
                    // Batch normal angehängt. Effekt: konstanter RAM-Verbrauch,
                    // egal wie lange die Fahrt dauert.
                    //
                    // 54.000 × 48 Bytes ≈ 2.6 MB max. in RAM während der Aufnahme.
                    // Ohne Cap: 8h-Fahrt = 720.000 × 48 = 33 MB + ~96 MB JSON → OOM.
                    if self.motionSamples.count + batch.count > self.maxMotionSamplesCap {
                        // Stride-Downsampling: jeden 2. Eintrag behalten
                        self.motionSamples = stride(
                            from: 0,
                            to: self.motionSamples.count,
                            by: 2
                        ).map { self.motionSamples[$0] }
                    }
                    self.motionSamples.append(contentsOf: batch)
                }
            }
        }
    }

    // MARK: - Motion Downsampling

    /// Reduziert Motion-Samples auf maximal 54.000 Einträge (~36 Min. bei 25 Hz).
    /// Bei längeren Fahrten werden gleichmäßig verteilte Samples ausgewählt,
    /// sodass die zeitliche Abdeckung erhalten bleibt (Beschleunigungs-/Bremsereignisse
    /// über die gesamte Fahrtdauer werden nicht verloren).
    /// Beispiel: 8h-Fahrt = 720.000 Samples → auf 54.000 ausgedünnt = 1 von je ~13.
    private func downsampleMotionSamples(_ samples: [MotionSample]) -> [MotionSample] {
        let maxSamples = 54_000
        guard samples.count > maxSamples else { return samples }
        let step = Double(samples.count) / Double(maxSamples)
        return (0..<maxSamples).map { i in
            samples[min(Int(Double(i) * step), samples.count - 1)]
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.elapsedTime += 1
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: - Formatierungen

    var formattedTime: String {
        let h = Int(elapsedTime) / 3600
        let m = (Int(elapsedTime) % 3600) / 60
        let s = Int(elapsedTime) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var formattedDistance: String { String(format: "%.1f", distanceKm) }
    var formattedMaxSpeed: String { String(format: "%.0f", maxSpeed) }
}
