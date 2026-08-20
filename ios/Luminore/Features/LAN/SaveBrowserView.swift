import LuminoreCore
import SwiftData
import SwiftUI

/// Host-only list of this profile's saved matches, shown from the configuration
/// screen. A save can only be loaded into a room holding exactly as many players
/// as it has seats; mismatched saves stay visible (and deletable) but inert.
struct SaveBrowserView: View {
    @ObservedObject var session: MatchSessionService
    @Query private var saves: [GameSaveRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: GameSaveRecord?

    init(session: MatchSessionService, ownerKey: String) {
        self.session = session
        _saves = Query(
            filter: #Predicate<GameSaveRecord> { $0.ownerKey == ownerKey },
            sort: \.savedAt,
            order: .reverse
        )
    }

    /// The seats a save would be loaded onto. Bots count: they can hold a seat too.
    private var currentPlayers: [Participant] {
        session.room?.participants.filter(\.isConnected) ?? []
    }

    var body: some View {
        Group {
            if saves.isEmpty {
                ContentUnavailableView(
                    "save.empty",
                    systemImage: "tray",
                    description: Text("save.empty.detail")
                )
            } else {
                List {
                    ForEach(saves) { save in
                        row(for: save)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDeletion = save
                                } label: {
                                    Label("save.delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("save.browser.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("common.cancel") { dismiss() }
            }
        }
        .confirmationDialog(
            "save.delete.confirm",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("save.delete", role: .destructive) {
                if let pendingDeletion {
                    modelContext.delete(pendingDeletion)
                    try? modelContext.save()
                }
                pendingDeletion = nil
            }
            Button("common.cancel", role: .cancel) { pendingDeletion = nil }
        }
    }

    @ViewBuilder
    private func row(for save: GameSaveRecord) -> some View {
        if save.playerCount == currentPlayers.count, !save.seats.isEmpty {
            NavigationLink {
                SaveSeatMatchView(session: session, record: save, onLoaded: { dismiss() })
            } label: {
                SaveSummary(save: save, mismatchAgainst: nil)
            }
        } else {
            SaveSummary(save: save, mismatchAgainst: currentPlayers.count)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SaveSummary: View {
    let save: GameSaveRecord
    /// Non-nil when this save can't be loaded into the current room.
    let mismatchAgainst: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: save.roomName).font(.headline)
                Spacer()
                Text(save.savedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label(save.gameMode.titleKey, systemImage: "gamecontroller")
                Label("save.playerCount \(save.playerCount)", systemImage: "person.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("save.currentTurn \(save.currentSeatNickname)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(verbatim: save.seats.map(\.nickname).joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            if let mismatchAgainst {
                Label(
                    "save.playerCountMismatch \(save.playerCount) \(mismatchAgainst)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }
}

extension GameMode {
    var titleKey: LocalizedStringKey {
        switch self {
        case .standard: "config.mode.standard"
        case .silkRoad: "config.mode.silkRoad"
        case .duel: "config.mode.duel"
        }
    }
}
