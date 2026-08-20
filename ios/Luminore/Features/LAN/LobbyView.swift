import LuminoreCore
import SwiftUI
import UIKit

/// The waiting room shown between joining and configuring a match. The host also
/// drives seating here: the roster order becomes the turn order once the game
/// starts, AI seats can be added/removed, and their nicknames can be randomised.
struct LobbyView: View {
    @ObservedObject var session: MatchSessionService

    /// The host reorders seats directly — the list stays in edit mode so every row
    /// always shows its drag handle, with no "reorder"/"done" round trip. Each drop
    /// is applied and broadcast immediately, so there is nothing to confirm.
    /// Reordering only makes sense while the roster is still forming.
    private var isReordering: Bool {
        session.isHost && session.room?.descriptor.stage == .lobby
    }

    var body: some View {
        VStack(spacing: 16) {
            if let room = session.room {
                header(room)
                roster(room)
                if session.isHost {
                    hostControls(room)
                } else {
                    ProgressView("lobby.waitingHost")
                }
            }
        }
        .padding(.vertical)
        .navigationTitle("lobby.title")
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .toolbar {
            if session.isHost, let room = session.room {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("config.ai.easy") { session.addBot(difficulty: .easy) }
                        Button("config.ai.normal") { session.addBot(difficulty: .normal) }
                        Button("config.ai.hard") { session.addBot(difficulty: .hard) }
                    } label: {
                        Label("lobby.addBot", systemImage: "cpu")
                    }
                    .disabled(room.participants.count >= room.descriptor.maximumPlayers)
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ room: RoomSnapshot) -> some View {
        VStack(spacing: 4) {
            Text(room.descriptor.name).font(.largeTitle.bold())
            Label(
                room.descriptor.isPasswordProtected ? "lan.password.protected" : "lan.password.open",
                systemImage: room.descriptor.isPasswordProtected ? "lock.fill" : "lock.open"
            )
            .font(.subheadline).foregroundStyle(.secondary)
            if let code = session.roomCode {
                HStack(spacing: 10) {
                    Text(code)
                        .font(.title3.bold().monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("internet.room.code.copy")
                    ShareLink(item: code) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("internet.room.code.share")
                }
                Text("internet.room.code.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func roster(_ room: RoomSnapshot) -> some View {
        List {
            ForEach(Array(room.participants.enumerated()), id: \.element.id) { index, participant in
                participantRow(index: index, participant: participant)
                    // Only AI seats can be removed, and a list in edit mode offers
                    // the delete control instead of a swipe action.
                    .deleteDisabled(!(session.isHost && participant.kind == .bot))
            }
            .onMove { source, destination in
                session.moveParticipants(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                for index in offsets where room.participants[index].kind == .bot {
                    session.removeBot(id: room.participants[index].id)
                }
            }
            .moveDisabled(!isReordering)
        }
        .listStyle(.plain)
        if session.isHost {
            Text("lobby.order.hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func participantRow(index: Int, participant: Participant) -> some View {
        HStack {
            // The seat number makes the turn order legible while dragging.
            Text("\(index + 1)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Image(systemName: participant.kind == .bot ? "cpu" : "person.crop.circle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(participant.nickname)
                // Random nicknames hide the tier the default names spelled out,
                // so bots always carry their difficulty as a caption.
                if participant.kind == .bot, let difficulty = participant.difficulty {
                    Text(Self.difficultyKey(difficulty))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if participant.kind == .human {
                MedalCountLabel(count: participant.medalCount, compact: true)
            }
            if participant.isHost {
                Image(systemName: "crown.fill").foregroundStyle(.yellow)
            }
            Spacer()
            Circle()
                .fill(participant.isConnected ? Color.green : Color.gray)
                .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private func hostControls(_ room: RoomSnapshot) -> some View {
        // The naming option is meaningless until there is an AI seat to name.
        if room.participants.contains(where: { $0.kind == .bot }) {
            Toggle("lobby.randomBotNames", isOn: Binding(
                get: { session.randomizesBotNames },
                set: { session.setRandomizesBotNames($0) }
            ))
            .padding(.horizontal)
        }
        Button("lobby.configure") { session.enterConfiguration() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(room.participants.filter(\.isConnected).count < 2)
        Text("lobby.minimum")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private static func difficultyKey(_ difficulty: BotDifficulty) -> LocalizedStringKey {
        switch difficulty {
        case .easy: "config.ai.easy"
        case .normal: "config.ai.normal"
        case .hard: "config.ai.hard"
        }
    }
}
