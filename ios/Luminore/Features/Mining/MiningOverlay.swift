import LuminoreCore
import SwiftUI

extension View {
    /// Attaches the 挖矿 overlay: the screen-edge countdown ring plus the rock
    /// pile everyone taps.
    ///
    /// Apply it after `.quickChatOverlay` and before the roulette / pause covers
    /// in `GameBoardView`, so those hide it without any `zIndex` juggling. A
    /// single `.modifier(...)` keeps the view's chain within the type-checker
    /// budget that file has already run up against.
    func miningOverlay(session: MatchSessionService, isEnabled: Bool = true) -> some View {
        modifier(MiningOverlayModifier(session: session, pile: session.miningPile, isEnabled: isEnabled))
    }
}

private struct MiningOverlayModifier: ViewModifier {
    @ObservedObject var session: MatchSessionService
    /// Observed separately from `session` so the fast-changing rock count only
    /// invalidates this overlay, not the whole board. See `MiningPileModel`.
    @ObservedObject var pile: MiningPileModel
    let isEnabled: Bool

    private var dig: MiningSnapshot? {
        // A pause outranks a dig; the host settles it, but a client can briefly
        // hold both while snapshots cross, and the pause cover should win.
        guard isEnabled, session.matchPause == nil else { return nil }
        return session.mining
    }

    func body(content: Content) -> some View {
        content
            // Stage first, ring second: the ring must sit *above* the stage's
            // full-screen material, or the scrim would wash the colours out.
            .overlay { stage }
            .overlay { ring }
            .animation(.easeInOut(duration: 0.25), value: session.mining?.id)
            .animation(.easeInOut(duration: 0.25), value: session.mining?.phase)
    }

    @ViewBuilder private var ring: some View {
        if let dig {
            MiningCountdownRing(
                startedAt: dig.startedAt,
                endsAt: dig.endsAt,
                isFadingOut: dig.phase != .digging
            )
        }
    }

    @ViewBuilder private var stage: some View {
        if let dig {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                MiningStageView(
                    session: dig,
                    remaining: pile.remaining,
                    isMiner: dig.minerID == session.localID,
                    isParticipant: session.canTapMiningPile,
                    onTap: { session.reportMiningTap() }
                )
            }
            .transition(.opacity)
            .accessibilityAddTraits(.isModal)
        }
    }
}
