import LuminoreCore
import SwiftUI

/// iPad landscape: the left column of the standard board. Every opponent is
/// visible at once, and the local player's reserved cards sit below them, one
/// tap from a purchase, instead of behind a sheet.
struct StandardWideSidebar: View {
    let snapshot: ClientGameSnapshot
    let opponents: [PublicPlayerSnapshot]
    let player: PublicPlayerSnapshot
    let isLocalTurn: Bool
    let onOpenOpponentReserved: (PublicPlayerSnapshot) -> Void
    let onSelectReserved: (DevelopmentCard) -> Void

    var body: some View {
        VStack(spacing: 12) {
            opponentList
            ReservedCardsPanel(
                cards: snapshot.localReservedCards,
                limit: snapshot.configuration.standardReserveLimit,
                player: player,
                isLocalTurn: isLocalTurn,
                showsHighlight: snapshot.configuration.affordableCardHighlightEnabled,
                onSelect: onSelectReserved
            )
        }
        .padding(14)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder private var opponentList: some View {
        // Up to six opponents: scroll only when they cannot all fit.
        ViewThatFits(in: .vertical) {
            cards.frame(maxHeight: .infinity)
            ScrollView { cards }.scrollBounceBehavior(.basedOnSize)
        }
    }

    private var cards: some View {
        VStack(spacing: 10) {
            ForEach(opponents) { opponent in
                OpponentCard(
                    roomy: true,
                    fillsHeight: true,
                    opponent: opponent,
                    isCurrent: opponent.id == snapshot.currentPlayerID,
                    reserveLimit: snapshot.configuration.standardReserveLimit
                )
                .contentShape(Rectangle())
                .onTapGesture { onOpenOpponentReserved(opponent) }
                .accessibilityHint(Text("game.opponent.reserved.hint"))
            }
        }
    }
}

struct ReservedCardsPanel: View {
    let cards: [DevelopmentCard]
    let limit: Int
    let player: PublicPlayerSnapshot
    let isLocalTurn: Bool
    let showsHighlight: Bool
    let onSelect: (DevelopmentCard) -> Void

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("game.reserved", systemImage: "tray.full")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(cards.count) / \(limit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0 ..< max(limit, cards.count), id: \.self) { index in
                    if index < cards.count {
                        let card = cards[index]
                        Button { onSelect(card) } label: {
                            DevelopmentCardView(
                                card: card,
                                compactHeight: 116,
                                isPurchasable: isLocalTurn && canPurchase(card, player: player),
                                showsPurchaseHighlight: showsHighlight
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(height: 118)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}
