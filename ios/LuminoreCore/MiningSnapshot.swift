import Foundation

/// The dig window as every client sees it.
///
/// Modelled on `MatchPause`: the host owns it, it rides inside each
/// `ClientGameSnapshot`, and clients simply mirror whatever the latest snapshot
/// says. That makes it self-healing — a dropped control message can never leave
/// somebody stuck behind a dig overlay.
///
/// Deliberately holds only the *static* setup. The rock count changes 5× a
/// second and travels separately in `MiningProgress`; a multi-KB snapshot per
/// tick would stall the whole match.
public struct MiningSnapshot: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// The five-second window is open and everyone is tapping.
        case digging
        /// Time is up; the win/lose reveal is playing.
        case resolved
        /// The miner won a token they have no room for and must discard first.
        case awaitingDiscard
    }

    public enum Outcome: String, Codable, Sendable {
        case success
        case failure
    }

    public let id: UUID
    public let minerID: UUID
    public let minerNickname: String
    /// The (never-gold) token buried under the pile. Already removed from the
    /// bank — it goes back if the miner runs out of time.
    public let gem: GemColor
    public let startedAt: Date
    public let endsAt: Date
    public let pileTotal: Int
    public let successThreshold: Int
    public let shovelSize: Int
    public let phase: Phase
    public let outcome: Outcome?
    /// Tokens the miner must discard before play resumes. `awaitingDiscard` only.
    public let discardCount: Int

    public init(
        id: UUID = UUID(),
        minerID: UUID,
        minerNickname: String,
        gem: GemColor,
        startedAt: Date,
        endsAt: Date,
        pileTotal: Int = MiningBalance.pileTotal,
        successThreshold: Int = MiningBalance.successThreshold,
        shovelSize: Int,
        phase: Phase = .digging,
        outcome: Outcome? = nil,
        discardCount: Int = 0
    ) {
        self.id = id
        self.minerID = minerID
        self.minerNickname = minerNickname
        self.gem = gem
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.pileTotal = max(1, pileTotal)
        self.successThreshold = min(max(0, successThreshold), max(1, pileTotal))
        self.shovelSize = max(1, shovelSize)
        self.phase = phase
        self.outcome = outcome
        self.discardCount = max(0, discardCount)
    }

    /// Same window, new phase. Everything else is immutable for the dig's life.
    public func with(phase: Phase, outcome: Outcome? = nil, discardCount: Int = 0) -> MiningSnapshot {
        MiningSnapshot(
            id: id,
            minerID: minerID,
            minerNickname: minerNickname,
            gem: gem,
            startedAt: startedAt,
            endsAt: endsAt,
            pileTotal: pileTotal,
            successThreshold: successThreshold,
            shovelSize: shovelSize,
            phase: phase,
            outcome: outcome ?? self.outcome,
            discardCount: discardCount
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, minerID, minerNickname, gem, startedAt, endsAt
        case pileTotal, successThreshold, shovelSize, phase, outcome, discardCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            minerID: try container.decode(UUID.self, forKey: .minerID),
            minerNickname: try container.decodeIfPresent(String.self, forKey: .minerNickname) ?? "",
            gem: try container.decode(GemColor.self, forKey: .gem),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endsAt: try container.decode(Date.self, forKey: .endsAt),
            pileTotal: try container.decodeIfPresent(Int.self, forKey: .pileTotal) ?? MiningBalance.pileTotal,
            successThreshold: try container.decodeIfPresent(Int.self, forKey: .successThreshold)
                ?? MiningBalance.successThreshold,
            shovelSize: try container.decodeIfPresent(Int.self, forKey: .shovelSize) ?? 4,
            phase: try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .digging,
            outcome: try container.decodeIfPresent(Outcome.self, forKey: .outcome),
            discardCount: try container.decodeIfPresent(Int.self, forKey: .discardCount) ?? 0
        )
    }
}

/// Host → clients, 5× a second while a dig is open. Tiny on purpose.
public struct MiningProgress: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let remaining: Int
    /// Repeated every tick so a client that joined late — or whose clock drifted
    /// — can re-anchor its countdown ring without waiting for a full snapshot.
    public let endsAt: Date

    public init(sessionID: UUID, remaining: Int, endsAt: Date) {
        self.sessionID = sessionID
        self.remaining = max(0, remaining)
        self.endsAt = endsAt
    }
}

/// Client → host, 5× a second: how many times this player tapped since the last
/// report. Counts, not individual events, so a burst costs one small message.
public struct MiningTapReport: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let taps: Int

    public init(sessionID: UUID, taps: Int) {
        self.sessionID = sessionID
        self.taps = max(0, taps)
    }
}

/// Miner → host: how the dig ended, as counted on the miner's own device.
///
/// The miner's device is the authority for the rock count (see
/// `MatchSessionService+Mining`), so the host takes this at face value and
/// settles the token from it. Consistent with the project's stance that local
/// tampering is not worth defending against.
public struct MiningOutcomeReport: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let remaining: Int

    public init(sessionID: UUID, remaining: Int) {
        self.sessionID = sessionID
        self.remaining = max(0, remaining)
    }
}

/// Miner → host: the tokens they chose to drop after winning one they had no
/// room for.
public struct MiningDiscard: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let tokens: [GemColor: Int]

    public init(sessionID: UUID, tokens: [GemColor: Int]) {
        self.sessionID = sessionID
        self.tokens = tokens.filter { $0.value > 0 }
    }
}
