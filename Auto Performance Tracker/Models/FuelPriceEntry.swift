import Foundation
import SwiftData

// MARK: - FuelPriceEntry (SwiftData)
// FIX ARCH-001: War in FuelPriceView.swift — SRP-Verletzung.
// Model hat keine Abhängigkeit von SwiftUI und gehört in die Models-Schicht.
@Model
final class FuelPriceEntry {
    var id: UUID
    var date: Date
    var fuelType: String       // "e5", "e10", "diesel", "lpg", "electricity"
    var pricePerUnit: Double   // €/L oder €/kWh
    var stationName: String
    var stationCity: String
    var isFromTrip: Bool = false    // true = eingefroren (Fahrt-Preis), darf nicht geändert werden

    init(date: Date = .now,
         fuelType: String,
         pricePerUnit: Double,
         stationName: String = "",
         stationCity: String = "",
         isFromTrip: Bool = false) {
        self.id           = UUID()
        self.date         = date
        self.fuelType     = fuelType
        self.pricePerUnit = pricePerUnit
        self.stationName  = stationName
        self.stationCity  = stationCity
        self.isFromTrip   = isFromTrip
    }
}
