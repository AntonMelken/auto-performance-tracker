import Foundation

// ═══════════════════════════════════════════════════════════════
// DrivingTipsEngine.swift
// Intelligente Fahrtipps — datengetrieben, Score-verknüpft, dynamisch
// ═══════════════════════════════════════════════════════════════

// MARK: - Tip Category

enum TipCategory: String, Sendable {
    case braking, acceleration, speed, cornering, consistency, efficiency, timeOfDay

    var icon: String {
        switch self {
        case .braking:       return "arrow.down.to.line.compact"
        case .acceleration:  return "bolt.fill"
        case .speed:         return "gauge.with.needle.fill"
        case .cornering:     return "arrow.triangle.turn.up.right.circle.fill"
        case .consistency:   return "waveform.path"
        case .efficiency:    return "leaf.fill"
        case .timeOfDay:     return "moon.stars.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .braking:       return "EF4444"
        case .acceleration:  return "F59E0B"
        case .speed:         return "3B82F6"
        case .cornering:     return "818CF8"
        case .consistency:   return "06B6D4"
        case .efficiency:    return "22C55E"
        case .timeOfDay:     return "A78BFA"
        }
    }

    // FIX CON-002: @MainActor weil L() @MainActor ist.
    // localizedName wird nur in Views oder aus @MainActor-Kontexten aufgerufen.
    @MainActor
    var localizedName: String {
        switch self {
        case .braking:       return L("tip.cat.braking")
        case .acceleration:  return L("tip.cat.acceleration")
        case .speed:         return L("tip.cat.speed")
        case .cornering:     return L("tip.cat.cornering")
        case .consistency:   return L("tip.cat.consistency")
        case .efficiency:    return L("tip.cat.efficiency")
        case .timeOfDay:     return L("tip.cat.timeofday")
        }
    }
}

// MARK: - Tip Impact

enum TipImpact: Int, Comparable, Sendable {
    case low = 1, medium = 2, high = 3
    static func < (lhs: TipImpact, rhs: TipImpact) -> Bool { lhs.rawValue < rhs.rawValue }

    // FIX CON-002: @MainActor weil L() @MainActor ist.
    @MainActor
    var localizedName: String {
        switch self {
        case .high:   return L("tip.impact.high")
        case .medium: return L("tip.impact.medium")
        case .low:    return L("tip.impact.low")
        }
    }
}

// MARK: - Trip Type

enum TripType: Equatable, Sendable {
    case shortTrip   // < 2 km
    case city        // avg < 50 km/h, minimal highway
    case mixed
    case highway     // >50% time at 80+ km/h

    static func detect(avgSpeedKmh: Double,
                       distanceKm: Double,
                       highwayRatio: Double) -> TripType {
        if distanceKm < 2           { return .shortTrip }
        if highwayRatio > 0.50      { return .highway   }
        if avgSpeedKmh < 45 && highwayRatio < 0.15 { return .city }
        return .mixed
    }
}

// MARK: - Rich Trip Analysis (unified context)

struct RichTripAnalysis: Sendable {
    let avgSpeedKmh: Double
    let maxSpeedKmh: Double
    let distanceKm: Double
    let speedStdDev: Double
    let fuelPer100km: Double
    let stoppedRatio: Double
    let speedDist: SpeedDistribution
    let tripType: TripType

    let overallScore: Int
    let speedScore: Int
    let accelerationScore: Int
    let brakingScore: Int
    let corneringScore: Int
    let consistencyScore: Int
    let efficiencyScore: Int
    let timeOfDayMultiplier: Double

    let harshAccelCount: Int
    let harshBrakeCount: Int
    let harshCornerCount: Int
    let speedLimitCompliance: Double
    let hasSpeedLimitData: Bool
    let longestCleanKm: Double
    let nightDrivingRatio: Double
    let rushHourRatio: Double
    let avgAccelMs2: Double
    let avgBrakeMs2: Double

