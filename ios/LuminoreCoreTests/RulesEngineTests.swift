import XCTest
@testable import LuminoreCore

final class RulesEngineTests: XCTestCase {
    private let rules = StandardRuleset()

    func testGameSetupDealsMarketAndNoblesForTwoThroughSevenPlayers() throws {
        for count in 2 ... 7 {
            let state = try makeGame(count: count, seed: UInt64(count))
            XCTAssertEqual(state.players.count, count)
            XCTAssertEqual(state.availableNobles.count, count + 1)
            XCTAssertEqual(state.market.values.flatMap { $0 }.count, 12)
            XCTAssertEqual(state.decks[1]?.count, 36)
            XCTAssertEqual(state.decks[2]?.count, 26)
            XCTAssertEqual(state.decks[3]?.count, 16)
        }
    }

    func testTakeThreeDifferentTokensAndAdvanceTurn() throws {
        var state = try makeGame(count: 2)
        let playerID = state.currentPlayer.id
        let nextID = state.players[(state.currentPlayerIndex + 1) % 2].id
        try rules.apply(.take(tokens: [.diamond: 1, .sapphire: 1, .ruby: 1], returning: [:]), playerID: playerID, to: &state)
        let player = try XCTUnwrap(state.players.first { $0.id == playerID })
        XCTAssertEqual(player.tokenCount, 3)
        XCTAssertEqual(state.bank[.diamond], 3)
        XCTAssertEqual(state.currentPlayer.id, nextID)
    }

    func testRandomFirstPlayerThenTurnsFollowSeatOrder() throws {
        for count in 2 ... 7 {
            var state = try makeGame(count: count, seed: UInt64(100 + count))
            let startingIndex = state.startingPlayerIndex
            XCTAssertEqual(state.currentPlayerIndex, startingIndex)

            for offset in 1 ... count {
                try rules.apply(.pass, playerID: state.currentPlayer.id, to: &state)
                XCTAssertEqual(state.currentPlayerIndex, (startingIndex + offset) % count)
            }
        }
    }

    func testPlayerMayTakeOnlyOneToken() throws {
        var state = try makeGame(count: 2)
        let id = state.currentPlayer.id
        try rules.apply(.take(tokens: [.diamond: 1], returning: [:]), playerID: id, to: &state)
        XCTAssertEqual(state.players.first { $0.id == id }?.tokens[.diamond], 1)
    }

    func testPlayerMayVoluntarilyPass() throws {
        var state = try makeGame(count: 2)
        let id = state.currentPlayer.id
        let revision = state.revision
        try rules.apply(.pass, playerID: id, to: &state)
        XCTAssertNotEqual(state.currentPlayer.id, id)
        XCTAssertEqual(state.revision, revision + 1)
    }

    func testTakingTwoRequiresFourTokensBeforeTheAction() throws {
        var state = try makeGame(count: 2)
        let playerID = state.currentPlayer.id
        state.bank[.diamond] = 3
        let original = state
        XCTAssertThrowsError(try rules.apply(.take(tokens: [.diamond: 2], returning: [:]), playerID: playerID, to: &state))
        XCTAssertEqual(state, original, "Rejected commands must be atomic")
    }

    func testTokenLimitRequiresExactReturns() throws {
        var state = try makeGame(count: 2)
        let index = state.currentPlayerIndex
        for color in GemColor.purchasableColors { state.players[index].tokens[color] = 2 }
        let id = state.currentPlayer.id
        let picks: [GemColor: Int] = [.diamond: 1, .sapphire: 1, .ruby: 1]
        XCTAssertThrowsError(try rules.apply(.take(tokens: picks, returning: [:]), playerID: id, to: &state))
        try rules.apply(
            .take(tokens: picks, returning: [.diamond: 1, .sapphire: 1, .ruby: 1]),
            playerID: id,
            to: &state
        )
        XCTAssertEqual(state.players[index].tokenCount, 10)
    }

    func testReserveMarketCardAwardsGoldAndRefillsMarket() throws {
        var state = try makeGame(count: 2)
        let playerID = state.currentPlayer.id
        let marketBefore = try XCTUnwrap(state.market[1])
        let card = marketBefore[1]
        let replacement = try XCTUnwrap(state.decks[1]?.last)
        let deckCount = try XCTUnwrap(state.decks[1]?.count)
        try rules.apply(.reserve(source: .market(cardID: card.id), returning: [:]), playerID: playerID, to: &state)
        let player = try XCTUnwrap(state.players.first { $0.id == playerID })
        XCTAssertEqual(player.reservedCards.first?.id, card.id)
        XCTAssertEqual(player.tokens[.gold], 1)
        XCTAssertEqual(state.market[1]?.count, 4)
        XCTAssertEqual(state.market[1]?[0], marketBefore[0])
        XCTAssertEqual(state.market[1]?[1], replacement)
        XCTAssertEqual(state.market[1]?[2], marketBefore[2])
        XCTAssertEqual(state.market[1]?[3], marketBefore[3])
        XCTAssertEqual(state.decks[1]?.count, deckCount - 1)
    }

