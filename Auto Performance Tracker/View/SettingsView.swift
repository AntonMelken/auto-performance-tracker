import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \VehicleProfile.sortOrder) private var profiles: [VehicleProfile]
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]

    @EnvironmentObject private var subscription: SubscriptionManager
    @EnvironmentObject private var changelog: ChangelogService
    @AppStorage("currentOwnerUserId") private var currentOwnerUserId: String = ""

    /// Nur Fahrzeuge des aktuellen Users anzeigen
    private var myProfiles: [VehicleProfile] {
        profiles.filter { $0.ownerUserId == currentOwnerUserId }
    }

    /// Nur Fahrten des aktuellen Users anzeigen
    private var myTrips: [Trip] {
        guard !currentOwnerUserId.isEmpty else { return [] }
        return trips.filter { $0.ownerUserId == currentOwnerUserId }
    }

    @State private var showAddProfile    = false
    @State private var editingProfile: VehicleProfile? = nil
    @State private var showDeleteConfirm = false
    @State private var showExportError   = false   // FIX QUAL-004: Export-Fehleranzeige
    @State private var exportErrorMsg    = ""
    @State private var showPrivacy       = false
    @State private var showImpressum     = false
    @State private var showChangelog     = false
    @State private var showPaywall       = false
    @AppStorage("analyticsOptIn")      private var analyticsOptIn = false
    @AppStorage("crashlyticsOptIn")    private var crashlyticsOptIn = true
    @AppStorage("appColorScheme")       private var appColorScheme = "dark"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @Environment(\.colorScheme) private var cs
    @EnvironmentObject private var lang: LanguageManager
    @EnvironmentObject private var notificationService: NotificationService

    var body: some View {
        NavigationStack {
            Form {

                    // MARK: Pro-Banner (Standard-User)
                    if !subscription.isPro {
                        Section {
                            Button(action: { showPaywall = true }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "crown.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("settings.pro_banner"))
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(Theme.text(cs))
                                        Text(L("settings.pro_subtitle"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary).font(.caption)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color.yellow.opacity(0.07))
                        }
                    }

                    // MARK: Fahrzeugprofile
                    Section {
                        ForEach(myProfiles) { profile in
                            ProfileRow(profile: profile, isDefault: profile.isDefault) {
                                setDefault(profile)
                            } onEdit: {
                                editingProfile = profile
                            }
                        }
                        .onDelete(perform: deleteProfiles)

                        // Standard: max 1 Fahrzeug
                        if subscription.isPro || myProfiles.count < SubscriptionManager.maxFreeVehicles {
                            Button(action: { showAddProfile = true }) {
                                Label(L("settings.add_vehicle"), systemImage: "plus.circle.fill")
                                    .foregroundStyle(.cyan)
                            }
                        } else {
                            Button(action: { showPaywall = true }) {
                                HStack {
                                    Label(L("settings.more_vehicle_pro"), systemImage: "plus.circle.fill")
                                    Spacer()
                                    Image(systemName: "crown.fill").foregroundStyle(.yellow).font(.caption)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(L("settings.vehicles"))
                    } footer: {
                        Text(subscription.isPro
                             ? L("settings.vehicle_tip_pro")
                             : L("settings.vehicle_tip_std"))
                            .font(.caption)
                    }

                    // MARK: Account & Sync
                    Section {
                        NavigationLink(destination: AccountView(trips: myTrips, vehicles: myProfiles)) {
                            Label(L("settings.account_sync"), systemImage: "icloud.fill")
                                .foregroundStyle(Theme.text(cs))
                        }
                    } header: { Text(L("settings.account")) }

                    // MARK: Kraftstoffpreise
                    Section {
                        NavigationLink(destination: FuelPriceView()) {
                            Label(L("settings.fuel_prices"), systemImage: "fuelpump.fill")
                                .foregroundStyle(Theme.text(cs))
                        }
                    } header: { Text(L("settings.fuel")) }

                    // MARK: Export
                    Section {
                        Button(action: exportCSV) {
                            Label(L("settings.export_csv"), systemImage: "tablecells")
                        }
                        Button(action: exportJSON) {
                            Label(L("settings.export_json"), systemImage: "doc.text")
                        }
                    } header: { Text(L("settings.export")) }

                    // MARK: Datenverwaltung
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label(L("settings.delete_all"), systemImage: "trash.fill")
                        }
                    } header: { Text(L("settings.data_mgmt")) }

                    // MARK: Datenschutz / Analytics
                    Section {
                        Toggle(isOn: $analyticsOptIn) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("settings.analytics_toggle"))
                                    .font(.system(size: 15))
                                Text(L("settings.analytics_note"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.cyan)
                        .onChange(of: analyticsOptIn) { _, val in
                            AnalyticsService.shared.setOptIn(val)
                        }

                        // DSGVO Art. 13 / Art. 6 – Crashlytics Opt-Out
                        // Firebase Crashlytics überträgt Absturz- und Fehlerberichte an Google LLC (USA).
                        Toggle(isOn: $crashlyticsOptIn) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("settings.crashlytics_toggle"))
                                    .font(.system(size: 15))
                                Text(L("settings.crashlytics_note"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.cyan)
                        .onChange(of: crashlyticsOptIn) { _, val in
                            CrashlyticsManager.isOptIn = val
                        }
                    } header: { Text(L("settings.privacy_section")) }
                    footer: { Text(L("settings.analytics_footer")).font(.caption) }

                    // MARK: Benachrichtigungen
                    Section {
                        Toggle(isOn: $notificationsEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("notif.settings.toggle"))
                                    .font(.system(size: 15))
                                Text(L("notif.settings.toggle_note"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.cyan)
                        .onChange(of: notificationsEnabled) { _, enabled in
                            NotificationService.shared.notificationsEnabled = enabled
                        }

                        if !notificationService.isPermissionGranted && notificationsEnabled {
                            Button(action: openIOSSettings) {
                                Label(L("notif.settings.open_ios"), systemImage: "gear")
                                    .foregroundStyle(.cyan)
                            }
                        }
                    } header: { Text(L("notif.settings.section")) }

                    // MARK: Erscheinungsbild
                    Section {
                        Picker(selection: $appColorScheme, label:
                            Label(L("settings.appearance"), systemImage: "circle.lefthalf.filled")
                        ) {
                            Text(L("settings.theme.system")).tag("system")
                            Text(L("settings.theme.light")).tag("light")
                            Text(L("settings.theme.dark")).tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Theme.pickerBg(cs))
                    } header: { Text(L("settings.appearance")) }

                    // MARK: App-Info & Changelog
                    Section {
                        HStack {
                            Text(L("settings.version"))
                            Spacer()
                            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                            let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                            Text("\(version) (\(build))").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L("settings.storage"))
                            Spacer()
                            Text(L("settings.storage_local")).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L("settings.sub_status"))
                            Spacer()
                            Text(subscription.isPro ? L("settings.sub_pro") : L("settings.sub_standard"))
                                .foregroundStyle(subscription.isPro ? Color.cyan : Color.secondary)
                                .fontWeight(subscription.isPro ? .semibold : .regular)
                        }

                        // Changelog mit Badge
                        Button(action: { showChangelog = true }) {
                            HStack {
                                Label(L("settings.changelog"), systemImage: "sparkles")
                                    .foregroundStyle(Theme.text(cs))
                                Spacer()
                                if changelog.hasUnread {
                                    Text(L("settings.new_badge"))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Color.cyan)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    } header: { Text(L("settings.info")) }

                    // MARK: Sprache
                    Section {
                        Picker(L("settings.language"), selection: $lang.current) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Theme.card(cs))
                    } header: { Text(L("settings.language")) }
                    footer: { Text(L("settings.language_footer")).font(.caption) }

                    // MARK: Rechtliches
                    Section {
                        Button(action: { showPrivacy = true }) {
                            legalRow(icon: "lock.shield.fill", title: L("settings.privacy"))
                        }
                        Button(action: { showImpressum = true }) {
                            legalRow(icon: "doc.text.fill", title: L("settings.impressum"))
                        }
                        Button(action: { openURL("https://antonmelken.github.io/auto-performance-tracker/agb.html") }) {
                            legalRow(icon: "scroll.fill", title: L("settings.terms"), isExternal: true)
                        }
                        Button(action: resetOnboarding) {
                            Label(L("settings.reset_onboarding"), systemImage: "arrow.counterclockwise")
                                .foregroundStyle(Theme.text(cs))
                        }
                        Button(action: {
                            Task { await subscription.restorePurchases() }
                        }) {
                            Label(L("settings.restore"), systemImage: "arrow.clockwise")
                                .foregroundStyle(Theme.text(cs))
                        }
                    } header: { Text(L("settings.legal")) }

                    // MARK: Kontakt & Support
                    Section {
                        Button(action: {
                            let email = "support@melnychuk-anton.de"
                            let subject = L("settings.email_subject")
                            let urlStr = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject)"
                            if let url = URL(string: urlStr) {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            legalRow(icon: "envelope.fill", title: L("settings.contact_support"))
                        }
                        Button(action: { openURL("https://antonmelken.github.io/auto-performance-tracker/support.html") }) {
                            legalRow(icon: "questionmark.circle.fill", title: L("settings.support_page"), isExternal: true)
                        }
                        Button(action: { openURL("https://melnychuk-anton.de") }) {
                            legalRow(icon: "person.circle.fill", title: L("settings.developer_website"), isExternal: true)
                        }
                    } header: { Text(L("settings.contact")) }
                    footer: { Text(L("settings.business_footer")).font(.caption) }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.bg(cs).ignoresSafeArea())
            .navigationTitle(L("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                AnalyticsService.shared.trackFeatureUsed("settings_opened")
            }
            .alert(L("settings.delete_confirm"), isPresented: $showDeleteConfirm) {
                Button(L("settings.delete_action"), role: .destructive, action: deleteAllTrips)
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("settings.delete_message"))
            }
            .sheet(isPresented: $showAddProfile) {
                ProfileEditSheet(profile: nil) { name, fuelType, consumption, price, colorHex in
                    addProfile(name: name, fuelType: fuelType, consumption: consumption, price: price, colorHex: colorHex)
                }
            }
            .sheet(item: $editingProfile) { profile in
                ProfileEditSheet(profile: profile) { name, fuelType, consumption, price, colorHex in
                    profile.name = name; profile.fuelType = fuelType
                    profile.consumptionPer100km = consumption; profile.fuelPricePerLiter = price
                    profile.colorHex = colorHex
                    try? ctx.save()
                }
            }
            .sheet(isPresented: $showPrivacy)    { PrivacyView() }
            .sheet(isPresented: $showImpressum)  { ImpressumView() }
            .sheet(isPresented: $showChangelog) { ChangelogView() }
            .sheet(isPresented: $showPaywall)   { PaywallView() }
            // FIX QUAL-004: Alert wenn CSV-Export fehlschlägt
            .alert(L("export.error.title"), isPresented: $showExportError) {
                Button(L("common.ok"), role: .cancel) { }
            } message: {
                Text(exportErrorMsg)
            }
        }
    }

    // MARK: - Actions

    private func openIOSSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func setDefault(_ profile: VehicleProfile) {
        myProfiles.forEach { $0.isDefault = false }
        profile.isDefault = true
        try? ctx.save()
    }

    private func addProfile(name: String, fuelType: String, consumption: Double, price: Double, colorHex: String = "") {
        let p = VehicleProfile(name: name, fuelType: fuelType, consumption: consumption,
                               pricePerLiter: price, sortOrder: myProfiles.count,
                               colorHex: colorHex.isEmpty ? VehicleProfile.randomColorHex() : colorHex)
        // Account-Isolation: Fahrzeug dem aktuellen User zuordnen
        p.ownerUserId = currentOwnerUserId
        if myProfiles.isEmpty { p.isDefault = true }
        ctx.insert(p); try? ctx.save()
    }

    private func deleteProfiles(at offsets: IndexSet) {
        offsets.map { myProfiles[$0] }.forEach { ctx.delete($0) }
        try? ctx.save()
        if myProfiles.first(where: { $0.isDefault }) == nil, let first = myProfiles.first {
            first.isDefault = true; try? ctx.save()
        }
    }

    private func deleteAllTrips() {
        // Nur eigene Trips löschen
        trips.filter { $0.ownerUserId == currentOwnerUserId }.forEach { ctx.delete($0) }
        try? ctx.save()
    }

    private func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
    }

    private func exportCSV() {
        let myTrips = trips.filter { $0.ownerUserId == currentOwnerUserId }
        do {
            let data = try ExportService.allTripsCSV(trips: myTrips)
            let url  = FileManager.default.temporaryDirectory.appendingPathComponent("AutoPerformanceTracker_Export.csv")
            try data.write(to: url)
            presentShareSheet(items: [url])
        } catch {
            CrashlyticsManager.record(error, context: "SettingsView - exportCSV")
            // FIX QUAL-004: Fehler dem User anzeigen statt lautlos scheitern
            exportErrorMsg  = error.localizedDescription
            showExportError = true
        }
    }

    private func exportJSON() {
        let myTrips = trips.filter { $0.ownerUserId == currentOwnerUserId }
        do {
            let data = try ExportService.allTripsJSON(trips: myTrips, vehicle: myProfiles.first(where: \.isDefault))
            let url  = FileManager.default.temporaryDirectory.appendingPathComponent("AutoPerformanceTracker_Export.json")
            try data.write(to: url)
            presentShareSheet(items: [url])
        } catch {
            CrashlyticsManager.record(error, context: "SettingsView - exportJSON")
            exportErrorMsg  = error.localizedDescription
            showExportError = true
        }
    }

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

    private func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    @ViewBuilder
    private func legalRow(icon: String, title: String, isExternal: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(Theme.text(cs))
            Spacer()
            if isExternal {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - ProfileRow
private struct ProfileRow: View {
    let profile: VehicleProfile
    let isDefault: Bool
    let onSetDefault: () -> Void
    let onEdit: () -> Void

    @Environment(\.colorScheme) private var cs

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(profile.profileColor.opacity(0.18)).frame(width: 40, height: 40)
                Image(systemName: profile.fuelIcon)
                    .foregroundStyle(profile.profileColor).font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text(cs))
                    if isDefault {
                        Text(L("settings.default")).font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(profile.profileColor.opacity(0.2))
                            .foregroundStyle(profile.profileColor)
                            .clipShape(Capsule())
                    }
                }
                Text(profile.displaySubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil.circle").foregroundStyle(.secondary).font(.system(size: 20))
            }.buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSetDefault)
    }
}

