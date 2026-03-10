import SwiftUI
import MapKit

// MARK: - Farbige Polyline
final class ColoredPolyline: MKPolyline {
    var color: UIColor = .systemBlue
}

// MARK: - Coordinator
final class TripMapCoordinator: NSObject, MKMapViewDelegate {

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let poly = overlay as? ColoredPolyline {
            let r = MKPolylineRenderer(polyline: poly)
            r.strokeColor = poly.color
            r.lineWidth   = 5
            r.lineCap     = .round
            r.lineJoin    = .round
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let pin = annotation as? ColoredPin else { return nil }
        let id   = "ColoredPin"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                   ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation      = annotation
        view.markerTintColor = pin.pinColor
        view.glyphImage      = pin.glyphImage
        view.displayPriority = .required
        return view
    }
}

// MARK: - ColoredPin
final class ColoredPin: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let pinColor: UIColor
    let glyphImage: UIImage?

    init(coord: CLLocationCoordinate2D, title: String, color: UIColor, glyph: UIImage?) {
        self.coordinate = coord; self.title = title
        self.pinColor = color; self.glyphImage = glyph
    }
}

// MARK: - SwiftUI Wrapper
struct TripMapView: UIViewRepresentable {
    let trip: Trip
    var showUserLocation = false

    func makeCoordinator() -> TripMapCoordinator { TripMapCoordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate          = context.coordinator
        map.showsUserLocation = showUserLocation
        map.showsCompass      = false
        map.showsScale        = true
        map.mapType           = .standard
        map.overrideUserInterfaceStyle = .dark
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        // Einmaliger Zugriff auf trip.points — der Getter decoded JSON aus SwiftData
        // (gecacht, aber trotzdem: Property nur einmal pro updateUIView lesen)
        let points = trip.points

        if points.count == 1 {
            let coord  = points[0].coordinate
            map.setRegion(MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500), animated: false)
            map.addAnnotation(ColoredPin(coord: coord, title: "Start", color: .systemGreen,
                                         glyph: UIImage(systemName: "flag.fill")))
            return
        }

        guard points.count > 1 else { return }

        // ── GPS-Punkte simplifizieren (Douglas-Peucker, ε=1.5m) ────────────────
        let simplified = simplify(points, tolerance: 1.5)

        // Farbige Segmente rendern
        for i in 0..<(simplified.count - 1) {
            let coords = [simplified[i].coordinate, simplified[i+1].coordinate]
            let poly   = ColoredPolyline(coordinates: coords, count: 2)
            poly.color = speedUIColor(kmh: simplified[i].speedKmh)
            map.addOverlay(poly, level: .aboveRoads)
        }

        map.addAnnotations([
            ColoredPin(coord: points.first!.coordinate, title: "Start",
                       color: .systemGreen, glyph: UIImage(systemName: "flag.fill")),
            ColoredPin(coord: points.last!.coordinate,  title: "Ziel",
                       color: .systemRed,   glyph: UIImage(systemName: "flag.checkered"))
        ])

        let region = MKCoordinateRegion(coordinates: points.map(\.coordinate))
        map.setRegion(region, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            map.setRegion(region, animated: false)
        }
    }

    // MARK: - Douglas-Peucker Simplification
    // Reduziert GPS-Punkte auf das Wesentliche ohne optischen Informationsverlust.
    // ε (tolerance) in Metern: 1.5m = sehr präzise, praktisch keine Genauigkeitseinbuße.
    private func simplify(_ pts: [TripPoint], tolerance: Double) -> [TripPoint] {
        guard pts.count > 2 else { return pts }

        var maxDist = 0.0
        var maxIdx  = 0
        let first = pts.first!
        let last  = pts.last!

        for i in 1..<(pts.count - 1) {
            let d = perpendicularDistance(pts[i], from: first, to: last)
            if d > maxDist { maxDist = d; maxIdx = i }
        }

        if maxDist > tolerance {
            let left  = simplify(Array(pts[0...maxIdx]), tolerance: tolerance)
            let right = simplify(Array(pts[maxIdx...]), tolerance: tolerance)
            return left.dropLast() + right
        } else {
            return [first, last]
        }
    }

    private func perpendicularDistance(_ pt: TripPoint, from a: TripPoint, to b: TripPoint) -> Double {
        let ax = a.longitude; let ay = a.latitude
        let bx = b.longitude; let by = b.latitude
        let px = pt.longitude; let py = pt.latitude

        let dx = bx - ax; let dy = by - ay
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let ex = px - ax; let ey = py - ay
            // Convert degrees to meters (approximate)
            return sqrt(ex * ex + ey * ey) * 111_000
        }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
        let nearX = ax + t * dx; let nearY = ay + t * dy
        let ex = (px - nearX) * 111_000 * cos(ay * .pi / 180)
        let ey = (py - nearY) * 111_000
        return sqrt(ex * ex + ey * ey)
    }

    // Einheitliche Farbpalette (identisch mit SpeedColor.swiftUIColor)
    private func speedUIColor(kmh: Double) -> UIColor {
        switch kmh {
        case ..<30:    return UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1) // #22C55E Grün
        case 30..<50:  return UIColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1) // #3B82F6 Blau
        case 50..<80:  return UIColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1) // #F59E0B Amber
        case 80..<130: return UIColor(red: 0.984, green: 0.451, blue: 0.090, alpha: 1) // #FB923C Orange
        default:       return UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1) // #EF4444 Rot
        }
    }
}

// MARK: - MKCoordinateRegion Extension
extension MKCoordinateRegion {
    init(coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty,
              let minLat = coordinates.map(\.latitude).min(),
              let maxLat = coordinates.map(\.latitude).max(),
              let minLng = coordinates.map(\.longitude).min(),
              let maxLng = coordinates.map(\.longitude).max() else {
            self.init()
            return
        }
        let center   = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let latDelta = max((maxLat - minLat) * 1.5, 0.004)
        let lngDelta = max((maxLng - minLng) * 1.5, 0.004)
        self.init(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta))
    }
}
