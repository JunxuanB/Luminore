import Foundation
import LuminoreCore
import SwiftData

/// A host-side, full serialization of an in-progress match ("存档"). Lives only on
/// the device that saved it, in a **local-only** SwiftData store (see
/// `PersistenceController`): the state blob is large and there is no cross-device
/// resume, so it is intentionally never mirrored to CloudKit.
///
/// A save is deliberately *not* bound to a room, a transport, or any reconnect
/// credential. It is loaded into a freshly hosted room from the configuration
/// screen, where the host maps each saved seat onto a present player — so the same
/// save works across LAN, internet, and nearby matches alike.
@Model
final class GameSaveRecord {
    var id: UUID = UUID()
    /// `AccountProfile.uuid.uuidString` of the host that saved it. Stored as a
    /// string so it can be used in a `#Predicate` — UUID equality traps in SwiftData.
    var ownerKey: String = ""
    var gameID: UUID = UUID()
    /// Name of the room the match was played in, for display only.
    var roomName: String = ""
    var modeRawValue: String = "standard"
    /// Number of seats. A save can only be loaded into a room with exactly this
    /// many connected players.
    var playerCount: Int = 0
    /// Nickname of whoever was to move when the match was saved, for display only.
    var currentSeatNickname: String = ""
    var savedAt: Date = Date()
    /// Encoded `GameState`.
    var statePayload: Data = Data()
    /// Encoded `[Participant]`, in the **same order** as `GameState.players`. Keeps
    /// each seat's nickname (so the host can tell the seats apart when matching
    /// players) and each bot's difficulty.
    var seatsPayload: Data = Data()

    init(
        ownerKey: String,
        gameID: UUID,
        roomName: String,
        modeRawValue: String,
        playerCount: Int,
        currentSeatNickname: String,
        statePayload: Data,
        seatsPayload: Data,
        savedAt: Date = Date()
    ) {
        self.ownerKey = ownerKey
        self.gameID = gameID
        self.roomName = roomName
        self.modeRawValue = modeRawValue
        self.playerCount = playerCount
        self.currentSeatNickname = currentSeatNickname
        self.statePayload = statePayload
        self.seatsPayload = seatsPayload
        self.savedAt = savedAt
    }

    var gameMode: GameMode { GameMode(rawValue: modeRawValue) ?? .standard }

    /// The saved seats, in turn order. Empty if the payload is unreadable, which
    /// makes the record show up in the browser as unloadable rather than crashing.
    var seats: [Participant] {
        (try? JSONDecoder().decode([Participant].self, from: seatsPayload)) ?? []
    }

    var state: GameState? {
        try? JSONDecoder().decode(GameState.self, from: statePayload)
    }
}
