import Foundation
import CoreLocation

// ═══════════════════════════════════════════════════════════════
// DrivingScoreEngine.swift
// 7-Säulen Fahrstil-Bewertung
// ═══════════════════════════════════════════════════════════════

// MARK: - Score Result (persisted as JSON in Trip)
struct DrivingScoreResult: Codable, Sendable {
    let overall: Int                    // Gewichteter Gesamtscore 0-100
    let speedScore: Int                 // Säule 1: Geschwindigkeit
    let accelerationScore: Int          // Säule 2: Beschleunigung
    let brakingScore: Int               // Säule 3: Bremsen
    let corneringScore: Int             // Säule 4: Kurvenverhalten
    let timeOfDayMultiplier: Double     // Säule 5: Zeitpunkt-Multiplikator (0.8–1.0)
    let consistencyScore: Int           // Säule 6: Fahrkonsistenz
    let efficiencyScore: Int            // Säule 7: Streckeneffizienz
    let hasSpeedLimitData: Bool         // Ob Tempolimit-Daten vorhanden waren

    // Detaildaten für Pro-UI
    let speedLimitCompliance: Double    // % der Zeit im Limit
    let avgAccelerationMs2: Double      // Durchschn. Beschleunigung
    let avgBrakingMs2: Double           // Durchschn. Bremsverzögerung
    let harshAccelCount: Int            // Anzahl harter Beschleunigungen
    let harshBrakeCount: Int            // Anzahl harter Bremsungen
    let harshCornerCount: Int           // Anzahl harter Kurven
    let longestCleanKm: Double          // Längste Strecke ohne Event
    let nightDrivingRatio: Double       // Anteil Nachtfahrt
    let rushHourRatio: Double           // Anteil Rush Hour
}

// MARK: - Persist helpers
// Außerhalb der @MainActor-isolierten Trip-Klasse definiert,
// damit Swift 6 die Codable-Conformance als nonisolated behandelt.
extension DrivingScoreResult {
    /// Deserialisiert einen JSON-Blob aus SwiftData.
    static func decode(from data: Data) -> DrivingScoreResult? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(DrivingScoreResult.self, from: data)
    }

    /// Serialisiert das Ergebnis für SwiftData-Persistierung.
    func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

// MARK: - Pillar Weights
private struct PillarWeights {
    static let speed: Double        = 0.20
    static let acceleration: Double = 0.15
    static let braking: Double      = 0.15
    static let cornering: Double    = 0.15
    static let timeOfDay: Double    = 0.10
    static let consistency: Double  = 0.15
    static let efficiency: Double   = 0.10
}

// MARK: - Engine

// FIX CON-002: @MainActor isolation nötig weil tipsForScore() L() aufruft,
// das seit LocalizationManager-Fix @MainActor ist.
// DrivingScoreEngine wird ausschließlich von Views und von Trip.finalize()
// aufgerufen (Trip ist @MainActor über SwiftData) — keine Background-Thread-Konflikte.
@MainActor
final class DrivingScoreEngine {

    static let shared = DrivingScoreEngine()
    private init() {}

    // MARK: - Main Calculation

