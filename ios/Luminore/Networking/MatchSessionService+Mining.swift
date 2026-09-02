import Foundation
import LuminoreCore

/// The rock count, on its own observable object.
///
/// It changes up to ten times a second — every local tap plus every 5 Hz update
/// from the miner. As a `@Published` on `MatchSessionService` that re-ran
/// `GameBoardView.body` each time, rebuilding the market, the opponent carousel
/// and both anchor-preference passes behind a cover nobody can see through.
/// Only the mining overlay observes this.
@MainActor
final class MiningPileModel: ObservableObject {
    @Published var remaining = MiningBalance.pileTotal
}

/// 挖矿: a seven-second tug-of-war that can fire after a player's turn.
///
/// **Why the trigger lives here and not in the ruleset.** `StandardBot` runs
/// `rules.apply` thousands of times per turn to score candidate moves, so a
/// random trigger inside `completeTurn` would make its simulation diverge from
/// the real apply. Keeping the feature at the session layer leaves the engine
/// pure, and leaves `GameState` — and every existing save file — untouched.
///
/// **Who owns the rock count: the miner's device.** Not the host. The miner's
/// own taps apply instantly with no round trip and are never corrected
/// afterwards, so the pile can't rubber-band under the one finger that matters.
/// Opponents' throws arrive as `.miningTap` counts and the miner's device folds
/// them in; it publishes the running count at 5 Hz purely so everyone else has
/// something to watch, and reports its final count as `.miningOutcome` for the
/// host to settle. The host keeps a fallback verdict in case that never arrives.
///
/// The trade this makes: an opponent's rocks now take two hops (client → host →
/// miner) instead of one, so rocks thrown in the last fraction of a second may
/// not land. That favours the miner slightly, and it is the price of the miner's
/// screen always telling the truth about their own dig.
///
/// **Why taps never ride the snapshot.** A snapshot is several KB; broadcasting
/// one 5× a second would stall the match. Everything here is tens of bytes.
extension MatchSessionService {
    /// A dig the host has decided to run, held until the action animation that
    /// triggered it has finished playing.
    struct MiningPlan {
        let minerID: UUID
        let minerNickname: String
        let gem: GemColor
        let shovelSize: Int
    }

    // MARK: - Roles

    /// True when this device is the one counting rocks: the miner in person, or
    /// the host standing in for a bot miner.
    var isMiningAuthority: Bool {
        guard let session = mining else { return false }
        if session.minerID == localID { return true }
        return isHost && minerIsBot(session)
    }

    private func minerIsBot(_ session: MiningSnapshot) -> Bool {
        authoritativeGame?.players.first { $0.id == session.minerID }?.kind == .bot
    }

    // MARK: - Trigger (host)

    /// Called at the end of a successful `apply`. Decides whether this turn ends
    /// in a dig and, if so, parks the plan for `startPendingMiningIfNeeded()`.
    func planMiningIfNeeded(after action: GameAction, actor: UUID, before: GameState, after state: GameState) {
        guard isHost,
              mining == nil, pendingMiningPlan == nil,
              state.configuration.mode == .standard,
              state.configuration.mining.isEnabled,
              state.status == .playing,
              !isPaused,
              let miner = state.players.first(where: { $0.id == actor }),
              miner.isConnected
        else { return }

        let rules = state.configuration.mining
        // "拿两颗同色" is checked first. Per the house rule it triggers on its own
        // roll and does *not* spend the round's single last-place allowance.
        var isSameColorTake = false
        if case let .take(tokens, _) = action {
            // Filter zero entries exactly as `StandardRuleset.applyTake` does, so
            // `[.ruby: 2, .onyx: 0]` — legal there — reads as a same-colour take
            // here too.
            let picks = tokens.filter { $0.value > 0 }
            isSameColorTake = picks.count == 1 && picks.first?.value == 2
        }

        var consumesRoundQuota = false
        let triggered: Bool
        if isSameColorTake, rollMining(chance: rules.sameColorChance) {
            triggered = true
        } else if before.roundNumber != lastMiningRound,
                  state.isInLastPlace(actor),
                  rollMining(chance: rules.lastPlaceChance) {
            triggered = true
            consumesRoundQuota = true
        } else {
            triggered = false
        }
        guard triggered, let gem = randomBuriedGem(in: state) else { return }

        if consumesRoundQuota { lastMiningRound = before.roundNumber }
        let opponents = state.players.filter { $0.id != actor && $0.isConnected }.count
        pendingMiningPlan = MiningPlan(
            minerID: actor,
            minerNickname: miner.nickname,
            gem: gem,
            shovelSize: MiningBalance.shovelSize(opponentCount: opponents)
        )
        startPendingMiningWatchdog()
    }

