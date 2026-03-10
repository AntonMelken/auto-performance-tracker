import SwiftUI
import UIKit
import Combine

// MARK: - SpeedometerAnimator (Feature 07: Smooth Speedometer via CADisplayLink)
//
// Interpoliert die angezeigte Geschwindigkeit in 60 fps mit exponentiellem Glätter.
// Alpha = 0.15: reagiert schnell auf Änderungen, filtert aber GPS-Jitter (<0.5 km/h) heraus.

@MainActor
final class SpeedometerAnimator: ObservableObject {
    @Published private(set) var displaySpeed: Double = 0

    private var targetSpeed: Double = 0
    private var displayLink: CADisplayLink?

    /// Smoothing-Faktor: 0.0 = kein Update, 1.0 = sofort. 0.15 ist ein guter Kompromiss.
    private let alpha: Double = 0.15

    /// Minimale Änderung die überhaupt einen neuen Ziel-Wert setzt (GPS-Jitter-Schwelle).
    private let jitterThreshold: Double = 0.5

    func setTarget(_ speed: Double) {
        guard abs(speed - targetSpeed) > jitterThreshold else { return }
        targetSpeed = max(speed, 0)
        startDisplayLinkIfNeeded()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let delta = targetSpeed - displaySpeed
        // Wenn nah genug am Ziel → einrasten und DisplayLink stoppen
        if abs(delta) < 0.05 {
            displaySpeed = targetSpeed
            stopDisplayLink()
        } else {
            displaySpeed += delta * alpha
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        displayLink?.invalidate()
    }
}

// MARK: - SpeedometerView

struct SpeedometerView: View {
    let speedKmh: Double
    var maxKmh: Double = 240

    @StateObject private var animator = SpeedometerAnimator()

    /// Glättete Anzeige-Geschwindigkeit (von CADisplayLink interpoliert)
    private var displaySpeed: Double { animator.displaySpeed }

    /// Progress 0…1, clamped — basiert auf geglätteter Geschwindigkeit
    private var progress: Double { min(max(displaySpeed, 0) / maxKmh, 1.0) }

    /// Farbe der aktuellen Zone (für Zahl-Glow) — basiert auf geglätteter Geschwindigkeit
    private var currentZoneColor: Color { SpeedZone.color(for: displaySpeed) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                SpeedometerCanvas(speedKmh: displaySpeed, progress: progress, side: side)
                    .frame(width: side, height: side)

                SpeedometerLabels(side: side)
                    .frame(width: side, height: side)

                VStack(spacing: 2) {
                    Text("\(Int(displaySpeed))")
                        .font(Font(UIFont.systemFont(ofSize: side * 0.20, weight: .thin)))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.15), value: Int(displaySpeed))
                        .shadow(color: currentZoneColor.opacity(0.5), radius: 8)
                    Text("km/h")
                        .font(Font(UIFont.systemFont(ofSize: side * 0.052, weight: .ultraLight)))
                        .foregroundStyle(.secondary)
                        .tracking(2)
                }
                .offset(y: side * 0.17)
                .frame(width: side, height: side)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // Eingehende GPS-Geschwindigkeit an den Animator weitergeben
        .onChange(of: speedKmh) { _, newSpeed in
            animator.setTarget(newSpeed)
        }
        .onAppear {
            // Initialen Wert sofort setzen (kein unnötiges Ramp-Up von 0)
            animator.setTarget(speedKmh)
        }
    }
}

// MARK: - Gauge

/// Koordinatensystem: SwiftUI Canvas Y zeigt nach UNTEN.
/// clockwise: false → visuell im Uhrzeigersinn auf dem Screen.
///
/// Winkel-Tabelle:
///   135° = unten-links (7-8 Uhr) →   0 km/h
///   180° = links       (9 Uhr)   →  30 km/h  (168.75°)
///   270° = oben        (12 Uhr)  → 120 km/h
///   405° = unten-rechts(4-5 Uhr) → 240 km/h
private enum Gauge {
    static let startDeg: Double = 135.0
    static let sweepDeg: Double = 270.0
    static let maxKmh:   Double = 240.0

    static func angle(for kmh: Double) -> Double {
        startDeg + sweepDeg * (min(max(kmh, 0), maxKmh) / maxKmh)
    }

    static func arcPath(from fromKmh: Double, to toKmh: Double,
                        radius: CGFloat, center: CGPoint) -> Path {
        var p = Path()
        p.addArc(center: center,
                 radius: radius,
                 startAngle: .degrees(angle(for: fromKmh)),
                 endAngle:   .degrees(angle(for: toKmh)),
                 clockwise: false)  // false = visuell UZS im Y-down System
        return p
    }
}

// MARK: - SpeedZone

private struct SpeedZone {
    let upper: Double
    let color: Color

