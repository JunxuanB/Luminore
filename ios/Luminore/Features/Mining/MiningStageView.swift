import LuminoreCore
import SwiftUI

/// The centre panel of a dig: who is digging, what to do, the pile itself, and
/// the win/lose reveal.
///
/// The reveal is self-contained rather than routed through `GameAnchorKey`
/// flights: the overlay dims the whole board, so a token flying to the bank or
/// to a player's stack would land somewhere nobody can see.
struct MiningStageView: View {
    let session: MiningSnapshot
    let remaining: Int
    let isMiner: Bool
    let isParticipant: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDigging: Bool { session.phase == .digging }

    /// Explicit `LocalizedStringKey`s: an inline ternary of string literals can
    /// silently resolve to `String` and render the raw key.
    private var roleKey: LocalizedStringKey {
        isMiner ? "mining.role.miner" : "mining.role.other"
    }

    private var discardKey: LocalizedStringKey {
        isMiner ? "mining.discard.prompt" : "mining.discard.waiting"
    }

    private var succeeded: Bool { session.outcome == .success }

    var body: some View {
        VStack(spacing: 18) {
            header
            MiningPileView(
                gem: session.gem,
                remaining: succeeded ? 0 : remaining,
                total: session.pileTotal,
                isMiner: isMiner,
                isInteractive: isDigging && isParticipant,
                onTap: onTap
            )
            .overlay { if !isDigging, succeeded, !reduceMotion { MiningSparkleBurst() } }
            footer
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(roleKey)
                .font(.title2.weight(.bold))
            if isDigging {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var subtitle: String {
        isMiner
            ? AppLanguage.string("mining.hint.miner")
            : AppLanguage.string("mining.hint.other", session.minerNickname)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch session.phase {
        case .digging:
            progressBar
        case .resolved:
            resultBanner
        case .awaitingDiscard:
            VStack(spacing: 6) {
                resultBanner
                Text(discardKey)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shows how close the pile is to the win line, so both sides can read the
    /// race at a glance instead of guessing from the heap.
    private var progressBar: some View {
        let cleared = Double(session.pileTotal - remaining) / Double(max(1, session.pileTotal))
        let target = Double(session.pileTotal - session.successThreshold) / Double(max(1, session.pileTotal))
        return VStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(cleared >= target ? Color.green : Color.orange)
                        .frame(width: proxy.size.width * cleared)
                    // The win line: everything to its right is a miner victory.
                    Rectangle()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: proxy.size.width * target)
                }
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.18), value: remaining)

            Text(AppLanguage.string("mining.progress", "\(Int((cleared * 100).rounded()))%"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 280)
    }

    private var resultBanner: some View {
        Label {
            Text(resultText)
        } icon: {
            Image(systemName: succeeded ? "sparkles" : "xmark.circle")
        }
        .font(.headline)
        .foregroundStyle(succeeded ? Color.green : Color.secondary)
        .transition(.scale.combined(with: .opacity))
    }

    private var resultText: String {
        succeeded
            ? AppLanguage.string("mining.result.success", session.minerNickname, session.gem.localizedName)
            : AppLanguage.string("mining.result.failure", session.minerNickname)
    }
}

/// A short radial pop for the moment the token comes free.
private struct MiningSparkleBurst: View {
    @State private var expanded = false

    private static let count = 12

    var body: some View {
        ZStack {
            ForEach(0 ..< Self.count, id: \.self) { index in
                let angle = Double(index) / Double(Self.count) * 2 * .pi
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 1.00, green: 0.82, blue: 0.45))
                    .offset(
                        x: CGFloat(cos(angle)) * (expanded ? 100 : 16),
                        y: CGFloat(sin(angle)) * (expanded ? 100 : 16)
                    )
                    .opacity(expanded ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .task {
            withAnimation(.easeOut(duration: 0.75)) { expanded = true }
        }
    }
}