    func calculate(points: [TripPoint], motionSamples: [MotionSample] = [],
                   distanceKm: Double, fuelL: Double, isElectric: Bool,
                   startDate: Date) -> DrivingScoreResult {

        let moving = points.filter { $0.speedKmh > 1 }
        guard moving.count > 5, distanceKm > 0.3 else {
            return defaultResult()
        }

        // ── Säule 1: Geschwindigkeit (GPS-basiert, zuverlässig) ──
        let (speedSc, compliance) = calcSpeedScore(points: moving)

        // ── Säulen 2-4: Fahrdynamik ──────────────────────────────
        // CoreMotion wenn vorhanden (neue Fahrten), sonst RMS-GPS-Fallback
        let hasCoreMotion = motionSamples.count > 50
        let (accelSc, avgAccel, harshAccelN): (Int, Double, Int)
        let (brakeSc, avgBrake, harshBrakeN): (Int, Double, Int)
        let (cornerSc, harshCornerN): (Int, Int)

        if hasCoreMotion {
            (accelSc,  avgAccel,   harshAccelN)  = calcAccelFromMotion(motionSamples)
            (brakeSc,  avgBrake,   harshBrakeN)  = calcBrakeFromMotion(motionSamples)
            (cornerSc, harshCornerN)              = calcCornerFromMotion(motionSamples)
        } else {
            (accelSc,  avgAccel,   harshAccelN)  = calcAccelerationScore(points: points)
            (brakeSc,  avgBrake,   harshBrakeN)  = calcBrakingScore(points: points)
            (cornerSc, harshCornerN)              = calcCorneringScore(points: moving)
        }

        // ── Säule 5: Zeitpunkt ───────────────────────────────────
        let (timeMult, nightRatio, rushRatio) = calcTimeMultiplier(startDate: startDate, points: points)

        // ── Säule 6: Fahrkonsistenz ──────────────────────────────
        let (consistSc, longestClean) = hasCoreMotion
            ? calcConsistencyFromMotion(motionSamples, distanceKm: distanceKm)
            : calcConsistencyScore(points: points, distanceKm: distanceKm)

        // ── Säule 7: Effizienz ───────────────────────────────────
        let effSc = calcEfficiencyScore(distanceKm: distanceKm, fuelL: fuelL, isElectric: isElectric)

        // ── Gesamtscore ──────────────────────────────────────────
        let hasLimitData = moving.contains { $0.speedLimitKmh != nil }
        let timeScore    = Double(timeOfDayScore(from: timeMult))

        let weightedSum = (
            PillarWeights.speed        * Double(speedSc)  +
            PillarWeights.acceleration * Double(accelSc)  +
            PillarWeights.braking      * Double(brakeSc)  +
            PillarWeights.cornering    * Double(cornerSc) +
            PillarWeights.timeOfDay    * timeScore         +
            PillarWeights.consistency  * Double(consistSc) +
            PillarWeights.efficiency   * Double(effSc)
        )
        let totalWeight = PillarWeights.speed + PillarWeights.acceleration +
                          PillarWeights.braking + PillarWeights.cornering +
                          PillarWeights.timeOfDay + PillarWeights.consistency +
                          PillarWeights.efficiency  // = 1.00

        let overall = Int(min(100, max(0, weightedSum / totalWeight)))

        return DrivingScoreResult(
            overall: overall,
            speedScore: speedSc,
            accelerationScore: accelSc,
            brakingScore: brakeSc,
            corneringScore: cornerSc,
            timeOfDayMultiplier: timeMult,
            consistencyScore: consistSc,
            efficiencyScore: effSc,
            hasSpeedLimitData: hasLimitData,
            speedLimitCompliance: compliance,
            avgAccelerationMs2: avgAccel,
            avgBrakingMs2: avgBrake,
            harshAccelCount: harshAccelN,
            harshBrakeCount: harshBrakeN,
            harshCornerCount: harshCornerN,
            longestCleanKm: longestClean,
            nightDrivingRatio: nightRatio,
            rushHourRatio: rushRatio
        )
    }

