import SwiftUI

// MARK: - StatsShareCardView
// Rendert eine visuelle Share Card (390×560 pt) mit Statistiken eines Zeitraums.
// Wird per ImageRenderer als PNG exportiert und über UIActivityViewController geteilt.

struct StatsShareCardView: View {
    let period: String          // z.B. "März 2026", "Diese Woche"
    let tripCount: Int
    let totalKm: Double
    let avgScore: Int
    let totalCost: Double
    let totalFuel: Double
    let avgSpeedKmh: Double
    let totalDurationSeconds: Double
    let isElectric: Bool

    private var scoreColor: Color {
        avgScore >= 80 ? Color(hex: "22C55E")
            : avgScore >= 60 ? Color(hex: "F59E0B")
            : Color(hex: "EF4444")
    }

    private var formattedDuration: String {
        let h = Int(totalDurationSeconds) / 3600
        let m = (Int(totalDurationSeconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var body: some View {
        ZStack {
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
                    .padding(.bottom, 18)

                scoreRingZone
                    .padding(.bottom, 18)

                statsGrid
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                footerZone
            }
        }
        .frame(width: 390, height: 560)
    }

    // MARK: - Header

    private var headerZone: some View {
        HStack(alignment: .center) {
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
            Text(period)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(hex: "475569"))
        }
    }

    // MARK: - Score Ring

    private var scoreRingZone: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 11)
                    .frame(width: 110, height: 110)
                Circle()
                    .trim(from: 0, to: CGFloat(avgScore) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .frame(width: 110, height: 110)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("\(avgScore)")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Ø Fahrscore")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: "64748B"))
                }
            }

            // Fahrtenanzahl als Badge unter dem Ring
            HStack(spacing: 5) {
                Image(systemName: "car.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "64748B"))
                Text("\(tripCount) \(tripCount == 1 ? "Fahrt" : "Fahrten")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: "64748B"))
            }
        }
    }

    // MARK: - Stats Grid (2×2)

    private var statsGrid: some View {
        let fuelLabel = isElectric ? "kWh" : "L"
        let fuelValue = isElectric
            ? String(format: "%.2f \(fuelLabel)", totalFuel)
            : String(format: "%.1f \(fuelLabel)", totalFuel)

        let items: [(String, String, String, Color)] = [
            ("road.lanes",          String(format: "%.0f km", totalKm),       "Distanz gesamt",   Color(hex: "3B82F6")),
            ("clock.fill",          formattedDuration,                         "Fahrzeit gesamt",  Color(hex: "06B6D4")),
            (isElectric ? "bolt.fill" : "fuelpump.fill", fuelValue,            "Verbrauch gesamt", Color(hex: "A855F7")),
            ("eurosign.circle.fill", String(format: "%.2f €", totalCost),      "Kosten gesamt",    Color(hex: "EF4444")),
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

// MARK: - StatsShareCardRenderer

@MainActor
enum StatsShareCardRenderer {
    static func render(
        period: String,
        tripCount: Int,
        totalKm: Double,
        avgScore: Int,
        totalCost: Double,
        totalFuel: Double,
        avgSpeedKmh: Double,
        totalDurationSeconds: Double,
        isElectric: Bool
    ) -> UIImage? {
        let view = StatsShareCardView(
            period: period,
            tripCount: tripCount,
            totalKm: totalKm,
            avgScore: avgScore,
            totalCost: totalCost,
            totalFuel: totalFuel,
            avgSpeedKmh: avgSpeedKmh,
            totalDurationSeconds: totalDurationSeconds,
            isElectric: isElectric
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3.0

        guard let rendered = renderer.uiImage else { return nil }

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
    StatsShareCardView(
        period: "März 2026",
        tripCount: 12,
        totalKm: 487.3,
        avgScore: 82,
        totalCost: 64.50,
        totalFuel: 33.8,
        avgSpeedKmh: 68.4,
        totalDurationSeconds: 6 * 3600 + 45 * 60,
        isElectric: false
    )
    .preferredColorScheme(.dark)
}
