import SwiftUI
import SwiftData

// MARK: - TripListView

struct TripListView: View {
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [VehicleProfile]

    @EnvironmentObject private var lang: LanguageManager
    @AppStorage("currentOwnerUserId") private var currentOwnerUserId: String = ""
    @AppStorage("deepLinkTripId") private var deepLinkTripId: String = ""

    @State private var selectedTrip: Trip?
    @State private var searchText = ""
    @Environment(\.colorScheme) private var cs

    /// Nur Trips des aktuellen Users
    private var myTrips: [Trip] {
        trips.filter { $0.ownerUserId == currentOwnerUserId }
    }

    private var filtered: [Trip] {
        guard !searchText.isEmpty else { return myTrips }
        return myTrips.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(cs).ignoresSafeArea()

                VStack(spacing: 0) {
                    if myTrips.isEmpty {
                        emptyState
                    } else {
                        List {
                            ForEach(filtered) { trip in
                                TripRowView(
                                    trip: trip,
                                    profile: profiles.first(where: { $0.id == trip.vehicleProfileId })
                                        ?? profiles.first(where: \.isDefault)
                                        ?? profiles.first
                                )
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                    .onTapGesture { selectedTrip = trip }
                            }
                            .onDelete(perform: deleteTrips)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .padding(.top, 0)
                    }

                    AdMobBannerView()
                }
            }
            .navigationTitle(L("trips.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $searchText, prompt: L("trips.search"))
            .onChange(of: deepLinkTripId) { _, newId in
                guard !newId.isEmpty,
                      let uuid = UUID(uuidString: newId),
                      let trip = myTrips.first(where: { $0.id == uuid })
                else { return }
                selectedTrip = trip
                deepLinkTripId = ""
            }
            .sheet(item: $selectedTrip) { trip in
                // Korrekte Profil-Zuordnung: erst trip.vehicleProfileId, dann Default
                let tripProfile = profiles.first(where: { $0.id == trip.vehicleProfileId })
                    ?? profiles.first(where: \.isDefault)
                    ?? profiles.first
                TripDetailView(trip: trip, profile: tripProfile, allProfiles: profiles)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "car.rear.road.lane.dashed")
                .font(.system(size: 56)).foregroundStyle(.secondary)
            Text(L("trips.empty_title"))
                .font(.title3).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(L("trips.empty_message"))
                .font(.subheadline).foregroundStyle(Color(hex: "4A5A70")).multilineTextAlignment(.center)
        }.padding()
    }

    private func deleteTrips(at offsets: IndexSet) {
        for i in offsets { ctx.delete(filtered[i]) }
        try? ctx.save()
    }
}

// MARK: - TripRowView

struct TripRowView: View {
    let trip: Trip
    let profile: VehicleProfile?
    @Environment(\.colorScheme) private var cs

    private var isElectric: Bool { profile?.isElectric == true }
    private var cat: SpeedColor { trip.speedColorCategory }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(trip.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text(cs))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(trip.formattedDate)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if !trip.vehicleProfileName.isEmpty {
                            Text("·").foregroundStyle(.secondary).font(.caption)
                            Text(trip.vehicleProfileName)
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.cyan.opacity(0.7))
                        }
                    }
                }
                Spacer()
                // Score-Badge
                ZStack {
                    Circle()
                        .fill(scoreColor(trip.efficiencyScore).opacity(0.15))
                        .frame(width: 42, height: 42)
                    Text("\(trip.efficiencyScore)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreColor(trip.efficiencyScore))
                }
            }

            // Metriken
            HStack(spacing: 0) {
                TripMetric(value: trip.formattedDistance, label: L("trips.metric.distance"), icon: "road.lanes", color: cat.swiftUIColor)
                Divider().frame(height: 28)
                TripMetric(value: trip.formattedDuration, label: L("trips.metric.time"), icon: "clock", color: .blue)
                Divider().frame(height: 28)
                TripMetric(value: "\(Int(trip.avgSpeedKmh)) km/h", label: L("trips.metric.avgspeed"), icon: "speedometer", color: .cyan)
                Divider().frame(height: 28)
                TripMetric(
                    value: isElectric
                        ? String(format: "%.2f kWh", trip.estimatedFuelL)
                        : String(format: "%.1f L", trip.estimatedFuelL),
                    label: L("trips.metric.fuel"),
                    icon: isElectric ? "bolt.fill" : "fuelpump",
                    color: .gray
                )
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(cat.swiftUIColor.opacity(0.25), lineWidth: 1))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(cat.swiftUIColor)
                .frame(width: 3)
                .padding(.vertical, 12)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 80 ? .green : score >= 60 ? Color(hex: "F59E0B") : .red
    }
}

