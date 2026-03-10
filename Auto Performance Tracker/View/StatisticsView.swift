import SwiftUI
import SwiftData
import Charts

// MARK: - Time Period Model
enum TimePeriod: String, CaseIterable {
    case day       = "day"
    case week      = "week"
    case month     = "month"
    case year      = "year"
    case total     = "total"
    case custom    = "custom"

    var localizedName: String {
        switch self {
        case .day:       return L("stats.period.day")
        case .week:     return L("stats.period.week")
        case .month:     return L("stats.period.month")
        case .year:      return L("stats.period.year")
        case .total: return L("stats.period.total")
        case .custom:   return L("stats.period.custom")
        }
    }
}

// MARK: - Distance Chart Data Point
private struct DistancePoint: Identifiable {
    var id = UUID()
    let bucket: String
    let bucketSort: Int
    let vehicleName: String
    let km: Double
    let color: Color
}

struct StatisticsView: View {
    @Query(sort: \Trip.startDate, order: .reverse)  private var trips: [Trip]
    @Query(sort: \VehicleProfile.sortOrder)         private var vehicles: [VehicleProfile]

    @EnvironmentObject private var lang: LanguageManager
    @EnvironmentObject private var subscription: SubscriptionManager
    @AppStorage("currentOwnerUserId") private var currentOwnerUserId: String = ""

    @Environment(\.colorScheme) private var cs
    @State private var selectedPeriod:      TimePeriod = .month
    @State private var selectedMonth:       String     = ""
    @State private var customStart:         Date       = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd:           Date       = Date()
    @State private var animatedScore:       Double     = 0
    @State private var fuelVehicleFilter:   UUID?      = nil   // nil = alle
    // MARK: - Fuel Type Helpers

    /// Gibt den Kraftstofftyp einer Fahrt zurück. Zuerst direkt aus Trip,
    /// dann Fallback über vehicleProfileId → VehicleProfile.
    private func tripFuelType(_ trip: Trip) -> String {
        if !trip.vehicleFuelType.isEmpty { return VehicleProfile.canonicalizeFuelType(trip.vehicleFuelType) }
        if let vid = trip.vehicleProfileId,
           let profile = vehicles.first(where: { $0.id == vid }) {
            return VehicleProfile.canonicalizeFuelType(profile.fuelType)
        }
        return "Benzin"
    }

    private func isElectricFuelType(_ fuelType: String) -> Bool {
        fuelType == "Elektrisch" || fuelType == "Electric"
    }

    /// Fahrzeugprofile des aktuell eingeloggten Nutzers
    private var myVehicles: [VehicleProfile] {
        vehicles.filter { $0.ownerUserId == currentOwnerUserId }
    }

    /// Hat der Account mindestens ein E-Auto-Profil?
    private var accountHasElectric: Bool {
        myVehicles.contains { $0.isElectric }
    }

    /// Hat der Account mindestens ein Verbrenner/Hybrid/LPG-Profil?
    private var accountHasCombustion: Bool {
        myVehicles.contains { $0.fuelType != "Elektrisch" }
    }

    /// Verbrenner-Trips im gefilterten Zeitraum (Benzin, Diesel, LPG, Hybrid)
    private var combustionTrips: [Trip] {
        fuelFilteredTrips.filter { !isElectricFuelType(tripFuelType($0)) }
    }

    /// E-Auto-Trips im gefilterten Zeitraum
    private var electricTrips: [Trip] {
        fuelFilteredTrips.filter { isElectricFuelType(tripFuelType($0)) }
    }

    /// Alle im Zeitraum vorhandenen Kraftstoffarten (Verbrenner), dedupliziert
    private var presentCombustionFuelTypes: [String] {
        let types = combustionTrips.map { tripFuelType($0) }
        var seen: [String] = []
        for t in types { if !seen.contains(t) { seen.append(t) } }
        return seen
    }

    // MARK: - Filtered Trips

    /// Nur Trips des aktuell eingeloggten Users
    private var myTrips: [Trip] {
        trips.filter { $0.ownerUserId == currentOwnerUserId }
    }

    private var filteredTrips: [Trip] {
        let cal = Calendar.current
        let now = Date()
        switch selectedPeriod {
        case .day:
            return myTrips.filter { cal.isDateInToday($0.startDate) }
        case .week:
            let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return myTrips.filter { $0.startDate >= start }
        case .month:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM yyyy"
            fmt.locale = LanguageManager.shared.locale
            if selectedMonth.isEmpty { return [] }
            return myTrips.filter { fmt.string(from: $0.startDate) == selectedMonth }
        case .year:
            let year = cal.component(.year, from: now)
            return myTrips.filter { cal.component(.year, from: $0.startDate) == year }
        case .total:
            return myTrips
        case .custom:
            let end = cal.date(byAdding: .day, value: 1, to: customEnd) ?? customEnd
            return myTrips.filter { $0.startDate >= customStart && $0.startDate < end }
        }
    }

