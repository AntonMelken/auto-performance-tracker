import Foundation
import SwiftData
import CoreLocation
import SwiftUI
import Combine

// MARK: - FuelPriceView
// FIX ARCH-001: FuelPriceEntry → Models/FuelPriceEntry.swift
//               TankerkoenigService → Services/TankerkoenigService.swift

// MARK: - FuelCategory
enum FuelCategory: String, CaseIterable {
    case e5     = "E5"
    case e10    = "E10"
    case diesel = "Diesel"
    case lpg    = "LPG"
    case ev     = "Elektro"
}

// MARK: - FuelPriceView

struct FuelPriceView: View {
    @Query(sort: \FuelPriceEntry.date, order: .reverse) private var entries: [FuelPriceEntry]
    @Environment(\.modelContext) private var ctx
    @Query(sort: \VehicleProfile.sortOrder) private var profiles: [VehicleProfile]

    // FIX ARCH-003: War @StateObject private var stationsService = NearbyStationsService.shared
    // @StateObject mit Singleton ist ein Anti-Pattern: SwiftUI kann den init-Closure
    // mehrfach aufrufen; bei .shared ist das zwar harmlos, aber semantisch falsch.
    // Fix: @EnvironmentObject — der Lifecycle liegt beim App-Root.
    @EnvironmentObject private var stationsService: NearbyStationsService

    @State private var showAddManual    = false
    @State private var manualPrice: Double = 1.89
    @State private var manualFuelType   = "e5"
    @State private var selectedTab: FuelTab = .stations
    @State private var fuelCategoryFilter: FuelCategory = .e5
    @State private var showMapsActionSheet     = false
    @State private var showHistoryMapsSheet    = false
    @State private var pendingHistoryMapsName  = ""
    @State private var pendingHistoryMapsCity  = ""
    @State private var pendingMapsStation: NearbyStation?
    @State private var showVehiclePriceSheet   = false
    @State private var pendingVehiclePrice: Double = 0
    @State private var pendingVehicleFuelType  = "e5"
    @State private var selectedProfileForPrice: VehicleProfile?

    // Feature 04 – Markenfilter (client-seitig)
    @State private var selectedBrand: String? = nil
    // Feature 06 – Sortierung: true = nach Entfernung, false = nach Preis
    @State private var sortByDistance: Bool = false

    // Auto-Refresh Timer
    @State private var refreshTimer: Timer? = nil

    @AppStorage("favoriteStationId")   private var favoriteStationId: String = ""
    @AppStorage("favoriteStationName") private var favoriteStationName: String = ""
    @AppStorage("favoriteStationCity") private var favoriteStationCity: String = ""
    @AppStorage("currentOwnerUserId")  private var currentOwnerUserId: String = ""

    /// Nur Fahrzeuge des aktuellen Users (Account-Isolation wie in SettingsView)
    private var myProfiles: [VehicleProfile] {
        profiles.filter { $0.ownerUserId == currentOwnerUserId }
    }

    private let fuelTypes = ["e5", "e10", "diesel", "lpg", "electricity"]

    enum FuelTab: String, CaseIterable {
        case stations = "Tankstellen"
        case history  = "Gespeicherte Tankstellen"
    }

    // ─── Body ────────────────────────────────────────────────────
    var body: some View {
        ZStack {
            Color(hex: "080C14").ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(FuelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 10)

                if selectedTab == .stations { stationsTab }
                else                        { historyTab  }
            }
        }
        .navigationTitle(L("fuel.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Feature 06: Sortier-Toggle Preis ↔ Entfernung (nur im Stations-Tab sinnvoll)
                if selectedTab == .stations {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { sortByDistance.toggle() }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: sortByDistance
                                  ? "location.fill"
                                  : "tag.fill")
                                .font(.system(size: 11))
                            Text(sortByDistance
                                 ? L("gas.sort_distance")
                                 : L("gas.sort_price"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(sortByDistance ? Color.cyan : Color(hex: "818CF8"))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((sortByDistance ? Color.cyan : Color(hex: "818CF8")).opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddManual = true }) {
                    Image(systemName: "plus").foregroundStyle(.cyan)
                }
            }
        }
        .sheet(isPresented: $showAddManual)         { addManualSheet }
        .sheet(isPresented: $showVehiclePriceSheet) { vehiclePriceSheet }
        .sheet(isPresented: $showMapsActionSheet) {
            if let station = pendingMapsStation {
                mapsChoiceSheet(station: station)
            }
        }
        .sheet(isPresented: $showHistoryMapsSheet) {
            historyMapsChoiceSheet(name: pendingHistoryMapsName, city: pendingHistoryMapsCity)
        }
        .onAppear {
            stationsService.requestLocation()
            startAutoRefresh()
            // Favorit-Station sofort online aktualisieren
            Task { await stationsService.refreshFavoriteStation() }
            AnalyticsService.shared.trackFeatureUsed("fuel_price_viewed")
        }
        .onDisappear { stopAutoRefresh() }
    }

