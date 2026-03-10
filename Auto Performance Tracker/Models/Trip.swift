import Foundation
import SwiftData
import CoreLocation
import SwiftUI

// MARK: - Unified Speed Color Palette (used everywhere in the app)
enum SpeedColor: String, Codable, CaseIterable, Sendable {
    case green, blue, amber, orange, red

    var swiftUIColor: Color {
        switch self {
        case .green:  return Color(hex: "22C55E")
        case .blue:   return Color(hex: "3B82F6")
        case .amber:  return Color(hex: "F59E0B")
        case .orange: return Color(hex: "FB923C")
        case .red:    return Color(hex: "EF4444")
        }
    }

    var label: String {
        switch self {
        case .green:  return L("speed.city")
        case .blue:   return L("speed.local")
        case .amber:  return L("speed.country")
        case .orange: return L("speed.express")
        case .red:    return L("speed.highway")
        }
    }

    var icon: String {
        switch self {
        case .green:  return "building.2.fill"
        case .blue:   return "light.beacon.max.fill"
        case .amber:  return "road.lanes"
        case .orange: return "bolt.fill"
        case .red:    return "gauge.with.needle.fill"
        }
    }

    var rangeLabel: String {
        switch self {
        case .green:  return "< 30"
        case .blue:   return "30–50"
        case .amber:  return "50–80"
        case .orange: return "80–130"
        case .red:    return "> 130 km/h"
        }
    }

    static func from(kmh: Double) -> SpeedColor {
        switch kmh {
        case ..<30:     return .green
        case 30..<50:   return .blue
        case 50..<80:   return .amber
        case 80..<130:  return .orange
        default:        return .red
        }
    }
}

// MARK: - TripPoint
struct TripPoint: Codable, Identifiable, Sendable {
    var id = UUID()
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speedKmh: Double
    let accuracy: Double
    let course: Double
    let speedLimitKmh: Int?   // gecachtes Tempolimit zum Zeitpunkt (Pro only)

    init(from location: CLLocation, speedLimit: Int? = nil) {
        self.timestamp     = location.timestamp
        self.latitude      = location.coordinate.latitude
        self.longitude     = location.coordinate.longitude
        self.altitude      = location.altitude
        self.speedKmh      = max(0, location.speed * 3.6)
        self.accuracy      = location.horizontalAccuracy
        self.course        = location.course
        self.speedLimitKmh = speedLimit
    }

    /// Restore from cloud DTO (kein CLLocation verfügbar)
    init(timestamp: Date, latitude: Double, longitude: Double,
         altitude: Double, speedKmh: Double, accuracy: Double,
         course: Double, speedLimitKmh: Int? = nil) {
        self.timestamp     = timestamp
        self.latitude      = latitude
        self.longitude     = longitude
        self.altitude      = altitude
        self.speedKmh      = speedKmh
        self.accuracy      = accuracy
        self.course        = course
        self.speedLimitKmh = speedLimitKmh
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var speedColor: SpeedColor { SpeedColor.from(kmh: speedKmh) }
}

// MARK: - MotionSample
/// Ein einzelner CoreMotion-Messpunkt, 50Hz während der Fahrt gesammelt.
/// userAcceleration ist bereits gravity-bereinigt (CMDeviceMotion.userAcceleration).
struct MotionSample: Codable, Sendable {
    let timestamp: Date
    let longAccel:  Double   // Longitudinal (vorwärts/rückwärts), m/s²  (g × 9.81)
    let latAccel:   Double   // Lateral (links/rechts), m/s²
    let vertAccel:  Double   // Vertikal (hoch/runter), m/s²
    let yawRate:    Double   // Gierrate rad/s (vom Gyro)
}

// MARK: - SpeedDistribution
struct SpeedDistribution: Sendable {
    var under30: Double    = 0
    var from30to50: Double = 0
    var from50to80: Double = 0
    var from80to130: Double = 0
    var over130: Double    = 0
}

// MARK: - Trip
@Model
final class Trip {
    var id: UUID
    var title: String
    var startDate: Date
    var endDate: Date?
    var pointsData: Data
    var distanceKm: Double
    var durationSeconds: Double
    var avgSpeedKmh: Double
    var maxSpeedKmh: Double
    var efficiencyScore: Int
    var estimatedFuelL: Double
    var estimatedCostEur: Double
    var notes: String
    var vehicleProfileId: UUID?
    var vehicleProfileName: String = ""    // Default für Migration bestehender Trips

