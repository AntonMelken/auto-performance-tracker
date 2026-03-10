import SwiftUI

// MARK: - Onboarding Daten
private struct OnboardingPage {
    let icon: String
    let iconColor: Color
    let titleKey: String
    let subtitleKey: String
}

private let pages: [OnboardingPage] = [
    OnboardingPage(
        icon: "car.fill",
        iconColor: .cyan,
        titleKey: "onboarding.1.title",
        subtitleKey: "onboarding.1.subtitle"
    ),
    OnboardingPage(
        icon: "location.fill",
        iconColor: Color(hex: "22C55E"),
        titleKey: "onboarding.2.title",
        subtitleKey: "onboarding.2.subtitle"
    ),
    OnboardingPage(
        icon: "chart.bar.xaxis",
        iconColor: Color(hex: "F59E0B"),
        titleKey: "onboarding.3.title",
        subtitleKey: "onboarding.3.subtitle"
    ),
    OnboardingPage(
        icon: "fuelpump.fill",
        iconColor: Color(hex: "FB923C"),
        titleKey: "onboarding.4.title",
        subtitleKey: "onboarding.4.subtitle"
    ),
    OnboardingPage(
        icon: "lock.shield.fill",
        iconColor: Color(hex: "818CF8"),
        titleKey: "onboarding.5.title",
        subtitleKey: "onboarding.5.subtitle"
    )
]

// MARK: - OnboardingView
struct OnboardingView: View {

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var currentPage = 0
    @State private var animateIcon = false

    var body: some View {
        ZStack {
            // Hintergrund
            Color(hex: "080C14").ignoresSafeArea()

            // Subtile Hintergrundgradient passend zur Seite
            RadialGradient(
                colors: [
                    pages[currentPage].iconColor.opacity(0.12),
                    Color.clear
                ],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: currentPage)

            VStack(spacing: 0) {

                // Skip-Button oben rechts
                HStack {
                    Spacer()
                    if currentPage < pages.count - 1 {
                        Button(L("common.skip")) {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                hasSeenOnboarding = true
                            }
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 24)
                        .padding(.top, 16)
                    }
                }
                .frame(height: 52)

                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(pages[currentPage].iconColor.opacity(0.12))
                        .frame(width: 130, height: 130)
                        .scaleEffect(animateIcon ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: animateIcon)

                    Circle()
                        .strokeBorder(pages[currentPage].iconColor.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 130, height: 130)

                    Image(systemName: pages[currentPage].icon)
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(pages[currentPage].iconColor)
                        .symbolEffect(.pulse, options: .repeating)
                }
                .padding(.bottom, 44)
                .animation(.easeInOut(duration: 0.4), value: currentPage)

                // Titel
                Text(L(pages[currentPage].titleKey))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
                    .animation(.easeInOut(duration: 0.35), value: currentPage)

                // Subtitle
                Text(L(pages[currentPage].subtitleKey))
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color(hex: "8A9BB5"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 36)
                    .animation(.easeInOut(duration: 0.35), value: currentPage)

                Spacer()

                // Page Dots
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? pages[currentPage].iconColor : Color.white.opacity(0.2))
                            .frame(width: i == currentPage ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.3), value: currentPage)
                    }
                }
                .padding(.bottom, 36)

                // Weiter / Los geht's Button
                Button(action: nextPage) {
                    HStack(spacing: 10) {
                        Text(currentPage == pages.count - 1 ? L("common.lets_go") : L("common.continue"))
                            .font(.system(size: 17, weight: .semibold))
                        Image(systemName: currentPage == pages.count - 1 ? "checkmark" : "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        LinearGradient(
                            colors: [pages[currentPage].iconColor, pages[currentPage].iconColor.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: pages[currentPage].iconColor.opacity(0.35), radius: 16, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
                .animation(.easeInOut(duration: 0.3), value: currentPage)
            }
        }
        .onAppear { animateIcon = true }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { drag in
                    if drag.translation.width < -40 && currentPage < pages.count - 1 {
                        withAnimation(.easeInOut(duration: 0.35)) { currentPage += 1 }
                    } else if drag.translation.width > 40 && currentPage > 0 {
                        withAnimation(.easeInOut(duration: 0.35)) { currentPage -= 1 }
                    }
                }
        )
    }

    private func nextPage() {
        if currentPage < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.35)) { currentPage += 1 }
        } else {
            // DSGVO Art. 7(1) – Nachweispflicht für Einwilligung:
            // Consent-Zeitstempel wird IMMER lokal in UserDefaults gespeichert,
            // unabhängig davon ob der User eingeloggt ist oder nicht.
            // Dies stellt sicher, dass auch Gäste und nicht-registrierte User
            // einen nachweisbaren Consent-Zeitpunkt haben.
            let consentISO = ISO8601DateFormatter().string(from: Date())
            UserDefaults.standard.set(consentISO, forKey: "dsgvoConsentTimestamp")
            UserDefaults.standard.set("onboarding_complete", forKey: "dsgvoConsentMethod")

            // Cloud-Audit-Log (nur wenn eingeloggt — kein Fehler wenn nicht)
            Task {
                await SupabaseManager.shared.logDsgvoAction("consent_given", details: ["method": "onboarding_complete"])
            }
            withAnimation(.easeInOut(duration: 0.4)) { hasSeenOnboarding = true }
        }
    }
}

#Preview {
    OnboardingView()
}
