import LuminoreCore
import SwiftData
import XCTest
@testable import Luminore

@MainActor
final class PersistenceModelsTests: XCTestCase {
    // A single shared in-memory container for the whole test class. iOS 26's
    // SwiftData traps when several ModelContainers for the same schema are alive at
    // once in one process (here the test host app already owns one), so we create
    // exactly one and give each test an isolated child context inside it.
    private static let sharedContainer: ModelContainer = {
        let schema = Schema([
            AccountProfile.self, MedalRecord.self, CompletedGameRecord.self, PresenceLease.self,
            GameSaveRecord.self
        ])
        // cloudKitDatabase: .none keeps the in-memory store from attaching CloudKit
        // mirroring (which the app's entitlement would otherwise trigger and crash).
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(Self.sharedContainer)
        // Shared container ⇒ wipe prior tests' rows so each test starts empty.
        try context.delete(model: AccountProfile.self)
        try context.delete(model: MedalRecord.self)
        try context.delete(model: CompletedGameRecord.self)
        try context.delete(model: PresenceLease.self)
        try context.delete(model: GameSaveRecord.self)
        try context.save()
        return context
    }

    private func makeSave(
        ownerKey: String,
        roomName: String = "Saturday Night",
        seats: [Participant] = [],
        savedAt: Date = Date()
    ) throws -> GameSaveRecord {
        GameSaveRecord(
            ownerKey: ownerKey,
            gameID: UUID(),
            roomName: roomName,
            modeRawValue: GameMode.standard.rawValue,
            playerCount: max(seats.count, 1),
            currentSeatNickname: seats.first?.nickname ?? "Ada",
            statePayload: Data([1, 2, 3]),
            seatsPayload: try JSONEncoder().encode(seats),
            savedAt: savedAt
        )
    }

    /// End-to-end: a real host saves a live match, and a later room loads it back
    /// with the same people. Covers what the browser reads off the record and what
    /// the loader puts back into a session.
    func testHostSaveRoundTripsThroughTheStoreAndReloadsIntoANewRoom() throws {
        let context = try makeContext()
        let hostID = UUID()
        let guestID = UUID()
        let seats = [
            Participant(id: hostID, nickname: "Host", isHost: true),
            Participant(id: guestID, nickname: "Guest"),
        ]
        var state = try StandardRuleset().makeGame(participants: seats, configuration: .init(), seed: 3)
        state.players[1].tokens = [.onyx: 2]
        state.currentPlayerIndex = 1

        let host = MatchSessionService(localID: hostID, nickname: "Host", mode: .lan)
        host.isHost = true
        host.authoritativeGame = state
        host.room = RoomSnapshot(
            descriptor: RoomDescriptor(
                id: UUID(), name: "Saturday Night", hostNickname: "Host", playerCount: 2,
                isPasswordProtected: false, stage: .playing
            ),
            participants: seats
        )
        host.saveAndEndMatch(context: context)
        XCTAssertNil(host.presentedError)

        let ownerKey = hostID.uuidString
        let record = try XCTUnwrap(try context.fetch(
            FetchDescriptor<GameSaveRecord>(predicate: #Predicate { $0.ownerKey == ownerKey })
        ).first)
        // What the browser shows.
        XCTAssertEqual(record.roomName, "Saturday Night")
        XCTAssertEqual(record.playerCount, 2)
        XCTAssertEqual(record.currentSeatNickname, "Guest")
        XCTAssertEqual(record.seats.map(\.nickname), ["Host", "Guest"])

        // A fresh room with the same two accounts: the default same-UUID pairing.
        let reloaded = MatchSessionService(localID: hostID, nickname: "Host", mode: .lan)
        reloaded.isHost = true
        reloaded.room = RoomSnapshot(
            descriptor: RoomDescriptor(
                id: UUID(), name: "Sunday", hostNickname: "Host", playerCount: 2,
                isPasswordProtected: false, stage: .configuration
            ),
            participants: seats
        )
        reloaded.loadSavedGame(record, assignment: [hostID: hostID, guestID: guestID])

        XCTAssertNil(reloaded.presentedError)
        XCTAssertEqual(reloaded.authoritativeGame?.currentPlayer.id, guestID)
        XCTAssertEqual(reloaded.authoritativeGame?.players.last?.tokens, [.onyx: 2])
        XCTAssertEqual(reloaded.phase, .game)
        // Loading leaves the save in place; deleting is an explicit choice.
        XCTAssertEqual(try context.fetch(FetchDescriptor<GameSaveRecord>()).count, 1)
    }

    func testSavesAccumulatePerProfileAndFilterByOwnerKey() throws {
        let context = try makeContext()
        let ownerKey = UUID().uuidString
        let otherKey = UUID().uuidString
        let now = Date()

        context.insert(try makeSave(ownerKey: ownerKey, roomName: "Older", savedAt: now - 600))
        context.insert(try makeSave(ownerKey: ownerKey, roomName: "Newer", savedAt: now))
        context.insert(try makeSave(ownerKey: otherKey, roomName: "Someone Else"))
        try context.save()

        // ownerKey is a String, so it is safe to use in a #Predicate (unlike UUID).
        var descriptor = FetchDescriptor<GameSaveRecord>(
            predicate: #Predicate { $0.ownerKey == ownerKey },
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 10
        let mine = try context.fetch(descriptor)

        // Saving twice keeps both records — a save is a slot, not a single overwrite.
        XCTAssertEqual(mine.map(\.roomName), ["Newer", "Older"])
        XCTAssertEqual(mine.first?.statePayload, Data([1, 2, 3]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<GameSaveRecord>()).count, 3)
    }

    func testSavedSeatsRoundTripNicknamesAndBotDifficulty() throws {
        let context = try makeContext()
        let ownerKey = UUID().uuidString
        let human = Participant(id: UUID(), nickname: "Ada", medalCount: 4)
        let bot = Participant(id: UUID(), nickname: "AI 1", kind: .bot, difficulty: .hard)

        let record = try makeSave(ownerKey: ownerKey, seats: [human, bot])
        context.insert(record)
        try context.save()

        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<GameSaveRecord>()).first)
        XCTAssertEqual(restored.playerCount, 2)
        XCTAssertEqual(restored.currentSeatNickname, "Ada")
        XCTAssertEqual(restored.gameMode, .standard)
        // Seat order is turn order, and each seat keeps the nickname the host used
        // to tell players apart plus the bot difficulty the AI driver needs.
        XCTAssertEqual(restored.seats.map(\.nickname), ["Ada", "AI 1"])
        XCTAssertEqual(restored.seats.map(\.id), [human.id, bot.id])
        XCTAssertEqual(restored.seats.last?.kind, .bot)
        XCTAssertEqual(restored.seats.last?.difficulty, .hard)
    }