    // Fuel price snapshot at trip end (Tankerkönig)
    var fuelPriceAtTrip: Double = 0.0
    var fuelPriceSource: String = ""

    // Account-Isolation: UUID des Besitzers (leer = verwaist / vor Einführung erstellt)
    var ownerUserId: String = ""

    /// Kraftstoffart des Fahrzeugs zum Zeitpunkt der Fahrt ("Benzin", "Diesel", "LPG", "Elektrisch", "Hybrid")
    /// Leer bei alten Fahrten → Fallback über vehicleProfileId
    var vehicleFuelType: String = ""

    // 7-Säulen Driving Score (JSON-encoded)
    var drivingScoreData: Data = Data()

    // CoreMotion-Rohdaten (25Hz, JSON-encoded MotionSample-Array)
    // Leer bei alten Fahrten → GPS-basierter Fallback wird verwendet.
    var motionData: Data = Data()

    // ── @Transient: nicht in SwiftData gespeichert, nur im RAM ──────────────
    // Verhindert wiederholtes JSON-Decoding bei jedem `trip.points`-Zugriff.
    // Jeder Decode kostet CPU + RAM; ohne Cache wurden z.B. in StatisticsView
    // ALLE Trips gleichzeitig dekodiert → Hunderte MB Spike → OOM-Kill.
    @Transient private var _cachedPoints: [TripPoint]? = nil
    @Transient private var _cachedPointsDataID: Int = 0     // Erkennungsmerkmal für Cache-Invalidierung

    @Transient private var _cachedMotionSamples: [MotionSample]? = nil
    @Transient private var _cachedMotionDataID: Int = 0

    // FIX PERF-002: speedDistribution iterierte alle points 5× und wurde bei
    // jedem SwiftUI-Render neu berechnet. Bei 500 Trips × 10.000 Punkten = 25 Mio.
    // Filteroperationen pro Render-Pass → Freeze.
    // Cache mit pointsData-ID als Invalidierungsschlüssel (O(1) statt O(n)).
    @Transient private var _cachedSpeedDist: SpeedDistribution? = nil
    @Transient private var _cachedSpeedDistDataID: Int = 0

    @MainActor init(title: String = "") {
        self.id                 = UUID()
        self.title              = title.isEmpty ? Self.defaultTitle() : title
        self.startDate          = .now
        self.pointsData         = Data()
        self.distanceKm         = 0
        self.durationSeconds    = 0
        self.avgSpeedKmh        = 0
        self.maxSpeedKmh        = 0
        self.efficiencyScore    = 0
        self.estimatedFuelL     = 0
        self.estimatedCostEur   = 0
        self.notes              = ""
        self.vehicleProfileName = ""
    }

    @MainActor static func defaultTitle() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy · HH:mm"
        return L("trip.default_title", f.string(from: .now))
    }

    var points: [TripPoint] {
        get {
            // Cache-Check: pointsData.count als leichtgewichtiger Proxy für Dateiidentität.
            // Vollständiger hash() wäre exakter, aber für Data mit bis zu mehreren MB
            // ist count ausreichend und O(1) statt O(n).
            let dataID = pointsData.count &+ (pointsData.first.map(Int.init) ?? 0)
            if _cachedPoints == nil || _cachedPointsDataID != dataID {
                _cachedPoints   = (try? JSONDecoder().decode([TripPoint].self, from: pointsData)) ?? []
                _cachedPointsDataID = dataID
            }
            return _cachedPoints!
        }
        set {
            _cachedPoints      = newValue
            pointsData         = (try? JSONEncoder().encode(newValue)) ?? Data()
            _cachedPointsDataID = pointsData.count &+ (pointsData.first.map(Int.init) ?? 0)
        }
    }

    var drivingScore: DrivingScoreResult? {
        // Decode/Encode-Helfer sind als nonisolated Extension auf DrivingScoreResult
        // in DrivingScoreEngine.swift definiert — außerhalb der @MainActor Trip-Klasse.
        // Löst Swift-6-Warnung "Main actor-isolated conformance in nonisolated context".
        get { DrivingScoreResult.decode(from: drivingScoreData) }
        set { drivingScoreData = newValue?.encode() ?? Data() }
    }

