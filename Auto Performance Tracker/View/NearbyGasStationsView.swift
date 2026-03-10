import SwiftUI

// MARK: - NearbyGasStationsView
// FIX ARCH-002: NearbyStation + NearbyStationsService → Services/NearbyStationsService.swift
// Diese Datei enthält nur noch den reinen SwiftUI-View.

struct NearbyGasStationsView: View {
    @EnvironmentObject private var service: NearbyStationsService

    var body: some View {
        ZStack { Color(hex: "080C14").ignoresSafeArea() }
            .onAppear {
                service.requestLocation()
                AnalyticsService.shared.trackFeatureUsed("nearby_gas_stations_viewed")
            }
    }
}

// MARK: - Feature 04: Marken-Erkennung für NearbyStation
private let popularBrands = [
    "ARAL", "Shell", "BP", "Jet", "Esso", "TotalEnergies", "Total",
    "Avia", "Star", "HEM", "Agip", "OMV", "Q1", "BFT", "Sprint",
    "Westfalen", "Raiffeisen", "ED", "OIL!", "CLASSIC"
]

extension NearbyStation {
    var detectedBrand: String? {
        let upper = name.uppercased()
        return popularBrands.first { upper.contains($0.uppercased()) }
    }
}
