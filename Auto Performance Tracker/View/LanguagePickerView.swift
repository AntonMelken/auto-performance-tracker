import SwiftUI

// MARK: - LanguagePickerView
// Allererster Screen beim ersten App-Start.
// Nutzer wählt die Sprache bevor irgendein anderer Screen erscheint.
struct LanguagePickerView: View {

    @AppStorage("hasChosenLanguage") private var hasChosenLanguage = false
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ZStack {
            Color(hex: "080C14").ignoresSafeArea()

            RadialGradient(
                colors: [Color.cyan.opacity(0.10), Color.clear],
                center: .top, startRadius: 0, endRadius: 380
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                // ── App-Icon / Logo ───────────────────────────────────
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(width: 110, height: 110)
                    Circle()
                        .strokeBorder(Color.cyan.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 110, height: 110)
                    Image(systemName: "car.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.cyan)
                }
                .padding(.top, 80)
                .padding(.bottom, 28)

                // ── Titel (zweisprachig, immer fix) ───────────────────
                Text("Auto Performance Tracker")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text("Please choose your language\nBitte wähle deine Sprache")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "8A9BB5"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
                    .padding(.bottom, 52)

                // ── Sprachauswahl-Buttons ─────────────────────────────
                VStack(spacing: 16) {
                    LanguageButton(
                        flag: "🇩🇪",
                        label: "Deutsch",
                        sublabel: "German",
                        isSelected: lang.current == .de
                    ) {
                        lang.current = .de
                    }

                    LanguageButton(
                        flag: "🇬🇧",
                        label: "English",
                        sublabel: "Englisch",
                        isSelected: lang.current == .en
                    ) {
                        lang.current = .en
                    }
                }
                .padding(.horizontal, 28)

                Spacer()

                // ── Weiter-Button ─────────────────────────────────────
                Button(action: {
                    // Set language first, then navigate on next runloop tick so
                    // @ObservedObject subscribers in the next view receive the
                    // correct language before their first render.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            hasChosenLanguage = true
                        }
                    }
                }) {
                    HStack(spacing: 10) {
                        Text(lang.current == .de ? "Weiter" : "Continue")
                            .font(.system(size: 17, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        LinearGradient(
                            colors: [.cyan, Color(hex: "0066FF")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: Color.cyan.opacity(0.35), radius: 16, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
            }
        }
    }
}

// MARK: - LanguageButton
private struct LanguageButton: View {
    let flag: String
    let label: String
    let sublabel: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(flag)
                    .font(.system(size: 36))

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(sublabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "8A9BB5"))
                }

                Spacer()

                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.cyan : Color.white.opacity(0.2),
                            lineWidth: 2
                        )
                        .frame(width: 26, height: 26)
                    if isSelected {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 14, height: 14)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isSelected)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                isSelected
                    ? Color.cyan.opacity(0.10)
                    : Color(hex: "111827").opacity(0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isSelected ? Color.cyan.opacity(0.5) : Color.white.opacity(0.07),
                        lineWidth: 1.5
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LanguagePickerView()
}
