import Foundation
import LuminoreCore
import SwiftData

@MainActor
final class MatchSessionService: ObservableObject {
    enum Phase: Equatable {
        case menu
        case connecting
        case lobby
        case configuration
        case game
        case results
        case reconnecting
        case ended
    }

    @Published var phase: Phase = .menu
    @Published var room: RoomSnapshot?
    @Published var game: ClientGameSnapshot?
    /// Latest host-confirmed action animation. All three transports publish the
    /// same event before their resulting game snapshot is presented.
    @Published var gameAnimationEvent: GameAnimationEvent?
    /// Newest quick-chat bubble to show, with the author's display name already
    /// resolved against the local roster. Replaced rather than queued — only one
    /// bubble is ever on screen. See `MatchSessionService+QuickChat`.
    @Published var quickChatEvent: QuickChatEvent?
    /// When the local quick-chat send cooldown lifts. Purely local anti-spam; the
    /// host deliberately does not rate-limit.
    @Published var quickChatCooldownEndsAt: Date?
    @Published var discoveredRooms: [DiscoveredMatchRoom] = []
    @Published var roomCode: String?
    @Published var turnDeadline: Date?
    @Published var openingTurnSelection: OpeningTurnSelection?
    @Published var presentedError: String?
    /// Authoritative pause state, mirrored from the game snapshot on clients and
    /// computed on the host. `nil` means the match is running. Drives which cover
    /// (host pause vs. disconnect-wait) is shown. See `isPaused`.
    @Published var matchPause: MatchPause?
    /// Open 挖矿 window; `nil` when nobody is digging. Host-owned and mirrored by
    /// clients straight from the game snapshot. See `MatchSessionService+Mining`.
    @Published var mining: MiningSnapshot?
    /// Rocks left on the pile *as this device renders it*: locally predicted on
    /// every tap, then converged onto the host's number 5× a second. Deliberately
    /// a nested observable rather than a `@Published` here — see `MiningPileModel`.
    let miningPile = MiningPileModel()

    /// Convenience: any pause (host or disconnect) is active.
    var isPaused: Bool { matchPause != nil }
    /// Set when the host saves & ends the match, or when a client is told the host
    /// did — the flow dismisses itself instead of showing a disconnection error.
    @Published var wasSuspended = false
    /// Host preference: name AI seats with playful random nicknames in the host's
    /// language instead of the difficulty-numbered defaults. Persisted across
    /// launches; change it through `setRandomizesBotNames(_:)`.
    @Published var randomizesBotNames = UserDefaults.standard.bool(forKey: MatchSessionService.randomBotNamesKey)

    let localID: UUID
    let deviceInstallID: UUID
    let mode: MultiplayerMode
    var serverURL: URL?
    var nickname: String
    var medalCount: Int
    var isHost = false
    var isPublic = true