    func testAccountAndPlaceholderRecordsPersistInMemory() throws {
        let context = try makeContext()

        let account = AccountProfile(nickname: "Aurora")
        let gameID = UUID()
        context.insert(account)
        context.insert(MedalRecord(issuerUUID: UUID(), issuerNicknameSnapshot: "Nova", gameID: gameID))
        context.insert(CompletedGameRecord(gameID: gameID, modeRawValue: "standard"))
        try context.save()

        let accounts = try context.fetch(FetchDescriptor<AccountProfile>())
        let medals = try context.fetch(FetchDescriptor<MedalRecord>())
        let games = try context.fetch(FetchDescriptor<CompletedGameRecord>())
        XCTAssertEqual(accounts.map(\.nickname), ["Aurora"])
        XCTAssertEqual(medals.first?.gameID, gameID)
        XCTAssertEqual(games.first?.gameID, gameID)
        XCTAssertEqual(medals.first?.roomName, "")
        XCTAssertNil(medals.first?.scoreMargin)
        XCTAssertEqual(games.first?.roomName, "")
        // logicalKey is now unique per profile rather than a shared "primary" key.
        XCTAssertEqual(account.logicalKey, account.uuid.uuidString)
    }

    func testFinishedOutcomePersistsPerProfileAndIsIdempotent() throws {
        let context = try makeContext()
        let winner = Participant(id: UUID(), nickname: "Winner", medalCount: 11)
        let loser = Participant(id: UUID(), nickname: "Loser", medalCount: 4)
        let bot = Participant(id: UUID(), nickname: "Bot", kind: .bot)
        var state = try StandardRuleset().makeGame(
            participants: [winner, loser, bot],
            configuration: .init(),
            seed: 22
        )
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.status = .finished
        state.players[0].medalCount = 12
        state.result = GameResult(
            standings: [
                .init(playerID: winner.id, nickname: winner.nickname, prestige: 15, developmentCards: 8, rank: 1, isWinner: true),
                .init(playerID: loser.id, nickname: loser.nickname, prestige: 9, developmentCards: 6, rank: 2, isWinner: false),
                .init(playerID: bot.id, nickname: bot.nickname, prestige: 4, developmentCards: 5, rank: 3, isWinner: false),
            ],
            winnerIDs: [winner.id],
            finishedAt: finishedAt
        )
        let snapshot = state.snapshot(for: winner.id)
        let winnerOwner = winner.id.uuidString

        let first = try MatchOutcomeRecorder.record(
            snapshot: snapshot,
            ownerKey: winnerOwner,
            localParticipantID: winner.id,
            transport: .internet,
            roomName: "Final Table",
            context: context
        )
        let repeated = try MatchOutcomeRecorder.record(
            snapshot: snapshot,
            ownerKey: winnerOwner,
            localParticipantID: winner.id,
            transport: .internet,
            roomName: "Final Table",
            context: context
        )
        let loserResult = try MatchOutcomeRecorder.record(
            snapshot: snapshot,
            ownerKey: loser.id.uuidString,
            localParticipantID: loser.id,
            transport: .internet,
            roomName: "Final Table",
            context: context
        )

        XCTAssertEqual(first, MatchOutcomeRecordingResult(insertedHistory: true, insertedMedals: 1))
        XCTAssertEqual(repeated, MatchOutcomeRecordingResult(insertedHistory: false, insertedMedals: 0))
        XCTAssertEqual(loserResult, MatchOutcomeRecordingResult(insertedHistory: true, insertedMedals: 0))

        let medals = try context.fetch(FetchDescriptor<MedalRecord>())
        let histories = try context.fetch(FetchDescriptor<CompletedGameRecord>())
        XCTAssertEqual(medals.count, 1)
        XCTAssertEqual(medals.first?.ownerKey, winnerOwner)
        XCTAssertEqual(medals.first?.issuerUUID, loser.id)
        XCTAssertEqual(medals.first?.awardedAt, finishedAt)
        XCTAssertEqual(medals.first?.roomName, "Final Table")
        XCTAssertEqual(medals.first?.scoreMargin, 6)
        XCTAssertEqual(histories.count, 2)
        let winnerHistory = try XCTUnwrap(histories.first { $0.ownerKey == winnerOwner })
        XCTAssertEqual(winnerHistory.multiplayerMode, .internet)
        XCTAssertEqual(winnerHistory.roomName, "Final Table")
        XCTAssertEqual(winnerHistory.result, state.result)
    }

