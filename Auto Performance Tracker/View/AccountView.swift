import SwiftUI
import AuthenticationServices

// ============================================================
// AccountView.swift
// Auto Performance Tracker · Account-Verwaltung + DSGVO
// Unterstützt: E-Mail, Apple Sign-In, Google, Anonym
// ============================================================

struct AccountView: View {

    // Daten werden von der übergeordneten View übergeben,
    // um den @Query / import Supabase Namenskonflikt zu vermeiden.
    var trips:    [Trip]    = []
    var vehicles: [VehicleProfile] = []

    @EnvironmentObject private var supabase: SupabaseManager

    @State private var selectedTab: AccountTab = .login

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()

                switch supabase.authState {
                case .unknown:
                    ProgressView()
                        .tint(.cyan)

                case .signedOut:
                    AuthView(selectedTab: $selectedTab)

                case .anonymous:
                    AnonymousAccountView()

                case .signedIn:
                    SignedInAccountView(trips: trips, vehicles: vehicles)
                }
            }
            .navigationTitle(L("account.title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Tab-Auswahl
// ─────────────────────────────────────────────
enum AccountTab: String, CaseIterable {
    case login     = "login"
    case register  = "register"

    var localizedName: String {
        switch self {
        case .login:    return L("account.tab.login")
        case .register: return L("account.tab.register")
        }
    }
}

// ============================================================
// MARK: - AUTH VIEW (nicht angemeldet)
// ============================================================
struct AuthView: View {
    @Binding var selectedTab: AccountTab
    @EnvironmentObject private var supabase: SupabaseManager

    // Formular
    @State private var email        = ""
    @State private var password     = ""
    @State private var name         = ""
    @State private var confirmPass  = ""
    @State private var isLoading    = false
    @State private var showError    = false
    @State private var errorText    = ""
    @State private var showReset    = false
    @State private var showPrivacy  = false
    @State private var showImpressum = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {

                // Logo & Headline
                VStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.cyan)
                    Text(L("account.headline"))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text(L("account.subtitle"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                // ── E-Mail-Bestätigungs-Banner ──
                if supabase.needsEmailConfirmation {
                    VStack(spacing: 10) {
                        Image(systemName: "envelope.badge.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.cyan)
                        Text(L("account.email_confirm"))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text(L("account.email_confirm_msg"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L("account.resend")) {
                            Task { try? await supabase.resetPassword(email: email) }
                        }
                        .font(.footnote)
                        .foregroundStyle(.cyan)
                    }
                    .padding(16)
                    .background(Color.cyan.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Tab-Picker
                Picker("", selection: $selectedTab) {
                    ForEach(AccountTab.allCases, id: \.self) {
                        Text($0.localizedName)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Fehlermeldung
                if showError {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                // ── Formular ──
                VStack(spacing: 14) {
                    if selectedTab == .register {
                        AuthTextField(title: L("account.field.name"), systemImage: "person", text: $name)
                    }
                    AuthTextField(title: L("account.field.email"), systemImage: "envelope", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    AuthTextField(title: L("account.field.password"), systemImage: "lock", text: $password, isSecure: true)
                        .textContentType(selectedTab == .register ? .newPassword : .password)
                    if selectedTab == .register {
                        AuthTextField(title: L("account.field.confirm_pw"), systemImage: "lock.rotation", text: $confirmPass, isSecure: true)
                            .textContentType(.newPassword)
                    }
                }
                .padding(.horizontal)

                // ── Haupt-Button ──
                Button(action: handleEmailAuth) {
                    HStack {
                        if isLoading {
                            ProgressView().tint(.black)
                        } else {
                            Text(selectedTab == .login ? L("account.login") : L("account.create"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(.cyan)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isLoading || email.isEmpty || password.isEmpty)
                .padding(.horizontal)

                // ── Passwort vergessen ──
                if selectedTab == .login {
                    Button(L("account.forgot_pw")) { showReset = true }
                        .font(.footnote)
                        .foregroundStyle(.cyan.opacity(0.8))
                }

                // ── Divider ──
                HStack {
                    Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.1))
                    Text(L("common.or")).font(.footnote).foregroundStyle(.secondary)
                    Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.1))
                }
                .padding(.horizontal)

                // ── Apple Sign-In ──
                SignInWithAppleButton(.signIn) { request in
                    let appleRequest = SupabaseManager.shared.startAppleSignIn()
                    request.requestedScopes = appleRequest.requestedScopes
                    request.nonce           = appleRequest.nonce
                } onCompletion: { result in
                    Task { await SupabaseManager.shared.handleAppleSignIn(result: result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                // Apple Sign-In Fehler reaktiv anzeigen (errorMessage wird async gesetzt)
                .onChange(of: supabase.errorMessage) { _, msg in
                    if let msg, !msg.isEmpty { showErrorMessage(msg); supabase.errorMessage = nil }
                }

                // ── Google Sign-In ──
                Button(action: handleGoogle) {
                    HStack(spacing: 10) {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.red)
                        Text(L("account.google"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
                .padding(.horizontal)

                // ── Anonym ──
                Button(action: handleAnonymous) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.fill.questionmark")
                        Text(L("account.guest"))
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }

                // ── Datenschutzhinweis ──
                VStack(spacing: 6) {
                    Text(L("account.tos"))
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 16) {
                        Button(L("account.privacy_link")) {
                            showPrivacy = true
                        }
                        .font(.caption2)
                        .foregroundStyle(.cyan.opacity(0.8))

                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.4))

                        Button(L("account.impressum_link")) {
                            showImpressum = true
                        }
                        .font(.caption2)
                        .foregroundStyle(.cyan.opacity(0.8))
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .alert(L("account.reset_pw"), isPresented: $showReset) {
            TextField(L("account.reset_email"), text: $email)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("account.reset_action")) {
                Task {
                    try? await SupabaseManager.shared.resetPassword(email: email)
                }
            }
            Button(L("common.cancel"), role: .cancel) { }
        } message: {
            Text(L("account.reset_msg"))
        }
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .animation(.easeInOut(duration: 0.2), value: showError)
        .sheet(isPresented: $showPrivacy)   { PrivacyView() }
        .sheet(isPresented: $showImpressum) { ImpressumView() }
    }

    // ── Aktionen ──
    private func handleEmailAuth() {
        guard validate() else { return }
        isLoading = true
        hideError()
        Task {
            do {
                if selectedTab == .login {
                    try await supabase.signInWithEmail(email: email, password: password)
                } else {
                    try await supabase.signUpWithEmail(email: email, password: password, name: name)
                }
            } catch {
                showErrorMessage(error.localizedDescription)
            }
            isLoading = false
        }
    }

    private func handleGoogle() {
        // Robusterer ViewController-Lookup (keyWindow ist deprecated ab iOS 15)
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            showErrorMessage(L("account.error.google_vc"))
            return
        }

        // Den obersten aktiven ViewController finden
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        isLoading = true
        Task {
            await supabase.signInWithGoogle(presenting: topVC)
            isLoading = false
            if let err = supabase.errorMessage {
                showErrorMessage(err)
                supabase.errorMessage = nil
            }
        }
    }

    private func handleAnonymous() {
        Task {
            do {
                try await supabase.signInAnonymously()
            } catch {
                // Typischer Fehler: Anonymous sign-ins sind im Supabase-Dashboard deaktiviert.
                // Lösung: Dashboard → Authentication → Sign In / Up → Anonymous sign-ins → Enable
                let msg = error.localizedDescription.contains("disabled")
                    ? L("account.error.guest_disabled")
                    : error.localizedDescription
                showErrorMessage(msg)
            }
        }
    }

    private func validate() -> Bool {
        if email.isEmpty || password.isEmpty { showErrorMessage(L("account.error.required")); return false }
        if selectedTab == .register && password != confirmPass { showErrorMessage(L("account.error.mismatch")); return false }
        if selectedTab == .register && password.count < 8 { showErrorMessage(L("account.error.short_pw")); return false }
        return true
    }

    private func showErrorMessage(_ msg: String) {
        errorText = msg; showError = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { hideError() }
    }
    private func hideError() { showError = false }
}

// ─────────────────────────────────────────────
// MARK: - Hilfskomponente: TextField
// ─────────────────────────────────────────────
struct AuthTextField: View {
    let title:       String
    let systemImage: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.cyan)
                .frame(width: 20)
            if isSecure {
                SecureField(title, text: $text)
            } else {
                TextField(title, text: $text)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .foregroundStyle(.white)
    }
}

// ============================================================
// MARK: - ANONYM ANGEMELDET
// ============================================================
struct AnonymousAccountView: View {
    @EnvironmentObject private var supabase: SupabaseManager

    @State private var email    = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var showUpgrade = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "person.fill.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(L("anon.title"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text(L("anon.message"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                // Upgrade-Banner
                Button(action: { showUpgrade = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "icloud.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("anon.upgrade"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(L("anon.upgrade_note"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color.cyan.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(.horizontal)

                Button(L("anon.sign_out")) {
                    Task { await supabase.signOut() }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeAnonymousView()
        }
    }
}

// ============================================================
// MARK: - GASTKONTO UPGRADE (volles Auth-UI, identisch zum Login)
// ============================================================
struct UpgradeAnonymousView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var supabase: SupabaseManager
    @State private var selectedTab: AccountTab = .register

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "icloud.and.arrow.up.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.cyan)
                                .padding(.top, 24)
                            Text(L("anon.upgrade_title"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            Text(L("anon.upgrade_message"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal)

                        // Das gleiche Auth-UI wie beim Start
                        AuthView(selectedTab: $selectedTab)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
        // Wenn Auth erfolgreich → Sheet automatisch schließen
        .onChange(of: supabase.authState) { _, state in
            if case .signedIn = state { dismiss() }
        }
    }
}

// ============================================================
// MARK: - ANGEMELDET: Account-Dashboard
// ============================================================
struct SignedInAccountView: View {
    let trips:    [Trip]
    let vehicles: [VehicleProfile]

    @EnvironmentObject private var supabase: SupabaseManager
    @EnvironmentObject private var subscription: SubscriptionManager

    @State private var isSyncing        = false
    @State private var showDeleteAlert  = false
    @State private var showExportSheet  = false
    @State private var exportData:      Data?
    @State private var showSignOutAlert = false
    @State private var showEditProfile  = false

    var body: some View {
        List {

            // MARK: Profil-Header (tippbar → Edit-Sheet)
            Section {
                Button(action: { showEditProfile = true }) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(AvatarColorKey.currentColor.opacity(0.18))
                                .frame(width: 60, height: 60)
                            Text(initials)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(AvatarColorKey.currentColor)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(supabase.displayName.isEmpty ? L("signed.user") : supabase.displayName)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                if subscription.isPro {
                                    Text(L("signed.pro_account"))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.yellow)
                                        .clipShape(Capsule())
                                }
                            }
                            if case .signedIn(_, let provider) = supabase.authState {
                                Label(providerLabel(provider), systemImage: providerIcon(provider))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !supabase.userEmail.isEmpty {
                                Text(supabase.userEmail)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary.opacity(0.7))
                            }
                        }
                        Spacer()
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.white.opacity(0.04))

            // MARK: Statistiken
            Section(L("signed.my_stats")) {
                HStack(spacing: 0) {
                    statCell(
                        value: "\(trips.count)",
                        label: L("signed.trips"),
                        icon: "car.fill",
                        color: .cyan
                    )
                    Divider().frame(height: 40)
                    statCell(
                        value: String(format: "%.0f km", trips.reduce(0) { $0 + $1.distanceKm }),
                        label: L("signed.total"),
                        icon: "road.lanes",
                        color: .blue
                    )
                    Divider().frame(height: 40)
                    statCell(
                        value: "\(vehicles.count)",
                        label: L("signed.vehicles"),
                        icon: "car.2.fill",
                        color: .purple
                    )
                }
            }
            .listRowBackground(Color.white.opacity(0.04))

            // MARK: Sync-Status & Cloud-Sync Button
            Section(L("signed.cloud_sync")) {
                // Cloud-Sync an/aus Toggle
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "cloudSyncEnabled") },
                    set: { UserDefaults.standard.set($0, forKey: "cloudSyncEnabled") }
                )) {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.fill")
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("signed.auto_sync"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                            Text(L("signed.auto_sync_desc"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.cyan)
                .listRowBackground(Color.white.opacity(0.04))

                HStack {
                    Image(systemName: syncStatusIcon)
                        .foregroundStyle(syncStatusColor)
                    Text(syncStatusText)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .listRowBackground(Color.white.opacity(0.04))

                Button(action: triggerSync) {
                    HStack {
                        if isSyncing {
                            ProgressView().tint(.cyan)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.cyan)
                        }
                        Text(isSyncing ? L("signed.syncing") : L("signed.sync_now"))
                            .foregroundStyle(isSyncing ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
                        Spacer()
                        Text(L("signed.trips_count", trips.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isSyncing)
                .listRowBackground(Color.white.opacity(0.04))
            }

            // MARK: DSGVO
            Section(L("signed.gdpr")) {
                Button(action: triggerExport) {
                    Label(L("signed.export_all"), systemImage: "square.and.arrow.up")
                        .foregroundStyle(.cyan)
                }
                .listRowBackground(Color.white.opacity(0.04))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("signed.your_rights"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L("signed.rights_text"))
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .listRowBackground(Color.white.opacity(0.04))

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label(L("signed.delete_account"), systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .listRowBackground(Color.white.opacity(0.04))
            }

            // MARK: Abmelden
            Section {
                Button(role: .destructive) {
                    showSignOutAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Text(L("signed.sign_out"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.red)
                        Spacer()
                    }
                }
                .listRowBackground(Color.white.opacity(0.04))
            }

            // MARK: App-Info
            Section {
                Text(L("signed.server_info"))
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(hex: "080C14"))
        .listStyle(.insetGrouped)
        .alert(L("signed.delete_confirm"), isPresented: $showDeleteAlert) {
            Button(L("signed.delete_request"), role: .destructive) {
                Task { try? await supabase.requestAccountDeletion() }
            }
            Button(L("common.cancel"), role: .cancel) { }
        } message: {
            Text(L("signed.delete_message"))
        }
        .alert(L("signed.sign_out_confirm"), isPresented: $showSignOutAlert) {
            Button(L("signed.sign_out"), role: .destructive) {
                Task { await supabase.signOut() }
            }
            Button(L("common.cancel"), role: .cancel) { }
        }
        .sheet(isPresented: $showExportSheet) {
            if let data = exportData {
                ExportDataSheet(data: data)
            }
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet()
        }
    }

    // ── Stat-Zelle ──
    private func statCell(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // ── Sync auslösen ──
    private func triggerSync() {
        isSyncing = true
        Task {
            await supabase.syncTrips(trips)
            await supabase.syncVehicles(vehicles)
            isSyncing = false
        }
    }

    // ── DSGVO-Export auslösen ──
    private func triggerExport() {
        Task {
            exportData = await supabase.exportMyData()
            if exportData != nil { showExportSheet = true }
        }
    }

    // ── Hilfsmethoden ──
    private var initials: String {
        supabase.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0) } }
            .joined()
            .uppercased()
            .prefix(2)
            .description
    }

    private func providerLabel(_ p: String) -> String {
        switch p {
        case "apple":  return "Apple"
        case "google": return "Google"
        default:       return "E-Mail"
        }
    }

    private func providerIcon(_ p: String) -> String {
        switch p {
        case "apple":  return "apple.logo"
        case "google": return "g.circle.fill"
        default:       return "envelope.fill"
        }
    }

    private var syncStatusIcon: String {
        switch supabase.syncState {
        case .success:  return "checkmark.icloud.fill"
        case .error:    return "exclamationmark.icloud.fill"
        case .syncing:  return "arrow.triangle.2.circlepath.icloud.fill"
        default:        return "icloud.fill"
        }
    }

    private var syncStatusColor: Color {
        switch supabase.syncState {
        case .success:  return .green
        case .error:    return .red
        case .syncing:  return .cyan
        default:        return .secondary
        }
    }

    private var syncStatusText: String {
        switch supabase.syncState {
        case .success(let date):
            let f = DateFormatter()
            f.timeStyle = .short
            f.locale    = LanguageManager.shared.locale
            return L("signed.last_sync", f.string(from: date))
        case .error(let msg):
            return L("signed.sync_error", msg)
        case .syncing:
            return L("signed.sync_active")
        default:
            return L("signed.not_synced")
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Profil bearbeiten Sheet
// ─────────────────────────────────────────────
// ─────────────────────────────────────────────
// MARK: - Avatar-Farbe (global gespeichert)
// ─────────────────────────────────────────────
struct AvatarColorKey {
    static let userDefaultsKey = "avatarColorIndex"
    static let colors: [(Color, String)] = [
        (.cyan,   "color.cyan"),
        (.blue,   "color.blue"),
        (.purple, "color.purple"),
        (.pink,   "color.pink"),
        (.orange, "color.orange"),
        (.green,  "color.green"),
        (.yellow, "color.yellow"),
        (.red,    "color.red")
    ]
    static var currentIndex: Int {
        get { UserDefaults.standard.integer(forKey: userDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }
    static var currentColor: Color { colors[currentIndex].0 }
}

struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var supabase: SupabaseManager

    @State private var nameInput        = ""
    @State private var isSaving         = false
    @State private var showError        = false
    @State private var errorText        = ""
    @State private var selectedColorIdx = AvatarColorKey.currentIndex
    @State private var showColorPicker  = false

    private var selectedColor: Color { AvatarColorKey.colors[selectedColorIdx].0 }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {

                        // ── Avatar (tippbar) ──
                        VStack(spacing: 10) {
                            Button(action: { withAnimation(.spring(response: 0.3)) { showColorPicker.toggle() } }) {
                                ZStack {
                                    Circle()
                                        .fill(selectedColor.opacity(0.2))
                                        .frame(width: 96, height: 96)
                                    Text(initials)
                                        .font(.system(size: 38, weight: .bold))
                                        .foregroundStyle(selectedColor)
                                    // Kamera-Badge
                                    Circle()
                                        .fill(Color(hex: "1C2A3A"))
                                        .frame(width: 30, height: 30)
                                        .overlay(
                                            Image(systemName: "paintpalette.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(selectedColor)
                                        )
                                        .offset(x: 30, y: 30)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 16)

                            Text(L("edit.change_color"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        // ── Farbauswahl ──
                        if showColorPicker {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L("edit.avatar_color"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                                    ForEach(Array(AvatarColorKey.colors.enumerated()), id: \.offset) { idx, pair in
                                        Button(action: {
                                            withAnimation(.spring(response: 0.25)) {
                                                selectedColorIdx = idx
                                            }
                                        }) {
                                            ZStack {
                                                Circle()
                                                    .fill(pair.0.opacity(0.25))
                                                    .frame(width: 52, height: 52)
                                                Circle()
                                                    .fill(pair.0)
                                                    .frame(width: 32, height: 32)
                                                if selectedColorIdx == idx {
                                                    Circle()
                                                        .strokeBorder(.white, lineWidth: 2.5)
                                                        .frame(width: 52, height: 52)
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 12, weight: .bold))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // ── Name-Feld ──
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("edit.display_name"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            HStack(spacing: 12) {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(selectedColor)
                                    .frame(width: 20)
                                TextField(L("edit.name_placeholder"), text: $nameInput)
                                    .foregroundStyle(.white)
                                    .autocorrectionDisabled()
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedColor.opacity(0.35), lineWidth: 1))
                        }
                        .padding(.horizontal)

                        // ── E-Mail (schreibgeschützt) ──
                        if !supabase.userEmail.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("edit.email_label"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                HStack(spacing: 12) {
                                    Image(systemName: "envelope.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    Text(supabase.userEmail)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary.opacity(0.5))
                                }
                                .padding(14)
                                .background(Color.white.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                            }
                            .padding(.horizontal)
                        }

                        if showError {
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle(L("edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().tint(.cyan)
                        } else {
                            Text(L("common.save"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selectedColor)
                        }
                    }
                    .disabled(isSaving || nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { nameInput = supabase.displayName }
    }

    private var initials: String {
        nameInput.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0) } }
            .joined()
            .uppercased()
            .prefix(2)
            .description
    }

    private func save() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Farbe lokal speichern
        AvatarColorKey.currentIndex = selectedColorIdx
        isSaving = true
        Task {
            do {
                try await supabase.updateDisplayName(trimmed)
                dismiss()
            } catch {
                errorText = L("edit.save_failed", error.localizedDescription)
                showError = true
                isSaving  = false
            }
        }
    }
}


// ─────────────────────────────────────────────
// MARK: - DSGVO Export-Sheet
// ─────────────────────────────────────────────
struct ExportDataSheet: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text(L("export.ready"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text(L("export.message"))
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    ShareLink(
                        item:    data,
                        preview: SharePreview(L("export.filename_gdpr"),
                                              image: Image(systemName: "doc.fill"))
                    ) {
                        Label(L("export.save_json"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(.cyan)
                            .foregroundStyle(.black)
                            .font(.system(size: 16, weight: .semibold))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    Text(L("export.gdpr_note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .navigationTitle(L("export.nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────
#Preview {
    AccountView()
        .preferredColorScheme(.dark)
}
