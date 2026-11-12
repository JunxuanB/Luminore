import SwiftUI

/// iPad adaptation for a UI designed around a portrait phone.
///
/// - `adaptiveColumn()` keeps menus, forms and lists in a centred column instead
///   of stretching them edge to edge on a 13" screen.
/// - `PhoneCanvas` lays a game board out at phone proportions and scales the
///   result up to fill the screen. The boards use fixed point sizes tuned for a
///   phone, so simply handing them a bigger frame leaves half the screen empty.
///   When the screen is wide enough (iPad landscape) it lays the board out
///   at least 860pt wide and sets `\.isWideBoard`, which the boards use to show a second
///   column: every opponent at once (standard) or both board pages (Duel).
///
/// On an iPhone all of it is a no-op.
enum AdaptiveLayout {
    /// Widest that menus, forms and lists are allowed to get.
    static let columnWidth: CGFloat = 780
    /// Anything narrower than this is treated as a phone and left untouched.
    static let phoneWidthLimit: CGFloat = 500
    /// The logical size a board is laid out at before being scaled.
    static let designWidth: CGFloat = 430
    static let designMaxWidth: CGFloat = 500
    static let designHeight: CGFloat = 780
    /// Narrowest and widest logical width of the two-column board.
    static let wideBoardWidth: CGFloat = 860
    static let wideBoardMaxWidth: CGFloat = 1040
    /// Logical width of its side column.
    static let sideColumnWidth: CGFloat = 344
    /// The two-column board needs less height: the opponent strip (standard) or
    /// the page picker (Duel) moves out of the main column.
    static let wideDesignHeight: CGFloat = 740
    /// A small iPad in landscape is shorter than that; shrink a little rather
    /// than clip the bottom of the Duel card board.
    static let wideMinimumScale: CGFloat = 0.85
}

/// Lets a full-bleed screen (a game board) opt out of the centred column that
/// wraps the rest of the app.
@MainActor
final class AdaptiveLayoutState: ObservableObject {
    @Published var fullWidthRequests = 0
}

private struct IsWideBoardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the board has room for its two-column (iPad landscape) layout.
    var isWideBoard: Bool {
        get { self[IsWideBoardKey.self] }
        set { self[IsWideBoardKey.self] = newValue }
    }
}

private struct AdaptiveColumn: ViewModifier {
    @StateObject private var state = AdaptiveLayoutState()

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: state.fullWidthRequests > 0 ? .infinity : AdaptiveLayout.columnWidth)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .environmentObject(state)
    }
}

extension View {
    /// Centres the app in a readable column on wide screens. Apply once, at the
    /// root; `PhoneCanvas` widens it again while a board is on screen.
    func adaptiveColumn() -> some View {
        modifier(AdaptiveColumn())
    }

    /// Fills the screen with the grouped background, so a full-height screen
    /// blends into the margins `adaptiveColumn()` leaves on an iPad.
    func groupedScreenBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

struct PhoneCanvas<Content: View>: View {
    @EnvironmentObject private var layoutState: AdaptiveLayoutState
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let layout = Self.layout(for: proxy.size)
            content
                .environment(\.isWideBoard, layout.isWide)
                .environment(\.hoistsTurnBorder, layout.scale != 1 || layout.isWide)
                .frame(width: layout.logical.width, height: layout.logical.height)
                .scaleEffect(layout.scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // Drawn here, outside the scaled board, so the "your turn" glow hugs the
        // real screen edge at its normal thickness instead of being magnified
        // around a letterboxed canvas.
        .overlayPreferenceValue(TurnBorderKey.self) { state in
            TurnBorderLayer(state: state)
        }
        .onAppear { layoutState.fullWidthRequests += 1 }
        .onDisappear { layoutState.fullWidthRequests -= 1 }
    }

    struct Layout: Equatable {
        /// The size the content is laid out at, before scaling.
        var logical: CGSize
        var scale: CGFloat
        var isWide: Bool
    }

    static func layout(for size: CGSize) -> Layout {
        guard size.width > AdaptiveLayout.phoneWidthLimit, size.height > 0 else {
            return Layout(logical: size, scale: 1, isWide: false)
        }
        // Prefer the two-column layout whenever it fits at full height.
        let wideScale = max(AdaptiveLayout.wideMinimumScale, size.height / AdaptiveLayout.wideDesignHeight)
        let wideAvailable = size.width / wideScale
        if wideAvailable >= AdaptiveLayout.wideBoardWidth {
            // Use the whole width (up to a cap) so a landscape iPad has no side bands.
            let width = min(wideAvailable, AdaptiveLayout.wideBoardMaxWidth)
            return Layout(
                logical: CGSize(width: width, height: size.height / wideScale),
                scale: wideScale,
                isWide: true
            )
        }
        let scale = max(1, min(
            size.width / AdaptiveLayout.designWidth,
            size.height / AdaptiveLayout.designHeight
        ))
        let width = min(size.width / scale, AdaptiveLayout.designMaxWidth)
        return Layout(logical: CGSize(width: width, height: size.height / scale), scale: scale, isWide: false)
    }
}
