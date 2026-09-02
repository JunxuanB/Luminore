import XCTest
@testable import LuminoreCore

final class MiningTests: XCTestCase {
    private let rules = StandardRuleset()

    // MARK: - Rules

    func testChancesAreClampedToZeroThroughOneHundred() {
        XCTAssertEqual(MiningRules(lastPlaceChance: 400, sameColorChance: -25).lastPlaceChance, 100)
        XCTAssertEqual(MiningRules(lastPlaceChance: 400, sameColorChance: -25).sameColorChance, 0)
    }

    func testDefaultsAreOffAtTwentyFiveAndTwenty() {
        let rules = MiningRules()
        XCTAssertFalse(rules.isEnabled)
        XCTAssertEqual(rules.lastPlaceChance, 25)
        XCTAssertEqual(rules.sameColorChance, 20)
    }

    func testDecodingToleratesMissingFieldsAndClampsWhatIsThere() throws {
        let decoded = try JSONDecoder().decode(
            MiningRules.self,
            from: Data(#"{"isEnabled":true,"lastPlaceChance":250}"#.utf8)
        )
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.lastPlaceChance, 100)
        // Absent field falls back to the default rather than zero.
        XCTAssertEqual(decoded.sameColorChance, 20)
    }

    /// A peer on an older build sends a configuration with no `mining` key at all.
    func testConfigurationWithoutMiningKeyDecodesToDefaults() throws {
        let json = #"{"mode":"standard","targetPrestige":15,"turnGracePeriodEnabled":true,"affordableCardHighlightEnabled":true}"#
        let configuration = try JSONDecoder().decode(GameConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(configuration.mining.isEnabled)
        XCTAssertEqual(configuration.mining.lastPlaceChance, 25)
    }

    func testConfigurationRoundTripPreservesMining() throws {
        let configuration = GameConfiguration(
            mining: MiningRules(isEnabled: true, lastPlaceChance: 40, sameColorChance: 5)
        )
        let decoded = try JSONDecoder().decode(
            GameConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.mining.lastPlaceChance, 40)
        XCTAssertEqual(decoded.mining.sameColorChance, 5)
    }

    // MARK: - Balance

    /// The dig has to stay winnable at every table size. This recomputes the
    /// break-even tap rate from the balance constants, so a future tweak to the
    /// window, the pile or the shovel curve that pushes it out of human reach
    /// fails here instead of in somebody's game.
    func testBreakEvenTapRateStaysInAHumanBandForEveryTableSize() {
        let opponentRate = 5.5 // a competent human throwing rocks back
        let debt = Double(MiningBalance.pileTotal - MiningBalance.successThreshold)
        for players in 2 ... 7 {
            let opponents = players - 1
            let shovel = Double(MiningBalance.shovelSize(opponentCount: opponents))
            let thrown = Double(opponents) * opponentRate * MiningBalance.duration
            let required = (debt + thrown) / (MiningBalance.duration * shovel)
            XCTAssertGreaterThan(required, 3.0, "\(players) players: too easy to be a race")
            XCTAssertLessThan(required, 5.5, "\(players) players: beyond a sustainable tap rate")
        }
    }

    func testBotRatesRiseWithDifficulty() {
        let dig = BotDifficulty.allCases.map(MiningBalance.botDigMultiplier)
        let rocks = BotDifficulty.allCases.map(MiningBalance.botRockTapsPerSecond)
        XCTAssertEqual(dig, dig.sorted(), "a harder bot must dig faster")
        XCTAssertEqual(rocks, rocks.sorted(), "a harder bot must throw faster")
        XCTAssertEqual(BotDifficulty.allCases.map(\.rawValue), ["easy", "normal", "hard"])
    }

    /// A bot miner aims at a multiple of what the dig actually demands, so its
    /// difficulty has to bracket the break-even line: easy short of it, hard past
    /// it. A fixed taps-per-second is what left bots hopeless as miners.
    func testBotDigMultipliersBracketBreakEven() {
        XCTAssertLessThan(MiningBalance.botDigMultiplier(.easy), 1.0)
        XCTAssertGreaterThan(MiningBalance.botDigMultiplier(.normal), 1.0)
        XCTAssertGreaterThan(
            MiningBalance.botDigMultiplier(.hard),
            MiningBalance.botDigMultiplier(.normal)
        )
    }

    /// The shovel is solved from `targetMinerTapsPerSecond`, so the demand on a
    /// miner must stay flat as the table grows rather than climbing out of reach.
    func testTheShovelKeepsTheDemandFlatAsTheTableGrows() {
        let debt = Double(MiningBalance.pileTotal - MiningBalance.successThreshold)
        var rates: [Double] = []
        for players in 2 ... 7 {
            let opponents = players - 1
            let shovel = Double(MiningBalance.shovelSize(opponentCount: opponents))
            let thrown = Double(opponents) * MiningBalance.referenceOpponentTapsPerSecond
                * MiningBalance.duration
            rates.append((debt + thrown) / (MiningBalance.duration * shovel))
        }
        let spread = (rates.max() ?? 0) - (rates.min() ?? 0)
        XCTAssertLessThan(spread, 0.6, "difficulty drifts with table size: \(rates)")
        for rate in rates {
            XCTAssertEqual(rate, MiningBalance.targetMinerTapsPerSecond, accuracy: 0.6)
        }
    }

    func testTheShovelGrowsWithTheTableAndStaysInRange() {
        var previous = 0
        for opponents in 1 ... 6 {
            let shovel = MiningBalance.shovelSize(opponentCount: opponents)
            XCTAssertGreaterThanOrEqual(shovel, previous, "more opponents never means a smaller shovel")
            XCTAssertTrue(MiningBalance.shovelRange.contains(shovel))
            previous = shovel
        }
        XCTAssertEqual(MiningBalance.shovelSize(opponentCount: 0), MiningBalance.shovelRange.lowerBound)
        XCTAssertEqual(MiningBalance.shovelSize(opponentCount: 400), MiningBalance.shovelRange.upperBound)
    }

    // MARK: - Snapshot    // MARK: - Snapshot

    func testSnapshotRoundTripsAndClampsThreshold() throws {
        let session = MiningSnapshot(
            minerID: UUID(),
            minerNickname: "Ang",
            gem: .ruby,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endsAt: Date(timeIntervalSince1970: 1_005),
            shovelSize: 5
        )
        let decoded = try JSONDecoder().decode(
            MiningSnapshot.self,
            from: JSONEncoder().encode(session)
        )
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.phase, .digging)
        XCTAssertNil(decoded.outcome)
    }

