import LuminoreCore
import XCTest
@testable import Luminore

@MainActor
final class MultiplayerTransportTests: XCTestCase {
    func testMedalCountsReachEveryTransportMode() throws {
        for mode in MultiplayerMode.allCases {
            let hostTransport = FakeMatchTransport(mode: mode)
            let clientTransport = FakeMatchTransport(mode: mode)
            hostTransport.other = clientTransport
            clientTransport.other = hostTransport

            let hostID = UUID()
            let clientID = UUID()
            let host = MatchSessionService(
                localID: hostID,
                nickname: "Host",
                medalCount: 18,
                mode: mode,
                transport: hostTransport
            )
            let client = MatchSessionService(
                localID: clientID,
                nickname: "Client",
                medalCount: 7,
                mode: mode,
                transport: clientTransport
            )

            host.host(roomName: "Medals", password: "")
            client.join(
                DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)),
                password: ""
            )
            host.enterConfiguration()
            host.startGame()

            let hostPlayers = try XCTUnwrap(host.game?.players)
            let clientPlayers = try XCTUnwrap(client.game?.players)
            XCTAssertEqual(hostPlayers.first { $0.id == hostID }?.medalCount, 18, "mode: \(mode)")
            XCTAssertEqual(hostPlayers.first { $0.id == clientID }?.medalCount, 7, "mode: \(mode)")
            XCTAssertEqual(clientPlayers.first { $0.id == hostID }?.medalCount, 18, "mode: \(mode)")
            XCTAssertEqual(clientPlayers.first { $0.id == clientID }?.medalCount, 7, "mode: \(mode)")
        }
    }

    func testAcceptedAnimationEventsReachEveryTransportMode() throws {
        for mode in MultiplayerMode.allCases {
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

            host.host(roomName: "Animation", password: "")
            client.join(
                DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)),
                password: ""
            )
            host.enterConfiguration()
            host.startGame()
            host.openingTurnSelection = OpeningTurnSelection(
                startedAt: Date().addingTimeInterval(-2),
                endsAt: Date().addingTimeInterval(-1)
            )
            host.scheduleOpeningTurnCompletion()

            let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
            host.apply(.take(tokens: [.diamond: 1], returning: [:]), from: actorID, allowsPass: true)

            let hostEvent = try XCTUnwrap(host.gameAnimationEvent, "host event for \(mode)")
            XCTAssertEqual(client.gameAnimationEvent, hostEvent, "client event for \(mode)")
            XCTAssertEqual(hostEvent.playerID, actorID)
            if case let .take(tokens) = hostEvent.kind {
                XCTAssertEqual(tokens, [.diamond: 1])
            } else {
                XCTFail("wrong animation payload for \(mode)")
            }

            client.leave()
            host.leave()
        }
    }

    func testQuickChatReachesEveryTransportMode() throws {
        for mode in MultiplayerMode.allCases {
            let hostTransport = FakeMatchTransport(mode: mode)
            let clientTransport = FakeMatchTransport(mode: mode)
            hostTransport.other = clientTransport
            clientTransport.other = hostTransport

            let hostID = UUID()
            let clientID = UUID()
            let host = MatchSessionService(
                localID: hostID,
                nickname: "Host",
                mode: mode,
                transport: hostTransport
            )
            let client = MatchSessionService(
                localID: clientID,
                nickname: "Guest",
                mode: mode,
                transport: clientTransport
            )

            host.host(roomName: "Chat", password: "")
            client.join(
                DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)),
                password: ""
            )
            host.enterConfiguration()
            host.startGame()

            // Client → host → (nobody else). The client echoes locally so the bubble
            // never waits on a round trip.
            client.sendQuickChat(.cheer)
            let clientEcho = try XCTUnwrap(client.quickChatEvent, "client echo for \(mode)")
            XCTAssertTrue(clientEcho.isLocalAuthor, "mode: \(mode)")
            XCTAssertEqual(clientEcho.phrase, .cheer)

            let onHost = try XCTUnwrap(host.quickChatEvent, "host receipt for \(mode)")
            XCTAssertEqual(onHost.authorID, clientID, "mode: \(mode)")
            XCTAssertEqual(onHost.phrase, .cheer)
            XCTAssertFalse(onHost.isLocalAuthor)
            // The name is resolved from the host's own roster, never from the payload.
            XCTAssertEqual(onHost.authorName, "Guest", "mode: \(mode)")

            // Host → clients.
            host.sendQuickChat(.hurryUp)
            let onClient = try XCTUnwrap(client.quickChatEvent, "client receipt for \(mode)")
            XCTAssertEqual(onClient.authorID, hostID, "mode: \(mode)")
            XCTAssertEqual(onClient.phrase, .hurryUp)
            XCTAssertFalse(onClient.isLocalAuthor)
            XCTAssertEqual(onClient.authorName, "Host", "mode: \(mode)")

            client.leave()
            host.leave()
            XCTAssertNil(host.quickChatEvent, "mode: \(mode)")
            XCTAssertNil(client.quickChatEvent, "mode: \(mode)")
            XCTAssertNil(host.quickChatCooldownEndsAt, "mode: \(mode)")
        }
    }

    func testQuickChatCooldownBlocksRapidSends() throws {
        let hostTransport = FakeMatchTransport(mode: .lan)
        let clientTransport = FakeMatchTransport(mode: .lan)
        hostTransport.other = clientTransport
        clientTransport.other = hostTransport

        let host = MatchSessionService(
            localID: UUID(),
            nickname: "Host",
            mode: .lan,
            transport: hostTransport
        )
        let client = MatchSessionService(
            localID: UUID(),
            nickname: "Guest",
            mode: .lan,
            transport: clientTransport
        )

        host.host(roomName: "Cooldown", password: "")
        client.join(
            DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)),
            password: ""
        )
        host.enterConfiguration()
        host.startGame()

        let before = quickChatCount(in: hostTransport)
        host.sendQuickChat(.cry)
        XCTAssertFalse(host.canSendQuickChat)
        host.sendQuickChat(.cheer)
        XCTAssertEqual(quickChatCount(in: hostTransport) - before, 1)
        XCTAssertEqual(host.quickChatEvent?.phrase, .cry)
    }

    func testQuickChatFromAnImpersonatingPeerIsIgnored() throws {
        let hostTransport = FakeMatchTransport(mode: .lan)
        let clientTransport = FakeMatchTransport(mode: .lan)
        hostTransport.other = clientTransport
        clientTransport.other = hostTransport

        let hostID = UUID()
        let clientID = UUID()
        let host = MatchSessionService(
            localID: hostID,
            nickname: "Host",
            mode: .lan,
            transport: hostTransport
        )
        let client = MatchSessionService(
            localID: clientID,
            nickname: "Guest",
            mode: .lan,
            transport: clientTransport
        )

        host.host(roomName: "Impersonation", password: "")
        client.join(
            DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)),
            password: ""
        )
        host.enterConfiguration()
        host.startGame()

        let peer = try XCTUnwrap(host.participantPeers[clientID])
        // The client claims the phrase came from the host's seat.
        host.receive(
            WireEnvelope(
                roomID: try XCTUnwrap(host.room?.descriptor.id),
                senderID: clientID,
                sequence: 9_000,
                payload: .quickChat(QuickChatMessage(authorID: hostID, phrase: .cry))
            ),
            from: peer
        )
        XCTAssertNil(host.quickChatEvent)
    }

    private func quickChatCount(in transport: FakeMatchTransport) -> Int {
        transport.sentEnvelopes.filter {
            if case .quickChat = $0.payload { return true }
            return false
        }.count
    }

    func testAllTransportsUseTheSamePasswordJoinHandshake() {
        for mode in MultiplayerMode.allCases {
            let hostTransport = FakeMatchTransport(mode: mode)
            let clientTransport = FakeMatchTransport(mode: mode)
            hostTransport.other = clientTransport
            clientTransport.other = hostTransport

            let hostID = UUID()
            let clientID = UUID()
            let host = MatchSessionService(
                localID: hostID,
                nickname: "Host",
                mode: mode,
                transport: hostTransport
            )
            let client = MatchSessionService(
                localID: clientID,
                nickname: "Guest",
                mode: mode,
                transport: clientTransport
            )

            host.host(roomName: "Shared Core", password: "opal")
            guard let descriptor = host.room?.descriptor else {
                return XCTFail("Host did not create a room for \(mode)")
            }
            client.join(DiscoveredMatchRoom(descriptor: descriptor), password: "opal")

            XCTAssertEqual(host.phase, .lobby, "host phase for \(mode)")
            XCTAssertEqual(client.phase, .lobby, "client phase for \(mode)")
            XCTAssertEqual(host.room?.participants.map(\.id).sorted(by: uuidSort), [hostID, clientID].sorted(by: uuidSort))
            XCTAssertEqual(client.room?.participants.count, 2)
            XCTAssertNotNil(client.currentSessionToken)

            host.enterConfiguration()
            host.startGame()

            XCTAssertEqual(host.phase, .game, "host game phase for \(mode)")
            XCTAssertEqual(client.phase, .game, "client game phase for \(mode)")
            XCTAssertEqual(host.game?.startingPlayerID, client.game?.startingPlayerID)
            XCTAssertEqual(host.openingTurnSelection, client.openingTurnSelection)
            XCTAssertTrue(host.isOpeningTurnSelection)
            XCTAssertTrue(client.isOpeningTurnSelection)
            XCTAssertNil(host.turnDeadline, "turn timer must wait for roulette for \(mode)")
            XCTAssertNil(client.turnDeadline, "client timer must wait for roulette for \(mode)")

            let revision = host.authoritativeGame?.revision
            if let startingPlayerID = host.game?.startingPlayerID {
                host.apply(.pass, from: startingPlayerID, allowsPass: true)
            }
            XCTAssertEqual(host.authoritativeGame?.revision, revision, "actions are locked during roulette for \(mode)")

            host.openingTurnSelection = OpeningTurnSelection(
                startedAt: Date().addingTimeInterval(-2),
                endsAt: Date().addingTimeInterval(-1)
            )
            host.scheduleOpeningTurnCompletion()
            XCTAssertFalse(host.isOpeningTurnSelection)
            XCTAssertNil(host.openingTurnSelection)
            XCTAssertNil(client.openingTurnSelection)
            XCTAssertNotNil(host.turnDeadline, "host timer starts after roulette for \(mode)")
            XCTAssertNotNil(client.turnDeadline, "client receives timer after roulette for \(mode)")

            client.leave()
            host.leave()
        }
    }

    func testDuelActionsAndSnapshotsReachEveryTransportMode() throws {
        for mode in MultiplayerMode.allCases {
            let hostTransport = FakeMatchTransport(mode: mode)
            let clientTransport = FakeMatchTransport(mode: mode)
            hostTransport.other = clientTransport
            clientTransport.other = hostTransport
            let host = MatchSessionService(localID: UUID(), nickname: "Host", mode: mode, transport: hostTransport)
            let client = MatchSessionService(localID: UUID(), nickname: "Guest", mode: mode, transport: clientTransport)

            host.host(roomName: "Duel", password: "")
            client.join(DiscoveredMatchRoom(descriptor: try XCTUnwrap(host.room?.descriptor)), password: "")
            host.enterConfiguration()
            var configuration = try XCTUnwrap(host.room?.configuration)
            configuration.mode = .duel
            host.updateConfiguration(configuration)
            host.startGame()
            host.openingTurnSelection = OpeningTurnSelection(
                startedAt: Date().addingTimeInterval(-2),
                endsAt: Date().addingTimeInterval(-1)
            )
            host.scheduleOpeningTurnCompletion()

            let actorID = try XCTUnwrap(host.authoritativeGame?.currentPlayer.id)
            let duel = try XCTUnwrap(host.authoritativeGame?.duel)
            let boardIndex = try XCTUnwrap(duel.board.indices.first { duel.board[$0] != .gold })
            host.apply(.duel(.take(boardIndices: [boardIndex], returning: [:])), from: actorID, allowsPass: true)

            XCTAssertEqual(host.game?.configuration.mode, .duel, "host mode: \(mode)")
            XCTAssertEqual(client.game?.configuration.mode, .duel, "client mode: \(mode)")
            XCTAssertEqual(host.game?.duel, client.game?.duel, "snapshot: \(mode)")
            XCTAssertNil(host.game?.duel?.board[boardIndex], "host board: \(mode)")
            XCTAssertNil(client.game?.duel?.board[boardIndex], "client board: \(mode)")

            client.leave()
            host.leave()
        }
    }

    func testWrongPasswordIsRejectedWithoutLeakingPassword() {
        let hostTransport = FakeMatchTransport(mode: .internet)
        let clientTransport = FakeMatchTransport(mode: .internet)
        hostTransport.other = clientTransport
        clientTransport.other = hostTransport
        let host = MatchSessionService(localID: UUID(), nickname: "Host", mode: .internet, transport: hostTransport)
        let client = MatchSessionService(localID: UUID(), nickname: "Guest", mode: .internet, transport: clientTransport)

        host.host(roomName: "Locked", password: "secret")
        client.join(DiscoveredMatchRoom(descriptor: host.room!.descriptor), password: "incorrect")

        XCTAssertEqual(client.phase, .ended)
        XCTAssertFalse((client.presentedError ?? "").contains("secret"))
        XCTAssertEqual(host.room?.participants.count, 1)
    }

    func testInternetServerURLValidation() throws {
        XCTAssertEqual(
            try InternetServerSettings.normalizedURL(from: " https://relay.example.com/ ").absoluteString,
            "https://relay.example.com"
        )
        XCTAssertEqual(
            try InternetServerSettings.normalizedURL(from: "http://localhost:8787").absoluteString,
            "http://localhost:8787"
        )
        XCTAssertThrowsError(try InternetServerSettings.normalizedURL(from: "http://relay.example.com"))
        XCTAssertThrowsError(try InternetServerSettings.normalizedURL(from: "https://relay.example.com/path"))
    }

    func testRelayApplicationCloseIsTerminal() throws {
        let applicationClose = try XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 4_000))
        XCTAssertEqual(
            InternetTransport.terminalRoomClosure(
                closeCode: applicationClose,
                closeReason: Data("host_timeout".utf8)
            ),
            "host_timeout"
        )
        XCTAssertEqual(
            InternetTransport.terminalRoomClosure(closeCode: applicationClose, closeReason: Data("other".utf8)),
            "room_closed"
        )
        XCTAssertNil(
            InternetTransport.terminalRoomClosure(closeCode: .goingAway, closeReason: Data("host_timeout".utf8))
        )

        let transport = FakeMatchTransport(mode: .internet)
        let session = MatchSessionService(localID: UUID(), nickname: "Guest", mode: .internet, transport: transport)
        session.phase = .reconnecting
        session.handleTransport(.roomClosed("host_timeout"))

        XCTAssertEqual(session.phase, .ended)
        XCTAssertNotNil(session.presentedError)
        XCTAssertEqual(transport.disconnectCalls, 1)
        XCTAssertFalse(transport.lastCloseRoom)
        XCTAssertTrue(session.isLeaving)
    }

    /// Creating a room while the network is flaky must not strand the host on the
    /// connecting spinner behind an alert: nothing was established, so the only
    /// useful place to land is the menu they can retry from.
    func testFailedRoomCreationReturnsTheHostToTheMenu() {
        for mode in MultiplayerMode.allCases {
            let transport = FakeMatchTransport(mode: mode)
            transport.failsHosting = "offline"
            let host = MatchSessionService(localID: UUID(), nickname: "Host", mode: mode, transport: transport)

            host.host(roomName: "Flaky", password: "")

            XCTAssertEqual(host.phase, .menu, "\(mode)")
            XCTAssertNotNil(host.presentedError, "\(mode)")
            XCTAssertNil(host.room, "\(mode)")
        }
    }

    /// Typing an invite code while the host is still in the chat app they shared it
    /// from parks the joiner on a wait, not on a reconnect — and never on a dead
    /// end. Once the host is back the ordinary handshake takes over.
    func testJoiningWhileTheHostIsAwayWaitsInsteadOfFailing() throws {
        let hostTransport = FakeMatchTransport(mode: .internet)
        let clientTransport = FakeMatchTransport(mode: .internet)
        hostTransport.other = clientTransport
        clientTransport.other = hostTransport
        let host = MatchSessionService(localID: UUID(), nickname: "Host", mode: .internet, transport: hostTransport)
        let client = MatchSessionService(localID: UUID(), nickname: "Guest", mode: .internet, transport: clientTransport)

        host.host(roomName: "Shared", password: "")
        let descriptor = try XCTUnwrap(host.room?.descriptor)

        // The relay accepted the socket but has no host attached to it yet.
        client.room = RoomSnapshot(descriptor: descriptor, participants: [])
        client.phase = .connecting
        clientTransport.emit(.hostUnavailable)

        XCTAssertEqual(client.phase, .reconnecting)
        XCTAssertTrue(client.isWaitingForHost)
        XCTAssertFalse(client.isLeaving)

        client.join(DiscoveredMatchRoom(descriptor: descriptor), password: "")

        XCTAssertEqual(client.phase, .lobby)
        XCTAssertFalse(client.isWaitingForHost)
        XCTAssertEqual(host.room?.participants.count, 2)
    }

    /// Returning to the app has to re-validate the link on every transport — the
    /// host most of all, since nothing else re-opens the socket that its room is
    /// advertised through.
    func testForegroundingRevalidatesTheTransportForHostAndClient() {
        for mode in MultiplayerMode.allCases {
            let hostTransport = FakeMatchTransport(mode: mode)
            let clientTransport = FakeMatchTransport(mode: mode)
            hostTransport.other = clientTransport
            clientTransport.other = hostTransport
            let host = MatchSessionService(localID: UUID(), nickname: "Host", mode: mode, transport: hostTransport)
            let client = MatchSessionService(localID: UUID(), nickname: "Guest", mode: mode, transport: clientTransport)

            host.host(roomName: "Away", password: "")
            client.join(DiscoveredMatchRoom(descriptor: host.room!.descriptor), password: "")

            host.applicationWillResignActive()
            host.applicationDidBecomeActive()
            client.applicationDidBecomeActive()

            XCTAssertEqual(hostTransport.foregroundCalls, 1, "\(mode)")
            XCTAssertEqual(clientTransport.foregroundCalls, 1, "\(mode)")
            XCTAssertEqual(host.phase, .lobby, "\(mode)")
            XCTAssertEqual(client.phase, .lobby, "\(mode)")

            // A session on its way out must not be revived by a late scene change.
            host.leave()
            host.applicationDidBecomeActive()
            XCTAssertEqual(hostTransport.foregroundCalls, 1, "\(mode)")
        }
    }

    func testSuspendCleanupSurvivesSessionRelease() async throws {
        let transport = FakeMatchTransport(mode: .internet)
        var session: MatchSessionService? = MatchSessionService(
            localID: UUID(),
            nickname: "Host",
            mode: .internet,
            transport: transport
        )
        session?.isHost = true
        session?.finishSuspendingAfterFlush()
        session = nil

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(transport.disconnectCalls, 1)
        XCTAssertTrue(transport.lastCloseRoom)
    }

    /// Loading a save with two seats deliberately swapped: progress must follow the
    /// *seat*, and the turn must land on whoever now owns the seat that was to move.
    func testLoadingSaveWithSwappedSeatsMovesProgressAndTurnWithTheSeat() throws {
        let transport = FakeMatchTransport(mode: .lan)
        let savedSeats = [
            Participant(id: UUID(), nickname: "Ada", isHost: true),
            Participant(id: UUID(), nickname: "Bob"),
            Participant(id: UUID(), nickname: "AI 1", kind: .bot, difficulty: .easy),
        ]
        var saved = try StandardRuleset().makeGame(
            participants: savedSeats,
            configuration: .init(),
            seed: 11
        )
        // Give each seat a distinguishable amount of progress, and hand the turn to
        // seat 1 so a naive "start from the first player" load would be caught.
        saved.players[0].tokens = [.ruby: 3]
        saved.players[1].tokens = [.sapphire: 1]
        saved.players[2].tokens = [.emerald: 2]
        saved.currentPlayerIndex = 1
        let record = try makeSaveRecord(from: saved, seats: savedSeats)

        let hostID = UUID()
        let guestID = UUID()
        let botID = UUID()
        let peer = TransportPeerID("guest")
        let present = [
            Participant(id: hostID, nickname: "Host", isHost: true),
            Participant(id: guestID, nickname: "Guest"),
            Participant(id: botID, nickname: "AI 9", kind: .bot, difficulty: .hard),
        ]
        let host = MatchSessionService(localID: hostID, nickname: "Host", mode: .lan, transport: transport)
        host.isHost = true
        host.room = RoomSnapshot(
            descriptor: RoomDescriptor(
                id: UUID(), name: "Fresh", hostNickname: "Host", playerCount: 3,
                isPasswordProtected: false, stage: .configuration
            ),
            participants: present
        )
        host.participantPeers[guestID] = peer
        host.peerParticipants[peer] = guestID

        // Ada's seat goes to the guest and Bob's to the host — a straight swap.
        host.loadSavedGame(record, assignment: [
            savedSeats[0].id: guestID,
            savedSeats[1].id: hostID,
            savedSeats[2].id: botID,
        ])

        let players = try XCTUnwrap(host.authoritativeGame?.players)
        XCTAssertEqual(players.map(\.id), [guestID, hostID, botID])
        XCTAssertEqual(players[0].tokens, [.ruby: 3])
        XCTAssertEqual(players[1].tokens, [.sapphire: 1])
        XCTAssertEqual(players[0].nickname, "Guest")
        // Seat 1 was to move, and the host now owns it.
        XCTAssertEqual(host.authoritativeGame?.currentPlayer.id, hostID)
        // Room order mirrors turn order, and the bot's difficulty comes from the
        // present roster (the AI driver reads it from there, not from the state).
        XCTAssertEqual(host.room?.participants.map(\.id), [guestID, hostID, botID])
        XCTAssertEqual(host.room?.participants.last?.difficulty, .hard)
        XCTAssertTrue(players.allSatisfy(\.isConnected))
        XCTAssertEqual(host.phase, .game)
        XCTAssertEqual(host.room?.descriptor.stage, .playing)
        // No opening roulette: it would gate actions and show a bogus starting seat.
        XCTAssertNil(host.openingTurnSelection)

        let snapshot = try XCTUnwrap(transport.sentEnvelopes.compactMap { envelope -> ClientGameSnapshot? in
            if case let .gameState(snapshot) = envelope.payload { return snapshot }
            return nil
        }.last)
        XCTAssertEqual(snapshot.currentPlayerID, hostID)
        XCTAssertNil(snapshot.openingTurnSelection)
    }

    /// Duel keeps a parallel per-player array keyed by the same ids. Rewriting those
    /// ids in place would let a later lookup hit an already-rebound seat, so a swap
    /// is the case that catches it.
    func testLoadingDuelSaveWithSwappedSeatsRemapsTheParallelDuelPlayers() throws {
        let transport = FakeMatchTransport(mode: .nearby)
        let savedSeats = [
            Participant(id: UUID(), nickname: "Ada", isHost: true),
            Participant(id: UUID(), nickname: "Bob"),
        ]
        var saved = try RulesEngine().makeGame(
            participants: savedSeats,
            configuration: .init(mode: .duel),
            seed: 21
        )
        let duelIndexOfAda = try XCTUnwrap(saved.duel?.players.firstIndex { $0.id == savedSeats[0].id })
        let duelIndexOfBob = try XCTUnwrap(saved.duel?.players.firstIndex { $0.id == savedSeats[1].id })
        saved.duel?.players[duelIndexOfAda].privileges = 2
        saved.duel?.players[duelIndexOfBob].privileges = 1
        let record = try makeSaveRecord(from: saved, seats: savedSeats)

        let hostID = UUID()
        let guestID = UUID()
        let present = [
            Participant(id: hostID, nickname: "Host", isHost: true),
            Participant(id: guestID, nickname: "Guest"),
        ]
        let host = MatchSessionService(localID: hostID, nickname: "Host", mode: .nearby, transport: transport)
        host.isHost = true
        host.room = RoomSnapshot(
            descriptor: RoomDescriptor(
                id: UUID(), name: "Fresh", hostNickname: "Host", playerCount: 2,
                isPasswordProtected: false, stage: .configuration
            ),
            participants: present
        )

        host.loadSavedGame(record, assignment: [
            savedSeats[0].id: guestID,
            savedSeats[1].id: hostID,
        ])

        let duel = try XCTUnwrap(host.authoritativeGame?.duel)
        XCTAssertEqual(Set(duel.players.map(\.id)), [hostID, guestID])
        // Ada's privileges followed her seat to the guest, Bob's to the host.
        XCTAssertEqual(duel.players.first { $0.id == guestID }?.privileges, 2)
        XCTAssertEqual(duel.players.first { $0.id == hostID }?.privileges, 1)
        // The saved configuration wins over whatever the configuration screen held.
        XCTAssertEqual(host.room?.configuration.mode, .duel)
        XCTAssertEqual(host.room?.descriptor.maximumPlayers, 2)
    }

    func testLoadingSaveIsRejectedWhenTwoSeatsShareOnePlayer() throws {
        let transport = FakeMatchTransport(mode: .lan)
        let savedSeats = [
            Participant(id: UUID(), nickname: "Ada", isHost: true),
            Participant(id: UUID(), nickname: "Bob"),
        ]
        let saved = try StandardRuleset().makeGame(
            participants: savedSeats,
            configuration: .init(),
            seed: 5
        )
        let record = try makeSaveRecord(from: saved, seats: savedSeats)

        let hostID = UUID()
        let guestID = UUID()
        let host = MatchSessionService(localID: hostID, nickname: "Host", mode: .lan, transport: transport)
        host.isHost = true
        host.room = RoomSnapshot(
            descriptor: RoomDescriptor(
                id: UUID(), name: "Fresh", hostNickname: "Host", playerCount: 2,
                isPasswordProtected: false, stage: .configuration
            ),
            participants: [
                Participant(id: hostID, nickname: "Host", isHost: true),
                Participant(id: guestID, nickname: "Guest"),
            ]
        )

        host.loadSavedGame(record, assignment: [
            savedSeats[0].id: hostID,
            savedSeats[1].id: hostID,
        ])

        XCTAssertNil(host.authoritativeGame)
        XCTAssertNotNil(host.presentedError)
        // The host stays on the configuration screen instead of being kicked out.
        XCTAssertEqual(host.room?.descriptor.stage, .configuration)
    }

    private func makeSaveRecord(from state: GameState, seats: [Participant]) throws -> GameSaveRecord {
        GameSaveRecord(
            ownerKey: UUID().uuidString,
            gameID: state.gameID,
            roomName: "Saved",
            modeRawValue: state.configuration.mode.rawValue,
            playerCount: state.players.count,
            currentSeatNickname: state.currentPlayer.nickname,
            statePayload: try JSONEncoder().encode(state),
            seatsPayload: try JSONEncoder().encode(seats)
        )
    }

    func testFinishedWinnerReconnectDoesNotOverwriteSettledMedalCount() throws {
        let transport = FakeMatchTransport(mode: .lan)
        let hostID = UUID()
        let winnerID = UUID()
        let installID = UUID()
        let peer = TransportPeerID("finished-winner")
        let participants = [
            Participant(id: hostID, nickname: "Host", isHost: true),
            Participant(id: winnerID, nickname: "Winner", medalCount: 2, isConnected: false),
        ]
        var state = try StandardRuleset().makeGame(participants: participants, configuration: .init(), seed: 4)
        state.status = .finished
        state.players[1].medalCount = 10

        let host = MatchSessionService(localID: hostID, nickname: "Host", mode: .lan, transport: transport)
        host.isHost = true
        host.authoritativeGame = state
        host.room = RoomSnapshot(
            descriptor: RoomDescriptor(
                id: UUID(), name: "Finished", hostNickname: "Host", playerCount: 1,
                isPasswordProtected: false, stage: .results
            ),
            participants: participants
        )
        host.tokens[winnerID] = "winner-token"
        host.seatInstalls[winnerID] = installID
        let challenge = PasswordAuthenticator.challenge()
        host.challenges[peer] = challenge

        host.handleJoin(
            JoinRequest(
                participantID: winnerID,
                nickname: "Winner",
                medalCount: 2,
                authenticationCode: PasswordAuthenticator.code(password: "", challenge: challenge),
                sessionToken: "winner-token",
                deviceInstallID: installID
            ),
            peer: peer
        )

        XCTAssertEqual(host.authoritativeGame?.players.first { $0.id == winnerID }?.medalCount, 10)
        XCTAssertEqual(host.room?.participants.first { $0.id == winnerID }?.medalCount, 10)
    }
}

private func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
}
