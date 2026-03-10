import SwiftUI
import SwiftData
import CoreLocation

struct RecordingView: View {
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var recorder: TripRecorder
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VehicleProfile.sortOrder) private var profiles: [VehicleProfile]
    @Query(sort: \Trip.startDate, order: .reverse) private var allTrips: [Trip]

    @EnvironmentObject private var subscription: SubscriptionManager
    @EnvironmentObject private var speedLimit: SpeedLimitService
    @EnvironmentObject private var lang: LanguageManager
    @AppStorage("currentOwnerUserId") private var currentOwnerUserId: String = ""

    @State private var showPermissionAlert       = false
    @State private var showStopConfirm           = false
    @State private var showProfilePicker         = false
    @State private var selectedProfileId: UUID?  = nil
    @State private var showPaywall               = false
    @State private var showKmLimitWarning        = false
    @State private var showSpeedLimitDisclaimer  = false
    @AppStorage("hasSeenSpeedLimitDisclaimer") private var hasSeenSpeedLimitDisclaimer = false

    @Environment(\.colorScheme) private var cs

    /// Nur Fahrzeuge des aktuellen Users
    private var myProfiles: [VehicleProfile] {
        profiles.filter { $0.ownerUserId == currentOwnerUserId }
    }

    private var activeProfile: VehicleProfile? {
        if let id = selectedProfileId, let p = myProfiles.first(where: { $0.id == id }) { return p }
        return myProfiles.first(where: \.isDefault) ?? myProfiles.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.recGradient(cs)
                .ignoresSafeArea()

                VStack(spacing: 0) {

                    // ── Status Bar ─────────────────────────────────────
                    statusBar
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .padding(.bottom, 2)

                    // ── TACHO (maximale Größe, volle Breite) ───────────
                    ZStack(alignment: .topTrailing) {
                        SpeedometerView(speedKmh: locationService.currentSpeed)
                            .padding(.horizontal, 2)

                        if subscription.isPro {
                            SpeedLimitView(limit: speedLimit.currentLimit, size: 58)
                                .padding(.top, 6)
                                .padding(.trailing, 10)
                                .animation(.spring(response: 0.4), value: speedLimit.currentLimit)
                        }
                    }
                    .layoutPriority(1) // Tacho nimmt allen freien Platz

                    // ── Metriken direkt unter dem Tacho ───────────────
                    liveMetrics
                        .padding(.horizontal)
                        .padding(.vertical, 6)

                    liveDrivingBar

                    if !subscription.isPro {
                        kmUsageBar
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .padding(.bottom, 4)
                    }

                    // ── Flexibler Spacer: drückt Buttons nach unten ───
                    Spacer(minLength: 0)

                    // ── Fahrzeug + Buttons (fest am unteren Rand) ──────
                    VStack(spacing: 16) {
                        profilePickerButton
                            .padding(.horizontal)

                        recordButton

                        pauseButton
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                    // ── AdMob Banner ───────────────────────────────────
                    AdMobBannerView()
                }
            }
            .navigationTitle("Auto Performance Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !subscription.isPro {
                        Button(action: { showPaywall = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 11))
                                Text("Pro")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.yellow)
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .onAppear {
                recorder.setContext(modelContext)
                locationService.requestPermission()
                if selectedProfileId == nil {
                    selectedProfileId = myProfiles.first(where: \.isDefault)?.id ?? myProfiles.first?.id
                }
            }
            .onChange(of: locationService.currentLocation) { _, loc in
                guard let loc, recorder.isRecording, !recorder.isPaused else { return }
                if subscription.isPro { speedLimit.update(location: loc) }
            }
            .onChange(of: myProfiles) { _, newProfiles in
                if selectedProfileId == nil || !newProfiles.contains(where: { $0.id == selectedProfileId }) {
                    selectedProfileId = newProfiles.first(where: \.isDefault)?.id ?? newProfiles.first?.id
                }
            }
            .alert(L("rec.gps_required"), isPresented: $showPermissionAlert) {
                Button(L("rec.open_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("rec.gps_message"))
            }
            .sheet(isPresented: $showStopConfirm) {
                StopConfirmSheet(
                    isPaused: recorder.isPaused,
                    onStop: {
                        showStopConfirm = false
                        stopRecording()
                    },
                    onPause: {
                        showStopConfirm = false
                        recorder.pauseRecording()
                    },
                    onResume: {
                        showStopConfirm = false
                        recorder.resumeRecording()
                    },
                    onContinue: { showStopConfirm = false }
                )
            }
            .sheet(isPresented: $showProfilePicker) {
                ProfilePickerSheet(profiles: myProfiles, selectedId: $selectedProfileId)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showSpeedLimitDisclaimer) {
                SpeedLimitDisclaimerSheet()
                    .environmentObject(lang)
            }
            .onChange(of: subscription.isPro) { _, isPro in
                if isPro && !hasSeenSpeedLimitDisclaimer {
                    showSpeedLimitDisclaimer = true
                }
            }
            .onAppear {
                if subscription.isPro && !hasSeenSpeedLimitDisclaimer {
                    showSpeedLimitDisclaimer = true
                }
            }
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if recorder.isRecording {
                    ZStack {
                        Circle().fill(recorder.isPaused ? Color.orange.opacity(0.3) : Color.red.opacity(0.3))
                            .frame(width: 14, height: 14)
                        Circle().fill(recorder.isPaused ? Color.orange : Color.red)
                            .frame(width: 7, height: 7)
                    }
                } else {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }

                Text(recorder.isRecording
                     ? (recorder.isPaused ? L("rec.status.paused") : L("rec.status.recording"))
                     : L("rec.status.ready"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(recorder.isRecording
                                     ? (recorder.isPaused ? Color.orange : Color.red)
                                     : Color.green)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background((recorder.isRecording
                         ? (recorder.isPaused ? Color.orange : Color.red)
                         : Color.green).opacity(0.1))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(
                (recorder.isRecording
                 ? (recorder.isPaused ? Color.orange : Color.red)
                 : Color.green).opacity(0.25),
                lineWidth: 1
            ))

            Spacer()

            if recorder.isRecording {
                Text(recorder.formattedTime)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(recorder.isPaused ? Color.orange : Color.cyan)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var liveMetrics: some View {
        HStack(spacing: 12) {
            MetricCard(icon: "location.fill",  value: recorder.formattedDistance, label: L("rec.metric.km"), color: .cyan)
            MetricCard(icon: "clock.fill",     value: recorder.formattedTime,     label: L("rec.metric.time"),  color: .blue)
            MetricCard(icon: "bolt.fill",      value: recorder.formattedMaxSpeed, label: L("rec.metric.maxspeed"),  color: .orange)
        }
    }

    // MARK: - Live Fahrstil-Indikator (ersetzt GPS-Balken)
    private var liveDrivingBar: some View {
        HStack(spacing: 12) {
            // GPS-Signal mini (kompakt, nicht dominant)
            HStack(spacing: 3) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9)).foregroundStyle(.secondary.opacity(0.6))
                ForEach(1...4, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(bar <= locationService.signalBars
                              ? Color.green.opacity(0.7) : Color.white.opacity(0.08))
                        .frame(width: 3, height: CGFloat(3 + bar * 3))
                }
            }

            Divider().frame(height: 14).background(Color.white.opacity(0.1))

            // Live-Ereigniszähler
            if recorder.isRecording {
                HStack(spacing: 5) {
                    Image(systemName: recorder.harshEventCount == 0
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(recorder.harshEventCount == 0 ? Color.green : Color.orange)

                    Text(recorder.harshEventCount == 0
                         ? L("rec.live.clean")
                         : L("rec.live.events", recorder.harshEventCount))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(recorder.harshEventCount == 0
                                         ? Color.green.opacity(0.9) : Color.orange)
                }
                .animation(.easeInOut(duration: 0.3), value: recorder.harshEventCount)
            } else {
                Text(locationService.accuracy > 0
                     ? "±\(Int(locationService.accuracy)) m"
                     : L("rec.gps.searching"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // Legacy — bleibt für eventuelle andere Nutzung
    private var gpsSignalBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 2)
                    .fill(bar <= locationService.signalBars ? Color.green : Color.white.opacity(0.1))
                    .frame(width: 4, height: CGFloat(4 + bar * 4))
            }
            Text(locationService.accuracy > 0 ? "±\(Int(locationService.accuracy)) m" : L("rec.gps.searching"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // Km-Verbrauch für Standard-User (nur eigene Trips zählen)
    private var myTrips: [Trip] {
        guard !currentOwnerUserId.isEmpty else { return [] }
        return allTrips.filter { $0.ownerUserId == currentOwnerUserId }
    }

    private var kmUsageBar: some View {
        let used  = subscription.monthlyKmUsed(from: myTrips)
        let limit = SubscriptionManager.monthlyKmLimit
        let ratio = min(used / limit, 1.0)
        let remaining = max(0, limit - used)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("rec.monthly_limit"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("rec.km_remaining", Int(remaining)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(remaining < 30 ? Color.red : Color.secondary)
                Button("Pro") { showPaywall = true }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.yellow)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.border(cs)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ratio > 0.9 ? Color.red : Color.cyan)
                        .frame(width: geo.size.width * ratio, height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(12)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border(cs)))
    }

    private var profilePickerButton: some View {
        Button(action: {
            if !recorder.isRecording { showProfilePicker = true }
        }) {
            HStack(spacing: 10) {
                if let profile = activeProfile {
                    Image(systemName: profile.fuelIcon)
                        .foregroundStyle(Color(hex: profile.fuelColorHex))
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text(cs))
                        Text(profile.displaySubtitle)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !recorder.isRecording {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "car.fill").foregroundStyle(.secondary)
                    Text(L("rec.no_profile"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.card(cs))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs)))
        }
        .buttonStyle(.plain)
        .disabled(recorder.isRecording)
        .opacity(recorder.isRecording ? 0.6 : 1)
    }

    private var recordButton: some View {
        Button(action: handleRecordTap) {
            ZStack {
                Circle()
                    .stroke(
                        recorder.isRecording ? Color.red.opacity(0.3) : Color.cyan.opacity(0.3),
                        lineWidth: 2
                    )
                    .frame(width: 100, height: 100)

                Circle()
                    .fill(
                        recorder.isRecording
                            ? LinearGradient(colors: [.red, Color(hex: "B91C1C")], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [.cyan, Color(hex: "0066FF")], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: recorder.isRecording ? .red.opacity(0.5) : .cyan.opacity(0.5), radius: 20)

                Image(systemName: recorder.isRecording ? "stop.fill" : "car.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    // NEU: Pause-Button (nur sichtbar während Aufnahme)
    private var pauseButton: some View {
        Group {
            if recorder.isRecording {
                Button(action: {
                    if recorder.isPaused { recorder.resumeRecording() }
                    else                 { recorder.pauseRecording()  }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(recorder.isPaused ? L("rec.resume") : L("rec.pause"))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(recorder.isPaused ? Color.green : Color.orange)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background((recorder.isPaused ? Color.green : Color.orange).opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(
                        (recorder.isPaused ? Color.green : Color.orange).opacity(0.3),
                        lineWidth: 1
                    ))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: recorder.isRecording)
    }

    // MARK: - Actions

    private func handleRecordTap() {
        if recorder.isRecording {
            showStopConfirm = true
        } else {
            // Km-Limit prüfen (Standard)
            if subscription.isKmLimitReached(from: myTrips) {
                showPaywall = true
                return
            }
            // Fahrzeug-Limit prüfen (Standard: 1 Fahrzeug)
            if !subscription.isPro && myProfiles.count > SubscriptionManager.maxFreeVehicles {
                showPaywall = true
                return
            }
            guard locationService.authStatus == .authorizedAlways ||
                  locationService.authStatus == .authorizedWhenInUse else {
                showPermissionAlert = true
                return
            }
            speedLimit.reset()
            if subscription.isPro { speedLimit.startPolling() }
            AnalyticsService.shared.trackFeatureUsed("recording_started")
            recorder.startRecording(vehicleProfile: activeProfile)
        }
    }

    private func stopRecording() {
        let trip = recorder.stopRecording(vehicleProfile: activeProfile)
        speedLimit.reset()

        // Kraftstoffpreis bei Fahrtende speichern (Tankerkönig)
        if let loc = locationService.currentLocation,
           let profile = activeProfile,
           !profile.tankerkoenig.isEmpty {
            TankerkoenigService.shared.fetchPrice(
                for: profile.tankerkoenig,
                near: loc
            ) { price, station, city in
                if price > 0 {
                    let entry = FuelPriceEntry(
                        fuelType: profile.tankerkoenig,
                        pricePerUnit: price,
                        stationName: station,
                        stationCity: city
                    )
                    if let ctx = trip?.modelContext {
                        ctx.insert(entry)
                        try? ctx.save()
                    }
                }
            }
        }

        // Werbung für Standard-User (nach Fahrt)
        if !SubscriptionManager.shared.isPro {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AdMobManager.shared.showInterstitial()
            }
        }
    }
}

// MARK: - StopConfirmSheet (mit Pause)

private struct StopConfirmSheet: View {
    @Environment(\.colorScheme) private var cs
    let isPaused: Bool
    let onStop: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Theme.bg(cs).ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 40, height: 4)
                    .padding(.top, 12).padding(.bottom, 24)

                ZStack {
                    Circle().fill(Color.red.opacity(0.12)).frame(width: 72, height: 72)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(.red)
                }
                .padding(.bottom, 16)

                Text(L("stop.title"))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text(cs))
                    .padding(.bottom, 8)

                Text(L("stop.message"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.bottom, 24)

                // Stoppen
                Button(action: onStop) {
                    Text(L("stop.save"))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(LinearGradient(colors: [.red, Color(hex: "B91C1C")],
                                                   startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 24).padding(.bottom, 10)

                // Pause / Fortsetzen
                Button(action: isPaused ? onResume : onPause) {
                    HStack(spacing: 8) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        Text(isPaused ? L("stop.resume") : L("stop.pause"))
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isPaused ? Color.green : Color.orange)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Theme.card(cs))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(
                        (isPaused ? Color.green : Color.orange).opacity(0.3)
                    ))
                }
                .padding(.horizontal, 24).padding(.bottom, 10)

                // Weiterfahren
                Button(action: onContinue) {
                    Text(L("stop.continue"))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Theme.card(cs))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.3)))
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .presentationBackground(Theme.bg(cs))
    }
}

// MARK: - ProfilePickerSheet

private struct ProfilePickerSheet: View {
    @Environment(\.colorScheme) private var cs
    let profiles: [VehicleProfile]
    @Binding var selectedId: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(cs).ignoresSafeArea()
                if profiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "car.fill").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text(L("profile.none_title")).font(.headline).foregroundStyle(.secondary)
                        Text(L("profile.none_message"))
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                } else {
                    List(profiles) { profile in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: profile.fuelColorHex).opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: profile.fuelIcon)
                                    .foregroundStyle(Color(hex: profile.fuelColorHex))
                                    .font(.system(size: 18))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text(cs))
                                Text(profile.displaySubtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedId == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.cyan).font(.system(size: 22))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedId = profile.id; dismiss() }
                        .listRowBackground(Theme.card(cs))
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(L("profile.choose"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("profile.close")) { dismiss() }.foregroundStyle(.secondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - MetricCard
struct MetricCard: View {
    @Environment(\.colorScheme) private var cs
    let icon: String
    let value: String
    let label: String
    var color: Color = .cyan

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(value)
                .font(.system(size: 17, weight: .regular)).foregroundStyle(Theme.text(cs))
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(label)
                .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                .tracking(0.5).textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.card(cs))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border(cs), lineWidth: 1))
    }
}