    func testReserveRequiresAvailableGoldAndIsAtomic() throws {
        var state = try makeGame(count: 2)
        let playerID = state.currentPlayer.id
        state.bank[.gold] = 0
        let cardID = try XCTUnwrap(state.market[1]?.first?.id)
        let original = state

        XCTAssertThrowsError(
            try rules.apply(
                .reserve(source: .market(cardID: cardID), returning: [:]),
                playerID: playerID,
                to: &state
            )
        ) { error in
            XCTAssertEqual(error as? GameRuleError, .noGoldAvailable)
        }
        XCTAssertEqual(state, original, "Rejected reserve must not remove or refill a card")
    }

    func testPurchaseMarketCardRefillsItsOriginalPosition() throws {
        var state = try makeGame(count: 2)
        let index = state.currentPlayerIndex
        let playerID = state.currentPlayer.id
        let marketBefore = try XCTUnwrap(state.market[1])
        let card = marketBefore[2]
        let replacement = try XCTUnwrap(state.decks[1]?.last)

        for color in GemColor.purchasableColors {
            state.players[index].tokens[color] = card.cost[color, default: 0]
        }
        try rules.apply(
            .purchase(source: .market(cardID: card.id), payment: card.cost, nobleID: nil),
            playerID: playerID,
            to: &state
        )

        XCTAssertEqual(state.market[1]?[0], marketBefore[0])
        XCTAssertEqual(state.market[1]?[1], marketBefore[1])
        XCTAssertEqual(state.market[1]?[2], replacement)
        XCTAssertEqual(state.market[1]?[3], marketBefore[3])
    }

    func testPurchaseUsesChosenColoredAndGoldPayment() throws {
        var state = try makeGame(count: 2)
        let index = state.currentPlayerIndex
        let playerID = state.currentPlayer.id
        let card = try XCTUnwrap(state.market[1]?.first)
        var payment: [GemColor: Int] = [:]
        var usedGold = false
        for color in GemColor.purchasableColors {
            let required = card.cost[color, default: 0]
            if required > 0, !usedGold {
                state.players[index].tokens[color] = max(0, required - 1)
                payment[color] = max(0, required - 1)
                usedGold = true
            } else {
                state.players[index].tokens[color] = required
                payment[color] = required
            }
        }
        state.players[index].tokens[.gold] = usedGold ? 1 : 0
        if usedGold { payment[.gold] = 1 }
        try rules.apply(.purchase(source: .market(cardID: card.id), payment: payment, nobleID: nil), playerID: playerID, to: &state)
        let player = try XCTUnwrap(state.players.first { $0.id == playerID })
        XCTAssertTrue(player.purchasedCards.contains(card))
        XCTAssertEqual(player.tokenCount, 0)
    }

    func testPreferredPurchaseUsesColoredTokensBeforeGold() {
        let card = DevelopmentCard(
            id: "preferred-payment",
            tier: 1,
            prestige: 0,
            bonus: .emerald,
            cost: [.diamond: 3, .sapphire: 2]
        )
        let existingBonus = DevelopmentCard(
            id: "existing-bonus",
            tier: 1,
            prestige: 0,
            bonus: .diamond,
            cost: [:]
        )
        let player = PublicPlayerSnapshot(
            id: UUID(),
            nickname: "Player",
            kind: .human,
            isConnected: true,
            tokens: [.diamond: 2, .sapphire: 1, .gold: 1],
            purchasedCards: [existingBonus],
            reservedCards: [],
            reservedCardCount: 0,
            nobles: [],
            prestige: 0
        )

        let decision = PurchasePlanner.preferredDecision(
            for: card,
            player: player,
            availableNobles: []
        )

        XCTAssertEqual(decision?.payment, [.diamond: 2, .sapphire: 1, .gold: 1])
    }

    func testInvalidPaymentLeavesStateUnchanged() throws {
        var state = try makeGame(count: 2)
        let card = try XCTUnwrap(state.market[3]?.first)
        let id = state.currentPlayer.id
        let original = state
        XCTAssertThrowsError(try rules.apply(.purchase(source: .market(cardID: card.id), payment: [:], nobleID: nil), playerID: id, to: &state))
        XCTAssertEqual(state, original)
    }

