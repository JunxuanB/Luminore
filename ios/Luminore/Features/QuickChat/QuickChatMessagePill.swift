import SwiftUI

/// The bottom-left bubble showing the newest quick-chat line.
///
/// The gradient-transparency look comes from masking the *background plate* — not
/// the label — so the plate dissolves into the board towards its trailing edge
/// while the text stays fully opaque and legible.
struct QuickChatMessagePill: View {
    let event: QuickChatEvent

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: event.phrase.iconName)
                .font(.footnote.weight(.bold))
                .foregroundStyle(event.phrase.tint)
            Text("quickChat.message \(event.authorName) \(event.phrase.localizedName)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 13)
        .padding(.trailing, 34) // room for the plate's fade-out tail
        .padding(.vertical, 9)
        .background { plate }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLanguage.string(
            "quickChat.message.accessibility %@ %@",
            event.authorName,
            event.phrase.localizedName
        )))
    }

    private var plate: some View {
        ZStack {
            Capsule().fill(reduceTransparency
                           ? AnyShapeStyle(Color(.secondarySystemBackground))
                           : AnyShapeStyle(.ultraThinMaterial))
            // A whisper of the phrase's colour, strongest at the leading edge.
            Capsule().fill(LinearGradient(
                colors: [event.phrase.tint.opacity(0.26), event.phrase.tint.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .mask(LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.66),
                .init(color: .black.opacity(0.15), location: 0.90),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        ))
        .shadow(color: .black.opacity(0.13), radius: 8, y: 3)
    }
}
