import Foundation
import LuminoreCore
@testable import Luminore

/// In-process transport pair used by the multiplayer tests: two instances
/// point at each other so a host and a client can exchange wire envelopes
/// synchronously, with no real networking.
@MainActor
final class FakeMatchTransport: MatchTransport {
    let mode: MultiplayerMode
    var roomCode: String? { mode == .internet ? "ABC234" : nil }
    var onEvent: ((MatchTransportEvent) -> Void)?
    var onRoomsChanged: (([DiscoveredMatchRoom]) -> Void)?
    weak var other: FakeMatchTransport?
    private var room: RoomDescriptor?
    private var hosting = false
    var disconnectCalls = 0
    var lastCloseRoom = false
    var sentEnvelopes: [WireEnvelope] = []
    var foregroundCalls = 0
    /// When set, `host(room:isPublic:)` reports a failure instead of coming up —
    /// the shape of a room-creation request that never reached the relay.
    var failsHosting: String?

    init(mode: MultiplayerMode) {
        self.mode = mode
    }

    func startBrowsing() {
        if let room = other?.room { onRoomsChanged?([DiscoveredMatchRoom(descriptor: room)]) }
    }

    func stopBrowsing() { onRoomsChanged?([]) }

    func resolveRoom(code: String) async throws -> DiscoveredMatchRoom {
        guard code == roomCode, let room = other?.room else { throw MatchTransportError.roomNotFound }
        return DiscoveredMatchRoom(descriptor: room)
    }

    func resolveRoom(id: UUID) async throws -> DiscoveredMatchRoom {
        guard let room = other?.room, room.id == id else { throw MatchTransportError.roomNotFound }
        return DiscoveredMatchRoom(descriptor: room)
    }

    func host(room: RoomDescriptor, isPublic: Bool) {
        _ = isPublic
        self.room = room
        hosting = true
        if let failsHosting {
            onEvent?(.failed(failsHosting))
        } else {
            onEvent?(.ready)
        }
    }

    func join(room: DiscoveredMatchRoom) {
        self.room = room.descriptor
        hosting = false
        onEvent?(.ready)
        onEvent?(.peerConnected(TransportPeerID("host")))
        other?.onEvent?(.peerConnected(TransportPeerID("client")))
    }

    func reconnect() {}

    func applicationDidBecomeActive() { foregroundCalls += 1 }

    /// Push a transport event at the session under test without going through a
    /// join, so outage handling can be exercised directly.
    func emit(_ event: MatchTransportEvent) { onEvent?(event) }

    func send(_ envelope: WireEnvelope, to recipient: TransportRecipient) {
        sentEnvelopes.append(envelope)
        guard let other else { return }
        switch recipient {
        case .host:
            other.onEvent?(.message(envelope, from: TransportPeerID("client")))
        case .peer, .allClients:
            other.onEvent?(.message(envelope, from: TransportPeerID("host")))
        }
    }

    func updateRoom(_ descriptor: RoomDescriptor, isPublic: Bool) {
        _ = isPublic
        room = descriptor
    }

    func disconnect(closeRoom: Bool) {
        disconnectCalls += 1
        lastCloseRoom = closeRoom
        if closeRoom { room = nil }
        hosting = false
    }
}
