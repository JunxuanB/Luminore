@preconcurrency import MultipeerConnectivity
import Foundation
import LuminoreCore

@MainActor
final class MultipeerTransport: NSObject, MatchTransport {
    static let serviceType = "luminore-mpc"

    let mode: MultiplayerMode = .nearby
    var roomCode: String? { nil }
    var onEvent: ((MatchTransportEvent) -> Void)?
    var onRoomsChanged: (([DiscoveredMatchRoom]) -> Void)?

    /// How many times a join re-sends its invitation before giving up, and how long
    /// it waits between attempts. MultipeerConnectivity drops an invitation without
    /// any callback when the host happens to be restarting its advertiser, so a
    /// single shot is not enough to make joining reliable.
    private static let invitationAttempts = 6
    private static let invitationRetryInterval: Duration = .seconds(4)
    /// Coalescing window for advertiser restarts (see `updateRoom`).
    private static let advertiseDebounce: Duration = .milliseconds(400)

    private let localPeer = MCPeerID(displayName: "Luminore-\(DeviceIdentity.installID.uuidString.prefix(12))")
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var advertisedInfo: [String: String]?
    private var advertiseTask: Task<Void, Never>?
    private var browser: MCNearbyServiceBrowser?
    private var descriptor: RoomDescriptor?
    private var discoveredPeers: [UUID: MCPeerID] = [:]
    private var discoveredRooms: [UUID: DiscoveredMatchRoom] = [:]
    private var transportIDs: [MCPeerID: TransportPeerID] = [:]
    private var peersByTransportID: [TransportPeerID: MCPeerID] = [:]
    private var targetRoomID: UUID?
    private var isHosting = false
    /// True while a room picker is on screen and wants `onRoomsChanged` updates.
    /// Distinct from whether the browser object exists — a joined client keeps
    /// browsing with no visible list (see `stopBrowsing`).
    private var isListVisible = false
    private var inviteTask: Task<Void, Never>?

    private var isConnectedToHost: Bool { session?.connectedPeers.isEmpty == false }

    /// A client must keep its browser alive for the whole session: MPC cancels a
    /// pending invitation when the browser that sent it goes away, and `reconnect()`
    /// needs the same browser to re-invite the host after a drop.
    private var needsBrowserForSession: Bool { !isHosting && targetRoomID != nil }

    func startBrowsing() {
        isListVisible = true
        ensureBrowser()
        publishRooms()
    }

    func stopBrowsing() {
        isListVisible = false
        onRoomsChanged?([])
        guard !needsBrowserForSession else { return }
        teardownBrowser()
    }

    /// Starts browsing only if it isn't already running. Recreating a live browser
    /// would invalidate every `MCPeerID` already handed out and abort in-flight
    /// invitations, so re-entrant calls must be a no-op.
    private func ensureBrowser() {
        guard browser == nil else { return }
        let browser = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
        browser.delegate = self
        self.browser = browser
        browser.startBrowsingForPeers()
    }

    private func teardownBrowser() {
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        discoveredPeers.removeAll()
        discoveredRooms.removeAll()
        onRoomsChanged?([])
    }

    func resolveRoom(code: String) async throws -> DiscoveredMatchRoom {
        _ = code
        throw MatchTransportError.unsupportedRoomCode
    }

    func resolveRoom(id: UUID) async throws -> DiscoveredMatchRoom {
        guard let room = discoveredRooms[id] else { throw MatchTransportError.roomNotFound }
        return room
    }

    func host(room: RoomDescriptor, isPublic: Bool) {
        _ = isPublic
        disconnect(closeRoom: true)
        descriptor = room
        isHosting = true
        session = makeSession()
        startAdvertising(room)
        onEvent?(.ready)
    }

    func join(room: DiscoveredMatchRoom) {
        guard discoveredPeers[room.id] != nil else {
            onEvent?(.failed(MatchTransportError.roomNotFound.localizedDescription))
            return
        }
        descriptor = room.descriptor
        targetRoomID = room.id
        isHosting = false
        session = makeSession()
        ensureBrowser()
        startInviting(announcesFailure: true)
    }

