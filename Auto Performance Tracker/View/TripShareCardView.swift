import SwiftUI

// MARK: - TripShareCardView
// Rendert eine visuelle Share Card (390×720 pt) mit allen Fahrten-Statistiken.
// Wird per ImageRenderer als PNG exportiert und über UIActivityViewController geteilt.

struct TripShareCardView: View {
    let trip: Trip
    let profile: VehicleProfile?

    private var scoreColor: Color {
        trip.efficiencyScore >= 80 ? Color(hex: "22C55E")
            : trip.efficiencyScore >= 60 ? Color(hex: "F59E0B")
            : Color(hex: "EF4444")
    }

    private var isElectric: Bool { profile?.isElectric == true }

    private var fuelValue: String {
        isElectric
            ? String(format: "%.2f kWh", trip.estimatedFuelL)
            : String(format: "%.1f L", trip.estimatedFuelL)
    }

    private var scoreLabel: String {
        trip.efficiencyScore >= 80 ? "Ausgezeichnet"
            : trip.efficiencyScore >= 60 ? "Gut"
            : "Verbesserungsbedarf"
    }

    var body: some View {
        ZStack {
            // Hintergrund zuerst – füllt exakt den Frame inkl. abgerundeter Ecken
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "080C14"), Color(hex: "0F1A2E")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 0) {
                headerZone
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                scoreRingZone
                    .padding(.bottom, 16)

                statsGrid
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                vehicleBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                footerZone
            }
        }
        .frame(width: 390, height: 720)
    }

    // MARK: - Header

    private var headerZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                // App-Icon + Name
                HStack(spacing: 8) {
                    Image("SplashIcon")
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    Text("Auto Performance Tracker")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "64748B"))
                }
                Spacer()
                // Datum
                Text(shortDate)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color(hex: "475569"))
            }

            // Fahrt-Titel
            Text(trip.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var shortDate: String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: trip.startDate)
    }

    // MARK: - Score Ring

    private var scoreRingZone: some View {
        ZStack {
            // Hintergrundring
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 11)
                .frame(width: 120, height: 120)

            // Fortschrittsring
            Circle()
                .trim(from: 0, to: CGFloat(trip.efficiencyScore) / 100)
                .stroke(
                    scoreColor,
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(-90))

            // Innen: Score + Label
            VStack(spacing: 1) {
                Text("\(trip.efficiencyScore)")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("Fahrscore")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: "64748B"))
            }
        }
    }

    // MARK: - Stats Grid (2×3)

    private var statsGrid: some View {
        let items: [(String, String, String, Color)] = [
            ("location.fill",            trip.formattedDistance,              "distanz",          Color(hex: "3B82F6")),
            ("clock.fill",               trip.formattedDuration,              "dauer",            Color(hex: "06B6D4")),
            ("speedometer",              "\(Int(trip.avgSpeedKmh)) km/h",     "ø geschwindigkeit", Color(hex: "22C55E")),
            ("gauge.with.needle.fill",   "\(Int(trip.maxSpeedKmh)) km/h",     "max. speed",       Color(hex: "F59E0B")),
            (isElectric ? "bolt.fill" : "fuelpump.fill", fuelValue,           "kraftstoff",       Color(hex: "A855F7")),
            ("eurosign.circle.fill",     String(format: "%.2f €", trip.estimatedCostEur), "kosten", Color(hex: "EF4444"))
        ]

        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(items.indices, id: \.self) { i in
                let (icon, value, label, color) = items[i]
                ShareStatCard(icon: icon, value: value, label: label, accentColor: color)
            }
        }
    }

    // MARK: - Vehicle Banner

    private var vehicleBanner: some View {
        HStack(spacing: 10) {
            // Fahrzeug-Icon
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 34, height: 34)
                Image(systemName: profile?.fuelIcon ?? "car.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: "94A3B8"))
            }

            // Name
            Text(profile?.name ?? (trip.vehicleProfileName.isEmpty ? "Fahrzeug" : trip.vehicleProfileName))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: "E2E8F0"))
                .lineLimit(1)

            Spacer()

            // Kraftstoff-Chip
            if let fuelType = profile?.fuelType ?? (trip.vehicleFuelType.isEmpty ? nil : trip.vehicleFuelType) {
                let chipColor = fuelChipColor(fuelType)
                Text(fuelType)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(chipColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(chipColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }

    private func fuelChipColor(_ fuelType: String) -> Color {
        switch fuelType {
        case "Elektrisch": return Color(hex: "06B6D4")
        case "Hybrid":     return Color(hex: "22C55E")
        case "Diesel":     return Color(hex: "F59E0B")
        case "LPG":        return Color(hex: "A855F7")
        default:           return Color(hex: "EF4444")
        }
    }

    // MARK: - Footer

    private var footerZone: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.07))
                .padding(.bottom, 10)

            HStack {
                Spacer()
                Text("App Store")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: "334155"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - ShareStatCard

struct ShareStatCard: View {
    let icon: String
    let value: String
    let label: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accentColor)

            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color(hex: "64748B"))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }
}

// MARK: - TripShareCardRenderer

@MainActor
enum TripShareCardRenderer {
    /// Rendert die Share Card als UIImage (PNG-ready) mit @ImageRenderer
    static func render(trip: Trip, profile: VehicleProfile?) -> UIImage? {
        let view = TripShareCardView(trip: trip, profile: profile)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3.0   // @3x für scharfe Darstellung auf Retina

        guard let rendered = renderer.uiImage else { return nil }

        // Ecken-Fix: Das gerenderte Bild auf einen soliden Hintergrund compositen,
        // damit transparente Ecken (außerhalb des RoundedRectangle) nicht als
        // weiße Lücken erscheinen wenn das Bild geteilt wird.
        let size = rendered.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = rendered.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.031, green: 0.047, blue: 0.078, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            rendered.draw(at: .zero)
        }
    }
}

// MARK: - Preview

#Preview {
    TripShareCardView(trip: previewTrip(), profile: previewProfile())
        .preferredColorScheme(.dark)
}

@MainActor
private func previewTrip() -> Trip {
    let t = Trip(title: "Fahrt 03.03.2026 · 09:45")
    t.distanceKm       = 47.3
    t.durationSeconds  = 38 * 60
    t.avgSpeedKmh      = 74.6
    t.maxSpeedKmh      = 127
    t.estimatedFuelL   = 3.4
    t.estimatedCostEur = 5.78
    t.efficiencyScore  = 82
    t.vehicleProfileName = "BMW 320d"
    t.vehicleFuelType  = "Diesel"
    return t
}

private func previewProfile() -> VehicleProfile {
    VehicleProfile(name: "BMW 320d", fuelType: "Diesel", consumption: 7.2, pricePerLiter: 1.70)
}
