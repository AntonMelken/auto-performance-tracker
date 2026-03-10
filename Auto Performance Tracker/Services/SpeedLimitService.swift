import Foundation
import CoreLocation
import SwiftUI
import Combine

// MARK: - Speed Limit Service (OpenStreetMap Overpass API)

final class SpeedLimitService: ObservableObject {

    static let shared = SpeedLimitService()

    @Published var currentLimit: Int? = nil   // nil = unbekannt
    @Published var isLoading: Bool    = false

    private var lastQueryLocation: CLLocation?
    /// Letzte bekannte Position — wird vom 1-Sekunden-Timer genutzt
    private var latestLocation: CLLocation?
    // NSCache bietet automatisches LRU-Eviction und korrekte Memory-Pressure-Behandlung.
    // NSNumber(value: -1) steht für "kein Limit bekannt" (nil-Ersatz, da NSCache keinen nil-Wert speichert).
    private let cache = NSCache<NSString, NSNumber>()
    private let gridResolution: Double = 0.0004  // ~40m Raster

    private var queryTask: Task<Void, Never>?
    /// 1-Sekunden-Poll-Timer (wie Google Maps Tempolimit-Aktualisierung)
    private var pollTimer: Timer?

    private init() {
        cache.countLimit = 600  // Mehr Cache-Einträge wegen feinerem Raster
    }

    // MARK: - Polling (bei Fahrtbeginn starten, bei Ende stoppen)

    /// Startet den 1-Sekunden-Timer. Führt bei jeder Sekunde einen Update-Check
    /// gegen die zuletzt bekannte Position durch — analog zu Google Maps.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let loc = self.latestLocation else { return }
            self.update(location: loc)
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Update (bei jedem Location-Update aufrufen)
    func update(location: CLLocation) {
        latestLocation = location
        // FIX PERF-003: Statischer 35m-Threshold → bei 100 km/h = 1 Request/1.26s
        // (Overpass-Rate-Limit: ~1 req/s pro IP → kann Throttling triggern).
        // Fix: adaptiver Threshold basierend auf GPS-Speed aus CLLocation.speed.
        //   < 0 (unbekannt) oder < 60 km/h  → 40m  (Stadtfahrt, hohe Granularität)
        //   60–100 km/h (Landstraße)         → 80m  (1 req/3.5s)
        //   > 100 km/h (Autobahn)            → 140m (1 req/5.0s — deutlich unter Rate-Limit)
        let speedKmh = location.speed >= 0 ? location.speed * 3.6 : 0
        let adaptiveThreshold: Double
        switch speedKmh {
        case 100...: adaptiveThreshold = 140
        case 60...:  adaptiveThreshold = 80
        default:     adaptiveThreshold = 40
        }

        if let last = lastQueryLocation,
           last.distance(from: location) < adaptiveThreshold { return }

        // Cache prüfen — NSNumber(-1) bedeutet "kein Limit bekannt"
        let key = gridKey(for: location.coordinate)
        if let cached = cache.object(forKey: key as NSString) {
            let limit = cached.intValue == -1 ? nil : cached.intValue
            DispatchQueue.main.async { [weak self] in self?.currentLimit = limit }
            return
        }

        lastQueryLocation = location
        fetchLimit(for: location.coordinate)
    }

