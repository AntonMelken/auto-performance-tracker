import StoreKit
import SwiftUI
import Combine

// MARK: - Product IDs (müssen mit App Store Connect übereinstimmen)
enum SubscriptionProduct: String, CaseIterable {
    case proMonthly = "com.anton.melnychuk.AutoPerformanceTracker.pro.monthly"
    case proYearly  = "com.anton.melnychuk.AutoPerformanceTracker.pro.yearly"
}

// MARK: - SubscriptionManager
@MainActor
final class SubscriptionManager: ObservableObject {

    static let shared = SubscriptionManager()

    // isPro wird NICHT in UserDefaults gecacht, da UserDefaults auf gejailbreakten
    // Geräten trivial manipuliert werden können (Sicherheits-Finding BUG-008 / SEC-006).
    // Stattdessen: beim App-Start immer gegen StoreKit + Server verifizieren.
    // Der Wert startet als false; checkPro() und setProFromServer() setzen ihn korrekt.
    @Published var isPro: Bool = false
    /// Admin-Flag: wird aus Supabase geladen, kann NICHT von StoreKit überschrieben werden
    @Published var isAdmin: Bool = false
    @Published var products: [Product] = []
    @Published var purchaseInProgress: Bool = false
    @Published var errorMessage: String? = nil

    private var updateListenerTask: Task<Void, Error>?

    // Standard-Limits
    static let monthlyKmLimit: Double = 250
    static let maxFreeVehicles: Int   = 1

    private init() {
        updateListenerTask = listenForTransactions()
        Task { await loadProducts(); await checkPro() }
    }

    deinit { updateListenerTask?.cancel() }

    // MARK: - Load Products
    func loadProducts() async {
        do {
            let ids = SubscriptionProduct.allCases.map(\.rawValue)
            let loaded = try await Product.products(for: ids)
            products = loaded.sorted { $0.price < $1.price }
            #if DEBUG
            print("[StoreKit] \(products.count) Produkte geladen: \(products.map(\.id))")
            #endif
            if products.isEmpty {
                #if DEBUG
                print("[StoreKit] ⚠️ Keine Produkte gefunden. App Store Connect konfiguriert? Sandbox-Account aktiv?")
                #endif
                errorMessage = "Produkte nicht verfügbar. Bitte später erneut versuchen."
            }
        } catch {
            #if DEBUG
            print("[StoreKit] loadProducts fehlgeschlagen:", error)
            #endif
            errorMessage = "Produkte konnten nicht geladen werden."
        }
    }

    // MARK: - Check Pro Status
    func checkPro() async {
        // Admin hat IMMER Pro — StoreKit wird nicht benötigt
        if isAdmin {
            isPro = true
            return
        }

        var hasActiveSub  = false   // verifizierte, nicht-widerrufene Transaktion gefunden
        var hasRevokedSub = false   // explizit widerrufene Transaktion (Rückerstattung)

        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            guard SubscriptionProduct.allCases.map(\.rawValue).contains(tx.productID) else { continue }
            if tx.revocationDate == nil {
                hasActiveSub = true
            } else {
                hasRevokedSub = true
            }
        }

        if hasActiveSub {
            // ✅ Aktives StoreKit-Abo → definitiv Pro
            isPro = true
            Task { await SupabaseManager.shared.setProStatus(true) }
        } else if hasRevokedSub {
            // ❌ Abo wurde rückerstattet → kein Pro
            isPro = false
            Task { await SupabaseManager.shared.setProStatus(false) }
        }
        // Keine Entitlements gefunden → isPro NICHT ändern.
        // In Sandbox/Simulator gibt es keine echten Transaktionen.
        // Der Server-Wert (via setProFromServer) bleibt maßgeblich.
    }

    /// Wird von SupabaseManager aufgerufen wenn is_pro in der Datenbank steht.
    /// Server-Wert wird übernommen, kann aber von checkPro() (StoreKit) überschrieben werden.
    func setProFromServer(_ value: Bool) {
        // Admin überschreibt alles — isPro bleibt true
        if isAdmin {
            isPro = true
            #if DEBUG
            print("[StoreKit] setProFromServer(\(value)) ignoriert – Admin hat immer Pro")
            #endif
            return
        }
        isPro = value
        #if DEBUG
        print("[StoreKit] setProFromServer → isPro=\(value)")
        #endif
    }

    /// Wird von SupabaseManager aufgerufen wenn is_admin in der Datenbank steht.
    /// Admin-Status kann NUR über die Datenbank gesetzt werden (nicht StoreKit).
    func setAdminFromServer(_ value: Bool) {
        isAdmin = value
        if value {
            isPro = true  // Admin = immer Pro
        }
        #if DEBUG
        print("[StoreKit] setAdminFromServer → isAdmin=\(value), isPro=\(isPro)")
        #endif
    }

    // MARK: - Purchase
    func purchase(_ product: Product) async {
        purchaseInProgress = true
        errorMessage = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let tx) = verification {
                    await tx.finish()
                    await checkPro()
                }
            case .userCancelled:
                break
            case .pending:
                errorMessage = L("paywall.pending")
            @unknown default:
                break
            }
        } catch {
            errorMessage = String(format: L("paywall.error.purchase"), error.localizedDescription)
        }
        purchaseInProgress = false
    }

    // MARK: - Restore
    func restorePurchases() async {
        purchaseInProgress = true
        do {
            try await AppStore.sync()
            await checkPro()
        } catch {
            errorMessage = L("paywall.error.restore")
        }
        purchaseInProgress = false
    }

    // MARK: - Transaction Listener
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let tx) = result else { continue }
                await tx.finish()
                await self?.checkPro()
            }
        }
    }

    // MARK: - Standard-Km-Limit prüfen
    func monthlyKmUsed(from trips: [Trip]) -> Double {
        let cal = Calendar.current
        let now = Date()
        return trips
            .filter { cal.isDate($0.startDate, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.distanceKm }
    }

    func isKmLimitReached(from trips: [Trip]) -> Bool {
        guard !isPro else { return false }
        return monthlyKmUsed(from: trips) >= Self.monthlyKmLimit
    }
}


