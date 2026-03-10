import SwiftUI

// MARK: - DisclaimerView
// Wird einmalig beim ersten App-Start angezeigt, VOR dem Onboarding.
// Der Nutzer muss die Checkbox aktiv ankreuzen, bevor er weitermachen kann.
// Damit dokumentiert die App, dass der Nutzer die Haftungsgrenzen verstanden hat.
struct DisclaimerView: View {

    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false
    @State private var accepted = false
    @State private var showMustAccept = false
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ZStack {
            Color(hex: "080C14").ignoresSafeArea()

            RadialGradient(
                colors: [Color.orange.opacity(0.10), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // ── Icon ──────────────────────────────────────────
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 110, height: 110)
                        Circle()
                            .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1.5)
                            .frame(width: 110, height: 110)
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(.top, 52)
                    .padding(.bottom, 20)

                    // ── Titel ─────────────────────────────────────────
                    Text(lang.localized("disclaimer.title"))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    Text(lang.localized("disclaimer.subtitle"))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color(hex: "8A9BB5"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                        .padding(.bottom, 32)

                    // ── Hinweiskarten ─────────────────────────────────
                    VStack(spacing: 14) {
                        DisclaimerCard(
                            icon: "info.circle.fill",
                            color: .cyan,
                            title: lang.localized("disclaimer.info_only"),
                            message: lang.localized("disclaimer.info_only_body")
                        )
                        DisclaimerCard(
                            icon: "car.fill",
                            color: .red,
                            title: lang.localized("disclaimer.no_drive"),
                            message: lang.localized("disclaimer.no_drive_body")
                        )
                        DisclaimerCard(
                            icon: "location.slash.fill",
                            color: .yellow,
                            title: lang.localized("disclaimer.gps_accuracy"),
                            message: lang.localized("disclaimer.gps_accuracy_body")
                        )
                        DisclaimerCard(
                            icon: "fuelpump.fill",
                            color: Color(hex: "FB923C"),
                            title: lang.localized("disclaimer.estimates"),
                            message: lang.localized("disclaimer.estimates_body")
                        )
                    }
                    .padding(.horizontal, 20)

                    // ── Checkbox ──────────────────────────────────────
                    Button(action: {
                        accepted.toggle()
                        if accepted { showMustAccept = false }
                    }) {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        accepted ? Color.green : Color.white.opacity(0.3),
                                        lineWidth: 1.5
                                    )
                                    .frame(width: 24, height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(accepted ? Color.green.opacity(0.15) : Color.clear)
                                    )
                                if accepted {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.top, 1)

                            Text(lang.localized("disclaimer.checkbox"))
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(Color(hex: "CBD5E1"))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 8)

                    // ── Fehlerhinweis ─────────────────────────────────
                    if showMustAccept {
                        Text(lang.localized("disclaimer.must_accept"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // ── Bestätigen-Button ─────────────────────────────
                    Button(action: confirmTapped) {
                        HStack(spacing: 10) {
                            Text(lang.localized("disclaimer.confirm"))
                                .font(.system(size: 17, weight: .semibold))
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(accepted ? .black : Color(hex: "4A5568"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            LinearGradient(
                                colors: accepted
                                    ? [.green, Color(hex: "16A34A")]
                                    : [Color(hex: "1E293B"), Color(hex: "1E293B")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(
                                    accepted ? Color.clear : Color.white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: accepted ? Color.green.opacity(0.35) : .clear,
                            radius: 16, y: 6
                        )
                        .animation(.easeInOut(duration: 0.25), value: accepted)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 52)
                }
            }
        }
    }

    private func confirmTapped() {
        guard accepted else {
            withAnimation(.easeInOut(duration: 0.2)) { showMustAccept = true }
            return
        }
        withAnimation(.easeInOut(duration: 0.4)) {
            hasAcceptedDisclaimer = true
        }
    }
}

// MARK: - DisclaimerCard
private struct DisclaimerCard: View {
    let icon: String
    let color: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(color)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(hex: "8A9BB5"))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(hex: "111827").opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

#Preview {
    DisclaimerView()
}