    /// Berechnet den DrivingScore IMMER neu aus den gespeicherten Punkten.
    /// Muss aufgerufen werden wenn die Score-Engine aktualisiert wurde,
    /// damit gecachte Scores mit alter (fehlerhafter) Logik überschrieben werden.
    @MainActor func forceRecalculateScore() {
        let pts = points
        guard !pts.isEmpty else { return }
        let result = DrivingScoreEngine.shared.calculate(
            points: pts,
            motionSamples: motionSamples,
            distanceKm: distanceKm,
            fuelL: estimatedFuelL,
            isElectric: vehicleProfileName.lowercased().contains("elektr"),
            startDate: startDate
        )
        self.drivingScore    = result
        self.efficiencyScore = result.overall
    }

    /// Legacy-Fallback: nur berechnen wenn noch kein Score vorhanden.
    /// Für neue Fahrten nach dem Update nicht mehr nötig.
    @MainActor func recalculateMissingScoreIfNeeded() {
        guard drivingScoreData.isEmpty else { return }
        forceRecalculateScore()
    }

    var motionSamples: [MotionSample] {
        get {
            // FIX PERF-006: Vorher JSON (54.000 × ~140 Bytes = ~7.5 MB).
            // Neu: binäres Format (54.000 × 40 Bytes = ~2.1 MB, -72%).
            // Rückwärtskompatibel: altes JSON wird erkannt und on-the-fly migriert.
            let dataID = motionData.count ^ (motionData.last.map(Int.init) ?? 0)
            if _cachedMotionSamples == nil || _cachedMotionDataID != dataID {
                _cachedMotionSamples = MotionSampleBinaryCodec.decode(motionData)
                _cachedMotionDataID  = dataID
            }
            return _cachedMotionSamples!
        }
        set {
            _cachedMotionSamples = newValue
            motionData           = MotionSampleBinaryCodec.encode(newValue)
            _cachedMotionDataID  = motionData.count ^ (motionData.last.map(Int.init) ?? 0)
        }
    }

    // MARK: - Finalize
    @MainActor func finalize(points: [TripPoint], distanceKm: Double,
                  fuelL: Double, costEur: Double, isElectric: Bool = false,
                  vehicleName: String = "",
                  vehicleFuelType: String = "",
                  motionSamples: [MotionSample] = []) {
        self.points             = points
        self.motionSamples      = motionSamples
        self.endDate            = .now
        self.vehicleFuelType    = vehicleFuelType
        guard let end = self.endDate else {
            // Sollte nie eintreten, aber schützt vor einem Crash bei unerwartetem Aufruf.
            self.durationSeconds = 0
            return
        }
        self.distanceKm         = distanceKm
        self.durationSeconds    = end.timeIntervalSince(startDate)
        self.estimatedFuelL     = fuelL
        self.estimatedCostEur   = costEur
        self.vehicleProfileName = vehicleName

        let speeds = points.map(\.speedKmh).filter { $0 > 0 }
        self.avgSpeedKmh  = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        self.maxSpeedKmh  = speeds.max() ?? 0

        // 7-Säulen Scoring — nutzt CoreMotion wenn vorhanden, sonst GPS-Fallback
        let scoreResult = DrivingScoreEngine.shared.calculate(
            points: points,
            motionSamples: motionSamples,
            distanceKm: distanceKm,
            fuelL: fuelL,
            isElectric: isElectric,
            startDate: startDate
        )
        self.drivingScore    = scoreResult
        self.efficiencyScore = scoreResult.overall
    }

    // MARK: - Speed Distribution
    // FIX PERF-002: War pure computed property → 5 filter-Passes pro Aufruf.
    // Jetzt gecacht: wird nur bei Änderung von pointsData neu berechnet.
    var speedDistribution: SpeedDistribution {
        let dataID = pointsData.count ^ (pointsData.last.map(Int.init) ?? 0)
        if let cached = _cachedSpeedDist, _cachedSpeedDistDataID == dataID {
            return cached
        }
        let pts   = points.filter { $0.speedKmh > 1 }
        let total = Double(pts.count)
        let dist: SpeedDistribution
        if pts.isEmpty {
            dist = SpeedDistribution()
        } else {
            // Einzel-Pass statt 5× filter: alle Buckets in O(n) befüllen
            var u30 = 0, r30 = 0, r50 = 0, r80 = 0, o130 = 0
            for pt in pts {
                let s = pt.speedKmh
                if      s <  30  { u30  += 1 }
                else if s <  50  { r30  += 1 }
                else if s <  80  { r50  += 1 }
                else if s < 130  { r80  += 1 }
                else             { o130 += 1 }
            }
            dist = SpeedDistribution(
                under30:     Double(u30)  / total,
                from30to50:  Double(r30)  / total,
                from50to80:  Double(r50)  / total,
                from80to130: Double(r80)  / total,
                over130:     Double(o130) / total
            )
        }
        _cachedSpeedDist       = dist
        _cachedSpeedDistDataID = dataID
        return dist
    }

