import SwiftUI
import Foundation
import Combine

// MARK: - Changelog Models

struct ChangelogEntry: Codable, Identifiable {
    let version: String
    let date: String
    let entries: [ChangelogItem]

    var id: String { version }
}

struct ChangelogItem: Codable, Identifiable {
    let type: String   // "new" | "fix" | "change" | "pro"
    let text: String

    var id: String { type + text }

    var color: Color {
        switch type {
        case "new":    return Color(hex: "22C55E")
        case "fix":    return Color(hex: "EF4444")
        case "change": return Color(hex: "3B82F6")
        case "pro":    return Color(hex: "F59E0B")
        default:       return Color.secondary
        }
    }

    var label: String {
        switch type {
        case "new":    return L("changelog.type.new")
        case "fix":    return L("changelog.type.fix")
        case "change": return L("changelog.type.change")
        case "pro":    return L("changelog.type.pro")
        default:       return type.uppercased()
        }
    }

    var icon: String {
        switch type {
        case "new":    return "sparkles"
        case "fix":    return "wrench.adjustable.fill"
        case "change": return "arrow.triangle.2.circlepath"
        case "pro":    return "crown.fill"
        default:       return "info.circle"
        }
    }
}

// MARK: - Changelog Service

final class ChangelogService: ObservableObject {

    static let shared = ChangelogService()

    // FIX BUG-004: Die alte URL enthielt einen Commit-Hash – damit zeigt sie immer auf
    // eine eingefrore Revision und wird bei jedem Gist-Update veraltet.
    // Permanente Raw-URL ohne Hash zeigt immer auf den aktuellen Stand des Gists.
    private let remoteURL = "https://gist.githubusercontent.com/AntonMelken/acacbc7ff8c00ee1d9d74a3d4f382e43/raw/gistfile1.txt"

    @Published var entries: [ChangelogEntry] = []
    @Published var hasUnread: Bool = false
    @Published var isLoading: Bool = false

    @AppStorage("lastSeenChangelogVersion") private var lastSeenVersion = ""

    private init() {
        loadCached()
        Task { await fetchRemote() }
    }

    // MARK: - Fetch from GitHub Gist
    func fetchRemote() async {
        guard let url = URL(string: remoteURL),
              !remoteURL.hasPrefix("DEINE") else {
            // Noch nicht konfiguriert — nutze lokale Fallback-Daten
            loadFallback()
            return
        }
        await MainActor.run { isLoading = true }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded   = try JSONDecoder().decode([ChangelogEntry].self, from: data)
            await MainActor.run { [weak self] in
                self?.entries = decoded
                self?.checkUnread()
                self?.isLoading = false
            }
            // Cache lokal
            if let cacheURL = cacheFileURL() {
                try? data.write(to: cacheURL)
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.isLoading = false
            }
        }
    }

    func markRead() {
        if let latest = entries.first?.version {
            lastSeenVersion = latest
        }
        hasUnread = false
    }

    private func checkUnread() {
        hasUnread = entries.first?.version != lastSeenVersion
    }

    private func loadCached() {
        guard let url  = cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ChangelogEntry].self, from: data) else {
            loadFallback()
            return
        }
        entries = decoded
        checkUnread()
    }

    private func cacheFileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("changelog_cache.json")
    }

    // MARK: - Fallback (solange Gist noch nicht eingerichtet)
    private func loadFallback() {
        entries = [
            ChangelogEntry(version: "3.0.0", date: "2026-02", entries: [
                ChangelogItem(type: "new",    text: L("changelog.fb.pause")),
                ChangelogItem(type: "new",    text: L("changelog.fb.fuel_prices")),
                ChangelogItem(type: "new",    text: L("changelog.fb.speed_limit")),
                ChangelogItem(type: "pro",    text: L("changelog.fb.pro_sub")),
                ChangelogItem(type: "fix",    text: L("changelog.fb.speedo_fix")),
                ChangelogItem(type: "fix",    text: L("changelog.fb.standby_fix")),
                ChangelogItem(type: "fix",    text: L("changelog.fb.badge_fix")),
                ChangelogItem(type: "change", text: L("changelog.fb.efficiency")),
                ChangelogItem(type: "change", text: L("changelog.fb.tips_rework")),
            ])
        ]
        checkUnread()
    }
}

// MARK: - Changelog View

struct ChangelogView: View {
    @EnvironmentObject var service: ChangelogService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "080C14").ignoresSafeArea()

                if service.isLoading && service.entries.isEmpty {
                    ProgressView(L("common.loading")).tint(.cyan)
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            ForEach(service.entries) { entry in
                                versionCard(entry)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle(L("changelog.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "080C14"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) {
                        service.markRead()
                        dismiss()
                    }
                    .foregroundStyle(.cyan)
                }
            }
            .onAppear { service.markRead() }
        }
    }

    private func versionCard(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Version-Header
            HStack {
                Text("\(L("changelog.version_prefix")) \(entry.version)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(entry.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().background(Color.white.opacity(0.08))

            // Items
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entry.entries) { item in
                    HStack(alignment: .top, spacing: 10) {
                        // Badge
                        HStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 10))
                            Text(item.label)
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundStyle(item.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(item.color.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(item.color.opacity(0.3), lineWidth: 1))
                        .frame(width: 90, alignment: .leading)

                        Text(item.text)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "8A9BB5"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(hex: "0F1A2E"))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06)))
    }
}