    // MARK: - Auto-Refresh
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                if let loc = stationsService.currentLocation {
                    await stationsService.fetchAll(near: loc)
                }
            }
        }
    }
    private func stopAutoRefresh() { refreshTimer?.invalidate(); refreshTimer = nil }

    // MARK: - Stations Tab ─────────────────────────────────────────
    private var stationsTab: some View {
        Group {
            if stationsService.isLoading {
                VStack(spacing: 16) {
                    ProgressView().tint(.cyan).scaleEffect(1.3)
                    Text(L("gas.loading")).foregroundStyle(.secondary)
                }.frame(maxHeight: .infinity)
            } else if let err = stationsService.errorMessage {
                errorState(err)
            } else if stationsService.stations.isEmpty && stationsService.lpgStations.isEmpty && stationsService.evStations.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    // Kraftstoff-Kategorie-Filter
                    fuelCategoryPicker.padding(.horizontal).padding(.bottom, 6)

                    // Feature 05 – Radius-Selektor
                    radiusSelector.padding(.bottom, 4)

                    // Feature 04 – Markenfilter (nur für konventionelle Kraftstoffe)
                    if fuelCategoryFilter != .lpg && fuelCategoryFilter != .ev {
                        brandFilterPicker.padding(.bottom, 6)
                    }

                    ScrollView {
                        VStack(spacing: 12) {
                            // Favorit-Banner
                            if !favoriteStationId.isEmpty { favoriteBanner }

                            // Highlights-Kacheln (angepasst je Kategorie)
                            highlightCards.padding(.horizontal)

                            // Station-Liste
                            VStack(spacing: 8) {
                                stationListForCategory
                            }.padding(.horizontal)
                        }
                        .padding(.top, 8).padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private var fuelCategoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FuelCategory.allCases, id: \.self) { cat in
                    fuelCategoryButton(cat)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func fuelCategoryButton(_ cat: FuelCategory) -> some View {
        let isSelected = fuelCategoryFilter == cat
        return Button(cat.rawValue) {
            withAnimation(.easeInOut(duration: 0.15)) {
                fuelCategoryFilter = cat
                selectedBrand = nil   // Markenfilter bei Kategorienwechsel zurücksetzen
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isSelected ? Color.cyan : Color(hex: "0F1A2E"))
        .foregroundStyle(isSelected ? Color.black : Color.gray)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(isSelected ? Color.clear : Color.white.opacity(0.07)))
    }

    // MARK: - Feature 05: Radius-Selektor
    private var radiusSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text(L("gas.radius_label"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                ForEach([5, 10, 15, 30], id: \.self) { km in
                    radiusButton(km)
                }
            }
            .padding(.trailing, 16)
        }
    }

    private func radiusButton(_ km: Int) -> some View {
        let isSelected = stationsService.selectedRadiusKm == km
        return Button("\(km) km") {
            guard stationsService.selectedRadiusKm != km else { return }
            stationsService.selectedRadiusKm = km
            // Neue Suche mit geändertem Radius auslösen
            if let loc = stationsService.currentLocation {
                Task { await stationsService.fetchAll(near: loc) }
            } else {
                stationsService.requestLocation()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isSelected ? Color(hex: "06B6D4") : Color(hex: "0F1A2E"))
        .foregroundStyle(isSelected ? Color.black : Color.gray)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(isSelected ? Color.clear : Color.white.opacity(0.07)))
    }

    // MARK: - Feature 04: Markenfilter
    private var brandFilterPicker: some View {
        let detectedBrands = Array(
            Set(stationsService.stations.compactMap(\.detectedBrand))
        ).sorted()
        guard !detectedBrands.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text(L("gas.brand_label"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                    brandButton(label: L("gas.brand_all"), isSelected: selectedBrand == nil) {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedBrand = nil }
                    }
                    ForEach(detectedBrands, id: \.self) { brand in
                        brandButton(label: brand, isSelected: selectedBrand == brand) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedBrand = (selectedBrand == brand) ? nil : brand
                            }
                        }
                    }
                }
                .padding(.trailing, 16)
            }
        )
    }

    private func brandButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isSelected ? Color(hex: "818CF8") : Color(hex: "0F1A2E"))
                .foregroundStyle(isSelected ? Color.white : Color.gray)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.clear : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feature 04+06: Gefilterte + sortierte Stationen (Brand + Distanz/Preis)

    /// Alle konventionellen Stationen nach aktivem Markenfilter begrenzen.
    private var brandFilteredStations: [NearbyStation] {
        guard let brand = selectedBrand else { return stationsService.stations }
        return stationsService.stations.filter {
            $0.name.uppercased().contains(brand.uppercased())
        }
    }

    /// Stationen für die aktuelle Kraftstoff-KeyPath gefiltert und sortiert zurückgeben.
    private func filteredSorted(by keyPath: KeyPath<NearbyStation, Double?>) -> [NearbyStation] {
        let base = brandFilteredStations.filter { $0[keyPath: keyPath] != nil }
        if sortByDistance {
            return base.sorted { $0.dist < $1.dist }
        } else {
            return base.sorted { ($0[keyPath: keyPath] ?? 9) < ($1[keyPath: keyPath] ?? 9) }
        }
    }

    @ViewBuilder
    private var highlightCards: some View {
        switch fuelCategoryFilter {
        case .e5:
            HStack(spacing: 10) {
                if let cheap = stationsService.cheapestE5 {
                    stationHighlightCard(station: cheap, icon: "tag.fill", color: .green,
                                         title: L("gas.cheapest"),
                                         detail: cheap.e5.map { String(format: "%.3f €", $0) } ?? "–",
                                         highlightFuel: "e5")
                }
                if let near = stationsService.nearest {
                    stationHighlightCard(station: near, icon: "location.fill", color: .cyan,
                                         title: L("gas.nearest"),
                                         detail: near.e5.map { String(format: "%.3f €", $0) } ?? String(format: "%.1f km", near.dist),
                                         highlightFuel: "e5")
                }
            }
        case .e10:
            HStack(spacing: 10) {
                if let cheap = stationsService.cheapestE10 {
                    stationHighlightCard(station: cheap, icon: "tag.fill", color: .green,
                                         title: L("gas.cheapest"),
                                         detail: cheap.e10.map { String(format: "%.3f €", $0) } ?? "–",
                                         highlightFuel: "e10")
                }
                if let near = stationsService.stations.filter({ $0.isOpen && $0.e10 != nil }).min(by: { $0.dist < $1.dist }) {
                    stationHighlightCard(station: near, icon: "location.fill", color: .cyan,
                                         title: L("gas.nearest"),
                                         detail: near.e10.map { String(format: "%.3f €", $0) } ?? String(format: "%.1f km", near.dist),
                                         highlightFuel: "e10")
                }
            }
        case .diesel:
            HStack(spacing: 10) {
                if let cheap = stationsService.cheapestDiesel {
                    stationHighlightCard(station: cheap, icon: "tag.fill", color: .green,
                                         title: L("gas.cheapest"),
                                         detail: cheap.diesel.map { String(format: "%.3f €", $0) } ?? "–",
                                         highlightFuel: "diesel")
                }
                if let near = stationsService.stations.filter({ $0.isOpen && $0.diesel != nil }).min(by: { $0.dist < $1.dist }) {
                    stationHighlightCard(station: near, icon: "location.fill", color: .cyan,
                                         title: L("gas.nearest"),
                                         detail: near.diesel.map { String(format: "%.3f €", $0) } ?? String(format: "%.1f km", near.dist),
                                         highlightFuel: "diesel")
                }
            }
        case .lpg:
            let lpgList = stationsService.lpgStations.prefix(2)
            if lpgList.isEmpty {
                EmptyView()
            } else if let lpg = lpgList.first {
                if lpgList.count > 1, let second = lpgList.last {
                    HStack(spacing: 10) {
                        stationHighlightCard(station: lpg, icon: "flame.fill", color: Color(hex: "F97316"),
                                             title: L("gas.nearest_lpg"),
                                             detail: lpg.lpg.map { String(format: "%.3f €", $0) } ?? L("gas.price_unknown"),
                                             highlightFuel: "lpg")
                        stationHighlightCard(station: second, icon: "flame.fill", color: Color(hex: "F97316"),
                                             title: "2. Nächste LPG",
                                             detail: second.lpg.map { String(format: "%.3f €", $0) } ?? L("gas.price_unknown"),
                                             highlightFuel: "lpg")
                    }
                } else {
                    stationHighlightCard(station: lpg, icon: "flame.fill", color: Color(hex: "F97316"),
                                         title: L("gas.nearest_lpg"),
                                         detail: lpg.lpg.map { String(format: "%.3f €", $0) } ?? L("gas.price_unknown"),
                                         highlightFuel: "lpg")
                }
            }
        case .ev:
            if let ev = stationsService.nearestEV {
                stationHighlightCard(station: ev, icon: "bolt.fill", color: Color(hex: "A78BFA"),
                                     title: L("gas.nearest_ev"),
                                     detail: ev.evPower.map { String(format: "%.0f kW", $0) } ?? L("gas.ev_unknown_power"))
            }
        }
    }

    @ViewBuilder
    private var stationListForCategory: some View {
        switch fuelCategoryFilter {
        case .e5:
            let e5Stations = filteredSorted(by: \.e5)
            if e5Stations.isEmpty { noDataHint(text: L("gas.no_stations")) }
            else { ForEach(e5Stations.prefix(20)) { conventionalRow($0, highlightFuel: "e5") } }
        case .e10:
            let e10Stations = filteredSorted(by: \.e10)
            if e10Stations.isEmpty { noDataHint(text: L("gas.no_stations")) }
            else { ForEach(e10Stations.prefix(20)) { conventionalRow($0, highlightFuel: "e10") } }
        case .diesel:
            let dieselStations = filteredSorted(by: \.diesel)
            if dieselStations.isEmpty { noDataHint(text: L("gas.no_stations")) }
            else { ForEach(dieselStations.prefix(20)) { conventionalRow($0, highlightFuel: "diesel") } }
        case .lpg:
            if stationsService.lpgStations.isEmpty {
                noDataHint(text: L("gas.no_lpg_stations"))
            } else {
                // Hinweis wenn Ergebnis aus erweiterter Suche stammt (> 15 km)
                if let nearest = stationsService.lpgStations.first, nearest.dist > 15 {
                    noDataHint(text: L("gas.no_lpg_nearby"))
                        .padding(.bottom, 4)
                }
                // LPG: immer nach Entfernung (API liefert keine Preise zuverlässig)
                ForEach(stationsService.lpgStations.prefix(20)) { lpgRow($0) }
            }
        case .ev:
            if stationsService.evStations.isEmpty {
                noDataHint(text: stationsService.ocmKeyMissing ? L("gas.ev_key_missing") : L("gas.no_ev_stations"))
            } else {
                // EV: immer nach Entfernung
                ForEach(stationsService.evStations.prefix(20)) { evRow($0) }
            }
        }
    }

    // MARK: - History Tab ─────────────────────────────────────────
    private var historyTab: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(L("fuel.empty_title")).font(.headline).foregroundStyle(.secondary)
                    Text(L("fuel.empty_message")).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L("fuel.add_manual")) { showAddManual = true }.foregroundStyle(.cyan)
                }.padding().frame(maxHeight: .infinity)
            } else {
                // Gruppiere Einträge nach Kraftstoffart in fester Reihenfolge
                let orderedTypes = ["e5", "e10", "diesel", "lpg", "electricity"]
                let grouped: [(String, [FuelPriceEntry])] = orderedTypes.compactMap { type in
                    let filtered = entries.filter { $0.fuelType == type }
                    return filtered.isEmpty ? nil : (type, filtered)
                }
                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(grouped, id: \.0) { (fuelType, typeEntries) in
                            VStack(spacing: 8) {
                                // Header mit aktuellem Preis dieser Kraftstoffart
                                if let latest = typeEntries.first {
                                    priceHeader(latest)
                                }
                                // Chart nur für diese Kraftstoffart
                                if typeEntries.count > 1 {
                                    priceHistoryChart(for: typeEntries)
                                }
                                // Einträge dieser Kraftstoffart
                                VStack(spacing: 1) {
                                    ForEach(typeEntries.prefix(50)) { historyRow($0) }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .padding(.horizontal)
                            }
                        }
                        Spacer(minLength: 24)
                    }.padding(.top, 8)
                }
            }
        }
    }

    // MARK: - Station Components ──────────────────────────────────

    private func stationHighlightCard(station: NearbyStation, icon: String, color: Color,
                                      title: String, detail: String,
                                      highlightFuel: String = "e5") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(color).font(.caption)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(station.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            HStack {
                Text(String(format: "%.1f km", station.dist)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                openStatusBadge(station.isOpen)
            }
            // Action-Buttons für Highlights
            HStack(spacing: 8) {
                // Preis speichern – korrekte Kraftstoffart aus dem aktiven Filter
                let price: Double? = {
                    switch highlightFuel {
                    case "e5":          return station.e5
                    case "e10":         return station.e10
                    case "diesel":      return station.diesel
                    case "lpg":         return station.lpg
                    default:            return station.e5 ?? station.e10 ?? station.diesel ?? station.lpg
                    }
                }()
                if let p = price {
                    Button(action: { savePrice(station, price: p, type: highlightFuel) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 9))
                            Text("Speichern").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.cyan)
                        .fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.cyan.opacity(0.1)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                // Route
                Button(action: { pendingMapsStation = station; showMapsActionSheet = true }) {
                    HStack(spacing: 3) {
                        Image(systemName: "map.fill").font(.system(size: 9))
                        Text("Route").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color(hex: "818CF8"))
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color(hex: "818CF8").opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.2)))
    }

    // Conventional station row
    private func conventionalRow(_ station: NearbyStation, highlightFuel: String = "e5") -> some View {
        let isFav = favoriteStationId == station.id
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: { toggleFavorite(station) }) {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(isFav ? .yellow : .secondary.opacity(0.5))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(station.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if isFav {
                            Text(L("gas.favorite")).font(.system(size: 9, weight: .bold)).foregroundStyle(.yellow)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.yellow.opacity(0.15)).clipShape(Capsule())
                        }
                    }
                    Text("\(station.place) · \(String(format: "%.1f km", station.dist))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    switch highlightFuel {
                    case "e5":
                        if let e5 = station.e5 {
                            Text(String(format: "%.3f €", e5))
                                .font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.cyan)
                        }
                    case "e10":
                        if let e10 = station.e10 {
                            Text(String(format: "%.3f €", e10))
                                .font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Color(hex: "67E8F9"))
                        }
                    case "diesel":
                        if let d = station.diesel {
                            Text(String(format: "%.3f €", d))
                                .font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        }
                    default:
                        if let e5 = station.e5 {
                            Text(String(format: "E5  %.3f €", e5))
                                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.cyan)
                        }
                        if let e10 = station.e10 {
                            Text(String(format: "E10 %.3f €", e10))
                                .font(.system(size: 11)).foregroundStyle(Color(hex: "67E8F9"))
                        }
                        if let d = station.diesel {
                            Text(String(format: "D   %.3f €", d))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                openStatusBadge(station.isOpen)
            }.padding(12)

            HStack(spacing: 6) {
                // Only show relevant save button for current filter
                switch highlightFuel {
                case "e5":
                    if let e5 = station.e5 { savePriceButton(station: station, price: e5, fuelType: "e5", label: "E5") }
                case "e10":
                    if let e10 = station.e10 { savePriceButton(station: station, price: e10, fuelType: "e10", label: "E10") }
                case "diesel":
                    if let d = station.diesel { savePriceButton(station: station, price: d, fuelType: "diesel", label: "Diesel") }
                default:
                    if let e5 = station.e5 { savePriceButton(station: station, price: e5, fuelType: "e5", label: "E5") }
                    if let e10 = station.e10 { savePriceButton(station: station, price: e10, fuelType: "e10", label: "E10") }
                    if let d = station.diesel { savePriceButton(station: station, price: d, fuelType: "diesel", label: "D") }
                }
                Spacer()
                Button(action: { pendingMapsStation = station; showMapsActionSheet = true }) {
                    Label(L("gas.open_maps"), systemImage: "map.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: "818CF8"))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(hex: "818CF8").opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .background(Color(hex: "0F1A2E")).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(isFav ? RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.3), lineWidth: 1) : nil)
    }

    // LPG station row
    private func lpgRow(_ station: NearbyStation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill").foregroundStyle(Color(hex: "F97316")).font(.system(size: 16))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(station.place) · \(String(format: "%.1f km", station.dist))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let lpg = station.lpg {
                        Text(String(format: "%.3f €/L", lpg))
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color(hex: "F97316"))
                    } else {
                        Text(L("gas.price_unknown")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("LPG").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: "F97316"))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(hex: "F97316").opacity(0.15)).clipShape(Capsule())
                }
            }.padding(12)
            HStack(spacing: 8) {
                if let lpg = station.lpg {
                    savePriceButton(station: station, price: lpg, fuelType: "lpg", label: "LPG")
                }
                Spacer()
                Button(action: { pendingMapsStation = station; showMapsActionSheet = true }) {
                    Label(L("gas.open_maps"), systemImage: "map.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: "818CF8"))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(hex: "818CF8").opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
        .background(Color(hex: "0F1A2E")).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // EV station row
    private func evRow(_ station: NearbyStation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").foregroundStyle(Color(hex: "A78BFA")).font(.system(size: 16))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(station.place) · \(String(format: "%.1f km", station.dist))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let kw = station.evPower {
                        Text(String(format: "%.0f kW", kw))
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color(hex: "A78BFA"))
                    }
                    openStatusBadge(station.isOpen)
                }
            }.padding(12)
            HStack(spacing: 8) {
                Spacer()
                Button(action: { pendingMapsStation = station; showMapsActionSheet = true }) {
                    Label(L("gas.open_maps"), systemImage: "map.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: "818CF8"))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(hex: "818CF8").opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
        .background(Color(hex: "0F1A2E")).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func savePriceButton(station: NearbyStation, price: Double, fuelType: String, label: String) -> some View {
        Button(action: { savePrice(station, price: price, type: fuelType) }) {
            Text("\(label) \(L("gas.save_price"))")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.cyan)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.cyan.opacity(0.1)).clipShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func openStatusBadge(_ isOpen: Bool) -> some View {
        Text(isOpen ? L("gas.open") : L("gas.closed"))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isOpen ? .green : .red.opacity(0.7))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((isOpen ? Color.green : Color.red).opacity(0.1)).clipShape(Capsule())
    }

    private var favoriteBanner: some View {
        let favStation = stationsService.stations.first { $0.id == favoriteStationId }
        return HStack(spacing: 10) {
            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("gas.fav_active")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.yellow)
                Text("\(favoriteStationName), \(favoriteStationCity)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                // Aktueller Live-Preis der Favorit-Station
                if let st = favStation {
                    HStack(spacing: 8) {
                        if let e5 = st.e5 {
                            Text("E5 \(String(format: "%.3f €", e5))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
                        }
                        if let e10 = st.e10 {
                            Text("E10 \(String(format: "%.3f €", e10))").font(.system(size: 11)).foregroundStyle(Color(hex: "67E8F9"))
                        }
                        if let d = st.diesel {
                            Text("D \(String(format: "%.3f €", d))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Button(L("gas.fav_remove")) {
                favoriteStationId = ""; favoriteStationName = ""; favoriteStationCity = ""
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12).background(Color.yellow.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.2)))
        .padding(.horizontal)
    }

    private func errorState(_ err: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.orange)
            Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L("common.try_again")) { stationsService.requestLocation() }.foregroundStyle(.cyan)
        }.padding().frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fuelpump.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(L("gas.no_stations")).foregroundStyle(.secondary)
            Button(L("gas.refresh")) { stationsService.requestLocation() }.foregroundStyle(.cyan)
        }.frame(maxHeight: .infinity)
    }

    private func noDataHint(text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(hex: "0F1A2E")).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - History Components ──────────────────────────────────

    private func priceHeader(_ entry: FuelPriceEntry) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("fuel.current_price")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(String(format: "%.3f €/L", entry.pricePerUnit))
                        .font(.system(size: 28, weight: .thin, design: .rounded)).foregroundStyle(.white)
                    if entry.isFromTrip {
                        Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(Color(hex: "4A5A70"))
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(fuelLabel(entry.fuelType)).font(.caption).foregroundStyle(.secondary)
                if !entry.stationName.isEmpty { Text(entry.stationName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Text(entry.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(16).background(Color(hex: "0F1A2E"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07)))
        .padding(.horizontal, 16)
    }

    private func priceHistoryChart(for typeEntries: [FuelPriceEntry]) -> some View {
        let recent = Array(typeEntries.prefix(10).reversed())
        let maxP = recent.map(\.pricePerUnit).max() ?? 2.0
        let minP = recent.map(\.pricePerUnit).min() ?? 1.5
        let range = max(maxP - minP, 0.05)

        return GeometryReader { geo in
            let w = geo.size.width; let h = geo.size.height
            let step = w / CGFloat(max(1, recent.count - 1))
            ZStack {
                Path { path in
                    for (i, entry) in recent.enumerated() {
                        let x = CGFloat(i) * step
                        let y = h - h * CGFloat((entry.pricePerUnit - minP) / range)
                        i == 0 ? path.move(to: .init(x: x, y: y)) : path.addLine(to: .init(x: x, y: y))
                    }
                }
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 60).padding(.horizontal, 16).padding(.bottom, 4)
    }

    /// Sucht in den aktuell geladenen Live-Stationen nach einer Station mit passendem Namen.
    private func liveStation(for entry: FuelPriceEntry) -> NearbyStation? {
        guard !entry.stationName.isEmpty else { return nil }
        let allStations = stationsService.stations + stationsService.lpgStations + stationsService.evStations
        return allStations.first { $0.name.localizedCaseInsensitiveContains(entry.stationName) || entry.stationName.localizedCaseInsensitiveContains($0.name) }
    }

    private func historyRow(_ entry: FuelPriceEntry) -> some View {
        let live = liveStation(for: entry)
        // Live-Preis dieser Kraftstoffart aus der gefundenen Station, falls vorhanden
        let livePrice: Double? = {
            guard let st = live else { return nil }
            switch entry.fuelType {
            case "e5":      return st.e5
            case "e10":     return st.e10
            case "diesel":  return st.diesel
            case "lpg":     return st.lpg
            default:        return nil
            }
        }()
        let displayPrice = livePrice ?? entry.pricePerUnit
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // Linke Seite: Kraftstoffart-Badges + Stationsinfo + Datum
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(fuelLabel(entry.fuelType))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        if entry.isFromTrip {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10)).foregroundStyle(Color(hex: "4A5A70"))
                        }
                        if let live { openStatusBadge(live.isOpen) }
                        if livePrice != nil {
                            Text("Live")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                    if !entry.stationName.isEmpty {
                        Text(entry.stationCity.isEmpty
                             ? entry.stationName
                             : "\(entry.stationName), \(entry.stationCity)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // Rechte Seite: Preis + Aktions-Icons
                VStack(alignment: .trailing, spacing: 6) {
                    Text(String(format: "%.3f €/L", displayPrice))
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .foregroundStyle(livePrice != nil ? .green : .cyan)
                    HStack(spacing: 10) {
                        if !entry.isFromTrip {
                            Button(action: { ctx.delete(entry); try? ctx.save() }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 13)).foregroundStyle(.red.opacity(0.55))
                            }.buttonStyle(.plain)
                        }
                        if !entry.stationName.isEmpty {
                            Button(action: {
                                pendingHistoryMapsName = entry.stationName
                                pendingHistoryMapsCity = entry.stationCity
                                showHistoryMapsSheet   = true
                            }) {
                                Image(systemName: "map.fill")
                                    .font(.system(size: 13)).foregroundStyle(Color(hex: "818CF8"))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            // "Für Fahrzeug nutzen" als eigene Zeile – kein Platzmangel mehr
            if !entry.isFromTrip {
                Button(action: {
                    pendingVehiclePrice    = displayPrice
                    pendingVehicleFuelType = entry.fuelType
                    showVehiclePriceSheet  = true
                }) {
                    Label("Für Fahrzeug nutzen", systemImage: "car.fill")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: "F59E0B"))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(hex: "F59E0B").opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).background(Color(hex: "0F1A2E"))
    }

    // MARK: - Manual Add Sheet
    private var addManualSheet: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()
                Form {
                    Section(L("fuel.type_section")) {
                        Picker(L("fuel.type_label"), selection: $manualFuelType) {
                            ForEach(fuelTypes, id: \.self) { Text(fuelLabel($0)).tag($0) }
                        }.pickerStyle(.segmented).listRowBackground(Color(hex: "0F1A2E"))
                    }
                    Section(L("fuel.price_section")) {
                        HStack {
                            TextField(L("fuel.price_placeholder"), value: $manualPrice,
                                      format: .number.precision(.fractionLength(3)))
                                .keyboardType(.decimalPad).foregroundStyle(.cyan)
                            Text("€").foregroundStyle(.secondary)
                        }.listRowBackground(Color(hex: "0F1A2E"))
                    }
                }
                .scrollContentBackground(.hidden).background(Color(hex: "080C14"))
            }
            .navigationTitle(L("fuel.add_manual")).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { showAddManual = false }.foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        let entry = FuelPriceEntry(fuelType: manualFuelType, pricePerUnit: manualPrice)
                        ctx.insert(entry); try? ctx.save()
                        // Fahrzeugpreis merken, dann erst Sheet schließen – vehiclePriceSheet
                        // erst nach abgeschlossener Dismiss-Animation öffnen
                        pendingVehiclePrice    = manualPrice
                        pendingVehicleFuelType = manualFuelType
                        showAddManual = false
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            showVehiclePriceSheet = true
                        }
                    }.foregroundStyle(.cyan).fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
    }

    // MARK: - Vehicle Price Adopt Sheet ───────────────────────────
    private var vehiclePriceSheet: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()
                VStack(spacing: 20) {
                    // Header mit Preis
                    VStack(spacing: 6) {
                        Text(L("gas.adopt_vehicle_title"))
                            .font(.headline).foregroundStyle(.white)
                        VStack(spacing: 4) {
                            Image(systemName: "fuelpump.fill").foregroundStyle(.cyan)
                                .font(.system(size: 20))
                            Text(String(format: "%.3f €/L", pendingVehiclePrice))
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                        }
                        Text(fuelLabel(pendingVehicleFuelType))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Diesen Preis als Standardpreis für ein Fahrzeug übernehmen?")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }.padding(.top, 8)

                    Divider().background(Color.white.opacity(0.1)).padding(.horizontal)

                    VStack(spacing: 8) {
                        ForEach(myProfiles) { profile in
                            let isCompatible = vehicleCompatible(profile: profile, fuelType: pendingVehicleFuelType)
                            Button(action: {
                                if isCompatible {
                                    profile.fuelPricePerLiter = pendingVehiclePrice
                                    try? ctx.save()
                                }
                                showVehiclePriceSheet = false
                            }) {
                                HStack {
                                    Image(systemName: profile.fuelIcon)
                                        .foregroundStyle(Color(hex: profile.fuelColorHex))
                                        .frame(width: 24)
                                    Text(profile.name).foregroundStyle(.white)
                                    Spacer()
                                    if isCompatible {
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(String(format: "%.3f €/L", pendingVehiclePrice))
                                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.cyan)
                                            Text(String(format: "vorher %.3f €/L", profile.fuelPricePerLiter))
                                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text(L("gas.incompatible_fuel")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(12).background(isCompatible ? Color.cyan.opacity(0.08) : Color(hex: "0F1A2E"))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .opacity(isCompatible ? 1.0 : 0.5)
                            }.buttonStyle(.plain).disabled(!isCompatible)
                        }
                    }.padding(.horizontal)

                    Button(L("common.cancel")) { showVehiclePriceSheet = false }.foregroundStyle(.secondary)
                    Spacer()
                }.padding(.top, 16)
            }
            .navigationTitle("Fahrzeugpreis aktualisieren").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .presentationBackground(Color(hex: "080C14"))
    }

    // MARK: - Maps Choice Bottom Sheet ───────────────────────────

    private func mapsChoiceSheet(station: NearbyStation) -> some View {
        VStack(spacing: 0) {
            // Handle
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            Text(L("gas.maps_choose"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 6)

            Text(station.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            VStack(spacing: 10) {
                Button(action: {
                    showMapsActionSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        openAppleMaps(station)
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                        Text(L("gas.maps_apple"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color(hex: "0F1A2E"))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(action: {
                    showMapsActionSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        openGoogleMaps(station)
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "map")
                            .font(.system(size: 18))
                            .foregroundStyle(.cyan)
                        Text(L("gas.maps_google"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color(hex: "0F1A2E"))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(action: { showMapsActionSheet = false }) {
                    Text(L("common.cancel"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "0F1A2E"))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
        .background(Color(hex: "080C14"))
        .presentationDetents([.height(290)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(hex: "080C14"))
    }

    // MARK: - Actions ─────────────────────────────────────────────

    private func toggleFavorite(_ station: NearbyStation) {
        if favoriteStationId == station.id {
            favoriteStationId = ""; favoriteStationName = ""; favoriteStationCity = ""
        } else {
            favoriteStationId = station.id; favoriteStationName = station.name; favoriteStationCity = station.place
            if let e5 = station.e5     { UserDefaults.standard.set(e5,  forKey: "favoriteStation_e5_price") }
            if let e10 = station.e10   { UserDefaults.standard.set(e10, forKey: "favoriteStation_e10_price") }
            if let d = station.diesel  { UserDefaults.standard.set(d,   forKey: "favoriteStation_diesel_price") }
        }
    }

    private func savePrice(_ station: NearbyStation, price: Double, type: String) {
        // Duplikat-Schutz: direkt per Fetch prüfen (nicht @Query, das kann beim ersten
        // Render noch leer sein und dadurch doppelte Einträge durchlassen).
        // Gleiche Station + gleicher Kraftstofftyp → bestehenden Eintrag aktualisieren
        // statt einen neuen hinzuzufügen, damit dieselbe Tankstelle nicht mehrfach erscheint.
        let stationName = station.name
        let descriptor = FetchDescriptor<FuelPriceEntry>(
            predicate: #Predicate { e in
                e.fuelType == type && e.stationName == stationName && !e.isFromTrip
            }
        )
        let existing = (try? ctx.fetch(descriptor)) ?? []

        if let existingEntry = existing.first {
            // Preis und Datum aktualisieren statt neu anlegen
            existingEntry.pricePerUnit = price
            existingEntry.date = .now
            try? ctx.save()
        } else {
            let entry = FuelPriceEntry(fuelType: type, pricePerUnit: price,
                                       stationName: station.name, stationCity: station.place)
            ctx.insert(entry); try? ctx.save()
        }

        // Fahrzeugpreis-Angebot: State vor dem Tab-Wechsel setzen, damit kein Reset entsteht
        pendingVehiclePrice    = price
        pendingVehicleFuelType = type
        showVehiclePriceSheet  = true

        withAnimation { selectedTab = .history }
    }

    // MARK: - History Maps Choice Bottom Sheet ────────────────────

    private func historyMapsChoiceSheet(name: String, city: String) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            Text(L("gas.maps_choose"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 6)

            Text(city.isEmpty ? name : "\(name), \(city)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            VStack(spacing: 10) {
                Button(action: {
                    showHistoryMapsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        openAppleMapsByName(name, city: city)
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                        Text(L("gas.maps_apple"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .background(Color(hex: "0F1A2E"))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(action: {
                    showHistoryMapsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        openGoogleMapsByName(name, city: city)
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "map")
                            .font(.system(size: 18))
                            .foregroundStyle(.cyan)
                        Text(L("gas.maps_google"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .background(Color(hex: "0F1A2E"))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(action: { showHistoryMapsSheet = false }) {
                    Text(L("common.cancel"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "0F1A2E"))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(320)]).presentationDragIndicator(.visible)
        .background(Color(hex: "080C14").ignoresSafeArea())
    }

    private func openAppleMapsByName(_ name: String, city: String) {
        let query = city.isEmpty ? name : "\(name) \(city)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "maps://?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    private func openGoogleMapsByName(_ name: String, city: String) {
        let query  = city.isEmpty ? name : "\(name) \(city)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let gURL   = URL(string: "comgooglemaps://?q=\(encoded)")
        if let gURL, UIApplication.shared.canOpenURL(gURL) {
            UIApplication.shared.open(gURL)
        } else if let webURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(encoded)") {
            UIApplication.shared.open(webURL)
        }
    }

    private func openAppleMaps(_ station: NearbyStation) {
        let name = station.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "maps://?q=\(name)&ll=\(station.lat),\(station.lng)") {
            UIApplication.shared.open(url)
        }
    }

    private func openGoogleMaps(_ station: NearbyStation) {
        let gURL = URL(string: "comgooglemaps://?q=\(station.lat),\(station.lng)&zoom=16")
        if let gURL, UIApplication.shared.canOpenURL(gURL) {
            UIApplication.shared.open(gURL)
        } else {
            // Google Maps Web-Fallback
            if let webURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(station.lat),\(station.lng)") {
                UIApplication.shared.open(webURL)
            }
        }
    }

    private func vehicleCompatible(profile: VehicleProfile, fuelType: String) -> Bool {
        switch fuelType {
        case "e5", "e10":     return profile.tankerkoenig == "e5"
        case "diesel":        return profile.tankerkoenig == "diesel"
        case "lpg":           return profile.fuelType.lowercased().contains("lpg")
                                  || profile.fuelType.lowercased().contains("gas")
        case "electricity":   return profile.isElectric
        default:              return false
        }
    }

    private func fuelLabel(_ type: String) -> String {
        switch type {
        case "e5":          return L("fuel.gasoline")
        case "e10":         return L("fuel.e10")
        case "diesel":      return L("fuel.diesel")
        case "lpg":         return L("fuel.lpg")
        case "electricity": return L("fuel.electricity")
        default:            return type
        }
    }
}

// (NearbyStationsService extensions → NearbyGasStationsView.swift)
