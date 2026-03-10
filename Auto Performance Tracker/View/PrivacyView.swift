import SwiftUI
import WebKit

// ──────────────────────────────────────────────────────────────────
// PrivacyView.swift
//
// Lädt die Datenschutzerklärung LIVE von:
//   https://antonmelken.github.io/private-policy-apt/
//
// FIX: WKWebView wird SOFORT gerendert (nicht erst nach dem Laden).
// Loading-Indicator liegt als ZStack-Overlay darüber und verschwindet
// sobald die Seite geladen ist. Bei Fehler → lokaler Fallback.
// ──────────────────────────────────────────────────────────────────

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var lang: LanguageManager

    @State private var isLoading = true
    @State private var loadFailed = false

    private let privacyURL = "https://antonmelken.github.io/auto-performance-tracker/datenschutz.html"

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()

                if loadFailed {
                    // ── Fallback: kein Internet / Ladefehler
                    FallbackPrivacyView()
                } else {
                    // ── WebView wird SOFORT gerendert, nicht erst nach Laden
                    PrivacyWebView(
                        urlString: privacyURL,
                        onLoadFinished: { success in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLoading = false
                                if !success { loadFailed = true }
                            }
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)

                    // ── Loading-Overlay liegt drüber und blendet sich aus
                    if isLoading {
                        ZStack {
                            Color(hex: "080C14").ignoresSafeArea()
                            VStack(spacing: 16) {
                                ProgressView()
                                    .progressViewStyle(
                                        CircularProgressViewStyle(tint: Color(hex: "818CF8"))
                                    )
                                    .scaleEffect(1.2)
                                Text(L("privacy.loading"))  // FIX QUAL-002: war hardcoded DE/EN
                                    .font(.subheadline)
                                    .foregroundStyle(Color(hex: "8A9BB5"))
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            .navigationTitle(L("privacy.nav_title"))
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
// MARK: - WKWebView Wrapper
// ──────────────────────────────────────────────────────────────────

struct PrivacyWebView: UIViewRepresentable {
    let urlString: String
    let onLoadFinished: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadFinished: onLoadFinished)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Dunkles Theme per CSS beim Laden injizieren
        let css = "html,body{background-color:#080C14!important;}"
        let source = "var s=document.createElement('style');s.innerText=`\(css)`;document.head.appendChild(s);"
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = UIColor(hex: "080C14")
        webView.scrollView.backgroundColor = UIColor(hex: "080C14")
        webView.isOpaque = false
        webView.scrollView.showsHorizontalScrollIndicator = false

        // URL sofort beim Erstellen laden
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url,
                                    cachePolicy: .reloadRevalidatingCacheData,
                                    timeoutInterval: 15))
        } else {
            DispatchQueue.main.async { self.onLoadFinished(false) }
        }

        return webView
    }

    // updateUIView absichtlich leer – Laden passiert nur einmal in makeUIView
    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: Coordinator
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoadFinished: (Bool) -> Void
        init(onLoadFinished: @escaping (Bool) -> Void) {
            self.onLoadFinished = onLoadFinished
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onLoadFinished(true) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.onLoadFinished(false) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.onLoadFinished(false) }
        }
    }
}

// UIColor hex helper
private extension UIColor {
    convenience init(hex: String) {
        let s = hex.replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let rgb = UInt64(s, radix: 16) else {
            self.init(white: 0, alpha: 1); return
        }
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >>  8) & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1
        )
    }
}

// ──────────────────────────────────────────────────────────────────
// MARK: - Statischer Fallback (kein Internet)
// ──────────────────────────────────────────────────────────────────

struct FallbackPrivacyView: View {
    @EnvironmentObject private var lang: LanguageManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                    Text(L("privacy.no_internet"))  // FIX QUAL-002: war hardcoded DE/EN
                        .font(.caption).foregroundStyle(.orange)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color(hex: "818CF8").opacity(0.15)).frame(width: 48, height: 48)
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(Color(hex: "818CF8")).font(.system(size: 22))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("privacy.header_title"))
                                .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                            Text(L("privacy.header_updated"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(L("privacy.header_intro"))
                        .font(.subheadline).foregroundStyle(Color(hex: "8A9BB5")).lineSpacing(4)
                }

                Divider().background(Color.white.opacity(0.08))

                Group {
                    section("person.fill",                           Color(hex: "22C55E"), "privacy.s1_title",  "privacy.s1_content")
                    section("location.fill",                         .cyan,                "privacy.s2_title",  "privacy.s2_content")
                    section("icloud.fill",                           Color(hex: "818CF8"), "privacy.s3_title",  "privacy.s3_content")
                    section("chart.bar.fill",                        Color(hex: "F59E0B"), "privacy.s4_title",  "privacy.s4_content")
                    section("fuelpump.fill",                         Color(hex: "FB923C"), "privacy.s5_title",  "privacy.s5_content")
                    section("square.and.arrow.up.fill",              Color(hex: "22C55E"), "privacy.s6_title",  "privacy.s6_content")
                    section("hand.raised.fill",                      Color(hex: "818CF8"), "privacy.s7_title",  "privacy.s7_content")
                    section("exclamationmark.shield.fill",           .red,                 "privacy.s8_title",  "privacy.s8_content")
                    section("person.crop.circle.badge.questionmark", Color(hex: "8A9BB5"), "privacy.s9_title",  "privacy.s9_content")
                }
                Group {
                    section("arrow.triangle.2.circlepath",           Color(hex: "22C55E"), "privacy.s10_title", "privacy.s10_content")
                    section("megaphone.fill",                         Color(hex: "F43F5E"), "privacy.s11_title", "privacy.s11_content")
                    section("ant.fill",                               Color(hex: "FF6B6B"), "privacy.s12_title", "privacy.s12_content")
                    section("clock.fill",                             Color(hex: "60A5FA"), "privacy.s13_title", "privacy.s13_content")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("privacy.footer_title")).font(.subheadline).fontWeight(.semibold).foregroundStyle(.white)
                    Text(L("privacy.footer_text")).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                }
                .padding(16)
                .background(Color(hex: "0F1A2E"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07)))
            }
            .padding(20)
        }
    }

    private func section(_ icon: String, _ color: Color, _ titleKey: String, _ contentKey: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(color.opacity(0.12)).frame(width: 34, height: 34)
                    Image(systemName: icon).foregroundStyle(color).font(.system(size: 14))
                }
                Text(L(titleKey)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            Text(L(contentKey))
                .font(.system(size: 14)).foregroundStyle(Color(hex: "8A9BB5"))
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(hex: "0F1A2E"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
    }
}

#Preview {
    PrivacyView()
}