    let rules = RulesEngine()
    var transport: any MatchTransport
    var participantPeers: [UUID: TransportPeerID] = [:]
    var peerParticipants: [TransportPeerID: UUID] = [:]
    var pendingPeers: Set<TransportPeerID> = []
    var challenges: [TransportPeerID: AuthChallenge] = [:]
    var hostPeer: TransportPeerID?
    var authoritativeGame: GameState?
    var roomPassword = ""
    var joinPassword = ""
    var sessionToken: String?
    var currentSessionToken: String? { sessionToken }
    var tokens: [UUID: String] = [:]
    /// Host-side map of participant UUID → the device install that owns that seat.
    /// Combined with `tokens`, this is the reconnect key: a seat can only be
    /// reclaimed by the same device that first took it, so two devices sharing one
    /// account UUID can never silently steal each other's seat.
    var seatInstalls: [UUID: UUID] = [:]
    var outgoingSequence: UInt64 = 0
    var lastIncomingSequence: [TransportPeerID: UInt64] = [:]
    var seenMessageIDs: Set<UUID> = []
    /// Timestamps of recent local quick-chat sends, used for the burst allowance.
    var quickChatSendTimes: [Date] = []
    var turnTask: Task<Void, Never>?
    var openingTurnTask: Task<Void, Never>?
    /// Host-side task that computes and applies the current bot seat's move.
    /// Cancelled and rescheduled whenever the authoritative game advances.
    var botTask: Task<Void, Never>?
    /// Tutorial-only bot override. These actions are validated against the live
    /// authoritative state before use; normal AI takes over if validation fails.
    var tutorialOpponentID: UUID?
    var tutorialOpponentActions: [GameAction] = []
    var reconnectTask: Task<Void, Never>?
    var animationBroadcastTask: Task<Void, Never>?
    /// Host-side pause truth (the client mirrors `matchPause` from the snapshot).
    /// `hostPaused` is the manual pause; `disconnectGraceUntil` is the deadline of
    /// the active reconnect-wait window. `matchPause` is derived from these.
    var hostPaused = false
    var disconnectGraceUntil: Date?
    var disconnectGraceTask: Task<Void, Never>?
    /// 挖矿 device-side state. The rock count itself lives in `miningPile`; the
    /// *authority* for it is the miner's device, not necessarily this one — see
    /// `MatchSessionService+Mining`. `miningKnownRemaining` is the host's copy of
    /// the last count the miner published, used only as a fallback verdict if the
    /// miner never reports one.
    var miningKnownRemaining = MiningBalance.pileTotal
    var pendingMiningPlan: MiningPlan?
    var pendingMiningTask: Task<Void, Never>?
    /// Thrown rocks made on this device that the miner has not been told about yet.
    var miningLocalTaps = 0
    /// Thrown rocks received but not yet folded in.
    var miningInboundTaps = 0
    /// Host: fractional carry so a bot's taps-per-second survives 5 Hz rounding.
    var miningBotCredit: [UUID: Double] = [:]
    /// Host: each thrower's remaining throw budget and when it was last spent —
    /// the token bucket behind `MiningBalance.throwCooldown`.
    var miningThrowBudget: [UUID: Double] = [:]
    var miningThrowStamp: [UUID: Date] = [:]
    /// This device's own next permitted throw, mirroring the host's cooldown so
    /// the heap on screen matches what actually lands.
    var miningNextThrowAt = Date.distantPast
    /// Miner's device: publishes the count and closes the window.
    var miningTickTask: Task<Void, Never>?
    /// Host: drives every bot's digging or throwing.
    var miningBotTask: Task<Void, Never>?
    /// Host: settles the dig if the miner's own verdict never arrives.
    var miningFallbackTask: Task<Void, Never>?
    var miningFlushTask: Task<Void, Never>?
    var miningFinishTask: Task<Void, Never>?
    var miningDiscardTask: Task<Void, Never>?
    /// Round in which a last-place dig already fired; at most one per round.
    var lastMiningRound: Int?
    /// Injectable for tests. Returns a value in `0..<1`.
    var miningRandom: () -> Double = { Double.random(in: 0 ..< 1) }
    /// How long the whole match freezes waiting for a dropped player to return
    /// before play continues (skipping seats still absent).
    let disconnectGraceDuration: TimeInterval = 15
    var isReconnectLoopActive = false
    var isLeaving = false
    /// Keeps the transport running for the short grant iOS gives a backgrounded
    /// app, so stepping out to share an invite code does not drop the room.
    private let backgroundGuard = BackgroundActivityGuard()

    init(
        localID: UUID,
        nickname: String,
        medalCount: Int = 0,
        mode: MultiplayerMode = .lan,
        serverURL: URL? = nil,
        deviceInstallID: UUID = DeviceIdentity.installID,
        transport: (any MatchTransport)? = nil
    ) {
        self.localID = localID
        self.nickname = nickname
        self.medalCount = max(0, medalCount)
        self.mode = mode
        self.serverURL = serverURL
        self.deviceInstallID = deviceInstallID
        self.transport = transport ?? MatchTransportFactory.make(mode: mode, serverURL: serverURL)
        configureTransportCallbacks()
    }

    func updateNickname(_ value: String) {
        nickname = value
    }

    func updateMedalCount(_ value: Int) {
        medalCount = max(0, value)
        guard authoritativeGame == nil, var room,
              let index = room.participants.firstIndex(where: { $0.id == localID })
        else { return }
        room.participants[index].medalCount = medalCount
        room.revision += 1
        self.room = room
        if isHost {
            broadcastRoom()
            updateAdvertisement()
        }
    }

    func updateInternetServer(_ url: URL) {
        guard mode == .internet, phase == .menu else { return }
        transport.disconnect(closeRoom: false)
        serverURL = url
        transport = InternetTransport(serverURL: url)
        configureTransportCallbacks()
    }

