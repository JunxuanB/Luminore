import Foundation

/// Host-authored setup overrides for a standard (2–7 player) match.
///
/// `GameConfiguration.customStandardRules == nil` means "自动": every value is
/// derived from the seated player count exactly as the printed rules prescribe.
/// Opening the custom panel materialises the struct from those same defaults, so
/// enabling it without touching a stepper changes nothing about the setup.
///
/// The struct rides inside `GameConfiguration`, which is already part of both
/// `RoomSnapshot` (lobby + configuration sync) and `ClientGameSnapshot` (in-match
/// sync), so guests on every transport receive the custom rules with no extra
/// plumbing — and a save file replays with the rules it was created under.
public struct StandardCustomRules: Codable, Equatable, Sendable {
    /// Face-up development cards per tier. Not customisable: the board grid is
    /// laid out around it.
    public static let marketRowSize = 4

    public static let defaultTokenLimit = 10
    public static let defaultReserveLimit = 3

    public static let gemRange = 1 ... 20
    public static let goldRange = 0 ... 20
    public static let nobleRange = 0 ... 10
    public static let tokenLimitRange = 8 ... 15
    public static let reserveLimitRange = 1 ... 5

    private static let catalogCounts: [Int: Int] = StandardCatalog.cards
        .reduce(into: [:]) { counts, card in counts[card.tier, default: 0] += 1 }

    /// How many cards of `tier` the printed catalog holds — the ceiling for
    /// `deckCount(tier:)`, since custom decks are a random subset of the catalog.
    public static func catalogCount(tier: Int) -> Int { catalogCounts[tier] ?? 0 }

    /// A deck never drops below one full market row, so every tier still opens
    /// with four face-up cards.
    public static func deckRange(tier: Int) -> ClosedRange<Int> {
        marketRowSize ... max(marketRowSize, catalogCount(tier: tier))
    }

    /// Tokens of each purchasable colour in the bank.
    public var gemCount: Int
    /// Gold (joker) tokens in the bank. At `0` no card can ever be reserved.
    public var goldCount: Int
    /// Cards of each tier that take part in the match, drawn at random from the
    /// catalog. Includes the four that start face up.
    public var tier1DeckCount: Int
    public var tier2DeckCount: Int
    public var tier3DeckCount: Int
    /// Noble tiles on the table.
    public var nobleCount: Int
    /// Tokens a player may hold at the end of their turn.
    public var tokenLimit: Int
    /// Cards a player may hold in reserve.
    public var reserveLimit: Int

    public init(
        gemCount: Int,
        goldCount: Int,
        tier1DeckCount: Int,
        tier2DeckCount: Int,
        tier3DeckCount: Int,
        nobleCount: Int,
        tokenLimit: Int = defaultTokenLimit,
        reserveLimit: Int = defaultReserveLimit
    ) {
        self.gemCount = Self.gemRange.clamping(gemCount)
        self.goldCount = Self.goldRange.clamping(goldCount)
        self.tier1DeckCount = Self.deckRange(tier: 1).clamping(tier1DeckCount)
        self.tier2DeckCount = Self.deckRange(tier: 2).clamping(tier2DeckCount)
        self.tier3DeckCount = Self.deckRange(tier: 3).clamping(tier3DeckCount)
        self.nobleCount = Self.nobleRange.clamping(nobleCount)
        self.tokenLimit = Self.tokenLimitRange.clamping(tokenLimit)
        self.reserveLimit = Self.reserveLimitRange.clamping(reserveLimit)
    }

    /// Everything an unmodified match of `playerCount` players would use.
    public static func standard(playerCount: Int) -> StandardCustomRules {
        let colored: Int
        let gold: Int
        switch playerCount {
        case 2: (colored, gold) = (4, 5)
        case 3: (colored, gold) = (5, 5)
        case 4: (colored, gold) = (7, 5)
        case 5: (colored, gold) = (8, 6)
        case 6: (colored, gold) = (9, 7)
        default: (colored, gold) = (10, 8)
        }
        return StandardCustomRules(
            gemCount: colored,
            goldCount: gold,
            tier1DeckCount: catalogCount(tier: 1),
            tier2DeckCount: catalogCount(tier: 2),
            tier3DeckCount: catalogCount(tier: 3),
            nobleCount: playerCount + 1,
            tokenLimit: defaultTokenLimit,
            reserveLimit: defaultReserveLimit
        )
    }

    public func deckCount(tier: Int) -> Int {
        switch tier {
        case 1: tier1DeckCount
        case 2: tier2DeckCount
        default: tier3DeckCount
        }
    }

    public mutating func setDeckCount(_ count: Int, tier: Int) {
        switch tier {
        case 1: tier1DeckCount = Self.deckRange(tier: 1).clamping(count)
        case 2: tier2DeckCount = Self.deckRange(tier: 2).clamping(count)
        default: tier3DeckCount = Self.deckRange(tier: 3).clamping(count)
        }
    }

    /// Re-runs every value through the initializer's clamps. Call after mutating
    /// fields directly (e.g. from a SwiftUI binding) before handing the struct on.
    public var clamped: StandardCustomRules {
        StandardCustomRules(
            gemCount: gemCount,
            goldCount: goldCount,
            tier1DeckCount: tier1DeckCount,
            tier2DeckCount: tier2DeckCount,
            tier3DeckCount: tier3DeckCount,
            nobleCount: nobleCount,
            tokenLimit: tokenLimit,
            reserveLimit: reserveLimit
        )
    }

    public var initialBank: [GemColor: Int] {
        var bank = Dictionary(uniqueKeysWithValues: GemColor.purchasableColors.map { ($0, gemCount) })
        bank[.gold] = goldCount
        return bank
    }

    /// `true` when nothing differs from an untouched match of `playerCount`.
    public func matchesDefaults(playerCount: Int) -> Bool {
        self == Self.standard(playerCount: playerCount)
    }

    private enum CodingKeys: String, CodingKey {
        case gemCount, goldCount
        case tier1DeckCount, tier2DeckCount, tier3DeckCount
        case nobleCount, tokenLimit, reserveLimit
    }

    /// Decoded leniently so a peer on an older or newer build still yields a
    /// playable setup: every field falls back to its printed-rules default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            gemCount: try container.decodeIfPresent(Int.self, forKey: .gemCount) ?? 7,
            goldCount: try container.decodeIfPresent(Int.self, forKey: .goldCount) ?? 5,
            tier1DeckCount: try container.decodeIfPresent(Int.self, forKey: .tier1DeckCount)
                ?? Self.catalogCount(tier: 1),
            tier2DeckCount: try container.decodeIfPresent(Int.self, forKey: .tier2DeckCount)
                ?? Self.catalogCount(tier: 2),
            tier3DeckCount: try container.decodeIfPresent(Int.self, forKey: .tier3DeckCount)
                ?? Self.catalogCount(tier: 3),
            nobleCount: try container.decodeIfPresent(Int.self, forKey: .nobleCount) ?? 5,
            tokenLimit: try container.decodeIfPresent(Int.self, forKey: .tokenLimit) ?? Self.defaultTokenLimit,
            reserveLimit: try container.decodeIfPresent(Int.self, forKey: .reserveLimit) ?? Self.defaultReserveLimit
        )
    }
}

private extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