// MARK: - Paywall View (Psychologically Optimised)
// Techniques used:
//   1. Default Effect   — Yearly pre-selected; user must actively switch to monthly
//   2. Anchoring        — Shows full-price (monthly×12 = ~47,88€) crossed out above yearly price
//   3. "2 months free"  — Concrete framing beats abstract percentages every time
//   4. Per-month price  — "nur 2,33 €/Mo" makes yearly feel trivially cheap
//   5. Loss Aversion    — Feature grid: Standard column is full of red ✗ marks
//   6. Social Proof     — "Meistgewählt" badge on yearly option
//   7. CTA Language     — "Jetzt starten" not "Kaufen" (activation vs transaction)
//   8. Trust anchors    — "Jederzeit kündbar · Kein Risiko" directly under CTA
//   9. Visual hierarchy — Yearly card is larger, highlighted, prominent
//  10. Scarcity framing — Header highlights what they're currently MISSING

struct PaywallView: View {
    @EnvironmentObject var manager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedYearly: Bool = true   // ← Default: Yearly

    // Convenience
    private var yearlyProduct: Product? { manager.products.first { $0.id.contains("yearly") } }
    private var monthlyProduct: Product? { manager.products.first { $0.id.contains("monthly") } }
    private var selectedProduct: Product? { selectedYearly ? yearlyProduct : monthlyProduct }

    // Anchor price: what the user would pay monthly × 12
    private var anchorAnnualPrice: String {
        guard let monthly = monthlyProduct else { return "" }
        let annual = monthly.price * 12
        return monthly.priceFormatStyle.format(annual)
    }

    // Per-month equivalent for yearly
    private var yearlyPerMonth: String {
        guard let yearly = yearlyProduct else { return "" }
        let perMonth = yearly.price / 12
        return yearly.priceFormatStyle.format(perMonth)
    }

    // Savings amount (e.g. "19,89 €")
    private var savingsAmount: String {
        guard let yearly = yearlyProduct, let monthly = monthlyProduct else { return "" }
        let saved = (monthly.price * 12) - yearly.price
        return monthly.priceFormatStyle.format(saved)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()

                // Subtle top glow
                LinearGradient(
                    colors: [Color.cyan.opacity(0.08), Color.clear],
                    startPoint: .top, endPoint: .center
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {

                        // ─── HEADER ────────────────────────────────────────
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color.yellow.opacity(0.15))
                                    .frame(width: 72, height: 72)
                                Circle()
                                    .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
                                    .frame(width: 72, height: 72)
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(Color.yellow)
                                    .symbolEffect(.pulse, options: .repeating)
                            }
                            .padding(.top, 20)

                            Text(L("paywall.headline"))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            // Loss-aversion headline
                            Text(L("paywall.limit_hint"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color(hex: "F87171"))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.bottom, 24)

                        // ─── PLAN TOGGLE ────────────────────────────────────
                        PlanToggle(selectedYearly: $selectedYearly)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)

                        // ─── PRICING CARD ───────────────────────────────────
                        Group {
                            if manager.products.isEmpty {
                                ProgressView().tint(.cyan).padding(40)
                            } else {
                                PricingCard(
                                    selectedYearly: selectedYearly,
                                    yearlyProduct: yearlyProduct,
                                    monthlyProduct: monthlyProduct,
                                    anchorAnnualPrice: anchorAnnualPrice,
                                    yearlyPerMonth: yearlyPerMonth,
                                    savingsAmount: savingsAmount
                                )
                                .padding(.horizontal, 20)
                            }
                        }
                        .padding(.bottom, 20)