    // MARK: - Computed Helpers
    var speedColorCategory: SpeedColor { SpeedColor.from(kmh: avgSpeedKmh) }

    var formattedDistance: String { String(format: "%.1f km", distanceKm) }
    var formattedDuration: String {
        let h = Int(durationSeconds) / 3600
        let m = (Int(durationSeconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)min" : "\(m) min"
    }
    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale    = LanguageManager.shared.locale
        return f.string(from: startDate)
    }
}

// MARK: - VehicleProfile
@Model
final class VehicleProfile {
    var id: UUID
    var name: String
    var fuelType: String
    var consumptionPer100km: Double
    var fuelPricePerLiter: Double
    var isDefault: Bool
    var sortOrder: Int
    /// Benutzerdefinierte Profilfarbe (Hex-String, z.B. "06B6D4"). Leer = Fallback auf fuelColorHex.
    var colorHex: String = ""

    /// Account-Isolation: UUID des Besitzers (leer = verwaist / vor Einführung erstellt)
    var ownerUserId: String = ""

    /// Palette für zufällige Profilfarben bei der Erstellung
    static let colorPalette: [String] = [
        "06B6D4", // Cyan
        "3B82F6", // Blau
        "8B5CF6", // Lila
        "EC4899", // Pink
        "F59E0B", // Amber
        "EF4444", // Rot
        "22C55E", // Grün
        "F97316", // Orange
        "14B8A6", // Teal
        "6366F1", // Indigo
        "A855F7", // Violett
        "84CC16", // Limette
    ]

    static func randomColorHex() -> String {
        colorPalette.randomElement() ?? "06B6D4"
    }

    init(name: String = "Mein Auto",
         fuelType: String = "Benzin",
         consumption: Double = 7.0,
         pricePerLiter: Double = 1.85,
         sortOrder: Int = 0,
         colorHex: String = "") {
        self.id                  = UUID()
        self.name                = name
        self.fuelType            = fuelType
        self.consumptionPer100km = consumption
        self.fuelPricePerLiter   = pricePerLiter
        self.isDefault           = false
        self.sortOrder           = sortOrder
        self.colorHex            = colorHex.isEmpty ? VehicleProfile.randomColorHex() : colorHex
    }

    func estimatedFuel(forKm km: Double) -> Double {
        (km / 100.0) * consumptionPer100km
    }

    func estimatedCost(forKm km: Double) -> Double {
        estimatedFuel(forKm: km) * fuelPricePerLiter
    }

    /// True für Elektro-Fahrzeuge unabhängig von der gespeicherten Sprachvariante
    var isElectric: Bool {
        fuelType == "Elektrisch" || fuelType == "Electric"
    }

    var isDiesel: Bool {
        fuelType == "Diesel"
    }

    var isLPG: Bool {
        fuelType == "LPG"
    }

    /// Normalisiert einen lokalisierten Kraftstoffnamen auf die kanonische interne Darstellung (Deutsch).
    static func canonicalizeFuelType(_ localized: String) -> String {
        switch localized {
        case "Electric", "Elektrisch":  return "Elektrisch"
        case "Gasoline":                return "Benzin"
        case "Diesel":                  return "Diesel"
        case "Hybrid":                  return "Hybrid"
        case "LPG":                     return "LPG"
        default:                        return localized
        }
    }

    var fuelIcon: String {
        switch fuelType {
        case "Elektrisch", "Electric": return "bolt.fill"
        case "Hybrid":                 return "leaf.fill"
        case "LPG":                    return "flame.fill"
        default:                       return "fuelpump.fill"
        }
    }

    var fuelColorHex: String {
        if isElectric        { return "00D4FF" }
        if fuelType == "Hybrid"  { return "22C55E" }
        if isDiesel          { return "F59E0B" }
        if isLPG             { return "A855F7" }
        return "EF4444"
    }