    func testDisconnectedPlayersKeepAssetsAndAreSkipped() throws {
        var state = try makeGame(count: 3)
        let disconnectedID = state.currentPlayer.id
        state.players[state.currentPlayerIndex].tokens[.ruby] = 2
        rules.setConnection(false, playerID: disconnectedID, in: &state)
        XCTAssertNotEqual(state.currentPlayer.id, disconnectedID)
        let disconnected = try XCTUnwrap(state.players.first { $0.id == disconnectedID })
        XCTAssertEqual(disconnected.tokens[.ruby], 2)
        XCTAssertFalse(disconnected.isConnected)
    }

    func testSetConnectionWithSkipTurnsFalseKeepsCurrentPlayer() throws {
        var state = try makeGame(count: 3)
        let currentID = state.currentPlayer.id
        // A brief blip must not steal the current player's turn; skipping is the
        // caller's decision (e.g. after the reconnect-grace window expires).
        rules.setConnection(false, playerID: currentID, skipTurns: false, in: &state)
        XCTAssertEqual(state.currentPlayer.id, currentID)
        XCTAssertFalse(try XCTUnwrap(state.players.first { $0.id == currentID }).isConnected)
    }

    func testFinalRoundFinishesWhenDisconnectedSeatsCrossRoundBoundary() throws {
        var state = try makeGame(count: 3)
        let startingID = state.players[state.startingPlayerIndex].id
        let triggeringIndex = (state.startingPlayerIndex + 1) % state.players.count
        let nextIndex = (state.startingPlayerIndex + 2) % state.players.count
        state.currentPlayerIndex = triggeringIndex
        state.players[triggeringIndex].purchasedCards.append(
            DevelopmentCard(id: "winning-disconnect", tier: 3, prestige: 15, bonus: .ruby, cost: [:])
        )
        state.players[state.startingPlayerIndex].isConnected = false
        state.players[nextIndex].isConnected = false
        let triggerID = state.players[triggeringIndex].id

        try rules.apply(.pass, playerID: triggerID, to: &state)

        XCTAssertEqual(state.status, .finished)
        XCTAssertEqual(state.result?.winnerIDs, [triggerID])
        XCTAssertNotEqual(startingID, triggerID)
    }

    func testNegativeTokenCountsAreRejectedAtomically() throws {
        var state = try makeGame(count: 2)
        let original = state
        XCTAssertThrowsError(
            try rules.apply(
                .take(tokens: [.diamond: 1, .ruby: 1, .emerald: 1], returning: [.gold: -1]),
                playerID: state.currentPlayer.id,
                to: &state
            )
        )
        XCTAssertEqual(state, original)
    }

    func testFinalRoundAndTieBreaker() throws {
        var state = try makeGame(count: 2)
        let triggeringID = state.currentPlayer.id
        state.players[state.currentPlayerIndex].purchasedCards.append(
            DevelopmentCard(id: "winning", tier: 3, prestige: 15, bonus: .ruby, cost: [:])
        )
        try rules.apply(.pass, playerID: triggeringID, to: &state)
        while state.status == .playing {
            try rules.apply(.pass, playerID: state.currentPlayer.id, to: &state)
        }
        XCTAssertEqual(state.result?.winnerIDs, [triggeringID])
        XCTAssertEqual(state.result?.standings.first?.rank, 1)
    }

    func testFinishedGameAwardsEachHumanWinnerOneMedalPerHumanLoser() throws {
        let winnerOne = Participant(id: UUID(), nickname: "Winner One", medalCount: 3)
        let winnerTwo = Participant(id: UUID(), nickname: "Winner Two", medalCount: 8)
        let disconnectedLoser = Participant(
            id: UUID(),
            nickname: "Offline",
            medalCount: 5,
            isConnected: false
        )
        let bot = Participant(id: UUID(), nickname: "Bot", kind: .bot, medalCount: 99)
        var state = try rules.makeGame(
            participants: [winnerOne, winnerTwo, disconnectedLoser, bot],
            configuration: .init(),
            seed: 9
        )
        state.players[0].purchasedCards = [
            DevelopmentCard(id: "winner-one", tier: 3, prestige: 15, bonus: .ruby, cost: [:])
        ]
        state.players[1].purchasedCards = [
            DevelopmentCard(id: "winner-two", tier: 3, prestige: 15, bonus: .onyx, cost: [:])
        ]

        try finishGame(&state)

        XCTAssertEqual(Set(state.result?.winnerIDs ?? []), Set([winnerOne.id, winnerTwo.id]))
        XCTAssertEqual(state.players[0].medalCount, 4)
        XCTAssertEqual(state.players[1].medalCount, 9)
        XCTAssertEqual(state.players[2].medalCount, 5)
        XCTAssertEqual(state.players[3].medalCount, 99)
    }