    func testLogicalKeysDeduplicateCloudMergedRowsInPresentation() throws {
        let context = try makeContext()
        let ownerKey = UUID().uuidString
        let issuer = UUID()
        let game = UUID()
        context.insert(MedalRecord(ownerKey: ownerKey, issuerUUID: issuer, issuerNicknameSnapshot: "A", gameID: game))
        context.insert(MedalRecord(ownerKey: ownerKey, issuerUUID: issuer, issuerNicknameSnapshot: "A", gameID: game))
        context.insert(MedalRecord(issuerUUID: issuer, issuerNicknameSnapshot: "Legacy", gameID: game))
        try context.save()

        let medals = try context.fetch(FetchDescriptor<MedalRecord>())
        XCTAssertEqual(medals.uniqueScopedMedals.count, 1)
    }

    func testAwardPresentationGroupsEveryHumanLoserAndWinner() throws {
        let winnerOne = Participant(id: UUID(), nickname: "W1", medalCount: 7)
        let winnerTwo = Participant(id: UUID(), nickname: "W2", medalCount: 9)
        let loser = Participant(id: UUID(), nickname: "L")
        let bot = Participant(id: UUID(), nickname: "Bot", kind: .bot)
        var state = try StandardRuleset().makeGame(
            participants: [winnerOne, winnerTwo, loser, bot],
            configuration: .init(),
            seed: 24
        )
        state.status = .finished
        state.result = GameResult(standings: [], winnerIDs: [winnerOne.id, winnerTwo.id])

        let presentation = MedalAwardPresentation(snapshot: state.snapshot(for: winnerOne.id))

        XCTAssertEqual(presentation.winners.map(\.id), [winnerOne.id, winnerTwo.id])
        XCTAssertEqual(presentation.issuers.map(\.id), [loser.id])
        XCTAssertEqual(presentation.transferCount, 2)
    }

    func testMultipleProfilesCoexistUnderOneStore() throws {
        let context = try makeContext()
        let first = AccountProfile(nickname: "Kid A")
        let second = AccountProfile(nickname: "Kid B")
        context.insert(first)
        context.insert(second)
        try context.save()

        let profiles = try context.fetch(FetchDescriptor<AccountProfile>(sortBy: [SortDescriptor(\.createdAt)]))
        XCTAssertEqual(profiles.count, 2)
        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertNotEqual(first.logicalKey, second.logicalKey)
    }

    func testPresenceLeaseStoresDeviceScopedIdentity() throws {
        let context = try makeContext()
        let profileUUID = UUID()
        let install = UUID()
        context.insert(PresenceLease(
            profileUUID: profileUUID,
            deviceInstallID: install,
            deviceName: "iPhone",
            activityLabel: "lan"
        ))
        try context.save()

        // Filter in Swift: UUID-equality #Predicate traps inside SwiftData on
        // current OS versions (mirrors PresenceCoordinator.leases(for:)).
        let leases = try context.fetch(FetchDescriptor<PresenceLease>())
            .filter { $0.profileUUID == profileUUID }
        XCTAssertEqual(leases.count, 1)
        XCTAssertEqual(leases.first?.deviceInstallID, install)
    }
}