// MARK: - ProfileEditSheet
struct ProfileEditSheet: View {
    let profile: VehicleProfile?
    let onSave: (String, String, Double, Double, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var cs
    @Query(sort: \FuelPriceEntry.date, order: .reverse) private var priceHistory: [FuelPriceEntry]

    @State private var name: String
    @State private var fuelType: String
    @State private var consumption: Double
    @State private var price: Double
    @State private var selectedColor: Color
    private var fuelTypes: [String] { [L("vehicle.fuel_gasoline"), L("vehicle.fuel_diesel"), L("vehicle.fuel_lpg"), L("vehicle.fuel_electric"), L("vehicle.fuel_hybrid")] }

    init(profile: VehicleProfile?, onSave: @escaping (String, String, Double, Double, String) -> Void) {
        self.profile = profile; self.onSave = onSave
        _name        = State(initialValue: profile?.name ?? "")
        _fuelType    = State(initialValue: profile?.fuelType ?? L("vehicle.fuel_gasoline"))
        _consumption = State(initialValue: profile?.consumptionPer100km ?? 7.0)
        _price       = State(initialValue: profile?.fuelPricePerLiter ?? ((profile?.isElectric ?? false) ? 0.30 : 1.89))
        let hex      = profile?.colorHex ?? VehicleProfile.randomColorHex()
        _selectedColor = State(initialValue: Color(hex: hex.isEmpty ? VehicleProfile.randomColorHex() : hex))
    }

    private var relevantFuelKey: String {
        if fuelType == L("vehicle.fuel_diesel") { return "diesel" }
        return "e5"
    }

    private var cheapestSavedPrice: Double? {
        priceHistory
            .filter { $0.fuelType == relevantFuelKey }
            .min(by: { $0.pricePerUnit < $1.pricePerUnit })
            .map { $0.pricePerUnit }
    }

    private var latestSavedPrice: Double? {
        priceHistory
            .first { $0.fuelType == relevantFuelKey }
            .map { $0.pricePerUnit }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(cs).ignoresSafeArea()
                Form {
                    Section(L("vehicle.name_section")) {
                        TextField(L("vehicle.name_placeholder"), text: $name).foregroundStyle(.cyan)
                    }
                    Section(L("vehicle.fuel_section")) {
                        Picker(L("vehicle.fuel_type"), selection: $fuelType) {
                            ForEach(fuelTypes, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented).listRowBackground(Theme.card(cs))

                        HStack {
                            Label(fuelType == L("vehicle.fuel_electric") ? L("vehicle.consumption_elec") : L("vehicle.consumption_fuel"),
                                  systemImage: "drop.fill")
                            Spacer()
                            TextField(L("vehicle.value"), value: $consumption,
                                      format: .number.precision(.fractionLength(1)))
                                .multilineTextAlignment(.trailing).foregroundStyle(.cyan)
                                .frame(width: 70).keyboardType(.decimalPad)
                        }
                        if fuelType != L("vehicle.fuel_electric") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(L("vehicle.fuel_price"), systemImage: "eurosign")
                                    Spacer()
                                    Text(String(format: "%.3f €/L", price))
                                        .foregroundStyle(.cyan).fontWeight(.semibold)
                                }
                                // Schnellauswahl aus gespeicherten Preisen
                                VStack(spacing: 6) {
                                    if let latest = latestSavedPrice {
                                        Button(action: { price = latest }) {
                                            HStack {
                                                Image(systemName: "clock.fill").foregroundStyle(.cyan).font(.system(size: 11))
                                                Text(String(format: L("vehicle.last_saved_price"), latest))
                                                    .font(.system(size: 12)).foregroundStyle(Theme.text(cs))
                                                Spacer()
                                                if abs(price - latest) < 0.001 {
                                                    Image(systemName: "checkmark").foregroundStyle(.cyan).font(.system(size: 11))
                                                }
                                            }
                                            .padding(8).background(Color.cyan.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain)
                                    }
                                    if let cheapest = cheapestSavedPrice, cheapest != latestSavedPrice {
                                        Button(action: { price = cheapest }) {
                                            HStack {
                                                Image(systemName: "tag.fill").foregroundStyle(.green).font(.system(size: 11))
                                                Text(String(format: L("vehicle.cheapest_saved"), cheapest))
                                                    .font(.system(size: 12)).foregroundStyle(Theme.text(cs))
                                                Spacer()
                                                if abs(price - cheapest) < 0.001 {
                                                    Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 11))
                                                }
                                            }
                                            .padding(8).background(Color.green.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain)
                                    }
                                    if latestSavedPrice == nil {
                                        Text(L("vehicle.no_prices_saved"))
                                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    }
                                }
                            }
                        } else {
                            // Elektro: manueller kWh-Preis (kein API verfügbar)
                            HStack {
                                Label(L("vehicle.power_price_label"), systemImage: "bolt.fill")
                                    .foregroundStyle(Theme.text(cs))
                                Spacer()
                                TextField("0.00", value: $price,
                                          format: .number.precision(.fractionLength(2)))
                                    .multilineTextAlignment(.trailing).foregroundStyle(Color(hex: "A78BFA"))
                                    .frame(width: 70).keyboardType(.decimalPad)
                                Text("€/kWh").foregroundStyle(.secondary).font(.caption)
                            }
                            Text(L("vehicle.power_not_available"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // MARK: Profilfarbe
                    Section(L("vehicle.color_section")) {
                        HStack {
                            Label(L("vehicle.color_section"), systemImage: "paintpalette.fill")
                                .foregroundStyle(Theme.text(cs))
                            Spacer()
                            ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 44, height: 32)
                        }

                        // Schnellwahl-Palette
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                            ForEach(VehicleProfile.colorPalette, id: \.self) { hex in
                                let c = Color(hex: hex)
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) { selectedColor = c }
                                } label: {
                                    Circle()
                                        .fill(c)
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: isSelected(hex: hex) ? 2.5 : 0)
                                                .padding(2)
                                        )
                                        .shadow(color: c.opacity(0.5), radius: isSelected(hex: hex) ? 6 : 0)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(Theme.card(cs))
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Theme.card(cs))
                }
                .scrollContentBackground(.hidden).background(Theme.bg(cs))
            }
            .navigationTitle(profile == nil ? L("vehicle.add") : L("vehicle.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg(cs), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }.foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let canonical = VehicleProfile.canonicalizeFuelType(fuelType)
                        onSave(name.trimmingCharacters(in: .whitespaces), canonical, consumption, price, colorHexFromPicker())
                        dismiss()
                    }
                    .fontWeight(.semibold).foregroundStyle(selectedColor)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private func isSelected(hex: String) -> Bool {
        Color(hex: hex).description == selectedColor.description
    }

    private func colorHexFromPicker() -> String {
        // Versuche, die gewählte Farbe zurück in Hex umzuwandeln
        // Vergleiche zuerst mit Palette
        for hex in VehicleProfile.colorPalette {
            if Color(hex: hex).description == selectedColor.description { return hex }
        }
        // Fallback: UIColor → Hex
        let uiColor = UIColor(selectedColor)
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
}
