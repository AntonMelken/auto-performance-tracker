import SwiftUI
import WebKit

// ──────────────────────────────────────────────────────────────────
// ImpressumView.swift
//
// Lädt das Impressum LIVE von:
//   https://antonmelken.github.io/auto-performance-tracker/impressum.html
// ──────────────────────────────────────────────────────────────────

struct ImpressumView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var lang: LanguageManager

    @State private var isLoading = true
    @State private var loadFailed = false

    private let impressumURL = "https://antonmelken.github.io/auto-performance-tracker/impressum.html"

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()

                if loadFailed {
                    // Fallback bei keiner Internetverbindung
                    FallbackImpressumView()
                } else {
                    PrivacyWebView(
                        urlString: impressumURL,
                        onLoadFinished: { success in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLoading = false
                                if !success { loadFailed = true }
                            }
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)

                    if isLoading {
                        ZStack {
                            Color(hex: "080C14").ignoresSafeArea()
                            VStack(spacing: 16) {
                                ProgressView()
                                    .progressViewStyle(
                                        CircularProgressViewStyle(tint: Color(hex: "818CF8"))
                                    )
                                    .scaleEffect(1.2)
                                Text(L("impressum.loading"))
                                    .font(.subheadline)
                                    .foregroundStyle(Color(hex: "8A9BB5"))
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            .navigationTitle(L("impressum.nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────────
// MARK: - Statischer Fallback (kein Internet)
// ──────────────────────────────────────────────────────────────────

struct FallbackImpressumView: View {
    @EnvironmentObject private var lang: LanguageManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                    Text(L("privacy.no_internet"))
                        .font(.caption).foregroundStyle(.orange)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color(hex: "818CF8").opacity(0.15)).frame(width: 48, height: 48)
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(Color(hex: "818CF8")).font(.system(size: 22))
                        }
                        Text(L("impressum.nav_title"))
                            .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Anton Melnychuk")
                            .font(.subheadline).fontWeight(.semibold).foregroundStyle(.white)
                        Text("Heppenheimer Strasse 39\n64658 Furth im Odenwald\nDeutschland")
                            .font(.subheadline).foregroundStyle(Color(hex: "8A9BB5")).lineSpacing(4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("support@melnychuk-anton.de", systemImage: "envelope.fill")
                            .font(.subheadline).foregroundStyle(.cyan)
                        Label("+49 (0) 175 3797891", systemImage: "phone.fill")
                            .font(.subheadline).foregroundStyle(Color(hex: "8A9BB5"))
                    }
                }

                Link(destination: URL(string: "https://antonmelken.github.io/auto-performance-tracker/impressum.html")!) {
                    HStack {
                        Image(systemName: "safari.fill").foregroundStyle(.cyan)
                        Text("Im Browser öffnen")
                            .font(.subheadline).foregroundStyle(.cyan)
                    }
                    .padding(14)
                    .background(Color.cyan.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cyan.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(20)
        }
    }
}

#Preview {
    ImpressumView()
}
