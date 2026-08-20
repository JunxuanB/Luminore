import LuminoreCore
import SwiftUI

/// Maps each seat of a saved match onto a player present in the current room.
/// Seats keep their turn order, so seat *n* here is seat *n* of the restored game.
/// Defaults to pairing identical UUIDs — the common case where the same people
/// came back — and lets the host override any pairing.
struct SaveSeatMatchView: View {
    @ObservedObject var session: MatchSessionService
    let record: GameSaveRecord
    let onLoaded: () -> Void
    @State private var assignment: [UUID: UUID] = [:]

    private var savedSeats: [Participant] { record.seats }
    private var currentPlayers: [Participant] {
        session.room?.participants.filter(\.isConnected) ?? []
    }

    /// Players picked for more than one seat. Any of these blocks the load.
    private var duplicated: Set<UUID> {
        var seen: Set<UUID> = []
        var repeated: Set<UUID> = []
        for id in savedSeats.compactMap({ assignment[$0.id] }) {
            if !seen.insert(id).inserted { repeated.insert(id) }
        }
        return repeated
    }

    private var isComplete: Bool {
        savedSeats.allSatisfy { assignment[$0.id] != nil } && duplicated.isEmpty
    }

    var body: some View {
        Form {
            Section {
                ForEach(savedSeats) { seat in
                    seatRow(seat)
                }
            } header: {
                Text("save.match.seats")
            } footer: {
                Text("save.match.hint")
            }

            Section {
                Button("save.match.confirm") {
                    session.loadSavedGame(record, assignment: assignment)
                    onLoaded()
                }
                .frame(maxWidth: .infinity)
                .disabled(!isComplete)
            } footer: {
                if !duplicated.isEmpty {
                    Text("save.match.duplicate").foregroundStyle(.red)
                } else if !isComplete {
                    Text("save.match.unassigned")
                }
            }
        }
        .navigationTitle("save.match.title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: applyDefaultAssignmentIfNeeded)
    }

    @ViewBuilder
    private func seatRow(_ seat: Participant) -> some View {
        let chosenID = assignment[seat.id]
        let chosen = currentPlayers.first { $0.id == chosenID }
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(verbatim: seat.nickname)
                } icon: {
                    Image(systemName: seat.kind == .bot ? "cpu" : "person.crop.circle.fill")
                }
                Text("save.seat.original \(String(seat.id.uuidString.prefix(8)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                ForEach(currentPlayers) { player in
                    Button {
                        assignment[seat.id] = player.id
                    } label: {
                        Label(
                            player.nickname,
                            systemImage: player.kind == .bot ? "cpu" : "person.crop.circle.fill"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(chosen?.nickname ?? AppLanguage.string("save.match.pick"))
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundStyle(
                    chosenID.map { duplicated.contains($0) ? Color.red : .accentColor } ?? .accentColor
                )
            }
        }
    }

    /// Same-UUID pairs first, then fill the remaining seats with whoever is left,
    /// in order — so a room of all-new players still arrives fully assigned.
    private func applyDefaultAssignmentIfNeeded() {
        guard assignment.isEmpty else { return }
        var remaining = currentPlayers
        var result: [UUID: UUID] = [:]
        for seat in savedSeats {
            guard let index = remaining.firstIndex(where: { $0.id == seat.id }) else { continue }
            result[seat.id] = remaining[index].id
            remaining.remove(at: index)
        }
        for seat in savedSeats where result[seat.id] == nil {
            guard !remaining.isEmpty else { break }
            result[seat.id] = remaining.removeFirst().id
        }
        assignment = result
    }
}
