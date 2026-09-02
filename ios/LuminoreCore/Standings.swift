import Foundation

/// Mid-match standings, computed with exactly the same ordering the final
/// results screen uses.
///
/// `StandardRuleset.finishGame` used to inline this sort, which made it the only
/// definition of "名次" in the codebase. 挖矿 needs to ask "is this seat in last
/// place?" every turn, so the logic lives here and `finishGame` calls it — two
/// copies would inevitably drift.
public enum Standings {
    /// Orders players the way the results screen does: prestige descending,
    /// then fewer development cards first, then nickname. Only prestige decides
    /// a *rank*; the rest are display tie-breakers.
    public static func sorted(_ players: [PlayerState]) -> [PlayerState] {
        players.sorted {
            if $0.prestige != $1.prestige { return $0.prestige > $1.prestige }
            if $0.developmentCardCount != $1.developmentCardCount {
                return $0.developmentCardCount < $1.developmentCardCount
            }
            return $0.nickname.localizedStandardCompare($1.nickname) == .orderedAscending
        }
    }

    /// Dense-by-prestige ranks, 1-based. Players on equal prestige share a rank,
    /// and the next distinct prestige skips ahead (1, 2, 2, 4).
    public static func ranks(_ players: [PlayerState]) -> [UUID: Int] {
        ranks(sorted: sorted(players))
    }

    /// Ranks for a roster already in `sorted(_:)` order — lets a caller that
    /// needs both the order and the ranks pay for only one sort.
    public static func ranks(sorted players: [PlayerState]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var previousPrestige: Int?
        var rank = 0
        for (offset, player) in players.enumerated() {
            if previousPrestige != player.prestige { rank = offset + 1 }
            previousPrestige = player.prestige
            result[player.id] = rank
        }
        return result
    }
}

public extension GameState {
    /// True when `playerID` sits alone-or-tied at the bottom of the table.
    ///
    /// Returns `false` while every seat is level (the usual state for the first
    /// few turns): with a single rank there is no "last place" to be in, and
    /// treating everyone as last would make 挖矿 fire constantly at the opening.
    func isInLastPlace(_ playerID: UUID) -> Bool {
        let ranks = Standings.ranks(players)
        guard let rank = ranks[playerID], let worst = ranks.values.max(), worst > 1 else { return false }
        return rank == worst
    }
}
