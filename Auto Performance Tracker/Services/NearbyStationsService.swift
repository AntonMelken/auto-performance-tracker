// FIX ARCH-002: Extrahiert aus NearbyGasStationsView.swift.
// NearbyStation-Model und NearbyStationsService gehören in die Services-Schicht.
import Foundation
import Combine
import CoreLocation

// MARK: - Station Model
struct NearbyStation: Identifiable, Sendable {
    let id: String
    let name: String
    let place: String
    // Tankerkoenig prices
    let e5: Double?
    let e10: Double?
    let diesel: Double?
    // LPG / EV
    let lpg: Double?        // Overpass (OSM) — user-contributed
    let evPower: Double?    // kW (OpenChargeMap)
    let dist: Double        // km
    let isOpen: Bool
    let lat: Double
    let lng: Double
    let stationType: StationType

    enum StationType {
        case conventional   // Tankerkoenig
        case lpg            // Overpass/OSM
        case ev             // OpenChargeMap
    }
}

// MARK: - NearbyStationsService
@MainActor
final class NearbyStationsService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = NearbyStationsService()

    // Keys werden aus der Info.plist gelesen (dort via xcconfig eingebunden).
    // Fallback auf hardcodierten Key, falls xcconfig-Substitution nicht klappt
    // (z.B. wenn xcconfig nicht im Build-Scheme verlinkt ist).
    private static let tankerkoenigFallback = "88a490b1-c57e-4bcc-ac85-49dae011c6bd"
    private let tankerkoenigKey: String = {
        let plistVal = (Bundle.main.object(forInfoDictionaryKey: "TankerkoenigAPIKey") as? String) ?? ""
        // Substitution failed → plistVal enthält noch den Literal "$(TANKERKOENIG_API_KEY)"
        if plistVal.isEmpty || plistVal.hasPrefix("$(") {
            return NearbyStationsService.tankerkoenigFallback
        }
        return plistVal
    }()
    let ocmKey: String = {
        let plistVal = (Bundle.main.object(forInfoDictionaryKey: "OpenChargeMapAPIKey") as? String) ?? ""
        if plistVal.hasPrefix("$(") { return "" }
        return plistVal
    }()

    private let manager = CLLocationManager()

    @Published var stations: [NearbyStation] = []
    @Published var lpgStations: [NearbyStation] = []
    @Published var evStations: [NearbyStation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentLocation: CLLocation?
    @Published var hasLocation = false
    /// Suchradius für Tankerkoenig (E5/E10/Diesel). Standard 15 km, wählbar 5/10/15/30 km.
    @Published var selectedRadiusKm: Int = 15

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = loc
            self.hasLocation = true
            await self.fetchAll(near: loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.errorMessage = L("gas.error_location") }
    }

    func fetchAll(near location: CLLocation) async {
        isLoading = true
        errorMessage = nil
        async let tanker  = fetchTankerkoenig(near: location, radiusKm: selectedRadiusKm)
        async let lpgTask = fetchLPGViaOverpass(near: location, radiusM: 15_000)
        async let evTask  = fetchEVStations(near: location)
        let (tk, lpgRes, evRes) = await (tanker, lpgTask, evTask)
        stations   = tk
        evStations = evRes

        // Wenn keine LPG-Stationen im 15 km-Radius → erweiterte Suche bis 75 km
        if lpgRes.isEmpty {
            let expanded = await fetchLPGViaOverpass(near: location, radiusM: 75_000)
            lpgStations = expanded  // zeigt nächste, unabhängig von Entfernung
        } else {
            lpgStations = lpgRes
        }

        isLoading = false
    }

    // MARK: - Tankerkoenig (E5, E10, Diesel)
    private func fetchTankerkoenig(near loc: CLLocation, radiusKm: Int = 15) async -> [NearbyStation] {
        let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
        let urlStr = "https://creativecommons.tankerkoenig.de/json/list.php"
            + "?lat=\(lat)&lng=\(lng)&rad=\(radiusKm)&sort=dist&type=all&apikey=\(tankerkoenigKey)"
        guard let url = URL(string: urlStr) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Decodable {
                struct St: Decodable {
                    let id: String; let name: String; let place: String
                    let e5: Double?; let e10: Double?; let diesel: Double?
                    let dist: Double; let isOpen: Bool
                    let lat: Double; let lng: Double
                }
                let ok: Bool; let stations: [St]
            }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            if resp.ok {
                return resp.stations.map {
                    NearbyStation(id: $0.id, name: $0.name, place: $0.place,
                                  e5: $0.e5, e10: $0.e10, diesel: $0.diesel,
                                  lpg: nil, evPower: nil,
                                  dist: $0.dist, isOpen: $0.isOpen,
                                  lat: $0.lat, lng: $0.lng, stationType: .conventional)
                }
            }
        } catch {}
        return []
    }

    // MARK: - LPG via Overpass API (OpenStreetMap) — kostenlos, kein Key nötig
    // radiusM: Suchradius in Metern. Standard 15 000 m; Fallback-Aufruf mit 75 000 m.
    private func fetchLPGViaOverpass(near loc: CLLocation, radiusM: Int = 15_000) async -> [NearbyStation] {
        let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
        let timeout = radiusM > 20_000 ? 30 : 15
        let query = "[out:json][timeout:\(timeout)];node[\"amenity\"=\"fuel\"][\"lpg\"=\"yes\"](around:\(radiusM),\(lat),\(lng));out body;"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(encoded)") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct OResp: Decodable {
                struct Element: Decodable {
                    let id: Int; let lat: Double; let lng: Double
                    let tags: [String: String]?
                    enum CodingKeys: String, CodingKey { case id, lat, lon, tags }
                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: CodingKeys.self)
                        id  = try c.decode(Int.self,    forKey: .id)
                        lat = try c.decode(Double.self, forKey: .lat)
                        lng = try c.decode(Double.self, forKey: .lon)
                        tags = try? c.decode([String: String].self, forKey: .tags)
                    }
                }
                let elements: [Element]
            }
            let resp = try JSONDecoder().decode(OResp.self, from: data)
            return resp.elements.map { el in
                let name = el.tags?["name"] ?? el.tags?["brand"] ?? L("gas.lpg_station")
                let city = el.tags?["addr:city"] ?? el.tags?["addr:place"] ?? ""
                let rawPrice = el.tags?["lpg:price"].flatMap { Double($0) }
                let locRef = CLLocation(latitude: el.lat, longitude: el.lng)
                let dist = loc.distance(from: locRef) / 1000.0
                return NearbyStation(id: "lpg-\(el.id)", name: name, place: city,
                                     e5: nil, e10: nil, diesel: nil,
                                     lpg: rawPrice, evPower: nil,
                                     dist: dist, isOpen: true,
                                     lat: el.lat, lng: el.lng, stationType: .lpg)
            }.sorted { $0.dist < $1.dist }
        } catch {}
        return []
    }

    // MARK: - EV via OpenChargeMap — kostenloser API-Key (https://openchargemap.org/site/develop/api)
    private func fetchEVStations(near loc: CLLocation) async -> [NearbyStation] {
        guard !ocmKey.hasPrefix("YOUR_") else { return [] }
        let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
        let urlStr = "https://api.openchargemap.io/v3/poi/?output=json&countrycode=DE"
            + "&latitude=\(lat)&longitude=\(lng)&distance=15&distanceunit=km&maxresults=20"
            + "&key=\(ocmKey)"
        guard let url = URL(string: urlStr) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct OCMStation: Decodable {
                let ID: Int
                struct AddressInfo: Decodable {
                    let Title: String; let Town: String?
                    let Latitude: Double; let Longitude: Double
                }
                struct Connection: Decodable { let PowerKW: Double? }
                let AddressInfo: AddressInfo
                let Connections: [Connection]?
                let StatusType: StatusType?
                struct StatusType: Decodable { let IsOperational: Bool? }
            }
            let list = try JSONDecoder().decode([OCMStation].self, from: data)
            return list.map { st in
                let maxKW = st.Connections?.compactMap(\.PowerKW).max()
                let locRef = CLLocation(latitude: st.AddressInfo.Latitude,
                                        longitude: st.AddressInfo.Longitude)
                let dist = loc.distance(from: locRef) / 1000.0
                return NearbyStation(id: "ev-\(st.ID)",
                                     name: st.AddressInfo.Title,
                                     place: st.AddressInfo.Town ?? "",
                                     e5: nil, e10: nil, diesel: nil,
                                     lpg: nil, evPower: maxKW,
                                     dist: dist, isOpen: st.StatusType?.IsOperational ?? true,
                                     lat: st.AddressInfo.Latitude,
                                     lng: st.AddressInfo.Longitude,
                                     stationType: .ev)
            }.sorted { $0.dist < $1.dist }
        } catch {}
        return []
    }

    // MARK: - Favorit-Station online aktualisieren
    /// Ruft den aktuellen Preis der gespeicherten Favorit-Station per ID direkt ab
    /// und aktualisiert den UserDefaults-Cache für alle Kraftstoffarten.
    /// Gibt die aktualisierte Station zurück (oder nil bei Fehler).
    @discardableResult
    func refreshFavoriteStation() async -> NearbyStation? {
        guard let stationId = UserDefaults.standard.string(forKey: "favoriteStationId"),
              !stationId.isEmpty else { return nil }

        let urlStr = "https://creativecommons.tankerkoenig.de/json/detail.php"
            + "?id=\(stationId)&apikey=\(tankerkoenigKey)"
        guard let url = URL(string: urlStr) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct DetailResp: Decodable {
                struct St: Decodable {
                    let id: String; let name: String; let place: String
                    let e5: Double?; let e10: Double?; let diesel: Double?
                    let isOpen: Bool; let lat: Double; let lng: Double
                }
                let ok: Bool; let station: St
            }
            let resp = try JSONDecoder().decode(DetailResp.self, from: data)
            guard resp.ok else { return nil }
            let st = resp.station

            // UserDefaults-Cache für alle verfügbaren Kraftstoffarten aktualisieren
            if let e5 = st.e5, e5 > 0 {
                UserDefaults.standard.set(e5, forKey: "favoriteStation_e5_price")
            }
            if let e10 = st.e10, e10 > 0 {
                UserDefaults.standard.set(e10, forKey: "favoriteStation_e10_price")
            }
            if let d = st.diesel, d > 0 {
                UserDefaults.standard.set(d, forKey: "favoriteStation_diesel_price")
            }

            // Stationsdaten in stations-Array aktualisieren falls vorhanden
            if let idx = stations.firstIndex(where: { $0.id == stationId }) {
                let updated = NearbyStation(id: st.id, name: st.name, place: st.place,
                                            e5: st.e5, e10: st.e10, diesel: st.diesel,
                                            lpg: nil, evPower: nil,
                                            dist: stations[idx].dist, isOpen: st.isOpen,
                                            lat: st.lat, lng: st.lng, stationType: .conventional)
                stations[idx] = updated
                return updated
            }

            // Station noch nicht in der Liste → als eigenständiges Objekt zurückgeben
            let currentLoc = currentLocation ?? CLLocation(latitude: st.lat, longitude: st.lng)
            let dist = currentLoc.distance(from: CLLocation(latitude: st.lat, longitude: st.lng)) / 1000.0
            return NearbyStation(id: st.id, name: st.name, place: st.place,
                                  e5: st.e5, e10: st.e10, diesel: st.diesel,
                                  lpg: nil, evPower: nil,
                                  dist: dist, isOpen: st.isOpen,
                                  lat: st.lat, lng: st.lng, stationType: .conventional)
        } catch {
            return nil
        }
    }

    // MARK: - Computed helpers
    var cheapestE5: NearbyStation?    { stations.filter { $0.isOpen && $0.e5     != nil }.min(by: { $0.e5!     < $1.e5! }) }
    var cheapestE10: NearbyStation?   { stations.filter { $0.isOpen && $0.e10    != nil }.min(by: { $0.e10!    < $1.e10! }) }
    var cheapestDiesel: NearbyStation? { stations.filter { $0.isOpen && $0.diesel != nil }.min(by: { $0.diesel! < $1.diesel! }) }
    var nearest: NearbyStation?       { stations.filter { $0.isOpen }.min(by: { $0.dist < $1.dist }) }
    var nearestLPG: NearbyStation?    { lpgStations.first }
    var nearestEV: NearbyStation?     { evStations.first }

    /// true wenn kein OpenChargeMap-Key konfiguriert
    var ocmKeyMissing: Bool { ocmKey.isEmpty || ocmKey.hasPrefix("YOUR_") }
}