                        // ─── CTA BUTTON ─────────────────────────────────────
                        CTAButton(
                            selectedYearly: selectedYearly,
                            product: selectedProduct,
                            isLoading: manager.purchaseInProgress
                        ) {
                            guard let p = selectedProduct else { return }
                            Task { await manager.purchase(p) }
                        }
                        .padding(.horizontal, 20)

                        // Trust signal — directly under CTA (critical placement)
                        HStack(spacing: 16) {
                            Label(L("paywall.trust_cancel"), systemImage: "checkmark.circle.fill")
                            Label(L("paywall.trust_secure"), systemImage: "lock.fill")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "6B7280"))
                        .padding(.top, 10)
                        .padding(.bottom, 24)

                        // ─── FEATURE GRID ───────────────────────────────────
                        FeatureGrid()
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)

                        // ─── FOOTER ─────────────────────────────────────────
                        VStack(spacing: 8) {
                            if let err = manager.errorMessage {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }

                            // Apple verlangt einen klar sichtbaren Restore-Button (Guideline 3.1.1)
                            Button(L("paywall.restore")) {
                                Task { await manager.restorePurchases() }
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.cyan.opacity(0.8))

                            Text(L("paywall.legal"))
                                .font(.system(size: 10))
                                .foregroundStyle(Color(hex: "374151"))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 32)
                        }
                    }
                }
            }
            .navigationTitle(L("paywall.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                if manager.products.isEmpty {
                    await manager.loadProducts()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                        .foregroundStyle(Color(hex: "4A5A70"))
                }
            }
            .overlay {
                if manager.purchaseInProgress {
                    ZStack {
                        Color.black.opacity(0.65).ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView().tint(.cyan).scaleEffect(1.4)
                            Text(L("paywall.loading"))
                                .foregroundStyle(.white)
                                .font(.subheadline)
                        }
                        .padding(32)
                        .background(Color(hex: "0F1A2E"))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
        }
    }
}

// MARK: - Plan Toggle (Yearly / Monthly switch)
private struct PlanToggle: View {
    @Binding var selectedYearly: Bool

    var body: some View {
        HStack(spacing: 0) {
            toggleOption(
                title: L("paywall.yearly"),
                badge: L("paywall.badge_popular"),
                isSelected: selectedYearly,
                isLeft: true
            ) { selectedYearly = true }

            toggleOption(
                title: L("paywall.monthly"),
                badge: nil,
                isSelected: !selectedYearly,
                isLeft: false
            ) { selectedYearly = false }
        }
        .background(Color(hex: "0F1A2E"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
    }

    @ViewBuilder
    private func toggleOption(title: String, badge: String?, isSelected: Bool, isLeft: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.cyan.opacity(0.18) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1.5)
                    )

                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? .white : Color(hex: "6B7280"))

                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.cyan)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(4)
    }
}