    func host(roomName: String, password: String, isPublic: Bool = true) {
        leave()
        isLeaving = false
        wasSuspended = false
        isHost = true
        self.isPublic = isPublic
        roomPassword = password
        let descriptor = RoomDescriptor(
            id: UUID(),
            name: roomName,
            hostNickname: nickname,
            playerCount: 1,
            isPasswordProtected: !password.isEmpty
        )
        room = RoomSnapshot(
            descriptor: descriptor,
            participants: [Participant(
                id: localID,
                nickname: nickname,
                medalCount: medalCount,
                isHost: true
            )]
        )
        sessionToken = randomToken()
        tokens[localID] = sessionToken
        seatInstalls[localID] = deviceInstallID

        phase = .connecting
        transport.host(room: descriptor, isPublic: isPublic)
    }

    func join(_ discovered: DiscoveredMatchRoom, password: String) {
        leave()
        isLeaving = false
        wasSuspended = false
        isHost = false
        room = RoomSnapshot(descriptor: discovered.descriptor, participants: [])
        joinPassword = password
        phase = .connecting
        transport.join(room: discovered)
    }

    func startBrowsing() { transport.startBrowsing() }
    func stopBrowsing() { transport.stopBrowsing() }

    func resolveRoom(code: String) async throws -> DiscoveredMatchRoom {
        try await transport.resolveRoom(code: code)
    }

    func resolveRoom(id: UUID) async throws -> DiscoveredMatchRoom {
        try await transport.resolveRoom(id: id)
    }

    /// Host-only reordering of the lobby roster. Seat order here becomes the turn
    /// order at `startGame` (the opening player is still drawn at random), so the
    /// host can seat people deliberately before configuring the match.
    func moveParticipants(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard isHost, var room, room.descriptor.stage == .lobby else { return }
        room.participants.move(fromOffsets: source, toOffset: destination)
        room.revision += 1
        self.room = room
        broadcastRoom()
    }

    func enterConfiguration() {
        guard isHost, var room, room.participants.filter(\.isConnected).count >= 2 else { return }
        room.descriptor.stage = .configuration
        room.revision += 1
        self.room = room
        phase = .configuration
        updateAdvertisement()
        broadcastRoom()
    }

    func updateConfiguration(_ configuration: GameConfiguration) {
        guard isHost, var room, room.descriptor.stage == .configuration else { return }
        if configuration.mode == .duel,
           room.participants.filter(\.isConnected).count != 2 {
            presentedError = AppLanguage.string("config.duel.requiresTwo")
            return
        }
        room.configuration = configuration
        room.descriptor.maximumPlayers = configuration.mode == .duel ? 2 : 7
        room.revision += 1
        self.room = room
        updateAdvertisement()
        broadcastRoom()
    }