    static let all: [SpeedZone] = [
        .init(upper: 30,  color: Color(hex: "22C55E")),  // grün   0–30
        .init(upper: 50,  color: Color(hex: "3B82F6")),  // blau   30–50  (identisch mit SpeedColor.blue)
        .init(upper: 80,  color: Color(hex: "F59E0B")),  // gelb  50–80
        .init(upper: 130, color: Color(hex: "FB923C")),  // orange 80–130
        .init(upper: 240, color: Color(hex: "EF4444")),  // rot  130–240
    ]

    static func color(for kmh: Double) -> Color {
        all.first { kmh < $0.upper }?.color ?? Color(hex: "EF4444")
    }
}

// MARK: - SpeedometerLabels

private struct SpeedometerLabels: View {
    let side: CGFloat

    private let entries: [(Int, Bool)] = [
        (0, false), (20, false), (30, true), (50, true),
        (60, false), (80, false), (100, false), (120, false),
        (140, false), (160, false), (180, false),
        (200, false), (220, false), (240, false)
    ]

    var body: some View {
        ZStack {
            ForEach(entries, id: \.0) { val, isWarning in
                let deg    = Gauge.angle(for: Double(val))
                let rad    = deg * .pi / 180.0
                let tickR  = Double(side) * 0.435
                let labelR = tickR - Double(side) * (isWarning ? 0.130 : 0.108)
                let cx     = Double(side) / 2
                let cy     = Double(side) / 2
                let x      = cx + cos(rad) * labelR
                let y      = cy + sin(rad) * labelR

                Text("\(val)")
                    .font(Font(UIFont.systemFont(
                        ofSize: side * (isWarning ? 0.040 : 0.044),
                        weight: isWarning ? .medium : .thin
                    )))
                    .foregroundStyle(isWarning ? Color(hex: "EF4444") : Color.white.opacity(0.70))
                    .position(x: x, y: y)
            }
        }
    }
}

// MARK: - SpeedometerCanvas

private struct SpeedometerCanvas: View {
    let speedKmh: Double
    let progress: Double
    let side: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let s  = size.width
            let cx = s / 2
            let cy = s / 2
            let ct = CGPoint(x: cx, y: cy)

            let outerR  = s * 0.46
            let trackR  = s * 0.40
            let tickOut = s * 0.435

            func toRad(_ d: Double) -> Double { d * .pi / 180 }

            // ── 1. Äußerer Ring
            ctx.fill(Path(ellipseIn: CGRect(x: cx-outerR, y: cy-outerR,
                                            width: outerR*2, height: outerR*2)),
                     with: .color(Color(hex: "0F1520")))
            ctx.stroke(Path(ellipseIn: CGRect(x: cx-outerR, y: cy-outerR,
                                              width: outerR*2, height: outerR*2)),
                       with: .color(Color.white.opacity(0.1)), lineWidth: 1.5)

            // ── 2. Zifferblatt
            let faceR = outerR * 0.90
            ctx.fill(Path(ellipseIn: CGRect(x: cx-faceR, y: cy-faceR,
                                            width: faceR*2, height: faceR*2)),
                     with: .color(Color(hex: "080C14")))

            // ── 3. Hintergrundtrack (voller 270°-Bogen, grau)
            ctx.stroke(
                Gauge.arcPath(from: 0, to: 240, radius: trackR, center: ct),
                with: .color(Color.white.opacity(0.07)),
                style: StrokeStyle(lineWidth: s * 0.026, lineCap: .butt)
            )

            // ── 4. Blau-Highlight 30–50 (lokale Zone, konsistent mit SpeedColor)
            // Gleicher Radius + gleiche Breite wie Haupttrack → exakt überlagert
            ctx.stroke(
                Gauge.arcPath(from: 30, to: 50, radius: trackR, center: ct),
                with: .color(Color(hex: "3B82F6").opacity(0.25)),
                style: StrokeStyle(lineWidth: s * 0.026, lineCap: .butt)
            )

            // ── 5. Aktiver Arc – zonenweise segmentiert
            // JEDE Zone wird als eigenes Segment gezeichnet.
            // Dadurch überdeckt z.B. Grün (0→20) nie die rote Zone (30→50).
            if speedKmh > 0.5 {
                var prevKmh = 0.0

                for zone in SpeedZone.all {
                    guard prevKmh < speedKmh else { break }

                    let segStart = prevKmh
                    let segEnd   = min(speedKmh, zone.upper)
                    guard segEnd > segStart else {
                        prevKmh = zone.upper
                        continue
                    }

                    let isLastSeg = (segEnd >= speedKmh - 0.01)
                    let lineCap: CGLineCap = isLastSeg ? .round : .butt

                    ctx.stroke(
                        Gauge.arcPath(from: segStart, to: segEnd, radius: trackR, center: ct),
                        with: .color(zone.color),
                        style: StrokeStyle(lineWidth: s * 0.020, lineCap: lineCap)
                    )

                    prevKmh = zone.upper
                }
            }

