import SwiftUI

/// The trailing-edge affordance for the quick-chat drawer.
///
/// At rest it is a bare 4 pt nub that fits inside the boards' 14 pt horizontal
/// gutter, so it costs no visible space. On entering a match it nudges out once
/// to show a speech-bubble icon and a chevron, then retracts — enough to teach
/// the swipe without parking a control on the board.
///
/// The tappable box is a constant 14 pt wide no matter what the visual is doing:
/// `contentShape` follows this view's own frame, and the visual is an `overlay`
/// that is free to spill past it without being hit-tested. That is what lets the
/// revealed tab sit over the rightmost card for a moment without stealing its tap.
struct QuickChatGrabber: View {
    /// Whether the introductory nudge still needs to play. Owned by the overlay so
    /// it survives this view being unmounted (which happens every time the drawer
    /// opens) and the hint therefore plays once per match, not after every close.
    let shouldHint: Bool
    let onHintShown: () -> Void
    let onOpen: () -> Void

    /// Drives the reveal: 0 = resting nub, 1 = fully extended tab.
    @State private var reveal: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the hit area — must stay within the boards' `.padding(.horizontal, 14)`.
    private static let hitWidth: CGFloat = 14
    private static let restingHeight: CGFloat = 36
    private static let revealedWidth: CGFloat = 28
    private static let revealedHeight: CGFloat = 52

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .frame(width: Self.hitWidth, height: 56)
                .overlay(alignment: .trailing) { visual }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("quickChat.open.accessibility"))
        .task(id: shouldHint) {
            guard shouldHint else { return }
            // Let the board settle (and any opening roulette finish) first.
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            // Claim the hint as it starts, so an interrupted retract cannot replay it.
            onHintShown()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { reveal = 1 }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { reveal = 0 }
        }
    }

    private var visual: some View {
        ZStack(alignment: .trailing) {
            tab
            nub
        }
        // Reduce Motion keeps the icon but drops the horizontal travel: the tab
        // cross-fades in place instead of being pushed out.
        .offset(x: reduceMotion ? 0 : (1 - reveal) * 6)
    }

    private var tab: some View {
        VStack(spacing: 2) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .frame(width: Self.revealedWidth, height: Self.revealedHeight)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 14,
                style: .continuous
            )
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.18), radius: 10, x: -3, y: 2)
        }
        .opacity(Double(reveal))
        .scaleEffect(x: reduceMotion ? 1 : 0.5 + 0.5 * reveal, anchor: .trailing)
    }

    /// Fades out as the tab takes over, so the two never read as two controls.
    private var nub: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 4, height: Self.restingHeight)
            .padding(.trailing, 2)
            .opacity(Double(1 - reveal))
    }
}