    // Fallback-Reihenfolge: primärer Server → Fallback bei Fehler
    private static let overpassURLs: [String] = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter"
    ]

    private func fetchLimit(for coord: CLLocationCoordinate2D) {
        queryTask?.cancel()
        queryTask = Task {
            let query = buildOverpassQuery(lat: coord.latitude, lon: coord.longitude)

            for urlString in Self.overpassURLs {
                guard let url = URL(string: urlString) else { continue }
                if Task.isCancelled { return }

                var request = URLRequest(url: url)
                request.httpMethod  = "POST"
                request.httpBody    = query.data(using: .utf8)
                request.timeoutInterval = 5

                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    if Task.isCancelled { return }

                    let parsed = parseOverpassResponse(data: data)
                    let key    = gridKey(for: coord)
                    // Nil → NSNumber(-1) als Sentinel-Wert (NSCache speichert kein nil)
                    cache.setObject(NSNumber(value: parsed ?? -1), forKey: key as NSString)

                    await MainActor.run { [weak self] in
                        self?.currentLimit = parsed
                    }
                    return  // Erfolg — kein Fallback nötig
                } catch {
                    // Dieser Server hat versagt → nächsten versuchen
                    continue
                }
            }
            // Alle Server versagt → letztes bekanntes Limit behalten (kein Update)
        }
    }

    // ── Overpass-Query: jetzt mit highway-Tag für Straßentyp-Priorisierung ──
    private func buildOverpassQuery(lat: Double, lon: Double) -> String {
        """
        [out:json][timeout:5];
        (
          way["maxspeed"](around:25,\(lat),\(lon));
        );
        out tags;
        """
    }

    // ── Straßentyp-Priorität (höher = wichtiger) ──
    private func highwayPriority(_ highway: String) -> Int {
        switch highway {
        case "motorway", "motorway_link":                  return 100
        case "trunk", "trunk_link":                        return 90
        case "primary", "primary_link":                    return 80
        case "secondary", "secondary_link":                return 70
        case "tertiary", "tertiary_link":                  return 60
        case "unclassified":                               return 50
        case "residential":                                return 40
        case "living_street":                              return 20
        case "service":                                    return 15
        case "track", "path", "footway", "cycleway":       return 5
        default:                                           return 30
        }
    }

    private func parseOverpassResponse(data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { return nil }

        // (highway-Priorität, speed-limit) Paare sammeln
        var candidates: [(priority: Int, limit: Int)] = []

        for el in elements {
            guard let tags = el["tags"] as? [String: Any],
                  let ms   = tags["maxspeed"] as? String else { continue }

            let highway = tags["highway"] as? String ?? "unknown"
            let prio    = highwayPriority(highway)

            if let val = Int(ms) {
                candidates.append((prio, val))
            } else {
                // Sonderfall: implizite Limits
                switch ms {
                case "DE:urban", "urban":       candidates.append((prio, 50))
                case "DE:rural", "rural":       candidates.append((prio, 100))
                case "DE:motorway", "motorway": candidates.append((prio, 130))
                case "DE:living_street":        candidates.append((prio, 7))
                case "walk":                    candidates.append((prio, 7))
                case "none":                    candidates.append((prio, 999))
                default: break
                }
            }
        }

        // Keine Kandidaten → nil
        guard !candidates.isEmpty else { return nil }

        // Höchste Straßentyp-Priorität gewinnt
        let maxPrio = candidates.map(\.priority).max() ?? 0
        let topCandidates = candidates.filter { $0.priority == maxPrio }

        // Unter gleichrangigen: den häufigsten Wert nehmen
        let limitCounts = Dictionary(grouping: topCandidates, by: \.limit)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }

        guard let best = limitCounts.first?.key else { return nil }
        return best >= 999 ? nil : best
    }

    private func gridKey(for coord: CLLocationCoordinate2D) -> String {
        let latKey = Int(coord.latitude  / gridResolution)
        let lngKey = Int(coord.longitude / gridResolution)
        return "\(latKey)_\(lngKey)"
    }

    func reset() {
        stopPolling()
        currentLimit      = nil
        lastQueryLocation = nil
        latestLocation    = nil
    }
}

// MARK: - VZ274 View (Geschwindigkeitsbegrenzungs-Schild)

struct SpeedLimitView: View {
    let limit: Int?
    var size: CGFloat = 52

