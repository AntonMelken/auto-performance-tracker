import Foundation
import Combine
import CoreLocation

// MARK: - TankerkoenigService (Legacy single-price fetch for TripRecorder)
// FIX ARCH-001: War in FuelPriceView.swift — SRP-Verletzung.
// Service-Logik (Netzwerk-Layer) gehört in Services/, nicht in View-Files.
//
// Hinweis: Für die Tankstellen-Listenansicht wird NearbyStationsService verwendet.
// TankerkoenigService wird nur von TripRecorder aufgerufen um den aktuellen Preis
// beim Fahrtstart zu speichern.
@MainActor
final class TankerkoenigService: ObservableObject {

    static let shared = TankerkoenigService()

    // FIX SEC-001: API-Key darf NICHT im Source-Code stehen – er wird über
    // xcconfig → Info.plist eingebunden.
    // xcconfig-Eintrag:  TANKERKOENIG_API_KEY = <dein-key>
    // Info.plist-Eintrag: TankerkoenigAPIKey = $(TANKERKOENIG_API_KEY)
    private let apiKey: String = {
        let val = (Bundle.main.object(forInfoDictionaryKey: "TankerkoenigAPIKey") as? String) ?? ""
        guard !val.isEmpty, !val.hasPrefix("$(") else { return "" }
        return val
    }()

    @Published var latestE5Price: Double     = 0
    @Published var latestDieselPrice: Double = 0
    @Published var lastUpdated: Date?
    @Published var isLoading: Bool = false
    @Published var lastError: String?

    private init() {}

    func fetchPrice(for fuelType: String,
                    near location: CLLocation,
                    completion: @escaping (Double, String, String) -> Void) {

        // Favorit-Station: Preis immer online aktualisieren (detail.php),
        // dann UserDefaults-Cache überschreiben.
        if let favId = UserDefaults.standard.string(forKey: "favoriteStationId"),
           !favId.isEmpty,
           let favName = UserDefaults.standard.string(forKey: "favoriteStationName"),
           let favCity = UserDefaults.standard.string(forKey: "favoriteStationCity") {

            if !apiKey.isEmpty {
                fetchFavoritePrice(stationId: favId, fuelType: fuelType,
                                   fallbackName: favName, fallbackCity: favCity,
                                   completion: completion)
                return
            }
            // Kein API-Key → gecachten Preis als Fallback nutzen
            if let favPrice = UserDefaults.standard.object(forKey: "favoriteStation_\(fuelType)_price") as? Double,
               favPrice > 0 {
                completion(favPrice, favName, favCity)
                return
            }
        }

        guard !apiKey.isEmpty else {
            let cached = fuelType == "diesel" ? latestDieselPrice : latestE5Price
            completion(cached, L("fuel.manual_source"), "")
            return
        }

        let lat = location.coordinate.latitude, lng = location.coordinate.longitude
        let urlStr = "https://creativecommons.tankerkoenig.de/json/list.php"
            + "?lat=\(lat)&lng=\(lng)&rad=3&sort=price&type=\(fuelType)&apikey=\(apiKey)"
        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor [weak self] in
                guard let self, let data, error == nil else { return }
                struct Resp: Decodable {
                    struct St: Decodable { let name: String; let place: String; let e5: Double?; let diesel: Double?; let isOpen: Bool }
                    let ok: Bool; let stations: [St]
                }
                if let r = try? JSONDecoder().decode(Resp.self, from: data),
                   r.ok, let s = r.stations.filter({ $0.isOpen }).first {
                    let price = fuelType == "diesel" ? s.diesel ?? 0 : s.e5 ?? 0
                    if fuelType == "diesel" { self.latestDieselPrice = price }
                    else                    { self.latestE5Price     = price }
                    self.lastUpdated = .now
                    completion(price, s.name, s.place)
                }
            }
        }.resume()
    }

    /// Ruft den aktuellen Preis einer bekannten Favorit-Station per ID direkt ab
    /// und aktualisiert den UserDefaults-Cache.
    private func fetchFavoritePrice(stationId: String, fuelType: String,
                                    fallbackName: String, fallbackCity: String,
                                    completion: @escaping (Double, String, String) -> Void) {
        let urlStr = "https://creativecommons.tankerkoenig.de/json/detail.php"
            + "?id=\(stationId)&apikey=\(apiKey)"
        guard let url = URL(string: urlStr) else {
            // URL-Fehler → Fallback auf Cache
            if let p = UserDefaults.standard.object(forKey: "favoriteStation_\(fuelType)_price") as? Double, p > 0 {
                completion(p, fallbackName, fallbackCity)
            }
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                struct DetailResp: Decodable {
                    struct St: Decodable {
                        let name: String; let place: String
                        let e5: Double?; let e10: Double?; let diesel: Double?
                        let isOpen: Bool
                    }
                    let ok: Bool; let station: St
                }
                if let data,
                   error == nil,
                   let r = try? JSONDecoder().decode(DetailResp.self, from: data),
                   r.ok {
                    let st = r.station
                    let price: Double
                    switch fuelType {
                    case "diesel": price = st.diesel ?? 0
                    case "e10":    price = st.e10    ?? 0
                    default:       price = st.e5     ?? 0
                    }
                    // Cache in UserDefaults aktualisieren
                    if price > 0 {
                        UserDefaults.standard.set(price, forKey: "favoriteStation_\(fuelType)_price")
                        if fuelType == "diesel" { self.latestDieselPrice = price }
                        else                    { self.latestE5Price     = price }
                        self.lastUpdated = .now
                    }
                    let effectivePrice = price > 0 ? price
                        : (UserDefaults.standard.object(forKey: "favoriteStation_\(fuelType)_price") as? Double ?? 0)
                    completion(effectivePrice, st.name, st.place)
                } else {
                    // Netzwerkfehler → Cache-Fallback
                    if let p = UserDefaults.standard.object(forKey: "favoriteStation_\(fuelType)_price") as? Double, p > 0 {
                        completion(p, fallbackName, fallbackCity)
                    }
                }
            }
        }.resume()
    }
}
