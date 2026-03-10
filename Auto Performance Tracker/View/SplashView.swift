import SwiftUI

// MARK: - SplashView
// Zeigt beim App-Start das Icon mit einer smooth Expand-Animation,
// bevor die Hauptapp erscheint.

struct SplashView: View {

    @Binding var isVisible: Bool

    // Animation States
    @State private var iconScale: CGFloat      = 0.6
    @State private var iconOpacity: Double     = 0.0
    @State private var glowOpacity: Double     = 0.0
    @State private var sloganOpacity: Double   = 0.0
    @State private var sloganOffset: CGFloat   = 12
    @State private var expandScale: CGFloat    = 1.0
    @State private var bgOpacity: Double       = 1.0
    @State private var whiteFlash: Double      = 0.0

    var body: some View {
        ZStack {
            // Hintergrund – expandiert am Ende und deckt alles ab
            Color(hex: "080C14")
                .ignoresSafeArea()
                .opacity(bgOpacity)

            // Weißer Flash-Effekt beim Übergang
            Color.white
                .ignoresSafeArea()
                .opacity(whiteFlash)

            VStack(spacing: 28) {

                // ── App Icon (SwiftUI-Nachbau) ──────────────────────────
                ZStack {
                    // Glow hinter dem Icon
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(hex: "6C63FF").opacity(0.6),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 10,
                                endRadius: 120
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)
                        .opacity(glowOpacity)

                    // Das Icon selbst
                    Image("SplashIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                        .shadow(
                            color: Color(hex: "6C63FF").opacity(0.5),
                            radius: 24, x: 0, y: 10
                        )
                }
                .scaleEffect(iconScale * expandScale)
                .opacity(iconOpacity)

                // ── Slogan ──────────────────────────────────────────────
                VStack(spacing: 6) {
                    Text("Auto Performance Tracker")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(L("splash.slogan"))  // FIX QUAL-001: war hardcoded "Drive Smarter. Glow Faster."
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "38BDF8"), Color(hex: "A78BFA")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                .opacity(sloganOpacity)
                .offset(y: sloganOffset)
            }
        }
        .onAppear { runSplashAnimation() }
    }

    // MARK: - Animation Sequenz
    private func runSplashAnimation() {

        // 1. Icon einblenden + skalieren
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            iconScale   = 1.0
            iconOpacity = 1.0
        }

        // 2. Glow einblenden
        withAnimation(.easeOut(duration: 0.8).delay(0.3)) {
            glowOpacity = 1.0
        }

        // 3. Slogan von unten einfliegen
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.5)) {
            sloganOpacity = 1.0
            sloganOffset  = 0
        }

        // 4. Kurz warten, dann Übergangsanimation starten
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {

            // Sanfter Glow-Pulse vor dem Exit
            withAnimation(.easeInOut(duration: 0.25)) {
                glowOpacity = 1.6
            }

            // Icon skaliert auf und verblasst weg (Icon "wächst" in die App)
            withAnimation(.easeIn(duration: 0.45).delay(0.1)) {
                expandScale  = 8.0
                iconOpacity  = 0.0
                sloganOpacity = 0.0
                whiteFlash   = 0.15
            }

            // Hintergrund verblasst als letztes
            withAnimation(.easeIn(duration: 0.2).delay(0.45)) {
                bgOpacity  = 0.0
                whiteFlash = 0.0
                isVisible  = false
            }
        }
    }
}

// MARK: - AppIconView (SwiftUI-Replica des Icons)
struct AppIconView: View {
    @State private var carPulse: Bool = false

    var body: some View {
        ZStack {
            // Gradient-Hintergrund (identisch zum echten Icon)
            LinearGradient(
                colors: [Color(hex: "38BDF8"), Color(hex: "6C63FF")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Balken-Chart
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(
                    zip(
                        [34.0, 48.0, 60.0, 72.0],
                        [Color(hex: "4ADE80"), Color(hex: "FACC15"),
                         Color(hex: "FB923C"), Color(hex: "F472B6")]
                    ).map { ($0, $1) },
                    id: \.0
                ) { height, color in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 12, height: height)
                }
            }
            .padding(.bottom, 18)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Pfeil nach oben-rechts
            Arrow()
                .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 70, height: 50)
                .offset(x: 4, y: -8)

            // Auto-Silhouette
            Image(systemName: "car.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
                .offset(y: 20)
                .scaleEffect(carPulse ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: carPulse)
        }
        .onAppear { carPulse = true }
    }
}

// MARK: - Arrow Shape
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Diagonale Linie von links-unten nach rechts-oben
        p.move(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
        p.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
        // Pfeilspitze
        p.move(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
        p.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 22))
        p.move(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
        p.addLine(to: CGPoint(x: rect.maxX - 22, y: rect.minY + 4))
        return p
    }
}

#Preview {
    SplashView(isVisible: .constant(true))
}