    private var fuelFilteredTrips: [Trip] {
        guard let filterID = fuelVehicleFilter else { return filteredTrips }
        return filteredTrips.filter { $0.vehicleProfileId == filterID }
    }

    private var months: [String] {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        fmt.locale = LanguageManager.shared.locale
        let keys = Dictionary(grouping: myTrips) { fmt.string(from: $0.startDate) }.keys
        return Array(keys).sorted(by: >)
    }

    private var periodLabel: String {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = LanguageManager.shared.locale
        switch selectedPeriod {
        case .day:
            fmt.dateStyle = .medium; return fmt.string(from: now)
        case .week:
            fmt.dateFormat = "'KW' w, yyyy"; return fmt.string(from: now)
        case .month:
            return selectedMonth
        case .year:
            return "\(cal.component(.year, from: now))"
        case .total:
            return L("stats.all_trips")
        case .custom:
            fmt.dateStyle = .short
            return "\(fmt.string(from: customStart)) – \(fmt.string(from: customEnd))"
        }
    }

    // MARK: - Gesamtstrecke Daten

    private var distanceChartPoints: [DistancePoint] {
        let cal = Calendar.current

        func bucketInfo(for trip: Trip) -> (label: String, sort: Int)? {
            let d = trip.startDate
            switch selectedPeriod {
            case .day:
                return nil
            case .week:
                let wd = cal.component(.weekday, from: d)
                let names = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
                return (names[wd - 1], wd)
            case .month:
                let w = cal.component(.weekOfMonth, from: d)
                return ("KW\(w)", w)
            case .year:
                let m = cal.component(.month, from: d)
                let fmt = DateFormatter(); fmt.dateFormat = "MMM"; fmt.locale = LanguageManager.shared.locale
                return (fmt.string(from: d), m)
            case .total, .custom:
                let y = cal.component(.year, from: d)
                let m = cal.component(.month, from: d)
                let fmt = DateFormatter(); fmt.dateFormat = "MMM yy"; fmt.locale = LanguageManager.shared.locale
                return (fmt.string(from: d), y * 12 + m)
            }
        }

        func profileColor(for trip: Trip) -> Color {
            if let vid = trip.vehicleProfileId,
               let profile = vehicles.first(where: { $0.id == vid }) {
                return profile.profileColor
            }
            return .cyan
        }

        func vehicleName(for trip: Trip) -> String {
            trip.vehicleProfileName.isEmpty ? "—" : trip.vehicleProfileName
        }

        // Gruppieren: [bucket: [vehicleName: (km, color, sort)]]
        var grouped: [String: [String: (Double, Color, Int)]] = [:]
        for trip in filteredTrips {
            guard let (label, sort) = bucketInfo(for: trip) else { continue }
            let vName = vehicleName(for: trip)
            let clr   = profileColor(for: trip)
            if grouped[label] == nil { grouped[label] = [:] }
            let prev = grouped[label]?[vName]
            grouped[label]?[vName] = ((prev?.0 ?? 0) + trip.distanceKm, clr, sort)
        }

        var points: [DistancePoint] = []
        for (bucket, vehicleMap) in grouped {
            let sort = vehicleMap.values.first?.2 ?? 0
            for (vName, (km, clr, _)) in vehicleMap {
                points.append(DistancePoint(bucket: bucket, bucketSort: sort,
                                            vehicleName: vName, km: km, color: clr))
            }
        }
        return points.sorted { $0.bucketSort < $1.bucketSort }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(cs).ignoresSafeArea()

                if myTrips.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 16) {
                                periodPicker.padding(.horizontal)

                                if selectedPeriod == .month && !months.isEmpty {
                                    monthPicker.padding(.horizontal)
                                }
                                if selectedPeriod == .custom {
                                    customDatePicker.padding(.horizontal)
                                }

                                heroSection
                                monthShareCard

                                if subscription.isPro {
                                    proScoreSection
                                    tripScoreHistoryChart
                                } else {
                                    efficiencyCard
                                }

                                speedTrendChart
                                // Verbrauchs-Charts: nur anzeigen wenn im Zeitraum Fahrten des jeweiligen Typs vorhanden sind
                                if !combustionTrips.isEmpty {
                                    fuelChartCombustion
                                }
                                if !electricTrips.isEmpty {
                                    fuelChartElectric
                                }
                                // Fallback: keine Fahrten mit bekanntem Typ – zeige Standard
                                if combustionTrips.isEmpty && electricTrips.isEmpty {
                                    fuelChartCombustion
                                }
                                distanceChart
                                monthlyGrid
                            }
                            .padding(.bottom, 24)
                        }
                        AdMobBannerView()
                    }
                }
            }
            .navigationTitle(L("stats.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                if selectedMonth.isEmpty { selectedMonth = months.first ?? "" }
                // MEMORY-FIX: forceRecalculateScore() für ALLE Trips auf einmal ist verboten.
                // Jeder Aufruf decoded points + motionSamples aus JSON (je 2-8 MB pro Trip).
                // 20 Trips gleichzeitig = ~194 MB RAM-Spike → OOM-Kill auf älteren Geräten.
                //
                // Stattdessen: nur Trips ohne Score werden lazy (einzeln) beim Rendern
                // ihrer UI-Elemente nachberechnet. Trips mit bereits vorhandenem Score
                // sind korrekt – forceRecalculate war nur als einmalige Migration gedacht.
                myTrips.filter { $0.drivingScoreData.isEmpty }
                       .forEach { $0.recalculateMissingScoreIfNeeded() }
                AnalyticsService.shared.trackFeatureUsed("statistics_viewed")
            }
            .onChange(of: months) { _, newMonths in
                if !newMonths.contains(selectedMonth) { selectedMonth = newMonths.first ?? "" }
            }
        }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TimePeriod.allCases, id: \.self) { period in
                    Button(period.localizedName) {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedPeriod = period }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(selectedPeriod == period ? Color.cyan : Theme.card(cs))
                    .foregroundStyle(selectedPeriod == period ? Color.black : Color.gray)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(selectedPeriod == period ? Color.clear : Theme.border(cs)))
                }
            }
        }
    }

    private var monthPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(months, id: \.self) { m in
                    Button(m) { selectedMonth = m }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selectedMonth == m ? Color.cyan.opacity(0.2) : Theme.card(cs))
                        .foregroundStyle(selectedMonth == m ? Color.cyan : Color.gray)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(selectedMonth == m ? Color.cyan.opacity(0.5) : Theme.border(cs)))
                }
            }
        }
    }

    private var customDatePicker: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("stats.from")).font(.caption).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.5)
                    DatePicker("", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                        .labelsHidden().accentColor(.cyan)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L("stats.to")).font(.caption).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.5)
                    DatePicker("", selection: $customEnd, in: customStart..., displayedComponents: .date)
                        .labelsHidden().accentColor(.cyan)
                }
            }
        }
        .padding(14)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.2)))
    }

    // MARK: - Hero

    private var heroSection: some View {
        let totalKm = filteredTrips.reduce(0.0) { $0 + $1.distanceKm }
        let count   = filteredTrips.count

        return HStack(spacing: 12) {
            heroMetric(value: String(format: "%.0f", totalKm), unit: "km", label: L("stats.total_distance"))
            Divider().frame(height: 50).background(Color.white.opacity(0.1))
            heroMetric(value: "\(count)", unit: count == 1 ? L("stats.trip_singular") : L("stats.trip_plural"), label: periodLabel)
        }
        .padding(20)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    private func heroMetric(value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 34, weight: .thin, design: .rounded)).foregroundStyle(Theme.text(cs))
                Text(unit).font(.system(size: 14, weight: .semibold)).foregroundStyle(.cyan)
            }
            Text(label).font(.caption).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Share Helper

    private func presentShareSheet(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(vc, animated: true)
    }

    // MARK: - Stats Share Card

    /// Rendert und teilt die Statistik-Share-Card als Bild
    @MainActor
    private func shareStatsCard() {
        let trips     = filteredTrips
        let totalKm   = trips.reduce(0.0) { $0 + $1.distanceKm }
        let avgScore  = trips.isEmpty ? 0 : trips.map { $0.efficiencyScore }.reduce(0, +) / trips.count
        let totalCost = trips.reduce(0.0) { $0 + $1.estimatedCostEur }
        let totalFuel = trips.reduce(0.0) { $0 + $1.estimatedFuelL }
        let avgSpeed  = trips.isEmpty ? 0.0 : trips.map { $0.avgSpeedKmh }.reduce(0, +) / Double(trips.count)
        let totalSecs = trips.reduce(0.0) { $0 + $1.durationSeconds }
        let hasElectric = trips.contains { isElectricFuelType(tripFuelType($0)) }

        guard let image = StatsShareCardRenderer.render(
            period: periodLabel,
            tripCount: trips.count,
            totalKm: totalKm,
            avgScore: avgScore,
            totalCost: totalCost,
            totalFuel: totalFuel,
            avgSpeedKmh: avgSpeed,
            totalDurationSeconds: totalSecs,
            isElectric: hasElectric
        ) else { return }

        presentShareSheet(items: [image])
    }

    /// Subtile Share-Card: nur bei ≥ 3 Fahrten und Ø Score ≥ 75
    @ViewBuilder
    private var monthShareCard: some View {
        let avgScore = filteredTrips.isEmpty ? 0 :
            filteredTrips.map { $0.efficiencyScore }.reduce(0, +) / filteredTrips.count

        if filteredTrips.count >= 3 && avgScore >= 75 {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: L("share.month.card"), avgScore, filteredTrips.reduce(0.0) { $0 + $1.distanceKm }))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text(cs))
                }
                Spacer()
                Button(action: shareStatsCard) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                        Text(L("share.month.button"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.cyan.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.cyan.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.card(cs))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.2), lineWidth: 1))
            .padding(.horizontal)
        }
    }

    // MARK: - Pro Score

    private var proScoreSection: some View {
        let aggregated = DrivingScoreEngine.shared.aggregate(trips: filteredTrips)
        let score = aggregated?.overall ?? 0
        let color: Color = score >= 80 ? .green : score >= 60 ? Color(hex: "F59E0B") : .red
        let label = score >= 80 ? L("stats.style_excellent") : score >= 60 ? L("stats.style_good") : L("stats.style_aggressive")

        return VStack(spacing: 16) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 8).frame(width: 80, height: 80)
                    Circle().trim(from: 0, to: CGFloat(animatedScore) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 80, height: 80).rotationEffect(.degrees(-90))
                    Text("\(score)")
                        .font(.system(size: 22, weight: .regular, design: .rounded)).foregroundStyle(color)
                        .contentTransition(.numericText()).animation(.easeOut(duration: 0.8), value: score)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("dscore.title")).font(.headline).foregroundStyle(Theme.text(cs))
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    Text(periodLabel).font(.caption).foregroundStyle(.secondary.opacity(0.7))
                }
                Spacer()
            }

            if let agg = aggregated {
                let pillars: [(String, Int, Color)] = [
                    (L("dscore.p.speed"),   agg.speedScore,        Color(hex: "3B82F6")),
                    (L("dscore.p.accel"),   agg.accelerationScore,  Color(hex: "22C55E")),
                    (L("dscore.p.brake"),   agg.brakingScore,       Color(hex: "EF4444")),
                    (L("dscore.p.corner"),  agg.corneringScore,     Color(hex: "F59E0B")),
                    (L("dscore.p.time"),    DrivingScoreEngine.shared.timeOfDayScore(from: agg.timeOfDayMultiplier), Color(hex: "818CF8")),
                    (L("dscore.p.consist"), agg.consistencyScore,   Color(hex: "06B6D4")),
                    (L("dscore.p.effic"),   agg.efficiencyScore,    Color(hex: "10B981")),
                ]
                VStack(spacing: 6) {
                    ForEach(pillars.indices, id: \.self) { i in
                        let (name, val, clr) = pillars[i]
                        HStack(spacing: 8) {
                            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.border(cs))
                                    RoundedRectangle(cornerRadius: 2).fill(clr)
                                        .frame(width: geo.size.width * CGFloat(min(val, 100)) / 100)
                                }
                            }
                            .frame(height: 5)
                            Text("\(val)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(clr).frame(width: 26, alignment: .trailing)
                        }
                    }
                }

                // Score-basierte Fahrtipps für den ausgewählten Zeitraum
                let scoreTips = DrivingScoreEngine.shared.tipsForScore(agg)
                if !scoreTips.isEmpty {
                    Divider().background(Theme.border(cs))
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("detail.smart_tips"), systemImage: "lightbulb.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.cyan)
                        ForEach(scoreTips.prefix(3), id: \.self) { tip in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.cyan.opacity(0.7))
                                    .padding(.top, 2)
                                Text(tip)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: "8A9BB5"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
        .padding(.horizontal)
        .onAppear {
            animatedScore = 0
            withAnimation(.easeOut(duration: 1.0).delay(0.3)) { animatedScore = Double(score) }
        }
        .onChange(of: score) { _, newScore in
            withAnimation(.easeOut(duration: 0.8)) { animatedScore = Double(newScore) }
        }
    }

    // MARK: - Free Efficiency Card

    private var efficiencyCard: some View {
        let score = filteredTrips.isEmpty ? 0 : filteredTrips.map(\.efficiencyScore).reduce(0, +) / filteredTrips.count
        let color: Color = score >= 80 ? .green : score >= 60 ? Color(hex: "F59E0B") : .red
        let label = score >= 80 ? L("stats.style_excellent") : score >= 60 ? L("stats.style_good") : L("stats.style_aggressive")

        // Score-basierte Tips für Freinutzer (aus DrivingScoreEngine)
        let aggregated = DrivingScoreEngine.shared.aggregate(trips: filteredTrips)
        let scoreTips = aggregated.map { DrivingScoreEngine.shared.tipsForScore($0) } ?? []

        return VStack(spacing: 16) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 8).frame(width: 80, height: 80)
                    Circle().trim(from: 0, to: CGFloat(animatedScore) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 80, height: 80).rotationEffect(.degrees(-90))
                    Text("\(score)")
                        .font(.system(size: 22, weight: .regular, design: .rounded)).foregroundStyle(color)
                        .contentTransition(.numericText()).animation(.easeOut(duration: 0.8), value: score)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("dscore.title")).font(.headline).foregroundStyle(Theme.text(cs))
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Fahrtipps basierend auf dem aggregierten Score
            if !scoreTips.isEmpty {
                Divider().background(Theme.border(cs))
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("detail.smart_tips"), systemImage: "lightbulb.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.cyan)
                    ForEach(scoreTips.prefix(3), id: \.self) { tip in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.cyan.opacity(0.7))
                                .padding(.top, 2)
                            Text(tip)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: "8A9BB5"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
        .padding(.horizontal)
        .onAppear {
            animatedScore = 0
            withAnimation(.easeOut(duration: 1.0).delay(0.3)) { animatedScore = Double(score) }
        }
        .onChange(of: score) { _, newScore in
            withAnimation(.easeOut(duration: 0.8)) { animatedScore = Double(newScore) }
        }
    }

    // MARK: - Score History Chart

    private var tripScoreHistoryChart: some View {
        let recentTrips = Array(filteredTrips.prefix(10).reversed())
        guard recentTrips.count > 1 else { return AnyView(EmptyView()) }

        let scores = recentTrips.map { $0.drivingScore?.overall ?? $0.efficiencyScore }
        let avg    = scores.reduce(0, +) / scores.count
        let maxS   = scores.max() ?? 100
        let minS   = max(0, (scores.min() ?? 0) - 10)
        let range  = Double(max(maxS - minS, 10))

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("stats.score_history"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary).textCase(.uppercase).tracking(0.5)
                    Spacer()
                    Text(L("stats.score_avg", avg)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.cyan)
                }

                GeometryReader { geo in
                    let hPad: CGFloat = 16  // horizontales Padding damit Rand-Punkte nicht abgeschnitten werden
                    let vPad: CGFloat = 26  // vertikales Padding für Labels oberhalb/unterhalb der Punkte
                    let w     = max(0, geo.size.width - hPad * 2)
                    let h     = max(0, geo.size.height - vPad * 2)
                    let step  = (w > 0 && recentTrips.count > 1)
                        ? w / CGFloat(recentTrips.count - 1)
                        : 1.0

                    // Guard: beim ersten Layout-Pass kann Größe 0 sein → sonst NaN in CoreGraphics
                    if w > 0, h > 0 {
                        let avgY = vPad + h - h * CGFloat(Double(avg - minS) / range)

                        ZStack {
                            Path { p in p.move(to: CGPoint(x: hPad, y: avgY)); p.addLine(to: CGPoint(x: hPad + w, y: avgY)) }
                                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                            Path { p in
                                for (i, s) in scores.enumerated() {
                                    let x = hPad + CGFloat(i) * step
                                    let y = vPad + h - h * CGFloat(Double(s - minS) / range)
                                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                                }
                                p.addLine(to: CGPoint(x: hPad + CGFloat(scores.count-1)*step, y: vPad + h))
                                p.addLine(to: CGPoint(x: hPad, y: vPad + h)); p.closeSubpath()
                            }
                            .fill(LinearGradient(colors: [Color.cyan.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))

                            Path { p in
                                for (i, s) in scores.enumerated() {
                                    let x = hPad + CGFloat(i)*step
                                    let y = vPad + h - h * CGFloat(Double(s-minS)/range)
                                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                            ForEach(scores.indices, id: \.self) { i in
                                let x = hPad + CGFloat(i)*step
                                let s = scores[i]
                                let y = vPad + h - h * CGFloat(Double(s-minS)/range)
                                let c: Color = s >= 80 ? .green : s >= 60 ? Color(hex: "F59E0B") : .red
                                ZStack {
                                    Circle().fill(Theme.bg(cs)).frame(width:10,height:10)
                                    Circle().fill(c).frame(width:7,height:7)
                                }.position(x: x, y: y)
                                // Label unterhalb des Punktes wenn zu nah am oberen Rand, sonst oberhalb
                                let labelY = y < vPad + 14 ? y + 14 : y - 12
                                Text("\(s)").font(.system(size:9,weight:.bold)).foregroundStyle(c).position(x: x, y: labelY)
                            }
                        }
                    }
                }
                .frame(height: 120)

                HStack {
                    ForEach(recentTrips.indices, id: \.self) { i in
                        Text("F\(i+1)").font(.system(size:9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(16)
            .background(Theme.card(cs))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
            .padding(.horizontal)
        )
    }

    // MARK: - Speed Trend (Balken mit Geschwindigkeitsfarben)

    private var speedTrendChart: some View {
        let recentTrips = Array(filteredTrips.prefix(15).reversed())
        let maxSpeed    = recentTrips.map(\.avgSpeedKmh).max() ?? 0
        let yMax        = max(maxSpeed * 1.2, 30)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("stats.speed_trend"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(1)

            if recentTrips.isEmpty {
                emptyChartPlaceholder(height: 180)
            } else {
                Chart {
                    ForEach(recentTrips.indices, id: \.self) { i in
                        let speed = recentTrips[i].avgSpeedKmh
                        let color = SpeedColor.from(kmh: speed).swiftUIColor
                        BarMark(
                            x: .value(L("chart.trip"), "F\(i+1)"),
                            y: .value(L("chart.speed"), speed)
                        )
                        // Satte SpeedColor — kein Gradient-Ausblenden, exakt wie in der Legende
                        .foregroundStyle(color)
                        .cornerRadius(5)
                        .annotation(position: .top) {
                            Text(String(format: "%.0f", speed))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(color)
                        }
                    }
                }
                .frame(height: 180)
                .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(.secondary) } }
                .chartYAxis { AxisMarks {
                    AxisGridLine().foregroundStyle(Theme.border(cs))
                    AxisValueLabel().foregroundStyle(.secondary)
                }}
                .chartYScale(domain: 0...yMax)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(SpeedColor.allCases, id: \.rawValue) { sc in
                            legendItem(color: sc.swiftUIColor, label: sc.rangeLabel)
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Fuel Chart: Verbrenner (Benzin / Diesel / LPG / Hybrid → L)

    private var fuelChartCombustion: some View {
        let recentTrips = Array(combustionTrips.prefix(15).reversed())
        let maxFuel     = recentTrips.map(\.estimatedFuelL).max() ?? 0
        let yMax        = max(maxFuel * 1.2, 1.0)

        // Chart-Titel: zeige spezifische Kraftstoffarten wenn mehr als eine vorhanden
        let fuelLabel: String = {
            let types = presentCombustionFuelTypes
            if types.count == 1 {
                switch types[0] {
                case "Diesel":  return L("stats.fuel_per_trip_diesel")
                case "LPG":     return L("stats.fuel_per_trip_lpg")
                default:        return L("stats.fuel_per_trip")
                }
            }
            return L("stats.fuel_per_trip")
        }()

        return VStack(alignment: .leading, spacing: 12) {
            Text(fuelLabel)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(1)

            // Fahrzeug-Filter (nur wenn > 1 Verbrenner-Fahrzeug)
            let combustionVehicles = myVehicles.filter { $0.fuelType != "Elektrisch" }
            if combustionVehicles.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(label: L("stats.all_vehicles"),
                                   color: .cyan,
                                   isActive: fuelVehicleFilter == nil) {
                            withAnimation { fuelVehicleFilter = nil }
                        }
                        ForEach(combustionVehicles) { v in
                            filterChip(label: v.name,
                                       color: v.profileColor,
                                       isActive: fuelVehicleFilter == v.id) {
                                withAnimation { fuelVehicleFilter = (fuelVehicleFilter == v.id) ? nil : v.id }
                            }
                        }
                    }
                }
            }

            if recentTrips.isEmpty {
                emptyChartPlaceholder(height: 160)
            } else {
                Chart {
                    ForEach(recentTrips.indices, id: \.self) { i in
                        let trip  = recentTrips[i]
                        let color = vehicleColor(for: trip)
                        BarMark(
                            x: .value(L("chart.trip"), "F\(i+1)"),
                            y: .value(L("chart.liters"), trip.estimatedFuelL)
                        )
                        .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.55)],
                                                        startPoint: .top, endPoint: .bottom))
                        .cornerRadius(6)
                        .annotation(position: .top) {
                            Text(String(format: "%.2f", trip.estimatedFuelL))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(color)
                        }
                    }
                }
                .frame(height: 160)
                .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(.secondary) } }
                .chartYAxis { AxisMarks {
                    AxisGridLine().foregroundStyle(Theme.border(cs))
                    AxisValueLabel().foregroundStyle(.secondary)
                }}
                .chartYScale(domain: 0...yMax)

                if combustionVehicles.count > 1 && fuelVehicleFilter == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(combustionVehicles) { v in legendItem(color: v.profileColor, label: v.name) }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Fuel Chart: Elektro (kWh)

    private var fuelChartElectric: some View {
        let recentTrips = Array(electricTrips.prefix(15).reversed())
        let maxFuel     = recentTrips.map(\.estimatedFuelL).max() ?? 0
        let yMax        = max(maxFuel * 1.2, 1.0)

        let electricVehicles = myVehicles.filter { $0.isElectric }

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("stats.fuel_per_trip_kwh"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(1)

            // Filter-Chips: wie bei Verbrennern – immer anzeigen (auch bei 1 Fahrzeug)
            if !electricVehicles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(label: L("stats.all_vehicles"),
                                   color: .cyan,
                                   isActive: fuelVehicleFilter == nil) {
                            withAnimation { fuelVehicleFilter = nil }
                        }
                        ForEach(electricVehicles) { v in
                            filterChip(label: v.name,
                                       color: v.profileColor,
                                       isActive: fuelVehicleFilter == v.id) {
                                withAnimation { fuelVehicleFilter = (fuelVehicleFilter == v.id) ? nil : v.id }
                            }
                        }
                    }
                }
            }

            if recentTrips.isEmpty {
                emptyChartPlaceholder(height: 160)
            } else {
                Chart {
                    ForEach(recentTrips.indices, id: \.self) { i in
                        let trip  = recentTrips[i]
                        let color = vehicleColor(for: trip)
                        BarMark(
                            x: .value(L("chart.trip"), "F\(i+1)"),
                            y: .value(L("chart.kwh"), trip.estimatedFuelL)
                        )
                        .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.55)],
                                                        startPoint: .top, endPoint: .bottom))
                        .cornerRadius(6)
                        .annotation(position: .top) {
                            Text(String(format: "%.2f", trip.estimatedFuelL))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(color)
                        }
                    }
                }
                .frame(height: 160)
                .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(.secondary) } }
                .chartYAxis { AxisMarks {
                    AxisGridLine().foregroundStyle(Theme.border(cs))
                    AxisValueLabel().foregroundStyle(.secondary)
                }}
                .chartYScale(domain: 0...yMax)

                // Legende: immer anzeigen (auch bei 1 E-Fahrzeug), wie bei Verbrennern
                if !electricVehicles.isEmpty && fuelVehicleFilter == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(electricVehicles) { v in legendItem(color: v.profileColor, label: v.name) }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Gesamtstrecke (NEU)

    private var distanceChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("stats.distance_chart"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(1)

            if selectedPeriod == .day {
                // Nur ab Woche verfügbar
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                        Text(L("stats.from_week_hint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 90)
            } else if distanceChartPoints.isEmpty {
                emptyChartPlaceholder(height: 160)
            } else {
                let pts    = distanceChartPoints
                let totals = Dictionary(grouping: pts, by: \.bucket).mapValues { $0.reduce(0.0) { $0 + $1.km } }
                let yMax   = max((totals.values.max() ?? 0) * 1.2, 10.0)
                let totalKm = filteredTrips.reduce(0.0) { $0 + $1.distanceKm }

                // Unique Buckets mit Sort-Order für Gesamt-Annotation
                let bucketTotals: [(bucket: String, sort: Int, total: Double)] = {
                    var seen: [String: (Int, Double)] = [:]
                    for pt in pts {
                        let existing = seen[pt.bucket]
                        seen[pt.bucket] = (pt.bucketSort, (existing?.1 ?? 0) + pt.km)
                    }
                    return seen.map { (bucket: $0.key, sort: $0.value.0, total: $0.value.1) }
                        .sorted { $0.sort < $1.sort }
                }()

                Chart {
                    // Gestapelte Balken ohne individuelle Annotation
                    ForEach(pts) { pt in
                        BarMark(
                            x: .value("Zeit", pt.bucket),
                            y: .value("km", pt.km)
                        )
                        .foregroundStyle(pt.color)
                        .cornerRadius(4)
                    }
                    // Unsichtbare PointMarks nur für Gesamt-Beschriftung pro Bucket
                    ForEach(bucketTotals, id: \.bucket) { t in
                        PointMark(
                            x: .value("Zeit", t.bucket),
                            y: .value("km", t.total)
                        )
                        .opacity(0)
                        .annotation(position: .top) {
                            Text(String(format: "%.0f", t.total))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                    }
                }
                .frame(height: 160)
                .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(.secondary).font(.system(size: 10)) } }
                .chartYAxis { AxisMarks {
                    AxisGridLine().foregroundStyle(Theme.border(cs))
                    AxisValueLabel().foregroundStyle(.secondary)
                }}
                .chartYScale(domain: 0...yMax)

                HStack {
                    Text(L("stats.total_distance")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f km", totalKm))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.cyan)
                }
                .padding(.top, 4)

                if vehicles.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(vehicles) { v in legendItem(color: v.profileColor, label: v.name) }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Grid

    private var monthlyGrid: some View {
        let avgSpeed  = filteredTrips.isEmpty ? 0.0 : filteredTrips.map(\.avgSpeedKmh).reduce(0, +) / Double(filteredTrips.count)
        let maxSpeed  = filteredTrips.map(\.maxSpeedKmh).max() ?? 0
        let totalCost = filteredTrips.reduce(0.0) { $0 + $1.estimatedCostEur }
        let totalSecs = filteredTrips.reduce(0.0) { $0 + $1.durationSeconds }
        let h = Int(totalSecs) / 3600
        let m = (Int(totalSecs) % 3600) / 60

        // Verbrenner-Verbrauch aufgeschlüsselt nach Kraftstoffart
        let benzinL  = filteredTrips.filter { tripFuelType($0) == "Benzin" || tripFuelType($0) == "Hybrid" }
                                    .reduce(0.0) { $0 + $1.estimatedFuelL }
        let dieselL  = filteredTrips.filter { tripFuelType($0) == "Diesel" }
                                    .reduce(0.0) { $0 + $1.estimatedFuelL }
        let lpgL     = filteredTrips.filter { tripFuelType($0) == "LPG" }
                                    .reduce(0.0) { $0 + $1.estimatedFuelL }
        let kWh      = filteredTrips.filter { isElectricFuelType(tripFuelType($0)) }
                                    .reduce(0.0) { $0 + $1.estimatedFuelL }

        let hasBenzin   = benzinL > 0
        let hasDiesel   = dieselL > 0
        let hasLPG      = lpgL > 0
        let hasElectric = kWh > 0

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatsCard(label: L("stats.avg_speed"),  value: "\(Int(avgSpeed)) km/h",        icon: "speedometer",          color: .cyan)
            StatsCard(label: L("stats.max_speed"),  value: "\(Int(maxSpeed)) km/h",        icon: "bolt.fill",            color: .orange)

            if hasBenzin {
                StatsCard(label: L("stats.total_fuel_benzin"), value: String(format: "%.1f L", benzinL), icon: "fuelpump.fill",   color: Color(hex: "EF4444"))
            }
            if hasDiesel {
                StatsCard(label: L("stats.total_fuel_diesel"), value: String(format: "%.1f L", dieselL), icon: "fuelpump.fill",   color: Color(hex: "F59E0B"))
            }
            if hasLPG {
                StatsCard(label: L("stats.total_fuel_lpg"),    value: String(format: "%.1f L", lpgL),    icon: "flame.fill",       color: Color(hex: "A855F7"))
            }
            if hasElectric {
                StatsCard(label: L("stats.total_kwh"),         value: String(format: "%.1f kWh", kWh),  icon: "bolt.circle.fill", color: Color(hex: "00D4FF"))
            }
            // Fallback: kein Profil angelegt
            if !hasBenzin && !hasDiesel && !hasLPG && !hasElectric {
                let totalFuel = filteredTrips.reduce(0.0) { $0 + $1.estimatedFuelL }
                StatsCard(label: L("stats.total_fuel"), value: String(format: "%.1f L", totalFuel), icon: "fuelpump.fill", color: .blue)
            }

            StatsCard(label: L("stats.total_cost"), value: String(format: "%.2f €", totalCost), icon: "eurosign",        color: .green)
            StatsCard(label: L("stats.total_time"), value: "\(h)h \(m)m",                  icon: "clock.fill",           color: Color(hex: "F59E0B"))
            StatsCard(label: L("stats.trips_count"),value: "\(filteredTrips.count)",        icon: "list.bullet.rectangle",color: .purple)
        }
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private func vehicleColor(for trip: Trip) -> Color {
        if let vid = trip.vehicleProfileId,
           let profile = vehicles.first(where: { $0.id == vid }) {
            return profile.profileColor
        }
        return SpeedColor.from(kmh: trip.avgSpeedKmh).swiftUIColor
    }

    private func filterChip(label: String, color: Color, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isActive ? color.opacity(0.25) : Theme.card(cs))
                .foregroundStyle(isActive ? color : Color.gray)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isActive ? color.opacity(0.5) : Theme.border(cs)))
        }
        .buttonStyle(.plain)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func emptyChartPlaceholder(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))
            Text(filteredTrips.isEmpty ? L("stats.no_data_period") : L("stats.no_data"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(height: height)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 56)).foregroundStyle(.secondary)
            Text(L("stats.empty_title")).font(.title3).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(L("stats.empty_message"))
                .font(.subheadline).foregroundStyle(Color(hex: "4A5A70")).multilineTextAlignment(.center)
        }
        .padding()
    }
}

private struct StatsCard: View {
    let label: String; let value: String; let icon: String; let color: Color
    @Environment(\.colorScheme) private var cs
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(value)
                .font(.system(size: 22, weight: .regular, design: .rounded)).foregroundStyle(Theme.text(cs))
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
    }
}