private struct TripMetric: View {
    let value: String
    let label: String
    let icon: String
    var color: Color = .cyan

    @Environment(\.colorScheme) private var cs

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(value).font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.text(cs)).minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - TripDetailView

struct TripDetailView: View {
    let trip: Trip
    let profile: VehicleProfile?
    let allProfiles: [VehicleProfile]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Environment(\.colorScheme) private var cs
    @State private var showProfilePicker = false
    @State private var showExportError   = false   // FIX QUAL-004: Export-Fehleranzeige
    @State private var exportErrorMsg    = ""
    @EnvironmentObject private var subscription: SubscriptionManager

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(cs).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {

                        // Karte
                        if trip.points.count >= 1 {
                            TripMapView(trip: trip)
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border(cs)))
                                .padding(.horizontal)

                            speedLegend
                        }

                        // Fahrzeugprofil-Anzeige mit Wechsel-Button
                        vehicleProfileCard

                        metricsGrid
                        fuelCard

                        // Driving Score
                        if subscription.isPro {
                            if let score = trip.drivingScore {
                                drivingScoreCard(score: score)
                                pillarBreakdown(score: score)
                                scoreDetailsCard(score: score)
                            } else {
                                analysisCard
                            }
                            smartTipsCard
                        } else {
                            freeScoreCard
                            proTeaser
                        }

                        shareButton
                        exportButtons
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle(trip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                // MEMORY-FIX: forceRecalculateScore() decoded points + motionSamples aus JSON
                // (zusammen bis zu ~10 MB pro Trip). Wird dies bei jedem Öffnen des Detail-Views
                // aufgerufen, verursacht es unnötige RAM-Spikes und CPU-Last.
                //
                // Jetzt: Score nur dann neu berechnen, wenn er tatsächlich fehlt.
                // Trips aus der aktuellen App-Version haben beim Speichern bereits einen
                // korrekten Score – kein erneutes Berechnen nötig.
                if trip.drivingScoreData.isEmpty {
                    trip.forceRecalculateScore()
                    try? ctx.save()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) { dismiss() }.foregroundStyle(.cyan)
                }
            }
            .sheet(isPresented: $showProfilePicker) {
                TripProfilePickerSheet(profiles: allProfiles, trip: trip, ctx: ctx)
            }
            // FIX QUAL-004: Alert wenn CSV-Export fehlschlägt (statt lautlosem Fehler)
            .alert(L("export.error.title"), isPresented: $showExportError) {
                Button(L("common.ok"), role: .cancel) { }
            } message: {
                Text(exportErrorMsg)
            }
        }
    }

    // MARK: - Vehicle Profile Card
    private var vehicleProfileCard: some View {
        HStack(spacing: 12) {
            if let p = profile {
                ZStack {
                    Circle().fill(Color(hex: p.fuelColorHex).opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: p.fuelIcon).foregroundStyle(Color(hex: p.fuelColorHex)).font(.system(size: 14))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text(cs))
                    Text(p.displaySubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "car.fill").foregroundStyle(.secondary)
                Text(L("detail.no_profile")).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { showProfilePicker = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.swap")
                    Text(L("detail.change_profile"))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.cyan)
            }
        }
        .padding(14)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Speed Legend
    private var speedLegend: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(SpeedColor.allCases, id: \.rawValue) { sc in
                    HStack(spacing: 4) {
                        Circle().fill(sc.swiftUIColor).frame(width: 8, height: 8)
                        Text(sc.rangeLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            let dist = trip.speedDistribution
            let segments: [(Double, Color)] = [
                (dist.under30, SpeedColor.green.swiftUIColor),
                (dist.from30to50, SpeedColor.blue.swiftUIColor),
                (dist.from50to80, SpeedColor.amber.swiftUIColor),
                (dist.from80to130, SpeedColor.orange.swiftUIColor),
                (dist.over130, SpeedColor.red.swiftUIColor)
            ]
            let total = segments.reduce(0) { $0 + $1.0 }

            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments.indices, id: \.self) { i in
                            let (value, color) = segments[i]
                            if value > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color)
                                    .frame(width: geo.size.width * CGFloat(value / total))
                            }
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal)
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            DetailCard(label: L("detail.distance"),  value: trip.formattedDistance,         icon: "road.lanes")
            DetailCard(label: L("detail.duration"),  value: trip.formattedDuration,         icon: "clock.fill")
            DetailCard(label: L("detail.avg_speed"), value: "\(Int(trip.avgSpeedKmh)) km/h", icon: "speedometer")
            DetailCard(label: L("detail.max_speed"), value: "\(Int(trip.maxSpeedKmh)) km/h", icon: "bolt.fill")
            DetailCard(label: L("detail.cost_per_100km"), value: costPer100kmValue,          icon: "eurosign.circle.fill")
            DetailCard(label: L("detail.co2"),       value: co2Value,                        icon: "leaf.fill")
        }
        .padding(.horizontal)
    }

    private var costPer100kmValue: String {
        guard trip.distanceKm > 0.1 else { return "–" }
        return String(format: "%.2f €", trip.estimatedCostEur / trip.distanceKm * 100)
    }

    /// Geschätzter CO₂-Ausstoß basierend auf Kraftstoffart und Verbrauch
    private var co2Value: String {
        if profile?.isElectric == true {
            return L("detail.co2_electric")
        }
        let liters = trip.estimatedFuelL
        let co2kg: Double
        if profile?.isDiesel == true {
            co2kg = liters * 2.65
        } else {
            co2kg = liters * 2.31    // Benzin E5/E10
        }
        if co2kg < 1.0 {
            return String(format: "%.0f g", co2kg * 1000)
        } else {
            return String(format: "%.2f kg", co2kg)
        }
    }

    private var fuelCard: some View {
        let isElectric = profile?.isElectric == true
        return VStack(alignment: .leading, spacing: 12) {
            Label(L("detail.fuel_title"), systemImage: isElectric ? "bolt.fill" : "fuelpump.fill")
                .font(.headline).foregroundStyle(.cyan)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isElectric
                         ? String(format: "%.2f kWh", trip.estimatedFuelL)
                         : String(format: "%.2f L", trip.estimatedFuelL))
                        .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Theme.text(cs))
                    Text(L("detail.fuel_estimated")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.2f €", trip.estimatedCostEur))
                        .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.cyan)
                    Text(L("detail.fuel_cost")).font(.caption).foregroundStyle(.secondary)
                }
            }

            if trip.fuelPriceAtTrip > 0 {
                HStack {
                    Image(systemName: isElectric ? "bolt" : "fuelpump").foregroundStyle(.secondary).font(.caption)
                    Text(L("detail.fuel_price_at", String(format: "%.3f", trip.fuelPriceAtTrip)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !trip.fuelPriceSource.isEmpty {
                        Text(trip.fuelPriceSource).font(.system(size: 9)).foregroundStyle(Color(hex: "4A5A70"))
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Pro: 7-Säulen Driving Score Card
    private func drivingScoreCard(score: DrivingScoreResult) -> some View {
        let color: Color = score.overall >= 80 ? .green : score.overall >= 60 ? Color(hex: "F59E0B") : .red
        let label = score.overall >= 80 ? L("dscore.excellent") : score.overall >= 60 ? L("dscore.good") : L("dscore.poor")

        return VStack(spacing: 16) {
            HStack(spacing: 20) {
                // Animated score ring
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 10).frame(width: 90, height: 90)
                    Circle().trim(from: 0, to: CGFloat(score.overall) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .frame(width: 90, height: 90).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(score.overall)")
                            .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(color)
                        Text("/100").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("dscore.title")).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text(cs))
                    Text(label).font(.subheadline).foregroundStyle(color)
                    if score.hasSpeedLimitData {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill").font(.system(size: 10))
                            Text(L("dscore.limit_active")).font(.system(size: 11))
                        }.foregroundStyle(.green.opacity(0.8))
                    }
                }
                Spacer()
            }
        }
        .padding(16)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.2)))
        .padding(.horizontal)
    }

    // MARK: - Pro: Säulen-Aufschlüsselung
    private func pillarBreakdown(score: DrivingScoreResult) -> some View {
        let pillars: [(String, String, Int, Color)] = [
            ("gauge.with.needle.fill", L("dscore.p.speed"),    score.speedScore,        Color(hex: "3B82F6")),
            ("arrow.up.right",         L("dscore.p.accel"),    score.accelerationScore,  Color(hex: "22C55E")),
            ("arrow.down.right",       L("dscore.p.brake"),    score.brakingScore,       Color(hex: "EF4444")),
            ("arrow.triangle.turn.up.right.circle", L("dscore.p.corner"), score.corneringScore, Color(hex: "F59E0B")),
            ("clock.fill",             L("dscore.p.time"),     DrivingScoreEngine.shared.timeOfDayScore(from: score.timeOfDayMultiplier), Color(hex: "818CF8")),
            ("checkmark.seal.fill",    L("dscore.p.consist"),  score.consistencyScore,   Color(hex: "06B6D4")),
            ("leaf.fill",              L("dscore.p.effic"),    score.efficiencyScore,     Color(hex: "10B981")),
        ]

        return VStack(alignment: .leading, spacing: 12) {
            Label(L("dscore.breakdown"), systemImage: "chart.bar.fill")
                .font(.headline).foregroundStyle(Color(hex: "818CF8"))

            ForEach(pillars.indices, id: \.self) { i in
                let (icon, label, value, color) = pillars[i]
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13)).foregroundStyle(color)
                        .frame(width: 20)
                    Text(label)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text(cs))
                    Spacer()

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06))
                            RoundedRectangle(cornerRadius: 3).fill(color)
                                .frame(width: geo.size.width * CGFloat(min(value, 100)) / 100)
                        }
                    }
                    .frame(width: 80, height: 6)

                    Text("\(min(value, 100))")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(Color(hex: "818CF8").opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "818CF8").opacity(0.15)))
        .padding(.horizontal)
    }

    // MARK: - Pro: Score Details
    private func scoreDetailsCard(score: DrivingScoreResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("dscore.details"), systemImage: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)

            let details: [(String, String)] = {
                var d: [(String, String)] = []
                if score.hasSpeedLimitData {
                    d.append((L("dscore.d.compliance"), String(format: "%.0f%%", score.speedLimitCompliance * 100)))
                }
                d.append((L("dscore.d.harsh_accel"), "\(score.harshAccelCount)"))
                d.append((L("dscore.d.harsh_brake"), "\(score.harshBrakeCount)"))
                d.append((L("dscore.d.harsh_corner"), "\(score.harshCornerCount)"))
                d.append((L("dscore.d.clean_km"), String(format: "%.1f km", score.longestCleanKm)))
                if score.nightDrivingRatio > 0.01 {
                    d.append((L("dscore.d.night"), String(format: "%.0f%%", score.nightDrivingRatio * 100)))
                }
                if score.rushHourRatio > 0.01 {
                    d.append((L("dscore.d.rush"), String(format: "%.0f%%", score.rushHourRatio * 100)))
                }
                return d
            }()

            ForEach(details.indices, id: \.self) { i in
                HStack {
                    Text(details[i].0).font(.system(size: 12)).foregroundStyle(Color(hex: "8A9BB5"))
                    Spacer()
                    Text(details[i].1).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text(cs))
                }
            }
        }
        .padding(14)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Smart Tips Card (unified, data-driven)

    private var smartTipsCard: some View {
        let tips = DrivingTipsEngine.shared.analyze(trip: trip)

        return VStack(alignment: .leading, spacing: 14) {
            // Header – ohne Potenzial-Badge (per-tip Gain-Badges in den Zeilen sind aussagekräftiger)
            HStack(alignment: .center) {
                Label(L("detail.smart_tips"), systemImage: "brain.fill")
                    .font(.headline).foregroundStyle(.cyan)
                Spacer()
            }

            // Tips
            VStack(alignment: .leading, spacing: 14) {
                ForEach(tips) { tip in
                    smartTipRow(tip)
                }
            }
        }
        .padding(16)
        .background(trip.drivingScore != nil
                    ? Color.cyan.opacity(0.04)
                    : Theme.card(cs).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.cyan.opacity(0.14), lineWidth: 1))
        .padding(.horizontal)
    }

    private func smartTipRow(_ tip: RichTip) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Category icon circle
            Image(systemName: tip.category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: tip.category.colorHex))
                .frame(width: 28, height: 28)
                .background(Color(hex: tip.category.colorHex).opacity(0.14))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                // Badges row
                HStack(spacing: 5) {
                    // Pillar score badge
                    if let ps = tip.pillarScore {
                        HStack(spacing: 3) {
                            Text(tip.category.localizedName)
                                .font(.system(size: 10, weight: .semibold))
                            Text("\(ps)")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(pillarBadgeColor(ps))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(pillarBadgeColor(ps).opacity(0.12))
                        .clipShape(Capsule())
                    }

                    // Positive indicator
                    if tip.isPositive {
                        Text("✓")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: "22C55E"))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color(hex: "22C55E").opacity(0.11))
                            .clipShape(Capsule())
                    }
                }

                // Tip body text
                Text(tip.text)
                    .font(.system(size: 13))
                    .foregroundStyle(tip.isPositive
                                     ? Color(hex: "6EE7B7")
                                     : Color(hex: "8A9BB5"))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }

    private func pillarBadgeColor(_ score: Int) -> Color {
        score >= 80 ? Color(hex: "22C55E") : score >= 60 ? Color(hex: "F59E0B") : .red
    }

    // MARK: - Free: Einfacher Score
    private var freeScoreCard: some View {
        let score = trip.efficiencyScore
        let color: Color = score >= 80 ? .green : score >= 60 ? Color(hex: "F59E0B") : .red
        let label = score >= 80 ? L("dscore.excellent") : score >= 60 ? L("dscore.good") : L("dscore.poor")

        return HStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 8).frame(width: 70, height: 70)
                Circle().trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 70, height: 70).rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("dscore.title")).font(.headline).foregroundStyle(Theme.text(cs))
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border(cs)))
        .padding(.horizontal)
    }

    // MARK: - Legacy analysis stats (trip without drivingScore)
    private var analysisCard: some View {
        let stats = DrivingTipsEngine.shared.statisticSummary(trip: trip)
        return VStack(alignment: .leading, spacing: 12) {
            Label(L("detail.analysis"), systemImage: "chart.bar.doc.horizontal")
                .font(.headline).foregroundStyle(Color(hex: "818CF8"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(stats, id: \.self) { stat in
                    Text(stat).font(.system(size: 13)).foregroundStyle(Color(hex: "8A9BB5"))
                }
            }
        }
        .padding(16)
        .background(Color(hex: "818CF8").opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "818CF8").opacity(0.15)))
        .padding(.horizontal)
    }

    // Pro-Teaser
    private var proTeaser: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill").font(.system(size: 28)).foregroundStyle(.yellow)
            Text(L("detail.pro_title"))
                .font(.headline).foregroundStyle(Theme.text(cs))
            Text(L("detail.pro_message"))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            NavigationLink(destination: PaywallView()) {
                Text(L("detail.pro_unlock"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Color.yellow).clipShape(Capsule())
            }
        }
        .padding(20)
        .background(Color.yellow.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.2)))
        .padding(.horizontal)
    }

    // MARK: - Share Trip

    private var tripShareText: String {
        String(format: L("share.trip.text"),
               trip.formattedDate,
               trip.distanceKm,
               trip.formattedDuration,
               trip.efficiencyScore,
               trip.avgSpeedKmh,
               trip.maxSpeedKmh)
    }

    private var shareButton: some View {
        Button(action: shareCard) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                Text(L("share.trip.button"))
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Theme.card(cs))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
        }
        .padding(.horizontal)
    }

    @MainActor
    private func shareCard() {
        guard let image = TripShareCardRenderer.render(trip: trip, profile: profile) else {
            // Fallback auf Text-Share wenn Rendering fehlschlägt
            presentShareSheet(items: [tripShareText])
            return
        }
        presentShareSheet(items: [image])
    }

    /// Präsentiert UIActivityViewController direkt über UIKit.
    /// Vermeidet den schwarzen-Screen-Bug bei verschachtelten SwiftUI-Sheets.
    private func presentShareSheet(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // Auf iPad: Popover-Anker setzen (sonst Crash)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX,
                                        y: root.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        // Den obersten präsentierten VC finden, damit wir nicht auf einen bereits präsentierten VC aufsetzen
        var topVC = root
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(vc, animated: true)
    }

    private var exportButtons: some View {
        HStack(spacing: 12) {
            Button(action: exportCSV) {
                Label("CSV", systemImage: "tablecells")
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.card(cs))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
            }
            Button(action: exportJSON) {
                Label("JSON", systemImage: "doc.text")
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.card(cs))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
            }
        }
        .foregroundStyle(.secondary).padding(.horizontal)
    }

    private func exportCSV() {
        do {
            let data = try ExportService.csvData(for: trip)
            let url  = FileManager.default.temporaryDirectory.appendingPathComponent("\(trip.title).csv")
            try data.write(to: url)
            presentShareSheet(items: [url])
        } catch {
            CrashlyticsManager.record(error, context: "TripListView - exportCSV")
            // FIX QUAL-004: Fehler dem User anzeigen statt lautlos scheitern
            exportErrorMsg  = error.localizedDescription
            showExportError = true
        }
    }

    private func exportJSON() {
        let data = (try? ExportService.jsonData(for: trip)) ?? Data()
        let url  = FileManager.default.temporaryDirectory.appendingPathComponent("\(trip.title).json")
        try? data.write(to: url)
        presentShareSheet(items: [url])
    }
}