    func testAllHumanTieCreatesNoMedals() throws {
        let participants = (0 ..< 4).map {
            Participant(id: UUID(), nickname: "Tie \($0)", medalCount: $0 + 1)
        }
        var state = try rules.makeGame(participants: participants, configuration: .init(), seed: 11)

        try finishGame(&state)

        XCTAssertEqual(state.result?.winnerIDs.count, participants.count)
        XCTAssertEqual(state.players.map(\.medalCount), [1, 2, 3, 4])
    }

    func testSevenPlayerWinnerReceivesSixMedals() throws {
        var state = try makeGame(count: 7)
        state.players[0].medalCount = 12
        state.players[0].purchasedCards = [
            DevelopmentCard(id: "large-table-winner", tier: 3, prestige: 15, bonus: .emerald, cost: [:])
        ]

        try finishGame(&state)

        XCTAssertEqual(state.result?.winnerIDs, [state.players[0].id])
        XCTAssertEqual(state.players[0].medalCount, 18)
    }

    func testEqualPrestigeSharesRankRegardlessOfCardCount() throws {
        var state = try makeGame(count: 3)
        state.players[0].purchasedCards = [
            DevelopmentCard(id: "few-cards", tier: 3, prestige: 15, bonus: .ruby, cost: [:])
        ]
        state.players[1].purchasedCards = (0 ..< 3).map {
            DevelopmentCard(id: "many-cards-\($0)", tier: 2, prestige: 5, bonus: .onyx, cost: [:])
        }
        state.players[2].purchasedCards = [
            DevelopmentCard(id: "runner-up", tier: 2, prestige: 8, bonus: .emerald, cost: [:])
        ]

        try finishGame(&state)

        let result = try XCTUnwrap(state.result)
        XCTAssertEqual(Set(result.winnerIDs), Set([state.players[0].id, state.players[1].id]))
        XCTAssertEqual(result.standings.map(\.rank), [1, 1, 3])
        XCTAssertEqual(result.standings.map(\.isWinner), [true, true, false])
        // 并列冠军互不发奖章，只从落败的人类玩家各收一枚。
        XCTAssertEqual(state.players.map(\.medalCount), [1, 1, 0])
    }

    func testClientSnapshotExposesEveryPlayersReservedCards() throws {
        var state = try makeGame(count: 2)
        let first = state.players[0].id
        let second = state.players[1].id
        state.players[0].reservedCards = [StandardCatalog.cards[0]]
        state.players[1].reservedCards = [StandardCatalog.cards[1], StandardCatalog.cards[2]]
        let snapshot = state.snapshot(for: first)
        XCTAssertEqual(snapshot.localReservedCards.map(\.id), [StandardCatalog.cards[0].id])
        let opponent = try XCTUnwrap(snapshot.players.first { $0.id == second })
        XCTAssertEqual(opponent.reservedCardCount, 2)
        XCTAssertEqual(opponent.reservedCards.map(\.id), [
            StandardCatalog.cards[1].id,
            StandardCatalog.cards[2].id,
        ])
    }

    // MARK: - Custom standard rules

    func testCustomSetupDrivesBankDecksAndNobles() throws {
        var custom = StandardCustomRules.standard(playerCount: 4)
        custom.gemCount = 12
        custom.goldCount = 2
        custom.tier1DeckCount = 15
        custom.tier2DeckCount = 12
        custom.tier3DeckCount = 9
        custom.nobleCount = 2

        let state = try makeGame(count: 4, custom: custom)
        XCTAssertTrue(GemColor.purchasableColors.allSatisfy { state.bank[$0] == 12 })
        XCTAssertEqual(state.bank[.gold], 2)
        XCTAssertEqual(state.availableNobles.count, 2)
        // Each tier still opens four face-up cards; the rest stays in the deck.
        for tier in 1 ... 3 {
            XCTAssertEqual(state.market[tier]?.count, 4)
        }
        XCTAssertEqual(state.decks[1]?.count, 11)
        XCTAssertEqual(state.decks[2]?.count, 8)
        XCTAssertEqual(state.decks[3]?.count, 5)
    }

