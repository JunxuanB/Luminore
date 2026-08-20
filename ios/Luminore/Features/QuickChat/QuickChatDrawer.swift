import LuminoreCore
import SwiftUI

/// The frosted panel that slides in from the trailing edge. Purely presentational:
/// it reports taps and knows nothing about the session.
struct QuickChatDrawer: View {
    /// 0 = fully closed, 1 = fully open. Drives the staggered entry so the panel
    /// unfurls with the finger rather than slabbing in at the end.
    let progress: CGFloat
    /// When the local send cooldown lifts, or `nil` if nothing has been sent yet.
    let cooldownEndsAt: Date?
    let onSelect: (QuickChatPhrase) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Seed for the overlay's drag maths on the very first frame, before the real
    /// size arrives through `QuickChatDrawerSizeKey`. NOT a layout constraint —
    /// forcing a minimum width here left a slab of dead space on the leading side
    /// in Chinese, where the phrases are far shorter than the English ones.
    static let estimatedSize = CGSize(width: 168, height: 220)

    var body: some View {
        Group {
            if let cooldownEndsAt {
                // The ticker only exists once something has been sent, and only while
                // the drawer itself is on screen. Same approach as `TurnProgressBar`.
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    stack(isCoolingDown: cooldownEndsAt > context.date)
                }
            } else {
                stack(isCoolingDown: false)
            }
        }
        // Hugs its content, so the panel is narrow in Chinese and wide in English
        // rather than being padded out to a one-size-fits-both constant.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 18)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .background(panelBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, x: -6, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("quickChat.title"))
    }

    private func stack(isCoolingDown: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(Array(QuickChatPhrase.selectable.enumerated()), id: \.element) { index, phrase in
                phraseButton(phrase, isCoolingDown: isCoolingDown)
                    .opacity(Double(entry(index)))
                    .offset(x: (1 - entry(index)) * 34)
                    .scaleEffect(0.94 + 0.06 * entry(index), anchor: .trailing)
            }

            if isCoolingDown {
                Text("quickChat.cooldown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isCoolingDown)
    }

    /// Each capsule trails the one above it, so the stack cascades open.
    private func entry(_ index: Int) -> CGFloat {
        guard !reduceMotion else { return progress }
        let start = CGFloat(index) * 0.10
        return min(1, max(0, (progress - start) / (1 - start)))
    }

    private var panelBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 26,
            bottomLeadingRadius: 26,
            style: .continuous
        )
        .fill(reduceTransparency
              ? AnyShapeStyle(Color(.secondarySystemBackground))
              : AnyShapeStyle(.regularMaterial))
    }

    private func phraseButton(_ phrase: QuickChatPhrase, isCoolingDown: Bool) -> some View {
        Button {
            onSelect(phrase)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: phrase.iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(phrase.tint)
                    .frame(width: 20)
                Text(phrase.localizedKey)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isCoolingDown)
        .opacity(isCoolingDown ? 0.45 : 1)
        .accessibilityHint(Text("quickChat.send.hint"))
    }
}
