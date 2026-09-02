import LuminoreCore
import XCTest
@testable import Luminore

/// Host-side 挖矿 behaviour.
///
/// The dig is driven by a 5-second wall clock in production; these tests call
/// `resolveMining()` directly instead of waiting it out. The ticker's only job is
/// to invoke that at `endsAt`, so nothing about the outcome logic is skipped.
@MainActor
final class MiningSessionTests: XCTestCase {
    /// A dig decided by the last `apply`, whether it is still parked waiting for
    /// an animation (`.take`) or was opened immediately (`.pass`, no animation).
    private func digMiner(_ host: MatchSessionService) -> UUID? {
        host.mining?.minerID ?? host.pendingMiningPlan?.minerID
    }

    // MARK: - Triggering

    func testTakingTwoOfOneColourTriggersADig() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)

        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: actorID, allowsPass: true)

        XCTAssertEqual(digMiner(host), actorID)
    }

    /// Zero-valued entries are legal in a `.take` and the engine filters them, so
    /// the trigger check must filter them the same way.
    func testASameColourTakePaddedWithZeroesStillTriggers() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)

        host.apply(.take(tokens: [.diamond: 2, .onyx: 0], returning: [:]), from: actorID, allowsPass: true)

        XCTAssertEqual(digMiner(host), actorID)
    }

    func testTakingThreeDifferentColoursDoesNotTriggerTheSameColourRoll() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)

        host.apply(.take(tokens: [.diamond: 1, .ruby: 1, .onyx: 1], returning: [:]), from: actorID, allowsPass: true)

        XCTAssertNil(digMiner(host))
    }

    func testLastPlaceTriggersOnlyForTheTrailingSeat() throws {
        let (host, _) = try startedMatch(sameColorChance: 0, lastPlaceChance: 100)
        // Put the seat that is about to move clearly ahead: it must not qualify.
        let leaderID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        award(host, playerID: leaderID, prestige: 4)

        host.apply(.pass, from: leaderID, allowsPass: true)
        XCTAssertNil(digMiner(host), "the leader is not in last place")

        // The next seat is now trailing, so its turn ends in a dig.
        let trailingID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.pass, from: trailingID, allowsPass: true)
        XCTAssertEqual(digMiner(host), trailingID)
    }

    func testAtMostOneLastPlaceDigPerRound() throws {
        // Three seats so a single round can contain two trailing players.
        let (host, _) = try startedMatch(bots: 1, sameColorChance: 0, lastPlaceChance: 100)
        let leaderID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        award(host, playerID: leaderID, prestige: 4)
        host.apply(.pass, from: leaderID, allowsPass: true)
        XCTAssertNil(digMiner(host), "the leader is not in last place")

        let firstTrailingID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.pass, from: firstTrailingID, allowsPass: true)
        XCTAssertEqual(digMiner(host), firstTrailingID)
        host.abortMining()

        let secondTrailingID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.pass, from: secondTrailingID, allowsPass: true)
        XCTAssertNil(digMiner(host), "the round's single allowance is already spent")

        // A new round unlocks it again: the leader passes, then the next trailing
        // seat digs.
        host.apply(.pass, from: try XCTUnwrap(host.authoritativeGame?.currentPlayer.id), allowsPass: true)
        XCTAssertNil(digMiner(host), "still the leader")
        host.apply(.pass, from: try XCTUnwrap(host.authoritativeGame?.currentPlayer.id), allowsPass: true)
        XCTAssertNotNil(digMiner(host))
    }

    /// A same-colour dig fires on its own roll and leaves the round's last-place
    /// allowance untouched.
    func testSameColourTriggerDoesNotSpendTheRoundAllowance() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 100)
        let leaderID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        award(host, playerID: leaderID, prestige: 4)

        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: leaderID, allowsPass: true)
        XCTAssertEqual(digMiner(host), leaderID)
        host.abortMining()

        let trailingID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.pass, from: trailingID, allowsPass: true)
        XCTAssertEqual(digMiner(host), trailingID, "the same-colour dig left the allowance unspent")
    }

    func testNothingTriggersWhenTheHouseRuleIsOff() throws {
        let (host, _) = try startedMatch(enabled: false, sameColorChance: 100, lastPlaceChance: 100)
        let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: actorID, allowsPass: true)
        XCTAssertNil(digMiner(host))
    }

    // MARK: - The window

    func testStartingADigMovesTheTokenOutOfTheBankAndFreezesTheTurnTimer() throws {
        let (host, client) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: actorID, allowsPass: true)
        let bankBefore = try XCTUnwrap(host.authoritativeGame?.bank)

        host.startPendingMiningIfNeeded()
        host.broadcastGame()

        let session = try XCTUnwrap(host.mining)
        XCTAssertEqual(session.phase, .digging)
        XCTAssertEqual(
            host.authoritativeGame?.bank[session.gem],
            bankBefore[session.gem, default: 0] - 1
        )
        XCTAssertEqual(
            session.endsAt.timeIntervalSince(session.startedAt),
            MiningBalance.duration,
            accuracy: 0.01,
            "the window length comes from the balance table, not a literal"
        )
        XCTAssertNil(host.turnDeadline, "the turn clock must not run during a dig")
        // The window reaches the client through the ordinary snapshot.
        XCTAssertEqual(client.mining, session)
        XCTAssertEqual(client.game?.mining, session)
    }

    func testNoMoveLandsWhileADigIsOpen() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: actorID, allowsPass: true)
        host.startPendingMiningIfNeeded()

        let revision = try XCTUnwrap(host.authoritativeGame?.revision)
        let nextID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.take(tokens: [.ruby: 1], returning: [:]), from: nextID, allowsPass: true)

        XCTAssertEqual(host.authoritativeGame?.revision, revision, "the move must be ignored")
    }

    /// Regression: `GameRuleset.setConnection` bumps the revision on its own, so
    /// somebody joining or dropping during the animation beat used to make
    /// `scheduleGameBroadcast` bail on its staleness guard *without* consuming the
    /// parked plan — leaving `apply` frozen behind a dig that never opened.
    func testAReconnectDuringTheAnimationBeatDoesNotStrandThePlannedDig() throws {
        let (host, _) = try startedMatch(bots: 1, sameColorChance: 100, lastPlaceChance: 0)
        let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: actorID, allowsPass: true)
        let plan = try XCTUnwrap(host.pendingMiningPlan, "parked behind the take animation")

        // Something else advances the game while the plan is still parked.
        var state = try XCTUnwrap(host.authoritativeGame)
        let botID = try XCTUnwrap(state.players.first { $0.kind == .bot }?.id)
        host.rules.setConnection(false, playerID: botID, skipTurns: false, in: &state)
        host.authoritativeGame = state

        // The delayed broadcast now fails its staleness guard; the plan must still
        // resolve rather than wedge the match.
        host.startPendingMiningIfNeeded()
        XCTAssertNil(host.pendingMiningPlan)
        XCTAssertEqual(host.mining?.minerID, plan.minerID)

        host.finishMining()
        let nextID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        let revision = try XCTUnwrap(host.authoritativeGame?.revision)
        host.apply(.take(tokens: [.ruby: 1], returning: [:]), from: nextID, allowsPass: true)
        XCTAssertGreaterThan(
            try XCTUnwrap(host.authoritativeGame?.revision),
            revision,
            "play resumes"
        )
    }

    // MARK: - Resolution

    func testDiggingOutTheTokenHandsItToTheMinerAndResumesPlay() throws {
        let (host, client) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let minerID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: minerID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)
        let held = try XCTUnwrap(host.authoritativeGame?.players.first { $0.id == minerID })
            .tokens[session.gem, default: 0]

        host.settleMining(MiningOutcomeReport(sessionID: session.id, remaining: session.successThreshold))

        XCTAssertEqual(host.mining?.outcome, .success)
        XCTAssertEqual(host.mining?.phase, .resolved)
        XCTAssertEqual(
            host.authoritativeGame?.players.first { $0.id == minerID }?.tokens[session.gem, default: 0],
            held + 1
        )
        XCTAssertEqual(client.mining?.outcome, .success)

        host.finishMining()
        XCTAssertNil(host.mining)
        XCTAssertNil(client.mining)
        XCTAssertNotNil(host.turnDeadline, "the turn clock restarts once the dig is over")
    }

    func testRunningOutOfTimeReturnsTheTokenToTheBank() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let minerID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        let bankBefore = try XCTUnwrap(host.authoritativeGame?.bank)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: minerID, allowsPass: true)
        let bankAfterTake = try XCTUnwrap(host.authoritativeGame?.bank)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)

        host.settleMining(MiningOutcomeReport(
            sessionID: session.id,
            remaining: session.successThreshold + 1
        ))

        XCTAssertEqual(host.mining?.outcome, .failure)
        XCTAssertEqual(host.authoritativeGame?.bank, bankAfterTake, "the pool is whole again")
        XCTAssertEqual(bankBefore[.diamond, default: 0] - 2, bankAfterTake[.diamond, default: 0])
    }

    func testWinningOverTheTokenLimitWaitsForADiscard() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let minerID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        let limit = try XCTUnwrap(host.authoritativeGame?.configuration.standardTokenLimit)
        fill(host, playerID: minerID, tokens: [.ruby: limit - 2, .onyx: 2])
        host.apply(.take(tokens: [.diamond: 2], returning: [.ruby: 2]), from: minerID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)

        host.settleMining(MiningOutcomeReport(sessionID: session.id, remaining: 0))

        XCTAssertEqual(host.mining?.phase, .awaitingDiscard)
        XCTAssertEqual(host.mining?.discardCount, 1)

        host.applyMiningDiscard(MiningDiscard(sessionID: session.id, tokens: [.onyx: 1]), from: minerID)
        XCTAssertEqual(host.mining?.phase, .resolved)
        let miner = try XCTUnwrap(host.authoritativeGame?.players.first { $0.id == minerID })
        XCTAssertEqual(miner.tokenCount, limit)
    }

    func testADiscardThatDoesNotMatchTheRequirementIsRejected() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let minerID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        let limit = try XCTUnwrap(host.authoritativeGame?.configuration.standardTokenLimit)
        fill(host, playerID: minerID, tokens: [.ruby: limit - 2, .onyx: 2])
        host.apply(.take(tokens: [.diamond: 2], returning: [.ruby: 2]), from: minerID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)
        host.settleMining(MiningOutcomeReport(sessionID: session.id, remaining: 0))

        // Too many, then a colour the miner does not hold.
        host.applyMiningDiscard(MiningDiscard(sessionID: session.id, tokens: [.onyx: 2]), from: minerID)
        XCTAssertEqual(host.mining?.phase, .awaitingDiscard)
        host.applyMiningDiscard(MiningDiscard(sessionID: session.id, tokens: [.emerald: 1]), from: minerID)
        XCTAssertEqual(host.mining?.phase, .awaitingDiscard)
        // And a discard attributed to somebody else.
        let otherID = try XCTUnwrap(host.authoritativeGame?.players.first { $0.id != minerID }?.id)
        host.applyMiningDiscard(MiningDiscard(sessionID: session.id, tokens: [.onyx: 1]), from: otherID)
        XCTAssertEqual(host.mining?.phase, .awaitingDiscard)
    }

    func testAutoDiscardDrawsDownTheDeepestStacksAndSpendsGoldLast() {
        let picks = MatchSessionService.autoDiscardPicks(
            from: [.ruby: 4, .onyx: 2, .gold: 3],
            count: 3
        )
        XCTAssertEqual(picks.values.reduce(0, +), 3)
        XCTAssertNil(picks[.gold], "gold is a wildcard and survives while colours remain")
        XCTAssertEqual(picks[.ruby], 2, "the deepest stack gives up the most")
        XCTAssertEqual(picks[.onyx], 1)

        XCTAssertEqual(
            MatchSessionService.autoDiscardPicks(from: [.gold: 2, .ruby: 1], count: 2),
            [.ruby: 1, .gold: 1],
            "gold only goes once nothing else is left"
        )
        // Never hands back more than the player actually holds.
        let short = MatchSessionService.autoDiscardPicks(from: [.ruby: 1], count: 5)
        XCTAssertEqual(short, [.ruby: 1])
    }

    // MARK: - Abort

    func testPausingSettlesTheDigAndLeavesThePoolWhole() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let minerID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: minerID, allowsPass: true)
        let bankAfterTake = try XCTUnwrap(host.authoritativeGame?.bank)
        host.startPendingMiningIfNeeded()
        XCTAssertNotNil(host.mining)

        host.pauseGame()

        XCTAssertNil(host.mining)
        XCTAssertEqual(host.authoritativeGame?.bank, bankAfterTake)
        XCTAssertTrue(host.isPaused)
    }

    func testAbortingWhileAwaitingADiscardStillBringsTheMinerBackUnderTheLimit() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        let minerID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
        let limit = try XCTUnwrap(host.authoritativeGame?.configuration.standardTokenLimit)
        fill(host, playerID: minerID, tokens: [.ruby: limit - 2, .onyx: 2])
        host.apply(.take(tokens: [.diamond: 2], returning: [.ruby: 2]), from: minerID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)
        host.settleMining(MiningOutcomeReport(sessionID: session.id, remaining: 0))
        XCTAssertEqual(host.mining?.phase, .awaitingDiscard)

        host.abortMining()

        XCTAssertNil(host.mining)
        let miner = try XCTUnwrap(host.authoritativeGame?.players.first { $0.id == minerID })
        XCTAssertEqual(miner.tokenCount, limit)
    }

    // MARK: - Transport parity

    /// CLAUDE.md requires every feature to work on all three transports; the dig
    /// rides the ordinary snapshot, so this is the check that it really does.
    func testTheDigWindowReachesClientsOnEveryTransportMode() throws {
        for mode in MultiplayerMode.allCases {
            for clientIsMiner in [false, true] {
                let (host, client) = try startedMatch(mode: mode, sameColorChance: 100, lastPlaceChance: 0)
                let minerID = clientIsMiner ? client.localID : host.localID
                giveTurn(to: minerID, in: host)
                let label = "\(mode), client mining: \(clientIsMiner)"

                host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: minerID, allowsPass: true)
                host.startPendingMiningIfNeeded()
                host.broadcastGame()

                let session = try XCTUnwrap(host.mining, "host window for \(label)")
                XCTAssertEqual(client.mining, session, "client window for \(label)")
                XCTAssertEqual(session.minerID, minerID, "miner for \(label)")
                XCTAssertEqual(client.miningPile.remaining, session.pileTotal, "fresh pile for \(label)")

                let miner = clientIsMiner ? client : host
                let thrower = clientIsMiner ? host : client
                XCTAssertTrue(miner.isMiningAuthority, "the miner owns the count for \(label)")
                XCTAssertFalse(thrower.isMiningAuthority, "for \(label)")

                // The miner's own dig lands with no round trip.
                miner.reportMiningTap()
                XCTAssertEqual(
                    miner.miningPile.remaining,
                    session.pileTotal - session.shovelSize,
                    "the miner's dig is instant, for \(label)"
                )

                // A throw is shown at once and queued for the miner.
                thrower.reportMiningTap()
                XCTAssertEqual(thrower.miningLocalTaps, 1, "queued for \(label)")

                // …and reaches the miner's pile through the host.
                let before = miner.miningPile.remaining
                host.routeMiningTap(
                    MiningTapReport(sessionID: session.id, taps: 3),
                    from: thrower.localID
                )
                XCTAssertEqual(
                    miner.miningPile.remaining,
                    before + 3 * MiningBalance.rocksPerOpponentTap,
                    "the throw lands on the miner's pile, for \(label)"
                )

                // The miner's published count becomes the host's fallback verdict
                // and everyone else's display, keeping their unreported throw.
                let progress = MiningProgress(
                    sessionID: session.id,
                    remaining: 55,
                    endsAt: session.endsAt
                )
                host.receiveMiningProgress(progress, from: minerID)
                XCTAssertEqual(host.miningKnownRemaining, 55, "host fallback for \(label)")
                if clientIsMiner {
                    thrower.receiveMiningProgress(progress, from: minerID)
                }
                XCTAssertEqual(
                    thrower.miningPile.remaining,
                    55 + MiningBalance.rocksPerOpponentTap,
                    "unreported throw survives the correction, for \(label)"
                )
            }
        }
    }

    func testThrowsAreCappedAndIgnoredForTheWrongWindow() throws {
        // Host is the miner, so it owns the count and folds throws in directly.
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        giveTurn(to: host.localID, in: host)
        let minerID = host.localID
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: minerID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)
        XCTAssertTrue(host.isMiningAuthority, "the host seat is digging")
        let otherID = try XCTUnwrap(host.authoritativeGame?.players.first { $0.id != minerID }?.id)

        // Dig down first: the pile never grows past its starting size.
        host.applyMinerDig(taps: 6, session: session)
        let dug = host.miningPile.remaining
        XCTAssertLessThan(dug, session.pileTotal)

        // The cooldown budget, not `maximumTapsPerReport`, is the binding limit.
        host.routeMiningTap(MiningTapReport(sessionID: session.id, taps: 9_999), from: otherID)
        XCTAssertEqual(
            host.miningPile.remaining,
            dug + Int(MiningBalance.throwBurstAllowance) * MiningBalance.rocksPerOpponentTap
        )

        let afterCap = host.miningPile.remaining
        host.routeMiningTap(MiningTapReport(sessionID: UUID(), taps: 5), from: otherID)
        XCTAssertEqual(host.miningPile.remaining, afterCap, "a throw at a stale window is dropped")

        // The miner's own taps must not be counted as throws against themselves.
        host.routeMiningTap(MiningTapReport(sessionID: session.id, taps: 3), from: minerID)
        XCTAssertEqual(host.miningPile.remaining, afterCap)
    }

    /// The miner's dig is applied locally and is never corrected afterwards —
    /// that is the whole point of moving the count onto their device.
    func testTheMinersOwnDigLandsImmediatelyAndIsNotCorrected() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        giveTurn(to: host.localID, in: host)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: host.localID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)
        XCTAssertTrue(host.isMiningAuthority)

        host.reportMiningTap()
        XCTAssertEqual(host.miningPile.remaining, session.pileTotal - session.shovelSize)

        // A stale count from elsewhere must not touch the authority's own pile.
        host.receiveMiningProgress(
            MiningProgress(sessionID: session.id, remaining: 90, endsAt: session.endsAt),
            from: host.localID
        )
        XCTAssertEqual(host.miningPile.remaining, session.pileTotal - session.shovelSize)
    }

    /// A bot miner must actually be able to win. Its rate is a multiple of what
    /// the table demands, so this checks the demand is computed, not assumed.
    func testABotMinerDigsAgainstTheRateTheTableDemands() throws {
        let (host, _) = try startedMatch(bots: 1, sameColorChance: 0, lastPlaceChance: 100)
        // Force the bot to be the trailing seat so it becomes the miner.
        let state = try XCTUnwrap(host.authoritativeGame)
        let botID = try XCTUnwrap(state.players.first { $0.kind == .bot }?.id)
        for player in state.players where player.id != botID {
            award(host, playerID: player.id, prestige: 4)
        }
        // Walk the turn round to the bot without letting a human trigger a dig.
        var guardCount = 0
        while host.authoritativeGame?.currentPlayer.id != botID, guardCount < 8 {
            let actor = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
            host.apply(.pass, from: actor, allowsPass: true)
            host.abortMining()
            guardCount += 1
        }
        host.apply(.pass, from: botID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining, "the trailing bot digs")
        XCTAssertEqual(session.minerID, botID)
        XCTAssertTrue(host.isMiningAuthority, "the host stands in for a bot miner")

        let required = host.requiredMinerTapRate(for: session)
        // Clearing the debt at exactly the required rate must land on the line.
        let cleared = required * MiningBalance.duration * Double(session.shovelSize)
        XCTAssertEqual(
            cleared,
            Double(session.pileTotal - session.successThreshold)
                + expectedThrow(host, session: session) * MiningBalance.duration,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            required * MiningBalance.botDigMultiplier(.hard),
            required,
            "a hard bot digs above the line"
        )
        XCTAssertLessThan(
            required * MiningBalance.botDigMultiplier(.easy),
            required,
            "an easy bot digs below it"
        )
    }

    private func expectedThrow(_ host: MatchSessionService, session: MiningSnapshot) -> Double {
        (host.authoritativeGame?.players ?? [])
            .filter { $0.id != session.minerID && $0.isConnected }
            .reduce(0.0) { total, player in
                guard player.kind == .bot else { return total + MiningBalance.referenceOpponentTapsPerSecond }
                let difficulty = host.room?.participants.first { $0.id == player.id }?.difficulty ?? .normal
                return total + MiningBalance.botRockTapsPerSecond(difficulty)
            }
    }

    // MARK: - Throw cooldown

    /// Mashing must not out-throw the rate the shovel is balanced against — that
    /// unbounded tap speed is what made a dig near-impossible and bots look weak.
    func testMashingIsCappedByTheThrowCooldown() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        giveTurn(to: host.localID, in: host)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: host.localID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)
        let otherID = try XCTUnwrap(host.authoritativeGame?.players.first { $0.id != host.localID }?.id)

        // Dig well down so the pile has room to be refilled.
        host.applyMinerDig(taps: 20, session: session)
        let dug = host.miningPile.remaining

        // One instant burst: only the burst allowance may land, not the batch.
        host.routeMiningTap(MiningTapReport(sessionID: session.id, taps: 12), from: otherID)
        let landed = host.miningPile.remaining - dug
        XCTAssertLessThanOrEqual(
            Double(landed),
            MiningBalance.throwBurstAllowance,
            "an instant burst may not exceed the burst allowance"
        )
        XCTAssertGreaterThan(landed, 0, "a first throw must still land")

        // A second burst in the same instant has no budget left at all.
        let afterFirst = host.miningPile.remaining
        host.routeMiningTap(MiningTapReport(sessionID: session.id, taps: 12), from: otherID)
        XCTAssertEqual(host.miningPile.remaining, afterFirst, "budget is spent")
    }

    /// The budget refills over time, so ordinary batched play is not clipped.
    func testTheThrowBudgetRefillsAtTheCooldownRate() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        giveTurn(to: host.localID, in: host)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: host.localID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)
        let otherID = try XCTUnwrap(host.authoritativeGame?.players.first { $0.id != host.localID }?.id)
        host.applyMinerDig(taps: 20, session: session)

        // Drain the bucket, then backdate the stamp by a full cooldown so exactly
        // one more rock is owed.
        host.routeMiningTap(MiningTapReport(sessionID: session.id, taps: 12), from: otherID)
        host.routeMiningTap(MiningTapReport(sessionID: session.id, taps: 12), from: otherID)
        let drained = host.miningPile.remaining
        host.miningThrowStamp[otherID] = Date().addingTimeInterval(-MiningBalance.throwCooldown)

        host.routeMiningTap(MiningTapReport(sessionID: session.id, taps: 12), from: otherID)
        XCTAssertEqual(
            host.miningPile.remaining - drained,
            MiningBalance.rocksPerOpponentTap,
            "one cooldown owes exactly one rock"
        )
    }

    /// The cooldown is deliberately one-sided.
    func testTheMinerHasNoCooldown() throws {
        let (host, _) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        giveTurn(to: host.localID, in: host)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: host.localID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        let session = try XCTUnwrap(host.mining)

        for tap in 1 ... 5 {
            host.reportMiningTap()
            XCTAssertEqual(
                host.miningPile.remaining,
                max(session.pileTotal - tap * session.shovelSize, 0),
                "dig \(tap) landed with no throttling"
            )
        }
    }

    /// A thrower's own screen must show only what will actually land.
    func testAThrowersLocalPileHonoursTheSameCooldown() throws {
        let (host, client) = try startedMatch(sameColorChance: 100, lastPlaceChance: 0)
        giveTurn(to: host.localID, in: host)
        host.apply(.take(tokens: [.diamond: 2], returning: [:]), from: host.localID, allowsPass: true)
        host.startPendingMiningIfNeeded()
        host.broadcastGame()
        let session = try XCTUnwrap(client.mining)
        client.miningPile.remaining = 40

        client.reportMiningTap()
        let afterFirst = client.miningPile.remaining
        XCTAssertEqual(afterFirst, 40 + MiningBalance.rocksPerOpponentTap)

        // Immediately again: swallowed, because the host would drop it too.
        client.reportMiningTap()
        XCTAssertEqual(client.miningPile.remaining, afterFirst, "mashing shows nothing extra")
        XCTAssertEqual(client.miningLocalTaps, 1, "and nothing extra is queued")
        _ = session
    }

    // MARK: - Helpers

    /// A live two-seat match with the opening roulette already elapsed.
    private func startedMatch(
        mode: MultiplayerMode = .lan,
        bots: Int = 0,
        enabled: Bool = true,
        sameColorChance: Int,
        lastPlaceChance: Int
    ) throws -> (MatchSessionService, MatchSessionService) {
        let hostTransport = FakeMatchTransport(mode: mode)
        let clientTransport = FakeMatchTransport(mode: mode)
        hostTransport.other = clientTransport
        clientTransport.other = hostTransport

        let host = MatchSessionService(localID: UUID(), nickname: "Host", mode: mode, transport: hostTransport)
        let client = MatchSessionService(localID: UUID(), nickname: "Guest", mode: mode, transport: clientTransport)
        host.host(roomName: "Mining", password: "")
        client.join(DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)), password: "")
        for _ in 0 ..< bots { host.addBot(difficulty: .normal) }
        host.enterConfiguration()

        var configuration = try XCTUnwrap(host.room?.configuration)
        configuration.mining = MiningRules(
            isEnabled: enabled,
            lastPlaceChance: lastPlaceChance,
            sameColorChance: sameColorChance
        )
        host.updateConfiguration(configuration)
        host.startGame()
        host.openingTurnSelection = OpeningTurnSelection(
            startedAt: Date().addingTimeInterval(-2),
            endsAt: Date().addingTimeInterval(-1)
        )
        host.scheduleOpeningTurnCompletion()
        // Fixed rolls: 0 always clears a non-zero chance and always picks the first
        // token in the weighted bag, so every trigger below is deterministic.
        host.miningRandom = { 0 }
        return (host, client)
    }

    /// Rotates the turn to a chosen seat so a test can pin who ends up mining —
    /// `startGame` picks the opening seat at random. Deliberately does not touch
    /// `startingPlayerIndex`, so don't use this in tests that count rounds.
    private func giveTurn(to playerID: UUID, in host: MatchSessionService) {
        guard var state = host.authoritativeGame,
              let index = state.players.firstIndex(where: { $0.id == playerID })
        else { return XCTFail("no such seat") }
        state.currentPlayerIndex = index
        host.authoritativeGame = state
    }

    private func award(_ host: MatchSessionService, playerID: UUID, prestige: Int) {
        guard var state = host.authoritativeGame,
              let index = state.players.firstIndex(where: { $0.id == playerID })
        else { return XCTFail("no such seat") }
        state.players[index].purchasedCards.append(DevelopmentCard(
            id: "test-award-\(playerID)",
            tier: 3,
            prestige: prestige,
            bonus: .ruby,
            cost: [:]
        ))
        host.authoritativeGame = state
    }

    private func fill(_ host: MatchSessionService, playerID: UUID, tokens: [GemColor: Int]) {
        guard var state = host.authoritativeGame,
              let index = state.players.firstIndex(where: { $0.id == playerID })
        else { return XCTFail("no such seat") }
        state.players[index].tokens = tokens
        host.authoritativeGame = state
    }
}