    func testCustomDeckIsADifferentRandomSubsetPerSeed() throws {
        var custom = StandardCustomRules.standard(playerCount: 2)
        custom.tier1DeckCount = 10
        let first = try makeGame(count: 2, seed: 1, custom: custom)
        let second = try makeGame(count: 2, seed: 2, custom: custom)
        let ids = { (state: GameState) in
            Set((state.market[1] ?? []).map(\.id)).union((state.decks[1] ?? []).map(\.id))
        }
        XCTAssertEqual(ids(first).count, 10)
        XCTAssertNotEqual(ids(first), ids(second))
    }

    func testNilCustomRulesReproduceThePrintedSetup() throws {
        for count in 2 ... 7 {
            let auto = try makeGame(count: count, seed: 7)
            let explicit = try makeGame(count: count, seed: 7, custom: .standard(playerCount: count))
            XCTAssertEqual(auto.bank, explicit.bank)
            XCTAssertEqual(auto.availableNobles.count, explicit.availableNobles.count)
            XCTAssertEqual(auto.decks.mapValues(\.count), explicit.decks.mapValues(\.count))
        }
    }

    func testCustomReserveLimitIsEnforced() throws {
        var custom = StandardCustomRules.standard(playerCount: 2)
        custom.reserveLimit = 1
        var state = try makeGame(count: 2, custom: custom)
        let playerID = state.currentPlayer.id
        let index = state.currentPlayerIndex
        let first = try XCTUnwrap(state.market[1]?.first)
        try rules.apply(.reserve(source: .market(cardID: first.id), returning: [:]), playerID: playerID, to: &state)

        // Back around to the same seat for a second reserve.
        state.currentPlayerIndex = index
        let second = try XCTUnwrap(state.market[2]?.first)
        XCTAssertThrowsError(
            try rules.apply(.reserve(source: .market(cardID: second.id), returning: [:]), playerID: playerID, to: &state)
        ) { error in
            XCTAssertEqual(error as? GameRuleError, .reserveLimitReached)
        }
    }

    func testCustomTokenLimitDecidesRequiredReturns() throws {
        var custom = StandardCustomRules.standard(playerCount: 2)
        custom.tokenLimit = 12
        var state = try makeGame(count: 2, custom: custom)
        let index = state.currentPlayerIndex
        for color in GemColor.purchasableColors { state.players[index].tokens[color] = 2 }
        let id = state.currentPlayer.id
        let picks: [GemColor: Int] = [.diamond: 1, .sapphire: 1, .ruby: 1]

        // 10 + 3 = 13 is one over the raised cap, so exactly one token comes back.
        XCTAssertThrowsError(try rules.apply(.take(tokens: picks, returning: [:]), playerID: id, to: &state))
        try rules.apply(.take(tokens: picks, returning: [.diamond: 1]), playerID: id, to: &state)
        XCTAssertEqual(state.players[index].tokenCount, 12)
    }

    func testCustomRulesAreClampedToSupportedRanges() {
        let custom = StandardCustomRules(
            gemCount: 999,
            goldCount: -5,
            tier1DeckCount: 999,
            tier2DeckCount: 0,
            tier3DeckCount: 999,
            nobleCount: 99,
            tokenLimit: 1,
            reserveLimit: 99
        )
        XCTAssertEqual(custom.gemCount, StandardCustomRules.gemRange.upperBound)
        XCTAssertEqual(custom.goldCount, StandardCustomRules.goldRange.lowerBound)
        XCTAssertEqual(custom.tier1DeckCount, StandardCustomRules.catalogCount(tier: 1))
        XCTAssertEqual(custom.tier2DeckCount, StandardCustomRules.marketRowSize)
        XCTAssertEqual(custom.tier3DeckCount, StandardCustomRules.catalogCount(tier: 3))
        XCTAssertEqual(custom.nobleCount, StandardCustomRules.nobleRange.upperBound)
        XCTAssertEqual(custom.tokenLimit, StandardCustomRules.tokenLimitRange.lowerBound)
        XCTAssertEqual(custom.reserveLimit, StandardCustomRules.reserveLimitRange.upperBound)
    }

    private func makeGame(
        count: Int,
        seed: UInt64 = 42,
        custom: StandardCustomRules? = nil
    ) throws -> GameState {
        let participants = (0 ..< count).map {
            Participant(id: UUID(), nickname: "Player \($0)", isHost: $0 == 0)
        }
        return try rules.makeGame(
            participants: participants,
            configuration: .init(customStandardRules: custom),
            seed: seed
        )
    }

    private func finishGame(_ state: inout GameState) throws {
        state.finalRoundTriggered = true
        state.currentPlayerIndex = (state.startingPlayerIndex - 1 + state.players.count) % state.players.count
        try rules.apply(.pass, playerID: state.currentPlayer.id, to: &state)
        XCTAssertEqual(state.status, .finished)
    }
}