    /// Die tatsächliche Profilfarbe: benutzerdefiniert (colorHex) oder Fallback auf Kraftstofffarbe.
    var profileColor: Color {
        colorHex.isEmpty ? Color(hex: fuelColorHex) : Color(hex: colorHex)
    }

    var displaySubtitle: String {
        if isElectric {
            return "\(String(format: "%.1f", consumptionPer100km)) kWh/100km"
        }
        return "\(fuelType) · \(String(format: "%.1f", consumptionPer100km)) L/100km · \(String(format: "%.2f", fuelPricePerLiter)) €/L"
    }

    var tankerkoenig: String {
        if isDiesel    { return "diesel" }
        if isLPG       { return "lpg" }
        if isElectric  { return "" }
        return "e5"
    }
}

// MARK: - MotionSample Binary Codec
// FIX PERF-006: Binäres Format statt JSON spart ~72% Speicher.
//
// Format-Spec (Little Endian):
//   Bytes  0– 3: Magic   = 0x4D 0x53 0x4D 0x50  ("MSMP")
//   Bytes  4– 7: Version = UInt32 = 2
//   Bytes  8–11: Count   = UInt32
//   Per Sample:  5 × Float64 = 40 Bytes
//                [timestamp, longAccel, latAccel, vertAccel, yawRate]
//
// Rückwärtskompatibilität: Falls Magic nicht passt → JSON-Fallback (alte Fahrten).
// Migration passiert automatisch beim nächsten Schreiben (Setter → immer binär).
enum MotionSampleBinaryCodec {

    private static let magic: [UInt8] = [0x4D, 0x53, 0x4D, 0x50]
    private static let version: UInt32 = 2
    private static let headerSize = 12  // 4 magic + 4 version + 4 count

    static func encode(_ samples: [MotionSample]) -> Data {
        guard !samples.isEmpty else { return Data() }
        let count = UInt32(samples.count)
        var data  = Data(capacity: headerSize + samples.count * 40)

        // Header
        data.append(contentsOf: magic)
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: count.littleEndian)   { data.append(contentsOf: $0) }

        // Samples
        for s in samples {
            appendDouble(&data, s.timestamp.timeIntervalSince1970)
            appendDouble(&data, s.longAccel)
            appendDouble(&data, s.latAccel)
            appendDouble(&data, s.vertAccel)
            appendDouble(&data, s.yawRate)
        }
        return data
    }

    static func decode(_ data: Data) -> [MotionSample] {
        guard !data.isEmpty else { return [] }

        // Magic prüfen — kein Magic → Legacy JSON
        if data.count >= 4 && data.prefix(4).elementsEqual(magic) {
            return decodeBinary(data)
        }
        // Rückwärtskompatibilität: altes JSON-Format
        return (try? JSONDecoder().decode([MotionSample].self, from: data)) ?? []
    }

    // ── Privat ──────────────────────────────────────────────────

    private static func decodeBinary(_ data: Data) -> [MotionSample] {
        guard data.count >= headerSize else { return [] }

        let countRaw = data[8..<12].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let count    = Int(countRaw)
        let expected = headerSize + count * 40
        guard data.count >= expected else { return [] }

        var samples = [MotionSample]()
        samples.reserveCapacity(count)
        var offset = headerSize

        for _ in 0..<count {
            let ts   = readDouble(data, offset: offset)
            let lng  = readDouble(data, offset: offset + 8)
            let lat  = readDouble(data, offset: offset + 16)
            let vert = readDouble(data, offset: offset + 24)
            let yaw  = readDouble(data, offset: offset + 32)
            offset  += 40
            // timestamp rekonstruieren: war relative zu einem Referenzzeitpunkt gespeichert
            // (motion.timestamp ist monotone Uhrzeit seit Boot; beim Encode wird Date().timeIntervalSince1970 gespeichert)
            samples.append(MotionSample(
                timestamp:  Date(timeIntervalSince1970: ts),
                longAccel:  lng,
                latAccel:   lat,
                vertAccel:  vert,
                yawRate:    yaw
            ))
        }
        return samples
    }

    private static func appendDouble(_ data: inout Data, _ value: Double) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readDouble(_ data: Data, offset: Int) -> Double {
        data[offset..<(offset + 8)].withUnsafeBytes { $0.load(as: Double.self) }
    }
}