    func startGame() {
        guard isHost, var room else { return }
        let connected = room.participants.filter(\.isConnected)
        guard connected.count >= 2 else { return }
        do {
            authoritativeGame = try rules.makeGame(
                participants: connected,
                configuration: room.configuration,
                seed: UInt64.random(in: .min ... .max)
            )
            openingTurnSelection = OpeningTurnSelection()
            lastMiningRound = nil
            room.participants = connected
            room.descriptor.playerCount = connected.count
            room.descriptor.stage = .playing
            room.revision += 1
            self.room = room
            phase = .game
            updateAdvertisement()
            broadcastRoom()
            scheduleOpeningTurnCompletion()
            broadcastGame()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func submit(_ action: GameAction) {
        guard phase == .game, !isOpeningTurnSelection, game?.currentPlayerID == localID else { return }
        if isHost {
            apply(action, from: localID, allowsPass: true)
        } else {
            sendToHost(.action(action))
        }
    }

    func returnToConfiguration() {
        guard isHost, var room else { return }
        abortMining()
        lastMiningRound = nil
        authoritativeGame = nil
        game = nil
        openingTurnTask?.cancel()
        botTask?.cancel()
        tutorialOpponentID = nil
        tutorialOpponentActions.removeAll()
        openingTurnSelection = nil
        clearPauseState()
        room.participants.removeAll { !$0.isConnected }
        guard room.participants.count >= 2 else {
            room.descriptor.stage = .lobby
            self.room = room
            phase = .lobby
            broadcastRoom()
            updateAdvertisement()
            return
        }
        room.descriptor.stage = .configuration
        room.revision += 1
        self.room = room
        phase = .configuration
        broadcast(.returnToConfiguration)
        broadcastRoom()
        updateAdvertisement()
    }

    func leave() {
        isLeaving = true
        backgroundGuard.end()
        abortMining()
        lastMiningRound = nil
        turnTask?.cancel()
        openingTurnTask?.cancel()
        botTask?.cancel()
        tutorialOpponentID = nil
        tutorialOpponentActions.removeAll()
        reconnectTask?.cancel()
        animationBroadcastTask?.cancel()
        disconnectGraceTask?.cancel()
        if !isHost, hostPeer != nil { sendToHost(.leave) }
        hostPeer = nil
        participantPeers.removeAll()
        peerParticipants.removeAll()
        pendingPeers.removeAll()
        challenges.removeAll()
        transport.disconnect(closeRoom: isHost)
        authoritativeGame = nil
        room = nil
        game = nil
        gameAnimationEvent = nil
        quickChatEvent = nil
        quickChatCooldownEndsAt = nil
        quickChatSendTimes.removeAll()
        turnDeadline = nil
        openingTurnSelection = nil
        phase = .menu
        isHost = false
        clearPauseState()
        isReconnectLoopActive = false
        tokens.removeAll()
        seatInstalls.removeAll()
        lastIncomingSequence.removeAll()
        seenMessageIDs.removeAll()
    }

    // MARK: Pause / resume (host authority)

    func pauseGame() {
        guard isHost, phase == .game, !isPaused, !isOpeningTurnSelection else { return }
        hostPaused = true
        // A pause outranks a dig: settle it before the covered snapshot goes out,
        // otherwise the window would tick away behind the pause cover.
        abortMining()
        turnTask?.cancel()
        botTask?.cancel()
        turnDeadline = nil
        recomputePauseAndBroadcast()
    }

    func resumeGame() {
        guard isHost, hostPaused else { return }
        hostPaused = false
        // If players dropped while the host held the pause, don't jump straight
        // back into play — start a reconnect-wait window for them.
        if hasDisconnectedInGamePlayers {
            beginDisconnectPause()
        } else {
            recomputePause()
            scheduleTurnTimer()
            broadcastGame()
            scheduleBotTurnIfNeeded()
        }
    }

    /// Reset every pause flag (used on leave / return-to-config / resume setup).
    func clearPauseState() {
        matchPause = nil
        hostPaused = false
        disconnectGraceUntil = nil
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
    }

    /// True when the match is live and at least one non-host seat is disconnected.
    var hasDisconnectedInGamePlayers: Bool {
        guard authoritativeGame?.status == .playing else { return false }
        return room?.participants.contains { !$0.isConnected && $0.id != localID } ?? false
    }

    /// Call when the app is about to lose the foreground. Claims the short
    /// background grant so a live link survives the round trip out to another app
    /// — the host pasting the invite code into a chat is exactly that round trip,
    /// and losing the relay socket there is what makes a freshly created room look
    /// to the joining friend like it never existed.
    func applicationWillResignActive() {
        guard !isLeaving, phase != .menu, phase != .ended else { return }
        backgroundGuard.begin()
    }

    /// Call when the app returns to the foreground. Sockets and radio services die
    /// while a process is suspended and only report it on their next use, so the
    /// link is re-validated up front instead of after a keepalive interval of
    /// silence — for the host, that silence is a window in which nobody can join.
    func applicationDidBecomeActive() {
        backgroundGuard.end()
        guard !isLeaving else { return }
        transport.applicationDidBecomeActive()
        guard !isHost, phase == .reconnecting, hostPeer == nil else { return }
        transport.reconnect()
        scheduleReconnect()
    }

    /// True while a client is parked waiting for a host it has never reached —
    /// joining by code while the host is briefly away — as opposed to recovering a
    /// link that was previously established. Only the wording differs, but
    /// "reconnecting" is actively confusing on a first join.
    var isWaitingForHost: Bool {
        !isHost && phase == .reconnecting && room?.participants.isEmpty == true
    }

    var isOpeningTurnSelection: Bool {
        guard let selection = openingTurnSelection else { return false }
        return Date() < selection.endsAt
    }
}
