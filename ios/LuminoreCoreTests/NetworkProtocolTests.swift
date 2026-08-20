import XCTest
@testable import LuminoreCore

final class NetworkProtocolTests: XCTestCase {
    func testLengthPrefixedFramerHandlesFragmentationAndStickyPackets() throws {
        let first = Data("first".utf8)
        let second = Data("second-message".utf8)
        var combined = try LengthPrefixedFramer.frame(first)
        combined.append(try LengthPrefixedFramer.frame(second))

        var parser = LengthPrefixedFramer()
        XCTAssertTrue(try parser.append(combined.prefix(3)).isEmpty)
        let frames = try parser.append(combined.dropFirst(3))
        XCTAssertEqual(frames, [first, second])
    }

    func testWireEnvelopeRoundTripPreservesAssociatedPayload() throws {
        let roomID = UUID()
        let senderID = UUID()
        let envelope = WireEnvelope(
            roomID: roomID,
            senderID: senderID,
            sequence: 9,
            payload: .action(.take(tokens: [.ruby: 1, .diamond: 1, .emerald: 1], returning: [:]))
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(WireEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.protocolVersion, 1)
    }

    func testGameAnimationMessageRoundTripPreservesActorAndPayload() throws {
        let playerID = UUID()
        let event = GameAnimationEvent(
            revision: 12,
            playerID: playerID,
            kind: .take(tokens: [.ruby: 2])
        )
        let envelope = WireEnvelope(
            roomID: UUID(),
            senderID: UUID(),
            sequence: 10,
            payload: .gameAnimation(event)
        )

        let decoded = try JSONDecoder().decode(
            WireEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.payload, .gameAnimation(event))
    }

    func testVersionedTakeActionFixtureDecodes() throws {
        let json = #"{"messageID":"11111111-1111-1111-1111-111111111111","payload":{"action":{"returning":{},"tokens":{"diamond":1,"emerald":1,"sapphire":1},"type":"take"},"type":"action"},"protocolVersion":1,"roomID":"22222222-2222-2222-2222-222222222222","senderID":"33333333-3333-3333-3333-333333333333","sequence":7}"#
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(
            envelope.payload,
            .action(.take(tokens: [.diamond: 1, .emerald: 1, .sapphire: 1], returning: [:]))
        )
    }

    func testQuickChatMessageRoundTripPreservesAuthorAndPhrase() throws {
        for phrase in QuickChatPhrase.selectable {
            let message = QuickChatMessage(authorID: UUID(), phrase: phrase)
            let envelope = WireEnvelope(
                roomID: UUID(),
                senderID: UUID(),
                sequence: 11,
                payload: .quickChat(message)
            )

            let decoded = try JSONDecoder().decode(
                WireEnvelope.self,
                from: JSONEncoder().encode(envelope)
            )

            XCTAssertEqual(decoded.payload, .quickChat(message), "phrase: \(phrase)")
            guard case let .quickChat(decodedMessage) = decoded.payload else {
                return XCTFail("wrong payload for \(phrase)")
            }
            // The author must survive the relay hop — the host stamps its own ID on
            // the envelope when forwarding, so the payload is the only source.
            XCTAssertEqual(decodedMessage.authorID, message.authorID)
            XCTAssertEqual(decodedMessage.id, message.id)
        }
    }

    func testQuickChatFixtureDecodes() throws {
        let json = #"{"messageID":"44444444-4444-4444-4444-444444444444","payload":{"quickChat":{"authorID":"55555555-5555-5555-5555-555555555555","id":"66666666-6666-6666-6666-666666666666","phrase":"hurryUp","sentAt":774316800},"type":"quickChat"},"protocolVersion":1,"roomID":"22222222-2222-2222-2222-222222222222","senderID":"33333333-3333-3333-3333-333333333333","sequence":12}"#
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(json.utf8))
        guard case let .quickChat(message) = envelope.payload else {
            return XCTFail("expected a quickChat payload")
        }
        XCTAssertEqual(message.phrase, .hurryUp)
        XCTAssertEqual(message.authorID, UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        XCTAssertEqual(message.id, UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
    }

    func testUnknownQuickChatPhraseDecodesAsUnrecognizedInsteadOfThrowing() throws {
        // A phrase added in a future build must not tear down the frame; it decodes
        // to `.unrecognized` and the receiver simply shows nothing.
        let json = #"{"authorID":"11111111-1111-1111-1111-111111111111","id":"22222222-2222-2222-2222-222222222222","phrase":"newInSomeFutureBuild","sentAt":774316800}"#
        let message = try JSONDecoder().decode(QuickChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.phrase, .unrecognized)
        XCTAssertEqual(message.authorID, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    func testUnknownMessageKindDecodesAsUnknownInsteadOfThrowing() throws {
        // Same contract one level up: an unfamiliar payload `type` means a newer
        // peer, not a corrupt frame. Throwing here would surface a user-visible
        // "invalid_frame" error mid-match on the internet transport.
        let json = #"{"messageID":"11111111-1111-1111-1111-111111111111","payload":{"type":"somethingNew"},"protocolVersion":1,"roomID":"22222222-2222-2222-2222-222222222222","senderID":"33333333-3333-3333-3333-333333333333","sequence":3}"#
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.payload, .unknown)
    }

    func testMalformedPayloadUnderAKnownKindStillThrows() {
        // Only the discriminator is lenient: genuine corruption must still surface.
        let json = #"{"messageID":"11111111-1111-1111-1111-111111111111","payload":{"type":"quickChat","quickChat":{"phrase":"hurryUp"}},"protocolVersion":1,"roomID":"22222222-2222-2222-2222-222222222222","senderID":"33333333-3333-3333-3333-333333333333","sequence":4}"#
        XCTAssertThrowsError(try JSONDecoder().decode(WireEnvelope.self, from: Data(json.utf8)))
    }

    func testLegacyJoinRequestWithoutDeviceInstallDecodes() throws {
        // A pre-install-ID (protocol v1) client omits deviceInstallID entirely; it
        // must still decode, with the field defaulting to nil so the host falls back
        // to token-only seat reclaim.
        let json = #"{"participantID":"11111111-1111-1111-1111-111111111111","nickname":"Ang","authenticationCode":"","sessionToken":null}"#
        let request = try JSONDecoder().decode(JoinRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.deviceInstallID)
        XCTAssertEqual(request.nickname, "Ang")
        XCTAssertEqual(request.medalCount, 0)
    }

    func testJoinRequestPreservesDeviceInstallAcrossRoundTrip() throws {
        let install = UUID()
        let request = JoinRequest(
            participantID: UUID(),
            nickname: "Nova",
            medalCount: 27,
            authenticationCode: Data([1, 2, 3]),
            sessionToken: "token",
            deviceInstallID: install
        )
        let decoded = try JSONDecoder().decode(JoinRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.deviceInstallID, install)
        XCTAssertEqual(decoded.medalCount, 27)
        XCTAssertEqual(decoded, request)
    }

    func testParticipantAndSnapshotMedalCountsRoundTripWithLegacyFallback() throws {
        let participant = Participant(id: UUID(), nickname: "Collector", medalCount: 42)
        let participantData = try JSONEncoder().encode(participant)
        XCTAssertEqual(
            try JSONDecoder().decode(Participant.self, from: participantData).medalCount,
            42
        )

        var legacyParticipant = try XCTUnwrap(JSONSerialization.jsonObject(with: participantData) as? [String: Any])
        legacyParticipant.removeValue(forKey: "medalCount")
        let legacyParticipantData = try JSONSerialization.data(withJSONObject: legacyParticipant)
        XCTAssertEqual(
            try JSONDecoder().decode(Participant.self, from: legacyParticipantData).medalCount,
            0
        )

        let state = try StandardRuleset().makeGame(
            participants: [participant, Participant(id: UUID(), nickname: "Other")],
            configuration: .init(),
            seed: 31
        )
        let snapshotData = try JSONEncoder().encode(state.snapshot(for: participant.id))
        var snapshotObject = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        var players = try XCTUnwrap(snapshotObject["players"] as? [[String: Any]])
        players[0].removeValue(forKey: "medalCount")
        snapshotObject["players"] = players
        let legacySnapshotData = try JSONSerialization.data(withJSONObject: snapshotObject)
        let legacySnapshot = try JSONDecoder().decode(ClientGameSnapshot.self, from: legacySnapshotData)
        XCTAssertEqual(legacySnapshot.players[0].medalCount, 0)
    }

    func testSetPausedMessageRoundTrips() throws {
        for paused in [true, false] {
            let envelope = WireEnvelope(
                roomID: UUID(),
                senderID: UUID(),
                sequence: 3,
                payload: .setPaused(paused)
            )
            let decoded = try JSONDecoder().decode(WireEnvelope.self, from: JSONEncoder().encode(envelope))
            XCTAssertEqual(decoded.payload, .setPaused(paused))
        }
    }

    func testSessionSuspendedMessageRoundTrips() throws {
        let envelope = WireEnvelope(roomID: UUID(), senderID: UUID(), sequence: 4, payload: .sessionSuspended)
        let decoded = try JSONDecoder().decode(WireEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded.payload, .sessionSuspended)
    }

    func testFrameRejectsOversizedPayload() {
        XCTAssertThrowsError(try LengthPrefixedFramer.frame(Data(count: LengthPrefixedFramer.maximumFrameSize + 1)))
    }

    func testLegacyConfigurationDefaultsGracePeriodToEnabled() throws {
        let json = #"{"mode":"standard","targetPrestige":15,"turnDurationSeconds":30}"#
        let configuration = try JSONDecoder().decode(GameConfiguration.self, from: Data(json.utf8))
        XCTAssertTrue(configuration.turnGracePeriodEnabled)
        XCTAssertTrue(configuration.affordableCardHighlightEnabled)
    }

    func testDisabledGracePeriodSurvivesRoundTrip() throws {
        let configuration = GameConfiguration(turnGracePeriodEnabled: false)
        let data = try JSONEncoder().encode(configuration)
        XCTAssertFalse(try JSONDecoder().decode(GameConfiguration.self, from: data).turnGracePeriodEnabled)
    }

    func testDisabledAffordableCardHighlightSurvivesRoundTrip() throws {
        let configuration = GameConfiguration(affordableCardHighlightEnabled: false)
        let data = try JSONEncoder().encode(configuration)
        XCTAssertFalse(
            try JSONDecoder().decode(GameConfiguration.self, from: data).affordableCardHighlightEnabled
        )
    }

    func testLegacyConfigurationHasNoCustomStandardRules() throws {
        let json = #"{"mode":"standard","targetPrestige":15,"turnDurationSeconds":30}"#
        let configuration = try JSONDecoder().decode(GameConfiguration.self, from: Data(json.utf8))
        XCTAssertNil(configuration.customStandardRules)
        XCTAssertEqual(configuration.standardTokenLimit, StandardCustomRules.defaultTokenLimit)
        XCTAssertEqual(configuration.standardReserveLimit, StandardCustomRules.defaultReserveLimit)
    }

    /// The host's custom setup has to reach every guest; it travels inside
    /// `GameConfiguration`, so a plain round trip is the contract worth pinning.
    func testCustomStandardRulesSurviveConfigurationRoundTrip() throws {
        var custom = StandardCustomRules.standard(playerCount: 5)
        custom.gemCount = 11
        custom.goldCount = 3
        custom.tier3DeckCount = 8
        custom.nobleCount = 1
        custom.tokenLimit = 13
        custom.reserveLimit = 2

        let message = NetworkMessage.updateConfiguration(
            GameConfiguration(customStandardRules: custom)
        )
        let decoded = try JSONDecoder().decode(NetworkMessage.self, from: JSONEncoder().encode(message))
        guard case let .updateConfiguration(configuration) = decoded else {
            return XCTFail("expected updateConfiguration")
        }
        XCTAssertEqual(configuration.customStandardRules, custom)
        XCTAssertEqual(configuration.standardTokenLimit, 13)
        XCTAssertEqual(configuration.standardReserveLimit, 2)
    }

    /// A peer on an older build may omit fields we added later; each one falls
    /// back to its printed-rules default rather than failing the whole frame.
    func testPartialCustomStandardRulesDecodeToDefaults() throws {
        let json = #"{"mode":"standard","targetPrestige":15,"customStandardRules":{"gemCount":9}}"#
        let configuration = try JSONDecoder().decode(GameConfiguration.self, from: Data(json.utf8))
        let custom = try XCTUnwrap(configuration.customStandardRules)
        XCTAssertEqual(custom.gemCount, 9)
        XCTAssertEqual(custom.tokenLimit, StandardCustomRules.defaultTokenLimit)
        XCTAssertEqual(custom.reserveLimit, StandardCustomRules.defaultReserveLimit)
        XCTAssertEqual(custom.tier1DeckCount, StandardCustomRules.catalogCount(tier: 1))
    }

    func testOpeningTurnSelectionSurvivesSnapshotRoundTripAndRemainsBackwardCompatible() throws {
        let participants = [
            Participant(id: UUID(), nickname: "One", isHost: true),
            Participant(id: UUID(), nickname: "Two"),
        ]
        let state = try StandardRuleset().makeGame(
            participants: participants,
            configuration: .init(),
            seed: 17
        )
        let selection = OpeningTurnSelection(
            startedAt: Date(timeIntervalSince1970: 100),
            endsAt: Date(timeIntervalSince1970: 105)
        )
        let snapshot = state.snapshot(for: participants[0].id, openingTurnSelection: selection)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ClientGameSnapshot.self, from: data)
        XCTAssertEqual(decoded.openingTurnSelection, selection)
        XCTAssertEqual(decoded.startingPlayerID, state.players[state.startingPlayerIndex].id)
        XCTAssertEqual(decoded.players, snapshot.players)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "openingTurnSelection")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(try JSONDecoder().decode(ClientGameSnapshot.self, from: legacyData).openingTurnSelection)
    }

    func testSnapshotCarriesPauseStateAndDecodes() throws {
        let participants = [
            Participant(id: UUID(), nickname: "One", isHost: true),
            Participant(id: UUID(), nickname: "Two"),
        ]
        let state = try StandardRuleset().makeGame(participants: participants, configuration: .init(), seed: 3)
        let pause = MatchPause(
            reason: .disconnect,
            resumeDeadline: Date(timeIntervalSince1970: 500),
            waitingForNicknames: ["Two"]
        )
        let data = try JSONEncoder().encode(state.snapshot(for: participants[0].id, pause: pause))
        let decoded = try JSONDecoder().decode(ClientGameSnapshot.self, from: data)
        XCTAssertEqual(decoded.pause, pause)

        // A snapshot without a pause field (running match / legacy) decodes to nil.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pause")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(ClientGameSnapshot.self, from: legacyData).pause)
    }

    func testLegacyPlayerSnapshotWithoutReservedCardsStillDecodes() throws {
        let participants = [
            Participant(id: UUID(), nickname: "One", isHost: true),
            Participant(id: UUID(), nickname: "Two"),
        ]
        var state = try StandardRuleset().makeGame(
            participants: participants,
            configuration: .init(),
            seed: 21
        )
        state.players[1].reservedCards = [StandardCatalog.cards[0]]
        let data = try JSONEncoder().encode(state.snapshot(for: participants[0].id))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var players = try XCTUnwrap(object["players"] as? [[String: Any]])
        players = players.map { player in
            var legacyPlayer = player
            legacyPlayer.removeValue(forKey: "reservedCards")
            return legacyPlayer
        }
        object["players"] = players

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ClientGameSnapshot.self, from: legacyData)

        XCTAssertTrue(decoded.players.allSatisfy(\.reservedCards.isEmpty))
        XCTAssertEqual(decoded.players.first { $0.id == participants[1].id }?.reservedCardCount, 1)
    }
}