            // ── 6. Tick Marks
            for i in 0...48 {
                let kmh  = Double(i) * 5.0
                let a    = toRad(Gauge.angle(for: kmh))
                let cosA = CGFloat(cos(a))
                let sinA = CGFloat(sin(a))

                let is30    = i == 6
                let is50    = i == 10
                let isMajor = i % 4 == 0

                let tickLen: CGFloat
                let tickW:   CGFloat
                let color:   Color

                if is30 || is50 {
                    tickLen = s * 0.075; tickW = 2.5
                    color   = Color(hex: "3B82F6")  // blau, konsistent mit SpeedColor.blue
                } else if isMajor {
                    tickLen = s * 0.058; tickW = 2.0
                    color   = Color.white.opacity(0.65)
                } else {
                    tickLen = s * 0.030; tickW = 1.0
                    color   = Color.white.opacity(0.20)
                }

                var tick = Path()
                tick.move(to:    CGPoint(x: cx + cosA * tickOut,
                                         y: cy + sinA * tickOut))
                tick.addLine(to: CGPoint(x: cx + cosA * (tickOut - tickLen),
                                         y: cy + sinA * (tickOut - tickLen)))
                ctx.stroke(tick, with: .color(color),
                           style: StrokeStyle(lineWidth: tickW, lineCap: .square))
            }

            // ── 7. Zeiger
            let nRad = toRad(Gauge.angle(for: speedKmh))
            let nx   = CGFloat(cos(nRad))
            let ny   = CGFloat(sin(nRad))
            let px   = -ny   // Senkrecht (für Breite)
            let py   =  nx

            let tipPt  = CGPoint(x: cx + nx*s*0.375,                     y: cy + ny*s*0.375)
            let waistL = CGPoint(x: cx + px*s*0.013 + nx*s*0.05,         y: cy + py*s*0.013 + ny*s*0.05)
            let waistR = CGPoint(x: cx - px*s*0.013 + nx*s*0.05,         y: cy - py*s*0.013 + ny*s*0.05)
            let tailL  = CGPoint(x: cx + px*s*0.008 - nx*s*0.06,         y: cy + py*s*0.008 - ny*s*0.06)
            let tailR  = CGPoint(x: cx - px*s*0.008 - nx*s*0.06,         y: cy - py*s*0.008 - ny*s*0.06)

            var needle = Path()
            needle.move(to: tipPt)
            needle.addLine(to: waistL); needle.addLine(to: tailL)
            needle.addLine(to: tailR);  needle.addLine(to: waistR)
            needle.closeSubpath()
            ctx.fill(needle,   with: .color(Color(hex: "C8D4E0")))
            ctx.stroke(needle, with: .color(Color.white.opacity(0.15)),
                       style: StrokeStyle(lineWidth: 0.5))

            // Cyan-Akzent am Zeigerende
            var tail = Path()
            tail.move(to:    CGPoint(x: cx + px*s*0.004, y: cy + py*s*0.004))
            tail.addLine(to: tailL); tail.addLine(to: tailR)
            tail.addLine(to: CGPoint(x: cx - px*s*0.004, y: cy - py*s*0.004))
            tail.closeSubpath()
            ctx.fill(tail, with: .color(Color.cyan.opacity(0.8)))

            // ── 8. Nabe
            let hubR  = s * 0.042
            let ihubR = hubR * 0.45
            ctx.fill(Path(ellipseIn: CGRect(x: cx-hubR,   y: cy-hubR,   width: hubR*2,   height: hubR*2)),
                     with: .color(Color(hex: "6A7A8A")))
            ctx.stroke(Path(ellipseIn: CGRect(x: cx-hubR,  y: cy-hubR,  width: hubR*2,   height: hubR*2)),
                       with: .color(Color.white.opacity(0.25)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: cx-ihubR,  y: cy-ihubR, width: ihubR*2,  height: ihubR*2)),
                     with: .color(Color(hex: "1A2535")))
        }
        .animation(.easeOut(duration: 0.2), value: progress)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(hex: "080C14").ignoresSafeArea()
        VStack(spacing: 16) {
            // Test verschiedener Zonen
            HStack(spacing: 16) {
                SpeedometerView(speedKmh: 0)    // kein Arc, Zeiger bei 0
                    .frame(width: 180, height: 180)
                SpeedometerView(speedKmh: 40)   // rot: rote Zone aktiv
                    .frame(width: 180, height: 180)
            }
            HStack(spacing: 16) {
                SpeedometerView(speedKmh: 65)   // gelb: Grün + Rot + Gelb Segment
                    .frame(width: 180, height: 180)
                SpeedometerView(speedKmh: 120)  // orange
                    .frame(width: 180, height: 180)
            }
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var val: UInt64 = 0
        Scanner(string: h).scanHexInt64(&val)
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >>  8) & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