    // MARK: - Default (zu wenig Daten)
    private func defaultResult() -> DrivingScoreResult {
        DrivingScoreResult(
            overall: 75, speedScore: 75, accelerationScore: 75,
            brakingScore: 75, corneringScore: 75, timeOfDayMultiplier: 1.0,
            consistencyScore: 75, efficiencyScore: 75, hasSpeedLimitData: false,
            speedLimitCompliance: 0, avgAccelerationMs2: 0, avgBrakingMs2: 0,
            harshAccelCount: 0, harshBrakeCount: 0, harshCornerCount: 0,
            longestCleanKm: 0, nightDrivingRatio: 0, rushHourRatio: 0
        )
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Säule 1: Geschwindigkeit
    // ═══════════════════════════════════════════════════════════

    private func calcSpeedScore(points: [TripPoint]) -> (Int, Double) {
        let withLimit = points.filter { $0.speedLimitKmh != nil && $0.speedLimitKmh! > 0 }

        if withLimit.count > 10 {
            // Limit-relative Bewertung (Pro mit SpeedLimit-Daten)
            var withinLimit = 0
            var slightOver  = 0    // bis +10%
            var moderateOver = 0   // +10 bis +20%
            // rest = heavy over

            for pt in withLimit {
                guard let limit = pt.speedLimitKmh, limit > 0 else { continue }
                let ratio = pt.speedKmh / Double(limit)
                if ratio <= 1.10      { withinLimit += 1 }
                else if ratio <= 1.20 { slightOver += 1 }
                else                  { moderateOver += 1 }
            }

            let total = Double(withLimit.count)
            let compliance = Double(withinLimit) / total
            let slightRatio = Double(slightOver) / total
            let heavyRatio = Double(moderateOver) / total

            var score = 100.0
            // Bonus für hohe Compliance
            if compliance >= 0.95 { score += 5 }

            // Abzüge
            score -= slightRatio * 20     // leichte Überschreitung: bis -20
            score -= heavyRatio * 60      // starke Überschreitung: bis -60

            return (clamp(score), compliance)

        } else {
            // Absolute Bewertung (kein Limit bekannt)
            let speeds = points.map(\.speedKmh)
            let maxSpd = speeds.max() ?? 0
            let _ = speeds.reduce(0, +) / Double(speeds.count)

            var score = 85.0  // Basis etwas niedriger ohne Limit-Referenz

            if maxSpd > 200      { score -= 35 }
            else if maxSpd > 180 { score -= 25 }
            else if maxSpd > 160 { score -= 18 }
            else if maxSpd > 140 { score -= 10 }
            else if maxSpd > 130 { score -= 5  }

            // Konstantfahrt-Bonus
            let stdDev = standardDeviation(speeds)
            if stdDev < 12      { score += 10 }
            else if stdDev < 20 { score += 5  }
            else if stdDev > 40 { score -= 10 }

            return (clamp(score), 0)
        }
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - CoreMotion Säulen 2-4+6 (präzise, 50Hz)
    // ═══════════════════════════════════════════════════════════

    /// Beschleunigungsscore aus echten Accelerometer-Daten.
    /// Verwendet RMS der Longitudinal-Komponente — ISO-2631-1 Methode.
    private func calcAccelFromMotion(_ samples: [MotionSample]) -> (Int, Double, Int) {
        // Bug 2 Fix: Nur positive Längs-Beschleunigungen (Anfahren/Beschleunigen)
        // Primär-Filter: longAccel > 0 (nach korrekter Achsenrotation in TripRecorder)
        var longAccels = samples.map { $0.longAccel }.filter { $0 > 0.1 }

        // Fallback: Falls longAccel durch Montage invertiert, abs() als Sicherheit
        if longAccels.isEmpty {
            longAccels = samples.map { abs($0.longAccel) }.filter { $0 > 0.1 }
        }
        guard !longAccels.isEmpty else { return (100, 0, 0) }

        let rms = sqrt(longAccels.map { $0 * $0 }.reduce(0, +) / Double(longAccels.count))
        let avg = longAccels.reduce(0, +) / Double(longAccels.count)

        // Harte Beschleunigung: 0.31g = 3.0 m/s² — klar spürbar, aber kein Sportwagen-Start nötig
        // 0.25g (2.45) = normales Stadtfahren → false positives
        // 0.31g (3.0)  = flotte Anfahrt, für Mitfahrer spürbar  ← korrekt
        // 0.40g (3.92) = sehr aggressiv
        let harshCount = countPeakEvents(in: longAccels, threshold: 3.0, minSamples: 3)

        let rmsScore: Double
        switch rms {
        case ..<0.3:  rmsScore = 100
        case ..<0.6:  rmsScore = 100 - (rms - 0.3) / 0.3 * 15
        case ..<1.0:  rmsScore = 85  - (rms - 0.6) / 0.4 * 20
        case ..<1.8:  rmsScore = 65  - (rms - 1.0) / 0.8 * 30
        case ..<2.5:  rmsScore = 35  - (rms - 1.8) / 0.7 * 20
        default:      rmsScore = max(0, 15 - (rms - 2.5) * 6)
        }

        // Cap bei 30 Punkten: verhindert sofortigen Absturz auf 0 durch Counting allein.
        // Restlicher Qualitätsabzug kommt kontinuierlich durch RMS.
        let harshPenalty = min(Double(harshCount) * 3.0, 30.0)
        return (clamp(rmsScore - harshPenalty), avg, harshCount)
    }

    /// Bremsscore aus echten Accelerometer-Daten (negative Longitudinal-Komponente).
    private func calcBrakeFromMotion(_ samples: [MotionSample]) -> (Int, Double, Int) {
        // Bug 2 Fix: Bremsen = negative longAccel → invertieren um positive Werte zu erhalten
        // Primär-Filter: -longAccel > 0.1 (d.h. longAccel < -0.1)
        var brakeAccels = samples.map { -$0.longAccel }.filter { $0 > 0.1 }

        // Fallback: Falls Vorzeichen durch Montage invertiert, abs() als Sicherheit
        if brakeAccels.isEmpty {
            brakeAccels = samples.map { abs($0.longAccel) }.filter { $0 > 0.1 }
        }
        guard !brakeAccels.isEmpty else { return (100, 0, 0) }

        let rms = sqrt(brakeAccels.map { $0 * $0 }.reduce(0, +) / Double(brakeAccels.count))
        let avg = brakeAccels.reduce(0, +) / Double(brakeAccels.count)

        // Harte Bremsung: 0.31g = 3.0 m/s²
        // DIESER BUG verursachte Bremsen = 0:
        // 2.45 m/s² (0.25g) = normales Stadtbremsen → 16 false positive "harte" Events
        // 16 Events × 5.0 Penalty = 80 Punkte Abzug → Score sank immer auf 0
        // Fix: 3.0 m/s² (0.31g) = klar spürbares Bremsen + Cap bei max. 30 Punkten Penalty
        let harshCount = countPeakEvents(in: brakeAccels, threshold: 3.0, minSamples: 3)

        let rmsScore: Double
        switch rms {
        case ..<0.3:  rmsScore = 100
        case ..<0.6:  rmsScore = 100 - (rms - 0.3) / 0.3 * 15
        case ..<1.0:  rmsScore = 85  - (rms - 0.6) / 0.4 * 20
        case ..<1.8:  rmsScore = 65  - (rms - 1.0) / 0.8 * 30
        case ..<2.5:  rmsScore = 35  - (rms - 1.8) / 0.7 * 20
        default:      rmsScore = max(0, 15 - (rms - 2.5) * 6)
        }

        // Cap bei 30 Punkten: 16 Events × 3.0 = 48 → begrenzt auf 30.
        // Score kann durch echte harte Bremsungen tief fallen, aber nicht durch Counting allein auf 0 crashen.
        let harshPenalty = min(Double(harshCount) * 3.0, 30.0)
        return (clamp(rmsScore - harshPenalty), avg, harshCount)
    }

    /// Kurvenverhalten aus Lateral-Beschleunigung (Accelerometer) und Yaw-Rate (Gyro).
    private func calcCornerFromMotion(_ samples: [MotionSample]) -> (Int, Int) {
        let laterals = samples.map { abs($0.latAccel) }.filter { $0 > 0.1 }
        guard !laterals.isEmpty else { return (90, 0) }

        let rms = sqrt(laterals.map { $0 * $0 }.reduce(0, +) / Double(laterals.count))

        // Harte Kurven: laterale g > 0.3g (2.94 m/s²) für > 5 Samples (100ms)
        let harshCount = countPeakEvents(in: laterals, threshold: 2.94, minSamples: 5)

        let rmsScore: Double
        switch rms {
        case ..<0.5:  rmsScore = 100
        case ..<0.9:  rmsScore = 100 - (rms - 0.5) / 0.4 * 20
        case ..<1.6:  rmsScore = 80  - (rms - 0.9) / 0.7 * 30
        case ..<2.5:  rmsScore = 50  - (rms - 1.6) / 0.9 * 25
        default:      rmsScore = max(0, 25 - (rms - 2.5) * 8)
        }

        let harshPenalty = Double(harshCount) * 3.0
        return (clamp(rmsScore - harshPenalty), harshCount)
    }

    /// Konsistenz aus CoreMotion: kombiniert Longitudinal + Lateral RMS.
    private func calcConsistencyFromMotion(_ samples: [MotionSample], distanceKm: Double) -> (Int, Double) {
        guard !samples.isEmpty else { return (75, 0) }

        let allMagnitudes = samples.map {
            sqrt($0.longAccel * $0.longAccel + $0.latAccel * $0.latAccel)
        }
        let rms = sqrt(allMagnitudes.map { $0 * $0 }.reduce(0, +) / Double(allMagnitudes.count))

        // Standardabweichung der Magnitude: niedrig = gleichmäßig
        let avg = allMagnitudes.reduce(0, +) / Double(allMagnitudes.count)
        let sd  = sqrt(allMagnitudes.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(allMagnitudes.count))

        let rmsScore: Double
        switch rms {
        case ..<0.6:  rmsScore = 100
        case ..<1.0:  rmsScore = 100 - (rms - 0.6) / 0.4 * 18
        case ..<1.5:  rmsScore = 82  - (rms - 1.0) / 0.5 * 25
        case ..<2.2:  rmsScore = 57  - (rms - 1.5) / 0.7 * 22
        default:      rmsScore = max(0, 35 - (rms - 2.2) * 10)
        }

        let sdPenalty: Double = sd < 0.5 ? 0 : sd < 1.0 ? 8 : sd < 1.5 ? 18 : 30
        let score = max(0.0, rmsScore - sdPenalty)

        // Längste saubere Strecke (approximiert via Zeitanteil ruhiger Fahrt)
        let cleanSamples = allMagnitudes.filter { $0 < 1.5 }.count
        let cleanRatio = Double(cleanSamples) / Double(allMagnitudes.count)
        let longestCleanKm = cleanRatio * distanceKm

        return (clamp(score), longestCleanKm)
    }

    /// Zählt zusammenhängende Peaks über threshold mit minSamples Mindestlänge.
    private func countPeakEvents(in values: [Double], threshold: Double, minSamples: Int) -> Int {
        var count = 0
        var runLength = 0
        for v in values {
            if v > threshold {
                runLength += 1
                if runLength == minSamples { count += 1 }
            } else {
                runLength = 0
            }
        }
        return count
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - GPS-Fallback Säulen 2-4 (RMS-basiert, robuster)
    // ═══════════════════════════════════════════════════════════

    // ── Säule 2: Beschleunigung (GPS-Fallback) ─────────────────
    private func calcAccelerationScore(points: [TripPoint]) -> (Int, Double, Int) {
        let rawAccels = accelerations(from: points)
        let posAccels = rawAccels.filter { $0 > 0.15 }
        guard !posAccels.isEmpty else { return (100, 0, 0) }

        let avg = posAccels.reduce(0, +) / Double(posAccels.count)

        // RMS-Methode: robuster gegen GPS-Noise als Schwellen
        let rms = sqrt(posAccels.map { $0 * $0 }.reduce(0, +) / Double(posAccels.count))
        let harshCount = posAccels.filter { $0 > 2.5 }.count

        let rmsScore: Double
        switch rms {
        case ..<0.6:  rmsScore = 100
        case ..<0.9:  rmsScore = 100 - (rms - 0.6) / 0.3 * 15
        case ..<1.3:  rmsScore = 85  - (rms - 0.9) / 0.4 * 25
        case ..<1.8:  rmsScore = 60  - (rms - 1.3) / 0.5 * 25
        default:      rmsScore = max(0, 35 - (rms - 1.8) * 12)
        }

        let harshPenalty = Double(harshCount) / Double(posAccels.count) * 50
        return (clamp(rmsScore - harshPenalty), avg, harshCount)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Säule 3: Bremsen
    // ═══════════════════════════════════════════════════════════

    // ── Säule 3: Bremsen (GPS-Fallback) ────────────────────────
    private func calcBrakingScore(points: [TripPoint]) -> (Int, Double, Int) {
        let rawAccels = accelerations(from: points)
        let negAccels = rawAccels.filter { $0 < -0.15 }.map { abs($0) }
        guard !negAccels.isEmpty else { return (100, 0, 0) }

        let avg = negAccels.reduce(0, +) / Double(negAccels.count)
        let rms = sqrt(negAccels.map { $0 * $0 }.reduce(0, +) / Double(negAccels.count))
        let harshCount = negAccels.filter { $0 > 3.0 }.count

        let rmsScore: Double
        switch rms {
        case ..<0.6:  rmsScore = 100
        case ..<0.9:  rmsScore = 100 - (rms - 0.6) / 0.3 * 15
        case ..<1.3:  rmsScore = 85  - (rms - 0.9) / 0.4 * 25
        case ..<1.8:  rmsScore = 60  - (rms - 1.3) / 0.5 * 25
        default:      rmsScore = max(0, 35 - (rms - 1.8) * 12)
        }

        let harshPenalty = Double(harshCount) / Double(negAccels.count) * 50
        return (clamp(rmsScore - harshPenalty), avg, harshCount)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Säule 4: Kurvenverhalten
    // ═══════════════════════════════════════════════════════════

    private func calcCorneringScore(points: [TripPoint]) -> (Int, Int) {
        guard points.count > 3 else { return (85, 0) }

        var harshCorners = 0
        var totalCornerForce: Double = 0
        var cornerCount = 0

        for i in 1..<points.count {
            let prev = points[i-1]
            let curr = points[i]

            // Heading-Differenz berechnen
            guard prev.course >= 0, curr.course >= 0 else { continue }
            var headingDelta = abs(curr.course - prev.course)
            if headingDelta > 180 { headingDelta = 360 - headingDelta }

            // Nur echte Kurven (>5° Änderung)
            guard headingDelta > 5 else { continue }

            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0.5, dt < 10 else { continue }

            // Laterale Kraft-Proxy: (heading_change_rad / dt) × speed_ms
            let headingRate = (headingDelta * .pi / 180) / dt  // rad/s
            let speedMs = curr.speedKmh / 3.6
            let lateralG = headingRate * speedMs / 9.81  // in g

            totalCornerForce += lateralG
            cornerCount += 1

            if lateralG > 0.25 { harshCorners += 1 }  // >0.25g = spürbar zu hastig
        }

        guard cornerCount > 3 else { return (85, 0) }

        let avgCornerG = totalCornerForce / Double(cornerCount)
        let harshRatio = Double(harshCorners) / Double(cornerCount)

        var score = 100.0
        score -= harshRatio * 75
        if avgCornerG > 0.22 { score -= 18 }
        else if avgCornerG > 0.16 { score -= 8 }
        else if avgCornerG < 0.10 { score += 3 }

        return (clamp(score), harshCorners)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Säule 5: Zeitpunkt — Gauß-Summenkurve + Exponential-Decay
    // ═══════════════════════════════════════════════════════════
    //
    // Mathematisches Modell (Destatis-kalibriert):
    //
    //   Risiko-Index R(h) = Σᵢ Aᵢ · exp(−(h − μᵢ)² / (2σᵢ²))
    //
    //   Jede Risikoquelle (Tiefnacht, Morgenrush, Abendrush, Dämmerung)
    //   wird als Gaußsche Glockenkurve modelliert. Summe ergibt eine
    //   kontinuierliche, glatte Risikokurve ohne harte Stufensprünge.
    //
    //   Score(h) = 100 · exp(−k · R(h)),  k = 1.68
    //
    //   Exponentieller Abfall: kleines R → Score nahe 100,
    //   großes R (z.B. Tiefnacht) → Score fällt auf ~35.
    //   Kalibrierung: Score(2 Uhr) ≈ 35, Score(12 Uhr) ≈ 100.
    //
    // ═══════════════════════════════════════════════════════════

    private func calcTimeMultiplier(startDate: Date, points: [TripPoint]) -> (Double, Double, Double) {
        guard !points.isEmpty else { return (1.0, 0, 0) }

        let cal = Calendar.current
        var nightCount = 0
        var rushCount  = 0
        var totalScore = 0.0

        for pt in points {
            let comps     = cal.dateComponents([.hour, .minute, .weekday], from: pt.timestamp)
            let hour      = comps.hour    ?? 12
            let minute    = comps.minute  ?? 0
            let weekday   = comps.weekday ?? 2   // 1=So, 7=Sa
            let isWeekend = weekday == 1 || weekday == 7

            // Fraktionale Stunde für kontinuierliche Kurvenauswertung
            // z.B. 08:30 → 8.5 statt Stufensprung bei 8 vs 9
            let h = Double(hour) + Double(minute) / 60.0

            // Zähler für UI-Ratios (klassische Grenzen beibehalten)
            if hour >= 22 || hour < 6 { nightCount += 1 }
            if !isWeekend && ((hour >= 7 && hour <= 9) || (hour >= 16 && hour <= 18)) {
                rushCount += 1
            }

            totalScore += gaussianTimeScore(h: h, isWeekend: isWeekend)
        }

        let total      = Double(points.count)
        let avgScore   = totalScore / total     // 35–100
        let nightRatio = Double(nightCount) / total
        let rushRatio  = Double(rushCount)  / total

        // Rückwärtskompatibilität: multiplier = avgScore / 100
        return (avgScore / 100.0, nightRatio, rushRatio)
    }

    /// Gauß-Funktion: G(h, μ, σ, A) = A · exp(−(h − μ)² / (2σ²))
    /// Modelliert eine einzelne Risikoquelle als glatte Glockenkurve.
    private func gauss(h: Double, mu: Double, sigma: Double, amplitude: Double) -> Double {
        let exponent = -pow(h - mu, 2) / (2.0 * sigma * sigma)
        return amplitude * exp(exponent)
    }

    /// Risiko-Index R(h) als Summe von Gauß-Kurven.
    /// Jede Kurve repräsentiert eine Risikoquelle (Destatis-kalibriert):
    ///
    ///  Peak 1 — Tiefnacht  (μ=2.0,  σ=1.8): Alkohol, extreme Müdigkeit → stärkster Peak
    ///  Peak 2 — Dämmerung  (μ=5.5,  σ=1.2): Schlechte Sicht, Blendung, Restmüdigkeit
    ///  Peak 3 — Morgenrush (μ=8.0,  σ=1.0): Werktag Berufsverkehr + Ablenkungs-Stress
    ///  Peak 4 — Abendrush  (μ=17.0, σ=1.5): Stärkster Berufsverkehr, Ermüdung nach Arbeit
    ///  Peak 5 — Spätnacht  (μ=21.5, σ=2.0): Nachlassende Konzentration, schlechte Sicht
    private func timeRiskIndex(h: Double, isWeekend: Bool) -> Double {
        let nightPeak    = gauss(h: h, mu: 2.0,  sigma: 1.8, amplitude: 0.65)
        let dawnDip      = gauss(h: h, mu: 5.5,  sigma: 1.2, amplitude: 0.25)
        let morningRush  = isWeekend ? 0.0 : gauss(h: h, mu: 8.0,  sigma: 1.0, amplitude: 0.28)
        let eveningRush  = isWeekend ? 0.0 : gauss(h: h, mu: 17.0, sigma: 1.5, amplitude: 0.32)
        let eveningFade  = gauss(h: h, mu: 21.5, sigma: 2.0, amplitude: 0.20)

        // Tiefnacht-Wrap: Stunden 22–24 sind physikalisch nahe an Stunde 2 (Tiefnacht)
        // Ohne Wrap würde die Kurve bei 23 Uhr zu früh abfallen
        let nightWrap    = gauss(h: h - 24.0, mu: 2.0, sigma: 1.8, amplitude: 0.65)

        return nightPeak + dawnDip + morningRush + eveningRush + eveningFade + nightWrap
    }

    /// Score(h) = 100 · exp(−k · R(h))
    /// k = 1.68 → kalibriert auf: Score(2:00) ≈ 35, Score(12:00) ≈ 100.
    ///
    /// Exponentieller Abfall: kleine Risikoindizes → Score nahe 100 (flach),
    /// hohe Risikoindizes → Score bricht schnell ein (konvex nach unten).
    private func gaussianTimeScore(h: Double, isWeekend: Bool) -> Double {
        let R = timeRiskIndex(h: h, isWeekend: isWeekend)
        let k = 1.68
        let score = 100.0 * exp(-k * R)
        return max(35.0, min(100.0, score))
    }

    /// Konvertiert den gespeicherten multiplier zurück in einen 0-100 Score.
    /// multiplier = avgScore / 100 → score = multiplier × 100
    func timeOfDayScore(from multiplier: Double) -> Int {
        Int(max(0, min(100, multiplier * 100)))
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Säule 6: Fahrkonsistenz
    // ═══════════════════════════════════════════════════════════

    private func calcConsistencyScore(points: [TripPoint], distanceKm: Double) -> (Int, Double) {
        guard points.count > 5, distanceKm > 0 else { return (75, 0) }

        let accels = accelerations(from: points)

        // ── Längste saubere Strecke ──────────────────────────
        var currentCleanKm: Double = 0
        var longestCleanKm: Double = 0
        for i in 1..<points.count {
            let dist    = points[i].clLocation.distance(from: points[i-1].clLocation) / 1000.0
            let isHarsh = i < accels.count && (accels[i] > 2.5 || accels[i] < -3.0)
            if isHarsh { longestCleanKm = max(longestCleanKm, currentCleanKm); currentCleanKm = 0 }
            else        { currentCleanKm += dist }
        }
        longestCleanKm = max(longestCleanKm, currentCleanKm)

        // ── Metrik 1: Standardabweichung aller Beschleunigungen ─
        // Misst wie GLEICHMÄSSIG die gesamte Fahrt ist.
        // Niedrige StdDev = flüssiges Fahren. Diese Metrik trifft auch
        // normale Fahrten, nicht nur extreme Ausreißer.
        let allA = accels.filter { abs($0) > 0.2 }
        var stdDevPenalty = 0.0
        if !allA.isEmpty {
            let avg     = allA.reduce(0, +) / Double(allA.count)
            let variance = allA.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(allA.count)
            let sd      = sqrt(variance)
            // Referenz: sd < 0.7 = sehr gleichmäßig (Autobahn/Landstraße)
            //           sd ~ 1.0 = normale Stadtfahrt
            //           sd ~ 1.5 = unruhige Stadtfahrt
            //           sd > 2.0 = aggressiv/ruckartig
            if      sd < 0.7  { stdDevPenalty =  0 }
            else if sd < 1.0  { stdDevPenalty = 10 }
            else if sd < 1.4  { stdDevPenalty = 22 }
            else if sd < 2.0  { stdDevPenalty = 38 }
            else              { stdDevPenalty = 55 }
        }

        // ── Metrik 2: Moderate-Events-Rate ──────────────────────
        let modCount  = accels.filter { ($0 > 1.5 && $0 <= 2.5) || ($0 < -1.8 && $0 >= -3.0) }.count
        let modRate   = Double(modCount) / distanceKm
        let modPenalty: Double
        if      modRate > 6 { modPenalty = 20 }
        else if modRate > 3 { modPenalty = 10 }
        else if modRate > 1 { modPenalty =  4 }
        else                { modPenalty =  0 }

        // ── Metrik 3: Harsh-Events-Rate ──────────────────────────
        let harshCount = accels.filter { $0 > 2.5 || $0 < -3.0 }.count
        let harshRate  = Double(harshCount) / distanceKm
        let harshPenalty: Double
        if      harshRate > 3 { harshPenalty = 30 }
        else if harshRate > 1 { harshPenalty = 15 }
        else if harshRate > 0 { harshPenalty =  7 }
        else                  { harshPenalty =  0 }

        let score = max(0.0, 100.0 - stdDevPenalty - modPenalty - harshPenalty)
        return (clamp(score), longestCleanKm)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Säule 7: Streckeneffizienz
    // ═══════════════════════════════════════════════════════════

    private func calcEfficiencyScore(distanceKm: Double, fuelL: Double, isElectric: Bool) -> Int {
        var score = 75.0

        // Kurzstrecken-Malus
        if distanceKm < 2       { score -= 15 }
        else if distanceKm < 3  { score -= 8  }
        else if distanceKm < 5  { score -= 3  }
        else if distanceKm > 10 { score += 5  }

        // Verbrauchsbewertung pro 100km
        if distanceKm > 1 && fuelL > 0 {
            if isElectric {
                let kwhPer100 = (fuelL / distanceKm) * 100
                if      kwhPer100 < 12 { score += 15 }
                else if kwhPer100 < 16 { score += 8  }
                else if kwhPer100 < 20 { score += 3  }
                else if kwhPer100 > 25 { score -= 10 }
                else if kwhPer100 > 30 { score -= 20 }
            } else {
                let per100 = (fuelL / distanceKm) * 100
                if      per100 < 5  { score += 15 }
                else if per100 < 7  { score += 8  }
                else if per100 < 9  { score += 3  }
                else if per100 > 12 { score -= 10 }
                else if per100 > 15 { score -= 20 }
            }
        }

        return clamp(score)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Aggregation (für StatisticsView)
    // ═══════════════════════════════════════════════════════════

    /// Aggregiert Scores über mehrere Fahrten zu einem Gesamtergebnis
    func aggregate(trips: [Trip]) -> DrivingScoreResult? {
        guard !trips.isEmpty else { return nil }
        let scored = trips.compactMap { $0.drivingScore }

        // ── Fallback: drivingScoreData fehlt → neu berechnen ──
        // (sollte nach forceRecalculateScore() nicht mehr auftreten)
        if scored.isEmpty {
            trips.forEach { $0.forceRecalculateScore() }
            let rescored = trips.compactMap { $0.drivingScore }
            guard !rescored.isEmpty else { return nil }
            let n2 = Double(rescored.count)
            return DrivingScoreResult(
                overall:              Int(rescored.map { Double($0.overall) }.reduce(0,+) / n2),
                speedScore:           Int(rescored.map { Double($0.speedScore) }.reduce(0,+) / n2),
                accelerationScore:    Int(rescored.map { Double($0.accelerationScore) }.reduce(0,+) / n2),
                brakingScore:         Int(rescored.map { Double($0.brakingScore) }.reduce(0,+) / n2),
                corneringScore:       Int(rescored.map { Double($0.corneringScore) }.reduce(0,+) / n2),
                timeOfDayMultiplier:  rescored.map(\.timeOfDayMultiplier).reduce(0,+) / n2,
                consistencyScore:     Int(rescored.map { Double($0.consistencyScore) }.reduce(0,+) / n2),
                efficiencyScore:      Int(rescored.map { Double($0.efficiencyScore) }.reduce(0,+) / n2),
                hasSpeedLimitData:    rescored.contains { $0.hasSpeedLimitData },
                speedLimitCompliance: rescored.map(\.speedLimitCompliance).reduce(0,+) / n2,
                avgAccelerationMs2:   rescored.map(\.avgAccelerationMs2).reduce(0,+) / n2,
                avgBrakingMs2:        rescored.map(\.avgBrakingMs2).reduce(0,+) / n2,
                harshAccelCount:      rescored.map(\.harshAccelCount).reduce(0,+),
                harshBrakeCount:      rescored.map(\.harshBrakeCount).reduce(0,+),
                harshCornerCount:     rescored.map(\.harshCornerCount).reduce(0,+),
                longestCleanKm:       rescored.map(\.longestCleanKm).max() ?? 0,
                nightDrivingRatio:    rescored.map(\.nightDrivingRatio).reduce(0,+) / n2,
                rushHourRatio:        rescored.map(\.rushHourRatio).reduce(0,+) / n2
            )
        }

        let n = Double(scored.count)
        return DrivingScoreResult(
            overall:                Int(scored.map { Double($0.overall) }.reduce(0, +) / n),
            speedScore:             Int(scored.map { Double($0.speedScore) }.reduce(0, +) / n),
            accelerationScore:      Int(scored.map { Double($0.accelerationScore) }.reduce(0, +) / n),
            brakingScore:           Int(scored.map { Double($0.brakingScore) }.reduce(0, +) / n),
            corneringScore:         Int(scored.map { Double($0.corneringScore) }.reduce(0, +) / n),
            timeOfDayMultiplier:    scored.map(\.timeOfDayMultiplier).reduce(0, +) / n,
            consistencyScore:       Int(scored.map { Double($0.consistencyScore) }.reduce(0, +) / n),
            efficiencyScore:        Int(scored.map { Double($0.efficiencyScore) }.reduce(0, +) / n),
            hasSpeedLimitData:      scored.contains { $0.hasSpeedLimitData },
            speedLimitCompliance:   scored.map(\.speedLimitCompliance).reduce(0, +) / n,
            avgAccelerationMs2:     scored.map(\.avgAccelerationMs2).reduce(0, +) / n,
            avgBrakingMs2:          scored.map(\.avgBrakingMs2).reduce(0, +) / n,
            harshAccelCount:        scored.map(\.harshAccelCount).reduce(0, +),
            harshBrakeCount:        scored.map(\.harshBrakeCount).reduce(0, +),
            harshCornerCount:       scored.map(\.harshCornerCount).reduce(0, +),
            longestCleanKm:         scored.map(\.longestCleanKm).max() ?? 0,
            nightDrivingRatio:      scored.map(\.nightDrivingRatio).reduce(0, +) / n,
            rushHourRatio:          scored.map(\.rushHourRatio).reduce(0, +) / n
        )
    }

    /// Gibt Tipps basierend auf den schwächsten Säulen zurück
    func tipsForScore(_ score: DrivingScoreResult) -> [String] {
        var tips: [(Int, String)] = []

        // Schwächste Säulen identifizieren
        if score.speedScore < 70 {
            tips.append((score.speedScore,
                         score.hasSpeedLimitData
                         ? L("dscore.tip.speed_limit")
                         : L("dscore.tip.speed_abs")))
        }
        if score.accelerationScore < 70 {
            tips.append((score.accelerationScore, L("dscore.tip.accel")))
        }
        if score.brakingScore < 70 {
            tips.append((score.brakingScore, L("dscore.tip.brake")))
        }
        if score.corneringScore < 70 {
            tips.append((score.corneringScore, L("dscore.tip.corner")))
        }
        if score.consistencyScore < 70 {
            tips.append((score.consistencyScore, L("dscore.tip.consistency")))
        }
        if score.efficiencyScore < 70 {
            tips.append((score.efficiencyScore, L("dscore.tip.efficiency")))
        }
        if score.nightDrivingRatio > 0.3 {
            tips.append((60, L("dscore.tip.night")))
        }

        // Nach schwächstem Score sortieren, max 4 Tipps
        let sorted = tips.sorted { $0.0 < $1.0 }.map(\.1)

        if sorted.isEmpty {
            return [L("dscore.tip.excellent")]
        }
        return Array(sorted.prefix(4))
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Helper Functions
    // ═══════════════════════════════════════════════════════════

    /// Berechnet Beschleunigungen in m/s² aus TripPoints
    private func accelerations(from points: [TripPoint]) -> [Double] {
        guard points.count > 1 else { return [] }
        var result: [Double] = [0]

        for i in 1..<points.count {
            let prev = points[i-1]
            let curr = points[i]
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)

            // dt < 0.3: GPS-Jitter, ignorieren
            // dt > 30:  Pause/Pause-Ende, kein echter Fahrübergang
            // dt 10-30: z.B. Ampelstopp → Anfahren: DAS ist ein wichtiger Moment!
            guard dt > 0.3, dt < 30 else {
                result.append(0)
                continue
            }

            let dv = (curr.speedKmh - prev.speedKmh) / 3.6
            let accel = dv / dt
            result.append(accel)
        }
        return result
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let avg = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }

    private func clamp(_ value: Double) -> Int {
        Int(max(0, min(100, value)))
    }
}