    func reconnect() {
        guard !isHosting, targetRoomID != nil else { return }
        ensureBrowser()
        if session == nil { session = makeSession() }
        // The caller (MatchSessionService's reconnect loop) already backs off and
        // surfaces its own reconnecting UI, so a silent retry is enough here.
        startInviting(announcesFailure: false)
    }

    func applicationDidBecomeActive() {
        if isHosting, let descriptor {
            // MPC stops advertising while the app is suspended and never resumes
            // on its own, so a host who stepped out to share the room would come
            // back invisible to everyone still looking for it. Republishing costs
            // nothing here: a suspended app has no invitation in flight for the
            // restart to interrupt.
            startAdvertising(descriptor)
        } else if targetRoomID != nil, !isConnectedToHost {
            reconnect()
        }
        if isListVisible { ensureBrowser() }
    }

    /// Re-sends the invitation until the session connects. A lone `invitePeer` is
    /// lost whenever the host is between advertiser instances, and MPC reports
    /// nothing back in that case — the joiner would just hang on the spinner.
    private func startInviting(announcesFailure: Bool) {
        inviteTask?.cancel()
        inviteTask = Task { @MainActor [weak self] in
            for _ in 0 ..< Self.invitationAttempts {
                guard let self, !Task.isCancelled, !self.isConnectedToHost else { return }
                self.sendInvitation()
                try? await Task.sleep(for: Self.invitationRetryInterval)
            }
            guard let self, !Task.isCancelled, !self.isConnectedToHost, announcesFailure else { return }
            self.onEvent?(.failed("nearby_join_failed"))
        }
    }

    private func sendInvitation() {
        guard !isHosting, let targetRoomID, let session else { return }
        ensureBrowser()
        guard let browser, let peer = discoveredPeers[targetRoomID] else { return }
        browser.invitePeer(
            peer,
            to: session,
            withContext: Data(targetRoomID.uuidString.utf8),
            timeout: 15
        )
    }

    func send(_ envelope: WireEnvelope, to recipient: TransportRecipient) {
        guard let session, let data = try? JSONEncoder().encode(envelope) else { return }
        let peers: [MCPeerID]
        switch recipient {
        case .host:
            peers = isHosting ? [] : session.connectedPeers
        case let .peer(peerID):
            peers = peersByTransportID[peerID].map { [$0] } ?? []
        case .allClients:
            peers = isHosting ? session.connectedPeers : []
        }
        guard !peers.isEmpty else { return }
        do {
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            onEvent?(.failed(error.localizedDescription))
        }
    }

