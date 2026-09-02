import Foundation

/// Host-authored settings for the 挖矿 mini-game.
///
/// Rides inside `GameConfiguration`, which is already part of both
/// `RoomSnapshot` (lobby + configuration sync) and `ClientGameSnapshot`
/// (in-match sync), so every transport carries it with no extra plumbing.
///
/// Standard mode only. Duel ignores it entirely.
public struct MiningRules: Codable, Equatable, Sendable {
    public static let defaultLastPlaceChance = 25
    public static let defaultSameColorChance = 20
    public static let chanceRange = 0 ... 100

    /// Master switch. Off by default — 挖矿 is an opt-in house rule.
    public var isEnabled: Bool
    /// Percent chance that a player who ends their turn in last place triggers
    /// a dig. At most one such trigger per round.
    public var lastPlaceChance: Int
    /// Percent chance that taking two tokens of the same colour triggers a dig.
    public var sameColorChance: Int

    public init(
        isEnabled: Bool = false,
        lastPlaceChance: Int = MiningRules.defaultLastPlaceChance,
        sameColorChance: Int = MiningRules.defaultSameColorChance
    ) {
        self.isEnabled = isEnabled
        self.lastPlaceChance = Self.clamp(lastPlaceChance)
        self.sameColorChance = Self.clamp(sameColorChance)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, chanceRange.lowerBound), chanceRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case lastPlaceChance
        case sameColorChance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            lastPlaceChance: try container.decodeIfPresent(Int.self, forKey: .lastPlaceChance)
                ?? Self.defaultLastPlaceChance,
            sameColorChance: try container.decodeIfPresent(Int.self, forKey: .sameColorChance)
                ?? Self.defaultSameColorChance
        )
    }
}

/// Every tunable number the dig uses, in one place.
///
/// **Balance sketch.** A miner wins by clearing `pileTotal - successThreshold`
/// = 80 rocks while `k` opponents throw them back, so the break-even tap rate is
/// `(80 + k·a·duration) / (duration · shovel)` for opponents adding at `a`/s.
/// At 7 seconds with `shovel = 3 + k`, a miner needs roughly 4.3 / 4.5 / 4.7
/// taps per second against one / two / three opponents tapping 5.5/s — brisk but
/// sustainable, and forgiving of a dropped tap in a way a 5-second window was
/// not. Widening the window helps the miner more than the opponents because the
/// 80-rock debt is fixed while their contribution merely scales with time.
public enum MiningBalance {
    /// Length of the dig window. All clients derive their countdown ring from
    /// the host's absolute `startedAt`/`endsAt`, so this only sets the spread.
    public static let duration: TimeInterval = 7
    public static let pileTotal = 100
    /// Rocks that may remain and still count as "dug out".
    public static let successThreshold = 20
    /// How long the win/lose reveal stays up before play resumes.
    public static let revealBeat: TimeInterval = 1.6
    /// Pile tick + tap-report cadence (5 Hz).
    public static let tickInterval: TimeInterval = 0.2
    /// How long the host waits for the miner to discard before doing it for them.
    public static let discardTimeout: TimeInterval = 20
    /// How long the host waits past `endsAt` for the miner's own verdict before
    /// settling from the last count it saw. See `MatchSessionService+Mining`.
    public static let outcomeGrace: TimeInterval = 1.5
    /// Backstop for a decided-but-unopened dig. Comfortably longer than the
    /// slowest `GameAnimationEvent.snapshotDelay`, which is what normally opens
    /// it; see `startPendingMiningWatchdog`.
    public static let plannedDigWatchdog: TimeInterval = 2.5

    /// The tap rate the whole balance is tuned around. A dig should demand about
    /// this much of its miner — at *every* table size.
    public static let targetMinerTapsPerSecond = 4.5
    /// What a single opponent is assumed to contribute when sizing the shovel:
    /// the most the cooldown lets anyone throw. Derived rather than guessed, so
    /// the balance is sized for the worst case that can actually happen — any
    /// opponent tapping slower simply makes the dig easier than the target.
    public static var referenceOpponentTapsPerSecond: Double { maximumThrowsPerSecond }

    public static let shovelRange = 3 ... 14

    /// Rocks one miner tap removes.
    ///
    /// Derived, not tabulated. Opposition grows linearly with the opponent count,
    /// so the shovel has to as well or the miner's advantage quietly erodes: the
    /// old `3 + k` curve demanded ~4.2 taps/s at two players but ~5.9 at seven,
    /// which is where "多个人同时丢基本上无法挖出" came from. Solving for
    /// `targetMinerTapsPerSecond` instead keeps the ask flat at roughly 4–4.5
    /// taps/s from two players to seven.
    public static func shovelSize(opponentCount: Int) -> Int {
        let debt = Double(pileTotal - successThreshold)
        let thrown = Double(max(0, opponentCount)) * referenceOpponentTapsPerSecond * duration
        let ideal = (debt + thrown) / (duration * targetMinerTapsPerSecond)
        return min(max(Int(ideal.rounded()), shovelRange.lowerBound), shovelRange.upperBound)
    }

    /// Rocks one opponent tap adds back.
    public static let rocksPerOpponentTap = 1

    /// Ceiling on the taps one 200 ms report may claim. Bounds the damage from a
    /// client that batched several windows together.
    public static let maximumTapsPerReport = 12

    /// Minimum spacing between two rocks from the *same* player.
    ///
    /// Sized a little above a comfortable tapping rate (~7 rocks a second), so
    /// ordinary play never notices it while mashing cannot bury a dig under a
    /// rate the shovel was never balanced for — `referenceOpponentTapsPerSecond`
    /// assumes 6, and nothing used to hold anyone to it.
    ///
    /// Deliberately one-sided: the miner has no cooldown at all. Digging out is
    /// meant to be the fast half of the race.
    public static let throwCooldown: TimeInterval = 0.14

    /// Rocks a player may land back-to-back after a quiet spell. Without some
    /// slack, a 200 ms report batch would be clipped by the cooldown even at a
    /// perfectly legitimate tapping rate.
    public static let throwBurstAllowance = 3.0

    /// Sustained rocks per second one player can land, after the cooldown.
    public static var maximumThrowsPerSecond: Double { 1 / throwCooldown }

    /// How hard a bot miner tries, as a multiple of the rate the dig *actually*
    /// demands of it at this table (see `MatchSessionService.requiredMinerTapRate`).
    ///
    /// An absolute taps-per-second could never work here: a dig tap is worth
    /// `shovel` rocks and a thrown rock is worth one, and both the shovel and the
    /// opposition change with who is at the table. Pinning bots to a fixed number
    /// is what made them hopeless as miners.
    public static func botDigMultiplier(_ difficulty: BotDifficulty) -> Double {
        switch difficulty {
        case .easy: return 0.90
        case .normal: return 1.15
        case .hard: return 1.45
        }
    }

    /// How fast a bot throws rocks back at somebody else's dig. Human-plausible
    /// on purpose — a bot should be felt, not unbeatable.
    public static func botRockTapsPerSecond(_ difficulty: BotDifficulty) -> Double {
        switch difficulty {
        case .easy: return 3.5
        case .normal: return 4.75
        case .hard: return 6.0
        }
    }
}
