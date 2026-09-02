import Foundation
import LuminoreCore

/// Host-side bot management: adding/removing AI seats in the lobby, and driving
/// their turns during play. Bots live entirely on the authoritative host — the
/// host computes each bot move locally and broadcasts the result like any other
/// action, so all three transports get bots for free with no protocol changes.
extension MatchSessionService {
    /// Seconds a bot "thinks" before playing, so humans can follow its move.
    private var botThinkDelay: TimeInterval { 0.7 }

    /// UserDefaults key backing the host's random-bot-name preference.
    nonisolated static let randomBotNamesKey = "lobby.randomBotNames"

    // MARK: - Lobby management (host only)

    func addBot(difficulty: BotDifficulty) {
        guard isHost, var room,
              room.descriptor.stage == .lobby || room.descriptor.stage == .configuration
        else { return }
        guard room.participants.count < room.descriptor.maximumPlayers else {
            presentedError = AppLanguage.string("lobby.bot.full")
            return
        }
        let bot = Participant(
            id: UUID(),
            nickname: botNickname(for: difficulty, in: room.participants),
            kind: .bot,
            difficulty: difficulty
        )
        room.participants.append(bot)
        room.descriptor.playerCount = room.participants.count
        room.revision += 1
        self.room = room
        updateAdvertisement()
        broadcastRoom()
    }

    func removeBot(id: UUID) {
        guard isHost, var room,
              let index = room.participants.firstIndex(where: { $0.id == id && $0.kind == .bot })
        else { return }
        room.participants.remove(at: index)
        room.descriptor.playerCount = room.participants.count
        room.revision += 1
        self.room = room
        updateAdvertisement()
        broadcastRoom()
    }

    /// Flip the host's naming preference and re-label the AI seats already in the
    /// room, so the toggle reads as an immediate, visible change rather than a
    /// setting that only affects the next bot.
    func setRandomizesBotNames(_ enabled: Bool) {
        guard randomizesBotNames != enabled else { return }
        randomizesBotNames = enabled
        UserDefaults.standard.set(enabled, forKey: Self.randomBotNamesKey)
        renameBots()
    }

    /// Re-draw every AI nickname under the current preference. Also used as a
    /// re-roll: calling it while randomisation is on hands out a fresh set.
    func renameBots() {
        guard isHost, var room,
              room.descriptor.stage == .lobby || room.descriptor.stage == .configuration,
              room.participants.contains(where: { $0.kind == .bot })
        else { return }
        var taken = Set(room.participants.filter { $0.kind == .human }.map(\.nickname))
        for index in room.participants.indices where room.participants[index].kind == .bot {
            let difficulty = room.participants[index].difficulty ?? .normal
            let name = botNickname(for: difficulty, excluding: taken)
            room.participants[index].nickname = name
            taken.insert(name)
        }
        room.revision += 1
        self.room = room
        broadcastRoom()
    }

    func botNickname(for difficulty: BotDifficulty, in participants: [Participant]) -> String {
        botNickname(for: difficulty, excluding: Set(participants.map(\.nickname)))
    }

    /// Either a playful random name or the difficulty-numbered default, always
    /// distinct from the names already in the room (numbering by "first free
    /// index" keeps it stable when a middle bot is removed).
    private func botNickname(for difficulty: BotDifficulty, excluding taken: Set<String>) -> String {
        if randomizesBotNames { return BotNameGenerator.randomName(excluding: taken) }
        let base: String
        switch difficulty {
        case .easy: base = AppLanguage.string("bot.name.easy")
        case .normal: base = AppLanguage.string("bot.name.normal")
        case .hard: base = AppLanguage.string("bot.name.hard")
        }
        var index = 1
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Turn driving (host only)

    /// If the authoritative game's current seat is a bot, schedule it to compute
    /// and apply its move. Re-entrant safe: cancels any pending bot task and only
    /// acts if the game state is unchanged when the computation finishes. Called
    /// after every broadcast (`scheduleGameBroadcast`), after the opening turn, and
    /// on resume — so it also handles Duel optional sub-actions, where the same bot
    /// remains the current player across multiple invocations.
    func scheduleBotTurnIfNeeded() {
        guard isHost, !isPaused, !isOpeningTurnSelection else { return }
        // A bot must not take its turn while a dig is freezing the table.
        guard mining == nil, pendingMiningPlan == nil else { return }
        guard let state = authoritativeGame, state.status == .playing else { return }
        let currentID = state.currentPlayer.id
        guard let participant = room?.participants.first(where: { $0.id == currentID }),
              participant.kind == .bot else { return }

        let difficulty = participant.difficulty ?? .normal
        let mode = state.configuration.mode
        let revision = state.revision
        let delay = botThinkDelay

        var scriptedAction: GameAction?
        if tutorialOpponentID == currentID, let candidate = tutorialOpponentActions.first {
            var probe = state
            if (try? rules.apply(candidate, playerID: currentID, to: &probe)) != nil {
                scriptedAction = candidate
            } else {
                tutorialOpponentID = nil
                tutorialOpponentActions.removeAll()
            }
        }

        botTask?.cancel()
        botTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            // GameState is a Sendable value type — computing the move off the main
            // actor keeps the UI responsive on slower host devices.
            let action: GameAction
            if let scriptedAction {
                action = scriptedAction
            } else {
                let controller = BotFactory.make(for: mode)
                action = controller.chooseAction(state: state, playerID: currentID, difficulty: difficulty)
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard self.isHost, !self.isPaused, !self.isOpeningTurnSelection,
                      let live = self.authoritativeGame, live.status == .playing,
                      live.revision == revision, live.currentPlayer.id == currentID
                else { return }
                if scriptedAction != nil,
                   self.tutorialOpponentID == currentID,
                   self.tutorialOpponentActions.first == action {
                    self.tutorialOpponentActions.removeFirst()
                }
                self.apply(action, from: currentID, allowsPass: true)
            }
        }
    }
}