    func testPhaseChangeKeepsTheWindowIdentity() {
        let session = MiningSnapshot(
            minerID: UUID(),
            minerNickname: "Ang",
            gem: .onyx,
            startedAt: Date(),
            endsAt: Date().addingTimeInterval(5),
            shovelSize: 4
        )
        let resolved = session.with(phase: .resolved, outcome: .success)
        XCTAssertEqual(resolved.id, session.id)
        XCTAssertEqual(resolved.gem, session.gem)
        XCTAssertEqual(resolved.outcome, .success)
        XCTAssertEqual(resolved.phase, .resolved)
    }

    func testProgressAndTapReportClampNegatives() {
        XCTAssertEqual(MiningProgress(sessionID: UUID(), remaining: -5, endsAt: Date()).remaining, 0)
        XCTAssertEqual(MiningTapReport(sessionID: UUID(), taps: -3).taps, 0)
        XCTAssertEqual(MiningDiscard(sessionID: UUID(), tokens: [.ruby: 2, .onyx: 0]).tokens, [.ruby: 2])
    }

    /// The whole point of keeping mining off `GameState`: existing snapshots from
    /// an older build must still decode, with no window.
    func testClientSnapshotWithoutMiningDecodesAsNoWindow() throws {
        var state = try makeGame(count: 3)
        state.bank[.ruby] = 4
        let snapshot = state.snapshot(for: state.players[0].id)
        XCTAssertNil(snapshot.mining)
        let decoded = try JSONDecoder().decode(
            ClientGameSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertNil(decoded.mining)
    }

    func testClientSnapshotCarriesTheMiningWindow() throws {
        let state = try makeGame(count: 3)
        let session = MiningSnapshot(
            minerID: state.players[1].id,
            minerNickname: state.players[1].nickname,
            gem: .emerald,
            startedAt: Date(timeIntervalSince1970: 2_000),
            endsAt: Date(timeIntervalSince1970: 2_005),
            shovelSize: 5
        )
        let decoded = try JSONDecoder().decode(
            ClientGameSnapshot.self,
            from: JSONEncoder().encode(state.snapshot(for: state.players[0].id, mining: session))
        )
        XCTAssertEqual(decoded.mining, session)
    }

    // MARK: - Standings

    func testRanksAreDenseAndSharedOnEqualPrestige() throws {
        var state = try makeGame(count: 4)
        award(&state, index: 0, prestige: 5)
        award(&state, index: 1, prestige: 3)
        award(&state, index: 2, prestige: 3)
        // players[3] stays on 0.
        let ranks = Standings.ranks(state.players)
        XCTAssertEqual(ranks[state.players[0].id], 1)
        XCTAssertEqual(ranks[state.players[1].id], 2)
        XCTAssertEqual(ranks[state.players[2].id], 2)
        // Two seats share rank 2, so the next distinct prestige is rank 4.
        XCTAssertEqual(ranks[state.players[3].id], 4)
    }

    /// The pre-sorted overload must agree with the sorting one.
    func testRanksAgreeWhetherOrNotTheRosterIsPreSorted() throws {
        var state = try makeGame(count: 5)
        award(&state, index: 0, prestige: 7)
        award(&state, index: 2, prestige: 3)
        award(&state, index: 4, prestige: 3)
        XCTAssertEqual(
            Standings.ranks(state.players),
            Standings.ranks(sorted: Standings.sorted(state.players))
        )
    }

    func testLastPlaceIsTheWorstRankAndCanBeShared() throws {
        var state = try makeGame(count: 3)
        award(&state, index: 0, prestige: 4)
        XCTAssertFalse(state.isInLastPlace(state.players[0].id))
        XCTAssertTrue(state.isInLastPlace(state.players[1].id))
        XCTAssertTrue(state.isInLastPlace(state.players[2].id))
    }

    /// Everyone level — the usual state for the first few turns — has no last
    /// place, otherwise a dig would fire on essentially every opening turn.
    func testNobodyIsLastWhenAllSeatsAreLevel() throws {
        let state = try makeGame(count: 4)
        for player in state.players {
            XCTAssertFalse(state.isInLastPlace(player.id))
        }
    }

    func testTwoPlayerLastPlaceIsTheTrailingSeat() throws {
        var state = try makeGame(count: 2)
        award(&state, index: 1, prestige: 2)
        XCTAssertTrue(state.isInLastPlace(state.players[0].id))
        XCTAssertFalse(state.isInLastPlace(state.players[1].id))
    }

    /// `finishGame` was refactored onto `Standings`; the two must agree exactly.
    func testFinalStandingRanksMatchTheSharedRanking() throws {
        var state = try makeGame(count: 4)
        award(&state, index: 0, prestige: 6)
        award(&state, index: 1, prestige: 6)
        award(&state, index: 2, prestige: 2)
        // Drive the game to its natural end so `finishGame` runs through `apply`.
        state.finalRoundTriggered = true
        state.currentPlayerIndex = (state.startingPlayerIndex + state.players.count - 1) % state.players.count
        try rules.apply(.pass, playerID: state.currentPlayer.id, to: &state)

        let result = try XCTUnwrap(state.result)
        let expected = Standings.ranks(state.players)
        for standing in result.standings {
            XCTAssertEqual(standing.rank, expected[standing.playerID], "seat \(standing.nickname)")
        }
        XCTAssertEqual(Set(result.winnerIDs), Set([state.players[0].id, state.players[1].id]))
    }

    // MARK: - Wire

    func testMiningMessagesRoundTripThroughTheEnvelope() throws {
        let sessionID = UUID()
        let payloads: [NetworkMessage] = [
            .miningTap(MiningTapReport(sessionID: sessionID, taps: 6)),
            .miningProgress(MiningProgress(
                sessionID: sessionID,
                remaining: 42,
                endsAt: Date(timeIntervalSince1970: 3_000)
            )),
            .miningDiscard(MiningDiscard(sessionID: sessionID, tokens: [.gold: 1, .ruby: 1])),
            .miningOutcome(MiningOutcomeReport(sessionID: sessionID, remaining: 7)),
        ]
        for payload in payloads {
            let envelope = WireEnvelope(roomID: UUID(), senderID: UUID(), sequence: 3, payload: payload)
            let decoded = try JSONDecoder().decode(
                WireEnvelope.self,
                from: JSONEncoder().encode(envelope)
            )
            XCTAssertEqual(decoded.payload, payload)
        }
    }

    func testMiningTapFixtureDecodes() throws {
        let json = #"{"messageID":"77777777-7777-7777-7777-777777777777","payload":{"miningTap":{"sessionID":"88888888-8888-8888-8888-888888888888","taps":5},"type":"miningTap"},"protocolVersion":1,"roomID":"22222222-2222-2222-2222-222222222222","senderID":"33333333-3333-3333-3333-333333333333","sequence":13}"#
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(json.utf8))
        guard case let .miningTap(report) = envelope.payload else {
            return XCTFail("expected a miningTap payload")
        }
        XCTAssertEqual(report.taps, 5)
        XCTAssertEqual(report.sessionID, UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
    }

    func testMiningProgressFixtureDecodes() throws {
        let json = #"{"messageID":"99999999-9999-9999-9999-999999999999","payload":{"miningProgress":{"endsAt":774316805,"remaining":18,"sessionID":"88888888-8888-8888-8888-888888888888"},"type":"miningProgress"},"protocolVersion":1,"roomID":"22222222-2222-2222-2222-222222222222","senderID":"33333333-3333-3333-3333-333333333333","sequence":14}"#
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(json.utf8))
        guard case let .miningProgress(progress) = envelope.payload else {
            return XCTFail("expected a miningProgress payload")
        }
        XCTAssertEqual(progress.remaining, 18)
        XCTAssertEqual(progress.endsAt, Date(timeIntervalSinceReferenceDate: 774_316_805))
    }

    // MARK: - Helpers

    private func makeGame(count: Int, seed: UInt64 = 42) throws -> GameState {
        let participants = (0 ..< count).map {
            Participant(id: UUID(), nickname: "Player \($0)", isHost: $0 == 0)
        }
        return try rules.makeGame(participants: participants, configuration: .init(), seed: seed)
    }

    /// Gives a seat exactly `prestige` points by handing it catalog cards.
    private func award(_ state: inout GameState, index: Int, prestige: Int) {
        var remaining = prestige
        var suffix = 0
        while remaining > 0 {
            let value = min(remaining, 3)
            state.players[index].purchasedCards.append(DevelopmentCard(
                id: "test-\(index)-\(suffix)",
                tier: 3,
                prestige: value,
                bonus: .ruby,
                cost: [:]
            ))
            remaining -= value
            suffix += 1
        }
    }
}