// MARK: - Pricing Card
private struct PricingCard: View {
    let selectedYearly: Bool
    let yearlyProduct: Product?
    let monthlyProduct: Product?
    let anchorAnnualPrice: String
    let yearlyPerMonth: String
    let savingsAmount: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    selectedYearly
                        ? LinearGradient(colors: [Color(hex: "0D2137"), Color(hex: "0A1828")], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color(hex: "0F1A2E"), Color(hex: "0F1A2E")], startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(selectedYearly ? Color.cyan.opacity(0.35) : Color.white.opacity(0.07), lineWidth: selectedYearly ? 1.5 : 1)
                )

            VStack(spacing: 0) {
                if selectedYearly {
                    yearlyCard
                } else {
                    monthlyCard
                }
            }
            .padding(20)
        }
        .animation(.easeInOut(duration: 0.25), value: selectedYearly)
    }

    // ── YEARLY ──────────────────────────────────────────────
    var yearlyCard: some View {
        VStack(spacing: 14) {
            // Top row: label + savings badge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("paywall.yearly"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                    Text(L("paywall.badge_2months"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "6EE7B7"))
                }
                Spacer()
                // Savings pill
                if !savingsAmount.isEmpty {
                    Text(L("paywall.saves_amount", savingsAmount))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.cyan)
                        .clipShape(Capsule())
                }
            }

            Divider().background(Color.white.opacity(0.08))

            // Main price block
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    // Anchor: struck-out monthly×12
                    if !anchorAnnualPrice.isEmpty {
                        Text(anchorAnnualPrice)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "6B7280"))
                            .strikethrough(true, color: Color(hex: "EF4444"))
                    }
                    // Actual yearly price
                    if let yearly = yearlyProduct {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(yearly.displayPrice)
                                .font(.system(size: 34, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                            Text(L("paywall.per_year"))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: "9CA3AF"))
                        }
                    }
                }
                Spacer()
                // Per-month equivalent — the "aha" number
                if !yearlyPerMonth.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L("paywall.equiv_per_month"))
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: "6B7280"))
                        Text(yearlyPerMonth)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cyan)
                        Text(L("paywall.per_month"))
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: "6B7280"))
                    }
                }
            }
        }
    }

    // ── MONTHLY ─────────────────────────────────────────────
    var monthlyCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("paywall.monthly"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "9CA3AF"))
                    Text(L("paywall.badge_2months"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "6EE7B7"))
                }
                Spacer()
            }

            Divider().background(Color.white.opacity(0.08))

            HStack(alignment: .bottom) {
                if let monthly = monthlyProduct {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(monthly.displayPrice)
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text(L("paywall.per_month"))
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "9CA3AF"))
                    }
                }
                Spacer()
                // Nudge towards yearly
                Button {
                    // This is handled by the toggle above — just a visual nudge
                } label: {
                    Text(L("paywall.switch_to_yearly"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - CTA Button
private struct CTAButton: View {
    let selectedYearly: Bool
    let product: Product?
    let isLoading: Bool
    let action: () -> Void

    var ctaLabel: String {
        selectedYearly ? L("paywall.cta_yearly") : L("paywall.cta_monthly")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(ctaLabel)
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
            .background(
                selectedYearly
                    ? LinearGradient(colors: [Color.cyan, Color.cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.75)], startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: selectedYearly ? Color.cyan.opacity(0.4) : Color.clear, radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(product == nil || isLoading)
        .animation(.easeInOut(duration: 0.2), value: selectedYearly)
    }
}

// MARK: - Feature Grid
private struct FeatureGrid: View {

    private let features: [(icon: String, text: String, proOnly: Bool)] = [
        ("infinity",                     "paywall.f_unlimited",   true),
        ("car.2.fill",                   "paywall.f_vehicles",    true),
        ("chart.bar.xaxis.ascending",    "paywall.f_analysis",    true),
        ("lightbulb.fill",               "paywall.f_tips",        true),
        ("fuelpump.fill",                "paywall.f_fuel",        false),
        ("speedometer",                  "paywall.f_speed_limit", true),
        ("xmark.circle.fill",            "paywall.f_no_ads",      true),
        ("map.fill",                     "paywall.f_gps",         false),
        ("chart.bar.fill",               "paywall.f_stats",       false),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L("paywall.feature"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 32) {
                    Text(L("paywall.standard"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "6B7280"))
                    Text(L("paywall.pro"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                .padding(.trailing, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.07))

            ForEach(Array(features.enumerated()), id: \.offset) { idx, feature in
                featureRow(icon: feature.icon, key: feature.text, proOnly: feature.proOnly)
                if idx < features.count - 1 {
                    Divider()
                        .background(Color.white.opacity(0.04))
                        .padding(.leading, 16)
                }
            }
        }
        .background(Color(hex: "0A1222"))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06)))
    }

    private func featureRow(icon: String, key: String, proOnly: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(proOnly ? Color.cyan.opacity(0.8) : Color(hex: "6B7280"))
                .frame(width: 20)

            Text(L(key))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 32) {
                // Standard column — show ✗ for pro-only features (loss aversion)
                Image(systemName: proOnly ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(proOnly ? Color.red.opacity(0.55) : Color(hex: "4B5563"))

                // Pro column — always ✓
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.cyan)
            }
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Old ProductButton kept for reference (not used)
private struct ProductButton: View {
    let product: Product
    let isYearly: Bool
    let monthlyProduct: Product?
    let action: () -> Void

    private var savingsLabel: String? {
        guard isYearly, let monthly = monthlyProduct else { return nil }
        let annualIfMonthly = monthly.price * Decimal(12)
        guard annualIfMonthly > 0 else { return nil }
        let savings = Decimal(1) - (product.price / annualIfMonthly)
        guard savings > Decimal(0.01) else { return nil }
        let pct = Int(truncating: (savings * 100) as NSDecimalNumber)
        return LanguageManager.shared.current == .de ? "SPARE \(pct)%" : "SAVE \(pct)%"
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isYearly ? L("paywall.yearly") : L("paywall.monthly"))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                        if let label = savingsLabel {
                            Text(label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.yellow)
                                .clipShape(Capsule())
                        }
                    }
                    Text(isYearly ? L("paywall.yearly_then", product.displayPrice) : L("paywall.monthly_cancel"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isYearly ? Color.yellow : Color.cyan)
            }
            .padding(16)
            .background(isYearly ? Color.yellow.opacity(0.08) : Color(hex: "0F1A2E"))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(
                isYearly ? Color.yellow.opacity(0.4) : Color.cyan.opacity(0.2),
                lineWidth: isYearly ? 1.5 : 1
            ))
        }
        .buttonStyle(.plain)
    }
}