// MARK: - Trip Profile Picker Sheet (Profil in Fahrt wechseln)
private struct TripProfilePickerSheet: View {
    let profiles: [VehicleProfile]
    let trip: Trip
    let ctx: ModelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var cs

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(cs).ignoresSafeArea()
                List(profiles) { profile in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color(hex: profile.fuelColorHex).opacity(0.15)).frame(width: 44, height: 44)
                            Image(systemName: profile.fuelIcon)
                                .foregroundStyle(Color(hex: profile.fuelColorHex)).font(.system(size: 18))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text(cs))
                            Text(profile.displaySubtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if trip.vehicleProfileId == profile.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.cyan).font(.system(size: 22))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Profil wechseln und Sprit/Kosten neu berechnen
                        trip.vehicleProfileId   = profile.id
                        trip.vehicleProfileName = profile.name
                        let isElectric = profile.isElectric
                        trip.estimatedFuelL   = profile.estimatedFuel(forKm: trip.distanceKm)
                        trip.estimatedCostEur = profile.estimatedCost(forKm: trip.distanceKm)

                        // Score neu berechnen mit neuem Verbrauch
                        let scoreResult = DrivingScoreEngine.shared.calculate(
                            points: trip.points,
                            distanceKm: trip.distanceKm,
                            fuelL: trip.estimatedFuelL,
                            isElectric: isElectric,
                            startDate: trip.startDate
                        )
                        trip.drivingScore    = scoreResult
                        trip.efficiencyScore = scoreResult.overall

                        try? ctx.save()
                        dismiss()
                    }
                    .listRowBackground(Theme.card(cs))
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
            .navigationTitle(L("detail.choose_profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("profile.close")) { dismiss() }.foregroundStyle(.secondary)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - DetailCard
private struct DetailCard: View {
    let label: String
    let value: String
    let icon: String
    @Environment(\.colorScheme) private var cs

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.5)
            Text(value)
                .font(.system(size: 22, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.text(cs)).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
    }
}