    // MARK: Build from Trip
    static func from(trip: Trip) -> RichTripAnalysis {
        let pts = trip.points
        let speeds = pts.map(\.speedKmh).filter { $0 > 1 }
        let avg = speeds.isEmpty ? 0.0 : speeds.reduce(0, +) / Double(speeds.count)
        let stdDev: Double = {
            guard speeds.count > 1 else { return 0 }
            let variance = speeds.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(speeds.count)
            return sqrt(variance)
        }()
        let stoppedRatio = pts.isEmpty ? 0.0
            : Double(pts.filter { $0.speedKmh < 2 }.count) / Double(pts.count)
        let per100 = trip.distanceKm > 0 && trip.estimatedFuelL > 0
            ? (trip.estimatedFuelL / trip.distanceKm) * 100 : 0.0
        let highwayRatio = trip.speedDistribution.from80to130 + trip.speedDistribution.over130
        let tripType = TripType.detect(avgSpeedKmh: avg,
                                       distanceKm: trip.distanceKm,
                                       highwayRatio: highwayRatio)

        if let s = trip.drivingScore {
            return RichTripAnalysis(
                avgSpeedKmh: avg, maxSpeedKmh: trip.maxSpeedKmh,
                distanceKm: trip.distanceKm, speedStdDev: stdDev,
                fuelPer100km: per100, stoppedRatio: stoppedRatio,
                speedDist: trip.speedDistribution, tripType: tripType,
                overallScore: s.overall,
                speedScore: s.speedScore,
                accelerationScore: s.accelerationScore,
                brakingScore: s.brakingScore,
                corneringScore: s.corneringScore,
                consistencyScore: s.consistencyScore,
                efficiencyScore: s.efficiencyScore,
                timeOfDayMultiplier: s.timeOfDayMultiplier,
                harshAccelCount: s.harshAccelCount,
                harshBrakeCount: s.harshBrakeCount,
                harshCornerCount: s.harshCornerCount,
                speedLimitCompliance: s.speedLimitCompliance,
                hasSpeedLimitData: s.hasSpeedLimitData,
                longestCleanKm: s.longestCleanKm,
                nightDrivingRatio: s.nightDrivingRatio,
                rushHourRatio: s.rushHourRatio,
                avgAccelMs2: s.avgAccelerationMs2,
                avgBrakeMs2: s.avgBrakingMs2
            )
        } else {
            return RichTripAnalysis(
                avgSpeedKmh: avg, maxSpeedKmh: trip.maxSpeedKmh,
                distanceKm: trip.distanceKm, speedStdDev: stdDev,
                fuelPer100km: per100, stoppedRatio: stoppedRatio,
                speedDist: trip.speedDistribution, tripType: tripType,
                overallScore: trip.efficiencyScore,
                speedScore: 75, accelerationScore: 75, brakingScore: 75,
                corneringScore: 75, consistencyScore: 75,
                efficiencyScore: trip.efficiencyScore,
                timeOfDayMultiplier: 1.0,
                harshAccelCount: 0, harshBrakeCount: 0, harshCornerCount: 0,
                speedLimitCompliance: 0, hasSpeedLimitData: false,
                longestCleanKm: trip.distanceKm * 0.6,
                nightDrivingRatio: 0, rushHourRatio: 0,
                avgAccelMs2: 0, avgBrakeMs2: 0
            )
        }
    }
}

// MARK: - Rich Tip (output)

struct RichTip: Identifiable, Sendable {
    let id: String
    let category: TipCategory
    let impact: TipImpact
    let pillarScore: Int?        // current score of the linked pillar (nil = global tip)
    let text: String             // dynamically generated with real numbers
    let estimatedGain: Int       // score points potentially gained (0 = positive/praise tip)
    let priority: Int            // higher = shown first
    let isPositive: Bool         // true = praise tip, false = improvement tip
}

// MARK: - Internal Tip Definition

private struct TipDef {
    let id: String
    let category: TipCategory
    let impact: TipImpact
    let isPositive: Bool
    let pillarExtract: (RichTripAnalysis) -> Int?
    let condition: (RichTripAnalysis) -> Bool
    let generate: (RichTripAnalysis) -> String
    let gainCalc: (RichTripAnalysis) -> Int

    init(id: String,
         category: TipCategory,
         impact: TipImpact,
         pillar: ((RichTripAnalysis) -> Int?)? = nil,
         isPositive: Bool = false,
         condition: @escaping (RichTripAnalysis) -> Bool,
         generate: @escaping (RichTripAnalysis) -> String,
         gain: @escaping (RichTripAnalysis) -> Int) {
        self.id = id
        self.category = category
        self.impact = impact
        self.isPositive = isPositive
        self.pillarExtract = pillar ?? { _ in nil }
        self.condition = condition
        self.generate = generate
        self.gainCalc = gain
    }
}

