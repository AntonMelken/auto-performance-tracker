import Foundation
import UIKit
import SwiftData

struct ExportService {

    // FIX BUG-002: ISO8601DateFormatter ist teuer (~1 ms pro Instanz). In der alten
    // Version wurde er bei jedem GPS-Punkt neu erzeugt – bei 100.000 Punkten ≈ 100 s
    // Freeze. Statische Instanz: einmalig initialisiert, thread-safe für concurrent reads.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Einzelne Fahrt

    // FIX QUAL-004: csvData wirft jetzt einen Fehler statt lautlos leere Data zurückzugeben.
    // Vorher: .data(using: .utf8) ?? Data() → User erhielt eine leere Export-Datei ohne Fehlermeldung.
    // Nachher: throws → Aufrufer kann den Fehler propagieren und dem User anzeigen.
    enum ExportError: LocalizedError {
        case encodingFailed
        var errorDescription: String? { "CSV-Daten konnten nicht als UTF-8 kodiert werden." }
    }

    static func csvData(for trip: Trip) throws -> Data {
        let fmt = iso8601   // lokale Referenz für Capture-Sicherheit
        var lines = ["Zeitstempel,Breitengrad,Längengrad,Geschwindigkeit (km/h),Genauigkeit (m),Kurs"]
        for p in trip.points {
            let row = [
                fmt.string(from: p.timestamp),
                String(format: "%.6f", p.latitude),
                String(format: "%.6f", p.longitude),
                String(format: "%.1f", p.speedKmh),
                String(format: "%.1f", p.accuracy),
                String(format: "%.1f", p.course)
            ].joined(separator: ",")
            lines.append(row)
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    static func jsonData(for trip: Trip) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(trip.points)
    }

    // MARK: - Alle Fahrten (Übersicht)
    static func allTripsCSV(trips: [Trip]) throws -> Data {
        var lines = ["ID,Titel,Datum,Distanz (km),Dauer,Ø Speed (km/h),Max Speed (km/h),Sprit (L),Kosten (€),Score"]
        for t in trips {
            let row = [
                t.id.uuidString,
                t.title,
                t.formattedDate,
                String(format: "%.2f", t.distanceKm),
                t.formattedDuration,
                String(format: "%.1f", t.avgSpeedKmh),
                String(format: "%.1f", t.maxSpeedKmh),
                String(format: "%.2f", t.estimatedFuelL),
                String(format: "%.2f", t.estimatedCostEur),
                "\(t.efficiencyScore)"
            ].joined(separator: ",")
            lines.append(row)
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    static func allTripsJSON(trips: [Trip], vehicle: VehicleProfile?) throws -> Data {
        struct TripPointExport: Encodable {
            let timestamp: Date
            let latitude: Double
            let longitude: Double
            let speedKmh: Double
            let accuracy: Double
            let course: Double
        }
        struct TripExport: Encodable {
            let id: String
            let title: String
            let startDate: Date
            let endDate: Date?
            let distanceKm: Double
            let durationSeconds: Double
            let avgSpeedKmh: Double
            let maxSpeedKmh: Double
            let estimatedFuelL: Double
            let estimatedCostEur: Double
            let efficiencyScore: Int
            let points: [TripPointExport]
        }
        struct Export: Encodable {
            let exportDate: Date
            let vehicleName: String
            let tripCount: Int
            let totalKm: Double
            let trips: [TripExport]
        }
        let tripExports = trips.map { t in
            TripExport(
                id: t.id.uuidString,
                title: t.title,
                startDate: t.startDate,
                endDate: t.endDate,
                distanceKm: t.distanceKm,
                durationSeconds: t.durationSeconds,
                avgSpeedKmh: t.avgSpeedKmh,
                maxSpeedKmh: t.maxSpeedKmh,
                estimatedFuelL: t.estimatedFuelL,
                estimatedCostEur: t.estimatedCostEur,
                efficiencyScore: t.efficiencyScore,
                points: t.points.map { p in
                    TripPointExport(
                        timestamp: p.timestamp,
                        latitude: p.latitude,
                        longitude: p.longitude,
                        speedKmh: p.speedKmh,
                        accuracy: p.accuracy,
                        course: p.course
                    )
                }
            )
        }
        let export = Export(
            exportDate: .now,
            vehicleName: vehicle?.name ?? "–",
            tripCount: trips.count,
            totalKm: trips.reduce(0) { $0 + $1.distanceKm },
            trips: tripExports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    // MARK: - ShareSheet
    static func share(data: Data, filename: String, from view: UIView) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url)
        } catch {
            // Schreiben fehlgeschlagen (z. B. voller Speicher) — keinen leeren Share-Sheet zeigen
            #if DEBUG
            print("[ExportService] Fehler beim Schreiben der Export-Datei: \(error.localizedDescription)")
            #endif
            // Fehlermeldung als Alert über UIAlertController anzeigen
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let vc = scene.windows.first?.rootViewController {
                let alert = UIAlertController(
                    title: L("export.error.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                vc.present(alert, animated: true)
            }
            return
        }
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let vc = scene.windows.first?.rootViewController {
            ac.popoverPresentationController?.sourceView = view
            vc.present(ac, animated: true)
        }
    }
}
