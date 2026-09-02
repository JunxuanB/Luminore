import Foundation
import LuminoreCore
import SwiftData

// MARK: - Save & load (host authority)

extension MatchSessionService {
    enum SaveLoadError: LocalizedError {
        case playerCountMismatch(expected: Int, actual: Int)
        case incompleteAssignment

        var errorDescription: String? {
            switch self {
            case .playerCountMismatch:
                AppLanguage.string("save.error.playerCountMismatch")
            case .incompleteAssignment:
                AppLanguage.string("save.error.incompleteAssignment")
            }
        }
    }

    /// Host: serialize the whole match to a new `GameSaveRecord`, tell clients the
    /// session ended, and tear down. Loadable later from the configuration screen
    /// via `loadSavedGame(_:assignment:)`.
    func saveAndEndMatch(context: ModelContext) {
        guard isHost else { return }
        // Settle any open dig before the snapshot is written, so the buried token
        // is back in the pool and the save never replays mid-window.
        abortMining()
        guard let state = authoritativeGame, let room else { return }
        do {
            // Seats are keyed by position: `currentPlayerIndex` and
            // `startingPlayerIndex` are positional, so the roster must be written in
            // `state.players` order, not room order.
            let seats: [Participant] = state.players.map { player in
                room.participants.first(where: { $0.id == player.id })
                    ?? Participant(
                        id: player.id,
                        nickname: player.nickname,
                        kind: player.kind,
                        medalCount: player.medalCount
                    )
            }
            context.insert(GameSaveRecord(
                ownerKey: localID.uuidString,
                gameID: state.gameID,
                roomName: room.descriptor.name,
                modeRawValue: state.configuration.mode.rawValue,
                playerCount: state.players.count,
                currentSeatNickname: state.currentPlayer.nickname,
                statePayload: try JSONEncoder().encode(state),
                seatsPayload: try JSONEncoder().encode(seats)
            ))
            try context.save()
        } catch {
            presentedError = error.localizedDescription
            return
        }
        broadcast(.sessionSuspended)
        finishSuspendingAfterFlush()
    }

    /// Give suspend frames a moment to flush before cancelling connections. The
    /// task intentionally retains the session: SwiftUI dismisses the flow as soon
    /// as `wasSuspended` flips, and a weak capture could otherwise skip cleanup.
    func finishSuspendingAfterFlush() {
        Task { [self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // Tear down first, then let SwiftUI dismiss. This prevents an immediate
            // tap on a new room from racing a still-existing Internet room (409).
            leave()
            wasSuspended = true
        }
    }

    /// Host: start the current room's match from a saved game instead of a fresh
    /// deal. `assignment` maps each saved seat's original id to the id of the
    /// present participant that takes it over; the host builds it in the seat
    /// matching screen. The saved `GameConfiguration` wins over whatever the
    /// configuration screen was showing.
    func loadSavedGame(_ record: GameSaveRecord, assignment: [UUID: UUID]) {
        guard isHost, var room else { return }
        abortMining()
        lastMiningRound = nil
        let connected = room.participants.filter(\.isConnected)
        let state: GameState
        let seating: [Participant]
        do {
            var loaded = try JSONDecoder().decode(GameState.self, from: record.statePayload)
            guard loaded.players.count == connected.count else {
                throw SaveLoadError.playerCountMismatch(
                    expected: loaded.players.count,
                    actual: connected.count
                )
            }
            // Resolve every seat up front: the assignment must be a bijection onto
            // the present players, otherwise two seats would share one identity.
            let takeovers: [Participant] = try loaded.players.map { player in
                guard let newID = assignment[player.id],
                      let participant = connected.first(where: { $0.id == newID })
                else { throw SaveLoadError.incompleteAssignment }
                return participant
            }
            guard Set(takeovers.map(\.id)).count == takeovers.count else {
                throw SaveLoadError.incompleteAssignment
            }

            // Duel seats are a parallel array keyed by the same ids. Map them by
            // their *original* ids before any mutation — rewriting ids in place
            // would let a later lookup hit a seat that was already rebound (e.g.
            // when two players swap seats).
            let duelOrder: [Int]? = loaded.duel.map { duel in
                loaded.players.map { player in
                    duel.players.firstIndex(where: { $0.id == player.id }) ?? 0
                }
            }

            for index in loaded.players.indices {
                let participant = takeovers[index]
                var seat = loaded.players[index].reseated(
                    as: participant.id,
                    nickname: participant.nickname,
                    medalCount: participant.medalCount
                )
                // `reseated` carries over the *saved* seat's kind, but a human may
                // be taking over a bot seat (or the reverse) — the present roster
                // is the truth about who plays it now.
                seat.kind = participant.kind
                seat.isConnected = true
                loaded.players[index] = seat
            }
            if let duelOrder, loaded.duel != nil {
                for (playerIndex, duelIndex) in duelOrder.enumerated() {
                    loaded.duel?.players[duelIndex].id = takeovers[playerIndex].id
                }
            }
            state = loaded
            seating = takeovers
        } catch {
            presentedError = error.localizedDescription
            return
        }

        authoritativeGame = state
        // The save's configuration wins: it decides the ruleset the state was
        // produced under, and it is what clients read to pick a board view.
        room.configuration = state.configuration
        room.descriptor.maximumPlayers = state.configuration.mode == .duel ? 2 : 7
        // Keep the roster in turn order so seat n of the room is seat n of the game.
        room.participants = seating
        room.descriptor.playerCount = seating.count
        room.descriptor.stage = .playing
        room.revision += 1
        self.room = room

        // No opening roulette: the saved state already knows whose turn it is, and
        // a live selection would gate `apply`/`submit`/the bot driver for 5s.
        openingTurnSelection = nil
        phase = .game
        clearPauseState()
        updateAdvertisement()
        broadcastRoom()
        scheduleTurnTimer()
        broadcastGame()
        scheduleBotTurnIfNeeded()
    }
}