// MARK: - Engine

// FIX CON-002: @MainActor isolation weil analyze() und tipDatabase()-Closures L() aufrufen,
// das seit LocalizationManager-Fix @MainActor ist.
// DrivingTipsEngine wird ausschließlich von Views aufgerufen — kein Background-Thread-Konflikt.
@MainActor
final class DrivingTipsEngine {

    static let shared = DrivingTipsEngine()
    private init() {}

    // ═══════════════════════════════════════════════════════════
    // MARK: - Public API
    // ═══════════════════════════════════════════════════════════

    /// Liefert bis zu 5 priorisierte, datengetriebene Fahrtipps.
    func analyze(trip: Trip) -> [RichTip] {
        let a = RichTripAnalysis.from(trip: trip)

        guard trip.distanceKm > 0.4 else {
            return [RichTip(id: "short", category: .efficiency, impact: .low,
                            pillarScore: nil,
                            text: String(format: L("tip.f.short_trip"), a.distanceKm),
                            estimatedGain: 0, priority: 0, isPositive: false)]
        }

        let db = tipDatabase()

        // 1. Filter passende Tips und berechne Priorität
        let matched: [RichTip] = db.compactMap { def in
            guard def.condition(a) else { return nil }
            let gain        = def.gainCalc(a)
            let ps          = def.pillarExtract(a)
            let pillarPenalty = ps.map { 100 - $0 } ?? 40
            let impactBonus = def.impact.rawValue * 12
            let priority    = pillarPenalty + impactBonus + gain
            return RichTip(
                id: def.id, category: def.category, impact: def.impact,
                pillarScore: ps,
                text: def.generate(a),
                estimatedGain: gain,
                priority: priority,
                isPositive: def.isPositive
            )
        }

        // 2. Max 1 Tip pro Kategorie (höchste Priorität gewinnt)
        var usedCategories = Set<String>()
        let deduped = matched
            .sorted { $0.priority > $1.priority }
            .filter { tip in
                if usedCategories.contains(tip.category.rawValue) { return false }
                usedCategories.insert(tip.category.rawValue)
                return true
            }

        // 3. Bis zu 4 Verbesserungstipps, dann ggf. 1 Positiv-Tip auffüllen
        let improvements = deduped.filter { !$0.isPositive }
        let positives    = deduped.filter {  $0.isPositive }
        var result = Array(improvements.prefix(4))
        if result.count < 3, let first = positives.first {
            result.append(first)
        }

        if result.isEmpty {
            return [RichTip(id: "default", category: .efficiency, impact: .low,
                            pillarScore: a.overallScore,
                            text: String(format: L("tip.f.overall_top"), a.overallScore),
                            estimatedGain: 0, priority: 0, isPositive: true)]
        }
        return result
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Tip Database
    // ═══════════════════════════════════════════════════════════

    private func tipDatabase() -> [TipDef] { [

        // ── BREMSEN ─────────────────────────────────────────────

        TipDef(id: "brake_harsh_multi",
               category: .braking, impact: .high,
               pillar: { $0.brakingScore },
               condition: { $0.harshBrakeCount > 2 },
               generate: { a in
                   let perKm = a.distanceKm / Double(a.harshBrakeCount)
                   return String(format: L("tip.f.brake_multi"),
                                 a.harshBrakeCount, a.distanceKm, perKm)
               },
               gain: { a in tipGain(pillar: a.brakingScore) }),

        TipDef(id: "brake_harsh_few",
               category: .braking, impact: .medium,
               pillar: { $0.brakingScore },
               condition: { $0.harshBrakeCount == 1 || $0.harshBrakeCount == 2 },
               generate: { a in String(format: L("tip.f.brake_few"), a.harshBrakeCount) },
               gain: { a in tipGain(pillar: a.brakingScore, divisor: 6) }),

        TipDef(id: "brake_avg_high",
               category: .braking, impact: .medium,
               pillar: { $0.brakingScore },
               condition: { $0.avgBrakeMs2 > 2.5 && $0.brakingScore < 80 && $0.harshBrakeCount == 0 },
               generate: { a in String(format: L("tip.f.brake_avg"), a.avgBrakeMs2) },
               gain: { a in tipGain(pillar: a.brakingScore, divisor: 7) }),

        TipDef(id: "brake_excellent",
               category: .braking, impact: .low,
               pillar: { $0.brakingScore },
               isPositive: true,
               condition: { $0.harshBrakeCount == 0 && $0.distanceKm > 2 && $0.brakingScore > 80 },
               generate: { a in
                   String(format: L("tip.f.brake_excellent"), a.distanceKm, a.brakingScore)
               },
               gain: { _ in 0 }),

        // ── BESCHLEUNIGUNG ───────────────────────────────────────

        TipDef(id: "accel_harsh_multi",
               category: .acceleration, impact: .high,
               pillar: { $0.accelerationScore },
               condition: { $0.harshAccelCount > 2 },
               generate: { a in
                   String(format: L("tip.f.accel_multi"), a.harshAccelCount, a.distanceKm)
               },
               gain: { a in tipGain(pillar: a.accelerationScore) }),

        TipDef(id: "accel_harsh_few",
               category: .acceleration, impact: .medium,
               pillar: { $0.accelerationScore },
               condition: { a in (a.harshAccelCount == 1 || a.harshAccelCount == 2) && a.accelerationScore < 85 },
               generate: { a in String(format: L("tip.f.accel_few"), a.harshAccelCount) },
               gain: { a in tipGain(pillar: a.accelerationScore, divisor: 6) }),

        TipDef(id: "accel_excellent",
               category: .acceleration, impact: .low,
               pillar: { $0.accelerationScore },
               isPositive: true,
               condition: { $0.harshAccelCount == 0 && $0.accelerationScore > 85 && $0.distanceKm > 2 },
               generate: { a in String(format: L("tip.f.accel_excellent"), a.accelerationScore) },
               gain: { _ in 0 }),

        // ── GESCHWINDIGKEIT ──────────────────────────────────────

        TipDef(id: "speed_limit_low",
               category: .speed, impact: .high,
               pillar: { $0.speedScore },
               condition: { $0.hasSpeedLimitData && $0.speedLimitCompliance < 0.80 },
               generate: { a in
                   let compliance = a.speedLimitCompliance * 100
                   let potGain    = max(0, min(18, (80 - a.speedScore) / 3))
                   return String(format: L("tip.f.speed_limit"),
                                 compliance, a.speedScore, potGain)
               },
               gain: { a in tipGain(pillar: a.speedScore) }),

        TipDef(id: "speed_limit_mid",
               category: .speed, impact: .medium,
               pillar: { $0.speedScore },
               condition: { a in
                   a.hasSpeedLimitData &&
                   a.speedLimitCompliance >= 0.80 &&
                   a.speedLimitCompliance < 0.95 &&
                   a.speedScore < 85
               },
               generate: { a in
                   let compliance = a.speedLimitCompliance * 100
                   let potGain    = max(0, min(8, (85 - a.speedScore) / 4))
                   return String(format: L("tip.f.speed_limit"),
                                 compliance, a.speedScore, potGain)
               },
               gain: { a in tipGain(pillar: a.speedScore, divisor: 7) }),

        TipDef(id: "speed_max_high",
               category: .speed, impact: .high,
               pillar: { $0.speedScore },
               condition: { $0.maxSpeedKmh > 150 },
               generate: { a in
                   let maxInt    = Int(a.maxSpeedKmh)
                   let savingPct = max(12, min(30, Int((a.maxSpeedKmh - 130) * 0.85)))
                   return String(format: L("tip.f.speed_high"), maxInt, maxInt, savingPct)
               },
               gain: { a in tipGain(pillar: a.speedScore) }),

        TipDef(id: "speed_variance",
               category: .speed, impact: .medium,
               pillar: { $0.speedScore },
               condition: { $0.speedStdDev > 35 && $0.speedScore < 80 && $0.maxSpeedKmh <= 150 },
               generate: { a in String(format: L("tip.f.speed_variance"), a.speedStdDev) },
               gain: { a in tipGain(pillar: a.speedScore, divisor: 6) }),

        TipDef(id: "speed_excellent",
               category: .speed, impact: .low,
               pillar: { $0.speedScore },
               isPositive: true,
               condition: { $0.speedScore > 88 },
               generate: { a in String(format: L("tip.f.speed_excellent"), a.speedScore) },
               gain: { _ in 0 }),

        // ── KURVENVERHALTEN ──────────────────────────────────────

        TipDef(id: "corner_multi",
               category: .cornering, impact: .high,
               pillar: { $0.corneringScore },
               condition: { $0.harshCornerCount > 1 },
               generate: { a in String(format: L("tip.f.corner_multi"), a.harshCornerCount) },
               gain: { a in tipGain(pillar: a.corneringScore) }),

        TipDef(id: "corner_single",
               category: .cornering, impact: .medium,
               pillar: { $0.corneringScore },
               condition: { $0.harshCornerCount == 1 && $0.corneringScore < 85 },
               generate: { _ in L("tip.f.corner_single") },
               gain: { a in tipGain(pillar: a.corneringScore, divisor: 7) }),

        // ── FAHRKONSISTENZ ───────────────────────────────────────

        TipDef(id: "consistency_low",
               category: .consistency, impact: .high,
               pillar: { $0.consistencyScore },
               condition: { $0.consistencyScore < 70 && $0.distanceKm > 2 },
               generate: { a in
                   let target = min(a.distanceKm * 0.85, a.longestCleanKm * 1.6)
                   return String(format: L("tip.f.consistency_low"),
                                 a.longestCleanKm, max(a.longestCleanKm + 0.5, target))
               },
               gain: { a in tipGain(pillar: a.consistencyScore) }),

        TipDef(id: "consistency_med",
               category: .consistency, impact: .medium,
               pillar: { $0.consistencyScore },
               condition: { a in a.consistencyScore >= 70 && a.consistencyScore < 85 && a.distanceKm > 3 },
               generate: { a in
                   String(format: L("tip.f.consistency_med"),
                          a.consistencyScore, a.longestCleanKm)
               },
               gain: { a in tipGain(pillar: a.consistencyScore, divisor: 6) }),

        // ── EFFIZIENZ ────────────────────────────────────────────

        TipDef(id: "fuel_high",
               category: .efficiency, impact: .high,
               pillar: { $0.efficiencyScore },
               condition: { $0.fuelPer100km > 10 && $0.distanceKm > 2 },
               generate: { a in String(format: L("tip.f.fuel_high"), a.fuelPer100km) },
               gain: { a in tipGain(pillar: a.efficiencyScore) }),

        TipDef(id: "fuel_medium",
               category: .efficiency, impact: .medium,
               pillar: { $0.efficiencyScore },
               condition: { a in a.fuelPer100km > 7 && a.fuelPer100km <= 10 && a.efficiencyScore < 80 },
               generate: { a in String(format: L("tip.f.fuel_medium"), a.fuelPer100km) },
               gain: { a in tipGain(pillar: a.efficiencyScore, divisor: 6) }),

        TipDef(id: "short_trip_eco",
               category: .efficiency, impact: .high,
               pillar: { $0.efficiencyScore },
               condition: { $0.tripType == .shortTrip || $0.distanceKm < 3 },
               generate: { a in String(format: L("tip.f.short_trip"), a.distanceKm) },
               gain: { _ in 0 }),

        TipDef(id: "fuel_excellent",
               category: .efficiency, impact: .low,
               pillar: { $0.efficiencyScore },
               isPositive: true,
               condition: { a in a.fuelPer100km > 0 && a.fuelPer100km < 6 && a.efficiencyScore > 80 },
               generate: { a in
                   String(format: L("tip.f.fuel_excellent"), a.fuelPer100km, a.efficiencyScore)
               },
               gain: { _ in 0 }),

        // ── AUTOBAHN ─────────────────────────────────────────────

        TipDef(id: "highway_cruise",
               category: .speed, impact: .medium,
               pillar: { $0.speedScore },
               condition: { a in
                   a.tripType == .highway && a.speedScore < 88 && a.maxSpeedKmh > 110
               },
               generate: { a in
                   let hwRatio     = (a.speedDist.from80to130 + a.speedDist.over130) * 100
                   let cruiseTarget = Int(min(130, a.avgSpeedKmh + 8))
                   return String(format: L("tip.f.highway_cruise"), hwRatio, cruiseTarget)
               },
               gain: { a in tipGain(pillar: a.speedScore, divisor: 7) }),

        // ── NACHT / TAGESZEIT ────────────────────────────────────

        TipDef(id: "night_heavy",
               category: .timeOfDay, impact: .high,
               pillar: { a in Int(a.timeOfDayMultiplier * 100) },
               condition: { $0.nightDrivingRatio > 0.50 },
               generate: { a in
                   let nightPct = a.nightDrivingRatio * 100
                   return String(format: L("tip.f.night_heavy"),
                                 nightPct, a.timeOfDayMultiplier)
               },
               gain: { a in Int(max(0, min(15, (1.0 - a.timeOfDayMultiplier) * 100 / 3))) }),

        TipDef(id: "rush_hour",
               category: .timeOfDay, impact: .medium,
               pillar: { a in Int(a.timeOfDayMultiplier * 100) },
               condition: { $0.rushHourRatio > 0.60 && $0.nightDrivingRatio < 0.30 },
               generate: { a in
                   String(format: L("tip.f.rush_hour"), a.rushHourRatio * 100)
               },
               gain: { a in Int(max(0, min(8, (1.0 - a.timeOfDayMultiplier) * 100 / 5))) }),

        // ── GLOBALE POSITIVE ─────────────────────────────────────

        TipDef(id: "overall_excellent",
               category: .efficiency, impact: .high,
               pillar: { $0.overallScore },
               isPositive: true,
               condition: { $0.overallScore >= 90 && $0.distanceKm > 2 },
               generate: { a in String(format: L("tip.f.overall_top"), a.overallScore) },
               gain: { _ in 0 }),

        TipDef(id: "overall_good",
               category: .efficiency, impact: .medium,
               pillar: { $0.overallScore },
               isPositive: true,
               condition: { a in a.overallScore >= 80 && a.overallScore < 90 },
               generate: { a in
                   let weakest = weakestPillarName(a)
                   return String(format: L("tip.f.overall_good"), a.overallScore, weakest)
               },
               gain: { _ in 0 }),

    ] }
}

// MARK: - Private Helpers

/// Berechnet den potenziellen Score-Gewinn für einen Pillar.
private func tipGain(pillar score: Int, divisor: Int = 5) -> Int {
    max(0, min(25, (100 - score) / divisor))
}

/// Gibt den Namen des schwächsten Score-Pillars zurück.
// FIX CON-002: @MainActor weil TipCategory.localizedName @MainActor ist.
@MainActor
private func weakestPillarName(_ a: RichTripAnalysis) -> String {
    let pillars: [(Int, String)] = [
        (a.brakingScore,      TipCategory.braking.localizedName),
        (a.accelerationScore, TipCategory.acceleration.localizedName),
        (a.speedScore,        TipCategory.speed.localizedName),
        (a.corneringScore,    TipCategory.cornering.localizedName),
        (a.consistencyScore,  TipCategory.consistency.localizedName),
        (a.efficiencyScore,   TipCategory.efficiency.localizedName),
    ]
    return pillars.min(by: { $0.0 < $1.0 })?.1 ?? ""
}

// MARK: - DrivingTipsEngine: Legacy Summary (still used by analysisCard)
extension DrivingTipsEngine {
    func statisticSummary(trip: Trip) -> [String] {
        var lines: [String] = []
        let dist = trip.speedDistribution
        let pts  = trip.points.filter { $0.speedKmh > 1 }
        guard !pts.isEmpty else { return [L("summary.no_data")] }

        if dist.under30     > 0.01 { lines.append(L("summary.under30",  Int(dist.under30     * 100))) }
        if dist.from30to50  > 0.01 { lines.append(L("summary.30to50",   Int(dist.from30to50  * 100))) }
        if dist.from50to80  > 0.01 { lines.append(L("summary.50to80",   Int(dist.from50to80  * 100))) }
        if dist.from80to130 > 0.01 { lines.append(L("summary.80to130",  Int(dist.from80to130 * 100))) }
        if dist.over130     > 0.01 { lines.append(L("summary.over130",  Int(dist.over130     * 100))) }

        let speeds = pts.map(\.speedKmh)
        let avg    = speeds.reduce(0, +) / Double(speeds.count)
        let maxSpd = speeds.max() ?? 0
        lines.append(L("summary.speed", Int(avg), Int(maxSpd)))

        if trip.estimatedFuelL > 0, trip.distanceKm > 0 {
            let per100 = (trip.estimatedFuelL / trip.distanceKm) * 100
            lines.append(String(format: L("summary.efficiency"), per100))
        }
        return lines
    }
}