    func updateRoom(_ descriptor: RoomDescriptor, isPublic: Bool) {
        _ = isPublic
        self.descriptor = descriptor
        guard isHosting else { return }
        // Replacing the advertiser is the only way to publish a new TXT record, but
        // it also tears down any invitation currently being negotiated. The room
        // revision bumps on nearly every message, so restart only when the published
        // record actually differs, and debounce bursts (a join mutates the roster,
        // the player count and the stage in quick succession).
        guard Self.discoveryInfo(descriptor) != advertisedInfo else { return }
        advertiseTask?.cancel()
        advertiseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.advertiseDebounce)
            guard !Task.isCancelled, let self, self.isHosting, let room = self.descriptor else { return }
            self.startAdvertising(room)
        }
    }

    private func startAdvertising(_ room: RoomDescriptor) {
        advertiseTask?.cancel()
        advertiseTask = nil
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        let info = Self.discoveryInfo(room)
        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeer,
            discoveryInfo: info,
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        self.advertiser = advertiser
        advertisedInfo = info
        advertiser.startAdvertisingPeer()
    }

    func disconnect(closeRoom: Bool) {
        _ = closeRoom
        inviteTask?.cancel()
        inviteTask = nil
        advertiseTask?.cancel()
        advertiseTask = nil
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        advertisedInfo = nil
        session?.disconnect()
        session?.delegate = nil
        session = nil
        transportIDs.removeAll()
        peersByTransportID.removeAll()
        descriptor = nil
        targetRoomID = nil
        isHosting = false
        // Browsing has its own view-owned lifetime. In particular,
        // MatchSessionService resets the current session before asking the
        // transport to join a room. Keep the discovered peer alive across that
        // reset so the room selected from the nearby list can still be invited.
        if !isListVisible { teardownBrowser() }
    }

    private func makeSession() -> MCSession {
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    private func handlePeer(_ peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            let id = transportIDs[peer] ?? TransportPeerID()
            transportIDs[peer] = id
            peersByTransportID[id] = peer
            if !isHosting {
                inviteTask?.cancel()
                inviteTask = nil
                onEvent?(.ready)
            }
            onEvent?(.peerConnected(id))
        case .notConnected:
            guard let id = transportIDs.removeValue(forKey: peer) else { return }
            peersByTransportID.removeValue(forKey: id)
            onEvent?(.peerDisconnected(id, nil))
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    private func handleFoundPeer(_ peer: MCPeerID, info: [String: String]?) {
        guard let descriptor = Self.parseDiscoveryInfo(info) else { return }
        let room = DiscoveredMatchRoom(descriptor: descriptor)
        discoveredPeers[descriptor.id] = peer
        discoveredRooms[descriptor.id] = room
        publishRooms()
        // The host reappeared (fresh advertiser, or back in range): invite it right
        // away instead of waiting out the retry interval.
        if targetRoomID == descriptor.id, !isConnectedToHost { sendInvitation() }
    }

    private func publishRooms() {
        guard isListVisible else { return }
        onRoomsChanged?(discoveredRooms.values.sorted {
            $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending
        })
    }

    private nonisolated static func discoveryInfo(_ room: RoomDescriptor) -> [String: String] {
        [
            "id": room.id.uuidString,
            "name": String(room.name.prefix(40)),
            "host": String(room.hostNickname.prefix(30)),
            "count": String(room.playerCount),
            "max": String(room.maximumPlayers),
            "locked": room.isPasswordProtected ? "1" : "0",
            "stage": room.stage.rawValue,
            "pv": String(WireEnvelope.currentProtocolVersion),
        ]
    }

    private nonisolated static func parseDiscoveryInfo(_ info: [String: String]?) -> RoomDescriptor? {
        guard let info,
              let idText = info["id"], let id = UUID(uuidString: idText),
              let name = info["name"], let host = info["host"],
              let countText = info["count"], let count = Int(countText),
              let maximumText = info["max"], let maximum = Int(maximumText),
              let stageText = info["stage"], let stage = RoomStage(rawValue: stageText),
              info["pv"] == String(WireEnvelope.currentProtocolVersion)
        else { return nil }
        return RoomDescriptor(
            id: id,
            name: name,
            hostNickname: host,
            playerCount: count,
            maximumPlayers: maximum,
            isPasswordProtected: info["locked"] == "1",
            stage: stage
        )
    }
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // MultipeerConnectivity's invitationHandler is a non-Sendable closure; box it
        // so it can cross into the MainActor task without a Swift 6 data-race error.
        let box = UncheckedSendableBox(invitationHandler)
        Task { @MainActor [weak self] in
            guard let self, self.isHosting, let session = self.session else {
                box.value(false, nil)
                return
            }
            // The joiner re-invites until it connects, so a duplicate can arrive
            // while the first one is already established. Accepting it again would
            // renegotiate and drop the working link.
            guard !session.connectedPeers.contains(peerID) else {
                box.value(false, nil)
                return
            }
            if let context, let requested = String(data: context, encoding: .utf8),
               requested != self.descriptor?.id.uuidString {
                box.value(false, nil)
                return
            }
            box.value(true, session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in self?.onEvent?(.failed(error.localizedDescription)) }
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Task { @MainActor [weak self] in self?.handleFoundPeer(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self, let roomID = self.discoveredPeers.first(where: { $0.value == peerID })?.key else { return }
            self.discoveredPeers.removeValue(forKey: roomID)
            self.discoveredRooms.removeValue(forKey: roomID)
            self.publishRooms()
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in self?.onEvent?(.failed(error.localizedDescription)) }
    }
}

extension MultipeerTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in self?.handlePeer(peerID, state: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= LengthPrefixedFramer.maximumFrameSize,
              let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data)
        else { return }
        Task { @MainActor [weak self] in
            guard let self, let id = self.transportIDs[peerID] else { return }
            self.onEvent?(.message(envelope, from: id))
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}


/// Wraps a non-Sendable value (here, MultipeerConnectivity's invitation handler) so it
/// can be captured into a concurrent task. Safe because the handler is only ever
/// invoked on the main actor.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
