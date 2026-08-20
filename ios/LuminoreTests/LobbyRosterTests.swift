import LuminoreCore
import XCTest
@testable import Luminore

/// Covers the host-only lobby controls: manual seat ordering (which becomes turn
/// order) and the random AI nickname preference.
@MainActor
final class LobbyRosterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: MatchSessionService.randomBotNamesKey)
        UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MatchSessionService.randomBotNamesKey)
        UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
        super.tearDown()
    }

    // MARK: - Seat ordering

    func testHostReorderReachesClientAndSetsTurnOrderOnEveryTransport() throws {
        for mode in MultiplayerMode.allCases {
            let (host, client) = try makePair(mode: mode, roomName: "Seating")
            host.addBot(difficulty: .easy)

            let before = try XCTUnwrap(host.room?.participants.map(\.id))
            XCTAssertEqual(before.count, 3, "mode: \(mode)")

            host.moveParticipants(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            let expected = [before[2], before[0], before[1]]
            XCTAssertEqual(host.room?.participants.map(\.id), expected, "mode: \(mode)")
            XCTAssertEqual(client.room?.participants.map(\.id), expected, "client roster for \(mode)")

            host.enterConfiguration()
            host.startGame()
            XCTAssertEqual(host.game?.players.map(\.id), expected, "turn order for \(mode)")
            XCTAssertEqual(client.game?.players.map(\.id), expected, "client turn order for \(mode)")
        }
    }

    func testClientCannotReorderRoster() throws {
        let (host, client) = try makePair(mode: .lan, roomName: "Seating")
        let before = try XCTUnwrap(host.room?.participants.map(\.id))

        client.moveParticipants(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(client.room?.participants.map(\.id), before)
        XCTAssertEqual(host.room?.participants.map(\.id), before)
    }

    func testReorderIsRejectedOnceTheRosterLeavesTheLobby() throws {
        let (host, _) = try makePair(mode: .lan, roomName: "Seating")
        host.enterConfiguration()
        let before = try XCTUnwrap(host.room?.participants.map(\.id))

        host.moveParticipants(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(host.room?.participants.map(\.id), before)
    }

    // MARK: - Bot naming

    func testDefaultBotNamesAreNumberedAndUnique() throws {
        let (host, _) = try makePair(mode: .lan, roomName: "Bots")
        host.addBot(difficulty: .easy)
        host.addBot(difficulty: .easy)
        host.addBot(difficulty: .hard)

        let names = try XCTUnwrap(host.room?.participants.filter { $0.kind == .bot }.map(\.nickname))
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(Set(names).count, 3)
        XCTAssertTrue(names.allSatisfy { $0.contains(where: \.isNumber) })
    }

    func testRandomBotNamesAreGeneratedUniquelyAndReachClients() throws {
        let (host, client) = try makePair(mode: .lan, roomName: "Bots")
        host.setRandomizesBotNames(true)
        for _ in 0 ..< 4 { host.addBot(difficulty: .normal) }

        let names = try XCTUnwrap(host.room?.participants.filter { $0.kind == .bot }.map(\.nickname))
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(Set(names).count, 4, "random names must not collide")
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(client.room?.participants.map(\.nickname), host.room?.participants.map(\.nickname))
    }

    func testTogglingRenamesExistingBotsAndPersistsThePreference() throws {
        let (host, _) = try makePair(mode: .lan, roomName: "Bots")
        host.addBot(difficulty: .easy)
        host.addBot(difficulty: .hard)
        let defaults = try XCTUnwrap(host.room?.participants.filter { $0.kind == .bot }.map(\.nickname))

        host.setRandomizesBotNames(true)
        let randomized = try XCTUnwrap(host.room?.participants.filter { $0.kind == .bot }.map(\.nickname))
        XCTAssertNotEqual(randomized, defaults)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: MatchSessionService.randomBotNamesKey))

        host.setRandomizesBotNames(false)
        let restored = try XCTUnwrap(host.room?.participants.filter { $0.kind == .bot }.map(\.nickname))
        XCTAssertEqual(restored, defaults, "turning the toggle off restores numbered names")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: MatchSessionService.randomBotNamesKey))
    }

    /// The in-app language picker only drives SwiftUI's `\.locale`, so anything
    /// built at runtime has to resolve through `AppLanguage` to follow it.
    func testGeneratedNamesFollowTheInAppLanguageOverrideNotTheSystemLanguage() throws {
        UserDefaults.standard.set("zh-Hans", forKey: AppLanguage.storageKey)
        let chinese = (0 ..< 10).map { _ in BotNameGenerator.randomName(excluding: []) }
        XCTAssertTrue(chinese.allSatisfy { $0.contains("的") }, "expected 「…的…」 names, got \(chinese)")
        XCTAssertTrue(chinese.allSatisfy { !$0.contains(where: \.isASCII) }, "got \(chinese)")

        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
        let english = (0 ..< 10).map { _ in BotNameGenerator.randomName(excluding: []) }
        XCTAssertTrue(english.allSatisfy { $0.allSatisfy(\.isASCII) }, "got \(english)")
    }

    func testDefaultBotNamesFollowTheInAppLanguageOverride() throws {
        UserDefaults.standard.set("zh-Hans", forKey: AppLanguage.storageKey)
        let (host, _) = try makePair(mode: .lan, roomName: "Bots")
        host.addBot(difficulty: .easy)

        let name = try XCTUnwrap(host.room?.participants.last?.nickname)
        XCTAssertTrue(name.hasPrefix("人机"), "got \(name)")
    }

    func testGeneratedNamesNeverCollideWithNamesAlreadyInTheRoom() {
        let taken = Set((0 ..< 200).map { _ in BotNameGenerator.randomName(excluding: []) })
        let fresh = BotNameGenerator.randomName(excluding: taken)
        XCTAssertFalse(taken.contains(fresh))
    }

    // MARK: - Helpers

    private func makePair(
        mode: MultiplayerMode,
        roomName: String
    ) throws -> (MatchSessionService, MatchSessionService) {
        let hostTransport = FakeMatchTransport(mode: mode)
        let clientTransport = FakeMatchTransport(mode: mode)
        hostTransport.other = clientTransport
        clientTransport.other = hostTransport

        let host = MatchSessionService(
            localID: UUID(),
            nickname: "Host",
            mode: mode,
            transport: hostTransport
        )
        let client = MatchSessionService(
            localID: UUID(),
            nickname: "Guest",
            mode: mode,
            transport: clientTransport
        )
        host.host(roomName: roomName, password: "")
        client.join(
            DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)),
            password: ""
        )
        return (host, client)
    }
}