    private func rollMining(chance: Int) -> Bool {
        guard chance > 0 else { return false }
        guard chance < 100 else { return true }
        return miningRandom() * 100 < Double(chance)
    }

    /// Picks the buried token, weighted by how many of each colour the bank holds
    /// (so a plentiful colour is likelier than the last of a scarce one). Gold is
    /// never buried — it is a wildcard, not a mining prize.
    private func randomBuriedGem(in state: GameState) -> GemColor? {
        let pool = GemColor.purchasableColors.flatMap { color in
            Array(repeating: color, count: max(0, state.bank[color] ?? 0))
        }
        guard !pool.isEmpty else { return nil }
        let index = min(Int(miningRandom() * Double(pool.count)), pool.count - 1)
        return pool[max(0, index)]
    }

    /// Insurance for the parked plan.
    ///
    /// A parked plan freezes `apply`, and it is normally consumed by
    /// `scheduleGameBroadcast` once the triggering animation ends. That task can
    /// be cancelled by anyone, though, and a plan nobody consumes would wedge the
    /// match. This fires a beat after the longest animation and resolves the plan
    /// itself; when the normal path already ran, it is a no-op.
    private func startPendingMiningWatchdog() {
        pendingMiningTask?.cancel()
        pendingMiningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MiningBalance.plannedDigWatchdog))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.pendingMiningPlan != nil else { return }
                self.startPendingMiningIfNeeded()
                self.broadcastGame()
                self.scheduleTurnTimer()
                self.scheduleBotTurnIfNeeded()
            }
        }
    }

    // MARK: - Start (host)

    /// Opens the dig window. Called from `scheduleGameBroadcast` immediately
    /// before `broadcastGame()`, so a single snapshot carries both "the bank lost
    /// a token" and "a dig has begun" — clients never see one without the other.
    func startPendingMiningIfNeeded() {
        guard isHost, let plan = pendingMiningPlan else { return }
        pendingMiningPlan = nil
        pendingMiningTask?.cancel()
        pendingMiningTask = nil
        guard mining == nil,
              var state = authoritativeGame,
              state.status == .playing,
              !isPaused,
              state.bank[plan.gem, default: 0] > 0
        else { return }

        // The prize really leaves the pool for the duration: players can see the
        // bank drop, and a failed dig visibly puts it back.
        state.bank[plan.gem, default: 0] -= 1
        state.revision += 1
        authoritativeGame = state

        let now = Date()
        let session = MiningSnapshot(
            minerID: plan.minerID,
            minerNickname: plan.minerNickname,
            gem: plan.gem,
            startedAt: now,
            endsAt: now.addingTimeInterval(MiningBalance.duration),
            shovelSize: plan.shovelSize
        )
        mining = session
        beginMiningWindow(session)
        turnTask?.cancel()
        turnDeadline = nil
        startMiningFallback(session)
    }

    /// Set up whichever tickers this device is responsible for. Runs on the host
    /// and on every client, off the snapshot.
    func beginMiningWindow(_ session: MiningSnapshot) {
        miningKnownRemaining = session.pileTotal
        miningPile.remaining = session.pileTotal
        miningLocalTaps = 0
        miningInboundTaps = 0
        miningBotCredit.removeAll()
        miningThrowBudget.removeAll()
        miningThrowStamp.removeAll()
        miningNextThrowAt = .distantPast
        if isMiningAuthority { startMinerTicker(session) }
        if isHost { startBotThrowTicker(session) }
    }

    // MARK: - The miner's device

    /// Publishes the count 5× a second and closes the window at `endsAt`.
    private func startMinerTicker(_ session: MiningSnapshot) {
        miningTickTask?.cancel()
        miningTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MiningBalance.tickInterval))
                if Task.isCancelled { return }
                await MainActor.run { self?.minerTick(session) }
            }
        }
    }

    private func minerTick(_ session: MiningSnapshot) {
        guard isMiningAuthority, mining?.id == session.id, mining?.phase == .digging else { return }
        publishMiningProgress(session)
        // The window always runs its full length — no early finish, so the other
        // players keep a chance to bury the pile again at the last moment.
        guard Date() >= session.endsAt else { return }
        miningTickTask?.cancel()
        miningTickTask = nil
        publishMiningProgress(session)
        reportMiningOutcome(session)
    }

    private func publishMiningProgress(_ session: MiningSnapshot) {
        let progress = MiningProgress(
            sessionID: session.id,
            remaining: miningPile.remaining,
            endsAt: session.endsAt
        )
        if isHost {
            broadcast(.miningProgress(progress))
        } else {
            sendToHost(.miningProgress(progress))
        }
    }

    private func reportMiningOutcome(_ session: MiningSnapshot) {
        let report = MiningOutcomeReport(sessionID: session.id, remaining: miningPile.remaining)
        if isHost {
            settleMining(report)
        } else {
            sendToHost(.miningOutcome(report))
        }
    }

    /// Fold opponents' rocks into the pile. Only meaningful on the miner's device.
    func creditMiningThrows(_ count: Int) {
        guard isMiningAuthority, let session = mining, session.phase == .digging, count > 0 else { return }
        let added = min(count, MiningBalance.maximumTapsPerReport) * MiningBalance.rocksPerOpponentTap
        // Capped at the starting size: without a ceiling the opponents could bank
        // an unbeatable buffer in the first second, before the miner lands a tap.
        miningPile.remaining = min(miningPile.remaining + added, session.pileTotal)
    }

    // MARK: - Bots (host)

    /// Bots dig and throw like everyone else. A steady taps-per-second with a
    /// fractional carry, so a 5 Hz tick never rounds their contribution away.
    private func startBotThrowTicker(_ session: MiningSnapshot) {
        miningBotTask?.cancel()
        guard authoritativeGame?.players.contains(where: { $0.kind == .bot && $0.isConnected }) == true else { return }
        miningBotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MiningBalance.tickInterval))
                if Task.isCancelled { return }
                await MainActor.run { self?.botTick(session) }
            }
        }
    }

    private func botTick(_ session: MiningSnapshot) {
        guard isHost, mining?.id == session.id, mining?.phase == .digging, Date() < session.endsAt,
              let state = authoritativeGame
        else { return }

        var thrown = 0
        for player in state.players where player.kind == .bot && player.isConnected {
            let difficulty = room?.participants.first(where: { $0.id == player.id })?.difficulty ?? .normal
            let isMiner = player.id == session.minerID
            let rate = isMiner
                ? requiredMinerTapRate(for: session) * MiningBalance.botDigMultiplier(difficulty)
                : MiningBalance.botRockTapsPerSecond(difficulty)
            let credit = miningBotCredit[player.id, default: 0] + rate * MiningBalance.tickInterval
            let taps = Int(credit)
            miningBotCredit[player.id] = credit - Double(taps)
            guard taps > 0 else { continue }
            if isMiner {
                // The host is this bot's device, so its digging lands directly.
                applyMinerDig(taps: taps, session: session)
            } else {
                thrown += taps
            }
        }
        // Bots skip the cooldown budget: the host already emits them at an exact
        // rate below the cap, so metering them again would only shave rounding.
        guard thrown > 0 else { return }
        deliverThrows(thrown, session: session)
    }

    /// The tap rate this dig actually demands of its miner, given exactly who is
    /// throwing rocks at it. Bot miners aim at a multiple of this rather than at
    /// a fixed taps-per-second, which is what makes them credible at every table
    /// size instead of hopeless at most of them.
    func requiredMinerTapRate(for session: MiningSnapshot) -> Double {
        guard let state = authoritativeGame else { return MiningBalance.targetMinerTapsPerSecond }
        let thrown = state.players
            .filter { $0.id != session.minerID && $0.isConnected }
            .reduce(0.0) { total, player in
                guard player.kind == .bot else { return total + MiningBalance.referenceOpponentTapsPerSecond }
                let difficulty = room?.participants.first(where: { $0.id == player.id })?.difficulty ?? .normal
                return total + MiningBalance.botRockTapsPerSecond(difficulty)
            }
        let debt = Double(session.pileTotal - session.successThreshold)
        return (debt + thrown * MiningBalance.duration) / (MiningBalance.duration * Double(session.shovelSize))
    }

    // MARK: - Settling (host)

    /// Take the miner's word for it and hand out (or bury) the token.
    func settleMining(_ report: MiningOutcomeReport) {
        guard isHost, let session = mining, session.phase == .digging, session.id == report.sessionID,
              var state = authoritativeGame,
              let index = state.players.firstIndex(where: { $0.id == session.minerID })
        else { return }
        cancelMiningTickers()

        let success = report.remaining <= session.successThreshold
        if success {
            state.players[index].tokens[session.gem, default: 0] += 1
        } else {
            state.bank[session.gem, default: 0] += 1
        }
        state.revision += 1
        authoritativeGame = state
        miningPile.remaining = report.remaining

        // The cap is host-configurable, so never assume 10.
        let overflow = success
            ? max(0, state.players[index].tokenCount - state.configuration.standardTokenLimit)
            : 0
        if overflow > 0 {
            mining = session.with(phase: .awaitingDiscard, outcome: .success, discardCount: overflow)
            broadcastGame()
            startMiningDiscardTimeout()
        } else {
            mining = session.with(phase: .resolved, outcome: success ? .success : .failure)
            broadcastGame()
            scheduleMiningFinish()
        }
    }

    /// If the miner's verdict never arrives — they dropped, or their report was
    /// lost — settle from the last count the host saw relayed. The match must not
    /// hang on one device.
    private func startMiningFallback(_ session: MiningSnapshot) {
        miningFallbackTask?.cancel()
        miningFallbackTask = Task { [weak self] in
            let wait = session.endsAt.timeIntervalSinceNow + MiningBalance.outcomeGrace
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isHost,
                      self.mining?.id == session.id, self.mining?.phase == .digging
                else { return }
                self.settleMining(MiningOutcomeReport(
                    sessionID: session.id,
                    remaining: self.miningKnownRemaining
                ))
            }
        }
    }

    private func scheduleMiningFinish() {
        miningFinishTask?.cancel()
        miningFinishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MiningBalance.revealBeat))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finishMining() }
        }
    }

    /// Close the window and hand the match back to the normal turn loop.
    func finishMining() {
        cancelMiningTasks()
        mining = nil
        miningLocalTaps = 0
        miningInboundTaps = 0
        miningBotCredit.removeAll()
        guard isHost else { return }
        scheduleTurnTimer()
        broadcastGame()
        scheduleBotTurnIfNeeded()
    }

    // MARK: - Over-limit discard

    /// Miner side: send the tokens the player chose to drop.
    func submitMiningDiscard(_ tokens: [GemColor: Int]) {
        guard let session = mining, session.phase == .awaitingDiscard, session.minerID == localID else { return }
        let discard = MiningDiscard(sessionID: session.id, tokens: tokens)
        if isHost {
            applyMiningDiscard(discard, from: localID)
        } else {
            sendToHost(.miningDiscard(discard))
        }
    }

    /// Host side: validate and settle the miner's discard.
    func applyMiningDiscard(_ discard: MiningDiscard, from playerID: UUID) {
        guard isHost, let session = mining, session.phase == .awaitingDiscard,
              session.id == discard.sessionID, session.minerID == playerID,
              var state = authoritativeGame,
              let index = state.players.firstIndex(where: { $0.id == playerID }),
              discard.tokens.values.reduce(0, +) == session.discardCount,
              discard.tokens.allSatisfy({ state.players[index].tokens[$0.key, default: 0] >= $0.value })
        else { return }

        for (color, amount) in discard.tokens {
            state.players[index].tokens[color, default: 0] -= amount
            if state.players[index].tokens[color] == 0 { state.players[index].tokens[color] = nil }
            state.bank[color, default: 0] += amount
        }
        state.revision += 1
        authoritativeGame = state
        miningDiscardTask?.cancel()
        miningDiscardTask = nil
        mining = session.with(phase: .resolved, outcome: .success)
        broadcastGame()
        scheduleMiningFinish()
    }

    /// Bot miners never choose, and a human miner may have walked away, so the
    /// host always has a deadline after which it discards for them.
    private func startMiningDiscardTimeout() {
        miningDiscardTask?.cancel()
        let miner = authoritativeGame?.players.first { $0.id == mining?.minerID }
        let needsHostChoice = miner?.kind == .bot || miner?.isConnected == false
        let delay = needsHostChoice ? MiningBalance.revealBeat : MiningBalance.discardTimeout
        miningDiscardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.autoMiningDiscard() }
        }
    }

    private func autoMiningDiscard() {
        guard isHost, let session = mining, session.phase == .awaitingDiscard,
              let state = authoritativeGame,
              let player = state.players.first(where: { $0.id == session.minerID })
        else { return }
        let picks = Self.autoDiscardPicks(from: player.tokens, count: session.discardCount)
        applyMiningDiscard(MiningDiscard(sessionID: session.id, tokens: picks), from: session.minerID)
    }

    /// Drops whichever colour the player holds most of, keeping gold until last —
    /// a wildcard is worth more than the n-th copy of one colour.
    static func autoDiscardPicks(from tokens: [GemColor: Int], count: Int) -> [GemColor: Int] {
        var pool = tokens
        var picks: [GemColor: Int] = [:]
        var remaining = count
        while remaining > 0 {
            let candidate = pool.filter { $0.value > 0 }.max { lhs, rhs in
                if (lhs.key == .gold) != (rhs.key == .gold) { return lhs.key == .gold }
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.rawValue > rhs.key.rawValue
            }
            guard let candidate else { break }
            pool[candidate.key] = candidate.value - 1
            picks[candidate.key, default: 0] += 1
            remaining -= 1
        }
        return picks
    }

    // MARK: - Abort

    /// Tear the dig down without a winner. Used whenever something outranks it:
    /// a pause, a disconnect freeze, returning to configuration, or leaving.
    /// Always leaves the token pool whole, so the window can never deadlock the
    /// match or leak a gem.
    func abortMining() {
        pendingMiningPlan = nil
        guard let session = mining else {
            cancelMiningTasks()
            return
        }
        cancelMiningTasks()
        if isHost, var state = authoritativeGame {
            switch session.phase {
            case .digging:
                // The prize is still buried and out of circulation: put it back.
                state.bank[session.gem, default: 0] += 1
                state.revision += 1
                authoritativeGame = state
            case .awaitingDiscard:
                // The miner already holds the prize; settle the discard for them
                // rather than leaving the seat permanently over the cap.
                if let index = state.players.firstIndex(where: { $0.id == session.minerID }) {
                    let picks = Self.autoDiscardPicks(
                        from: state.players[index].tokens,
                        count: session.discardCount
                    )
                    for (color, amount) in picks {
                        state.players[index].tokens[color, default: 0] -= amount
                        if state.players[index].tokens[color] == 0 { state.players[index].tokens[color] = nil }
                        state.bank[color, default: 0] += amount
                    }
                    state.revision += 1
                    authoritativeGame = state
                }
            case .resolved:
                break
            }
        }
        mining = nil
        miningLocalTaps = 0
        miningInboundTaps = 0
        miningBotCredit.removeAll()
    }

    private func cancelMiningTickers() {
        miningTickTask?.cancel()
        miningTickTask = nil
        miningBotTask?.cancel()
        miningBotTask = nil
        miningFallbackTask?.cancel()
        miningFallbackTask = nil
    }

    func cancelMiningTasks() {
        pendingMiningTask?.cancel()
        pendingMiningTask = nil
        cancelMiningTickers()
        miningFinishTask?.cancel()
        miningFinishTask = nil
        miningDiscardTask?.cancel()
        miningDiscardTask = nil
        miningFlushTask?.cancel()
        miningFlushTask = nil
    }

    // MARK: - Local taps (every device)

    /// True while this device may tap the pile.
    var canTapMiningPile: Bool {
        guard let session = mining, session.phase == .digging else { return false }
        return game?.players.contains { $0.id == localID } == true && Date() < session.endsAt
    }

    /// One tap on the rock pile.
    ///
    /// The miner's own dig lands on their own count with no round trip and is
    /// never corrected. Everyone else shows their thrown rock immediately and
    /// forwards it on the next 200 ms flush.
    func reportMiningTap() {
        guard canTapMiningPile, let session = mining else { return }
        if session.minerID == localID {
            // No cooldown for the miner — digging out is the fast half.
            applyMinerDig(taps: 1, session: session)
            return
        }
        // Mirror the host's cooldown locally so the heap on screen matches what
        // will actually land. Swallowing the tap here is quieter than showing a
        // rock the host is about to drop.
        let now = Date()
        guard now >= miningNextThrowAt else { return }
        miningNextThrowAt = now.addingTimeInterval(MiningBalance.throwCooldown)
        miningLocalTaps += 1
        miningPile.remaining = min(
            miningPile.remaining + MiningBalance.rocksPerOpponentTap,
            session.pileTotal
        )
        startMiningFlushIfNeeded()
    }

    /// Remove rocks on behalf of the miner. Used by the miner's own taps and by
    /// the host driving a bot miner.
    func applyMinerDig(taps: Int, session: MiningSnapshot) {
        guard taps > 0 else { return }
        miningPile.remaining = max(miningPile.remaining - taps * session.shovelSize, 0)
    }

    private func startMiningFlushIfNeeded() {
        guard miningFlushTask == nil else { return }
        miningFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MiningBalance.tickInterval))
                if Task.isCancelled { return }
                let finished = await MainActor.run { self?.flushMiningTaps() ?? true }
                if finished { return }
            }
        }
    }

    /// Returns `true` when the window closed and the flush loop should stop.
    private func flushMiningTaps() -> Bool {
        guard let session = mining, session.phase == .digging else {
            miningLocalTaps = 0
            // Clear the handle here, on the main actor, rather than after the loop
            // exits: a trailing cleanup could otherwise null out the handle of a
            // flush task that a *newer* dig had already started.
            miningFlushTask = nil
            return true
        }
        if miningLocalTaps > 0 {
            let taps = min(miningLocalTaps, MiningBalance.maximumTapsPerReport)
            miningLocalTaps = 0
            let report = MiningTapReport(sessionID: session.id, taps: taps)
            if isHost {
                routeMiningTap(report, from: localID)
            } else {
                sendToHost(.miningTap(report))
            }
        }
        return false
    }

    // MARK: - Inbound

    /// Host: a thrown-rock batch, headed for whoever owns the count.
    ///
    /// This is where the throw cooldown is applied, because the host is the only
    /// device that sees every thrower with a trustworthy identity. Whatever it
    /// forwards has already been rate-limited, so the miner's device can stay
    /// dumb and fast.
    func routeMiningTap(_ report: MiningTapReport, from playerID: UUID) {
        guard isHost, let session = mining, session.phase == .digging, session.id == report.sessionID else { return }
        guard playerID != session.minerID else { return }
        guard authoritativeGame?.players.contains(where: { $0.id == playerID }) == true else { return }
        let allowed = allowedThrows(report.taps, from: playerID)
        guard allowed > 0 else { return }
        deliverThrows(allowed, session: session)
    }

    /// Spend `playerID`'s throw budget, refilled at one rock per
    /// `MiningBalance.throwCooldown`.
    ///
    /// A fractional token bucket rather than a hard "one per N ms" gate: reports
    /// arrive in 200 ms batches, so a strict gate would clip perfectly ordinary
    /// tapping down to whatever fits one batch. The burst allowance covers the
    /// batching; the refill rate is the real limit.
    private func allowedThrows(_ requested: Int, from playerID: UUID) -> Int {
        let now = Date()
        let elapsed = now.timeIntervalSince(miningThrowStamp[playerID] ?? now)
        let budget = min(
            (miningThrowBudget[playerID] ?? MiningBalance.throwBurstAllowance)
                + elapsed / MiningBalance.throwCooldown,
            MiningBalance.throwBurstAllowance
        )
        miningThrowStamp[playerID] = now
        let allowed = min(min(requested, MiningBalance.maximumTapsPerReport), Int(budget))
        miningThrowBudget[playerID] = budget - Double(allowed)
        return allowed
    }

    /// Land already-approved rocks on whichever device owns the count.
    private func deliverThrows(_ count: Int, session: MiningSnapshot) {
        if isMiningAuthority {
            creditMiningThrows(count)
        } else if let peer = participantPeers[session.minerID] {
            send(.miningTap(MiningTapReport(sessionID: session.id, taps: count)), to: peer)
        }
    }

    /// Miner: rocks thrown at us, relayed by the host.
    func receiveMiningTap(_ report: MiningTapReport, from playerID: UUID) {
        if isHost {
            routeMiningTap(report, from: playerID)
        } else if mining?.id == report.sessionID {
            creditMiningThrows(report.taps)
        }
    }

    /// The miner's running count. The host relays it on and keeps it as its own
    /// fallback verdict; everyone else just renders it, preserving the throws
    /// they have made but not yet reported so the pile never jumps backwards
    /// under their own finger.
    func receiveMiningProgress(_ progress: MiningProgress, from playerID: UUID) {
        guard let session = mining, session.id == progress.sessionID else { return }
        if isHost {
            guard playerID == session.minerID else { return }
            miningKnownRemaining = progress.remaining
            for (participantID, peer) in participantPeers where participantID != session.minerID {
                send(.miningProgress(progress), to: peer)
            }
        }
        guard !isMiningAuthority else { return }
        let unreported = miningLocalTaps * MiningBalance.rocksPerOpponentTap
        miningPile.remaining = min(max(progress.remaining + unreported, 0), session.pileTotal)
    }

    /// Host: the miner's verdict.
    func receiveMiningOutcome(_ report: MiningOutcomeReport, from playerID: UUID) {
        guard isHost, mining?.minerID == playerID else { return }
        settleMining(report)
    }

    /// Client: mirror the dig window from the snapshot, exactly like `matchPause`.
    /// The snapshot is the only truth, so a lost progress message or a reconnect
    /// can never strand a client behind the overlay.
    func syncMining(from snapshot: ClientGameSnapshot) {
        let previous = mining
        mining = snapshot.mining
        guard let session = snapshot.mining else {
            if previous != nil {
                cancelMiningTasks()
                miningLocalTaps = 0
                miningInboundTaps = 0
            }
            return
        }
        if previous?.id != session.id {
            cancelMiningTasks()
            beginMiningWindow(session)
        }
    }
}