    var body: some View {
        if let limit {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

                Circle()
                    .strokeBorder(Color(hex: "E10600"), lineWidth: size * 0.10)
                    .frame(width: size, height: size)

                Text(limitText(limit))
                    .font(.system(size: size * (limit >= 100 ? 0.30 : 0.36),
                                  weight: .black, design: .rounded))
                    .foregroundStyle(Color.black)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: size, height: size)
            .transition(.scale.combined(with: .opacity))
        } else {
            ZStack {
                Circle()
                    .fill(Color(hex: "0F1A2E"))
                    .frame(width: size, height: size)
                Circle()
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1.5)
                    .frame(width: size, height: size)
                Image(systemName: "minus")
                    .font(.system(size: size * 0.3, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .frame(width: size, height: size)
        }
    }

    private func limitText(_ val: Int) -> String {
        val >= 999 ? "∞" : "\(val)"
    }
}

// MARK: - SpeedLimitDisclaimerSheet
// Wird einmalig beim ersten Sehen der Tempolimit-Anzeige gezeigt (Pro-Feature).
struct SpeedLimitDisclaimerSheet: View {

    @AppStorage("hasSeenSpeedLimitDisclaimer") private var hasSeenSpeedLimitDisclaimer = false
    @ObservedObject private var lang = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var accepted = false
    @State private var showMustAccept = false

    var body: some View {
        ZStack {
            Color(hex: "080C14").ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // Drag indicator
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 40, height: 4)
                        .padding(.top, 14)
                        .padding(.bottom, 28)

                    // Icon
                    ZStack {
                        Circle()
                            .fill(Color(hex: "E10600").opacity(0.12))
                            .frame(width: 96, height: 96)
                        Circle()
                            .strokeBorder(Color(hex: "E10600").opacity(0.25), lineWidth: 1.5)
                            .frame(width: 96, height: 96)
                        // Geschwindigkeitsschildform
                        ZStack {
                            Circle().fill(.white).frame(width: 56, height: 56)
                            Circle().strokeBorder(Color(hex: "E10600"), lineWidth: 6).frame(width: 56, height: 56)
                            Text("50")
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(.bottom, 20)

                    Text(lang.localized("speedlimit.disclaimer.title"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    Text(lang.localized("speedlimit.disclaimer.subtitle"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "8A9BB5"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 6)
                        .padding(.bottom, 24)

                    // Body-Text
                    Text(lang.localized("speedlimit.disclaimer.body"))
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "CBD5E1"))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)

                    // Checkbox
                    Button(action: {
                        accepted.toggle()
                        if accepted { showMustAccept = false }
                    }) {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        accepted ? Color.green : Color.white.opacity(0.3),
                                        lineWidth: 1.5
                                    )
                                    .frame(width: 24, height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(accepted ? Color.green.opacity(0.15) : Color.clear)
                                    )
                                if accepted {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.top, 1)

                            Text(lang.localized("speedlimit.disclaimer.checkbox"))
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "CBD5E1"))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                    if showMustAccept {
                        Text(lang.localized("disclaimer.must_accept"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }

                    // Bestätigen
                    Button(action: confirmTapped) {
                        HStack(spacing: 10) {
                            Text(lang.localized("speedlimit.disclaimer.confirm"))
                                .font(.system(size: 17, weight: .semibold))
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(accepted ? .black : Color(hex: "4A5568"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            LinearGradient(
                                colors: accepted
                                    ? [.green, Color(hex: "16A34A")]
                                    : [Color(hex: "1E293B"), Color(hex: "1E293B")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: accepted ? Color.green.opacity(0.35) : .clear, radius: 16, y: 6)
                        .animation(.easeInOut(duration: 0.25), value: accepted)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 48)
                }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(28)
        .presentationBackground(Color(hex: "080C14"))
        .interactiveDismissDisabled(true)
    }

    private func confirmTapped() {
        guard accepted else {
            withAnimation(.easeInOut(duration: 0.2)) { showMustAccept = true }
            return
        }
        hasSeenSpeedLimitDisclaimer = true
        dismiss()
    }
}

#Preview {
    ZStack {
        Color(hex: "080C14").ignoresSafeArea()
        HStack(spacing: 16) {
            SpeedLimitView(limit: 30, size: 64)
            SpeedLimitView(limit: 50, size: 64)
            SpeedLimitView(limit: 100, size: 64)
            SpeedLimitView(limit: 130, size: 64)
            SpeedLimitView(limit: nil, size: 64)
        }
    }
}
