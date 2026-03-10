import SwiftUI

// MARK: - AgeGateView
// Wird einmalig beim ersten App-Start angezeigt, VOR dem Disclaimer.
// Nutzer muss aktiv ein Geburtsjahr wählen. Unter 17 → Blockiert-Screen.
// Das Ergebnis wird dauerhaft in AppStorage gespeichert.
struct AgeGateView: View {

    @AppStorage("ageGatePassed") private var ageGatePassed = false
    @ObservedObject private var lang = LanguageManager.shared

    private static let minYear = 1920
    private static let minAge  = 17

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var maxSelectableYear: Int { currentYear - Self.minAge }  // ältestes erlaubtes Geb.-Jahr
    private var years: [Int] { (Self.minYear...currentYear).reversed().map { $0 } }

    @State private var selectedYear: Int
    @State private var showBlocked = false

    init() {
        let current = Calendar.current.component(.year, from: Date())
        _selectedYear = State(initialValue: current - Self.minAge)  // Default: exakt 17
    }

    var body: some View {
        if showBlocked {
            blockedView
        } else {
            pickerView
        }
    }

    // MARK: - Picker
    private var pickerView: some View {
        ZStack {
            Color(hex: "080C14").ignoresSafeArea()

            RadialGradient(
                colors: [Color.cyan.opacity(0.09), Color.clear],
                center: .top, startRadius: 0, endRadius: 380
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(width: 110, height: 110)
                    Circle()
                        .strokeBorder(Color.cyan.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 110, height: 110)
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.cyan)
                }
                .padding(.top, 64)
                .padding(.bottom, 20)

                Text(lang.localized("agegate.title"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(lang.localized("agegate.subtitle"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "8A9BB5"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 8)
                    .padding(.bottom, 32)

                Text(lang.localized("agegate.prompt"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: "8A9BB5"))
                    .padding(.bottom, 6)

                // Geburtsjahr-Picker
                Picker("", selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text(String(year))
                            .foregroundStyle(.white)
                            .tag(year)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 160)
                .clipped()
                .padding(.horizontal, 60)

                Spacer()

                Button(action: confirmAge) {
                    Text(lang.localized("agegate.confirm"))
                        .font(.system(size: 17, weight: .semibold))
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

    // MARK: - Blocked
    private var blockedView: some View {
        ZStack {
            Color(hex: "080C14").ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 110, height: 110)
                    Circle()
                        .strokeBorder(Color.red.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 110, height: 110)
                    Image(systemName: "xmark.shield.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.red)
                }
                .padding(.top, 80)
                .padding(.bottom, 24)

                Text(lang.localized("agegate.blocked.title"))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)

                Text(lang.localized("agegate.blocked.body"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "8A9BB5"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)

                Spacer()

                // Apple verbietet exit() in iOS-Apps (Guideline 2.4.5).
                // Stattdessen: zurück zum Picker — User bleibt auf dem Blocked-Screen
                // solange showBlocked == true (kann Alter nicht erneut eingeben ohne App-Neustart).
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showBlocked = false
                    }
                }) {
                    Text(lang.localized("agegate.blocked.close"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.red.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
            }
        }
    }

    // MARK: - Logic
    private func confirmAge() {
        if selectedYear <= maxSelectableYear {
            // Alt genug → Gate bestanden
            withAnimation(.easeInOut(duration: 0.4)) {
                ageGatePassed = true
            }
        } else {
            // Zu jung → Blockiert-Screen
            withAnimation(.easeInOut(duration: 0.3)) {
                showBlocked = true
            }
        }
    }
}

#Preview {
    AgeGateView()
        .environmentObject(LanguageManager.shared)
}
