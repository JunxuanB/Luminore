import SwiftUI

/// What the screen-edge turn indicator should currently show.
struct TurnBorderState: Equatable {
    var isLocalTurn = false
    /// Set while the grace-period flash is enabled for this turn.
    var graceDeadline: Date?
}

struct TurnBorderKey: PreferenceKey {
    static let defaultValue = TurnBorderState()

    static func reduce(value: inout TurnBorderState, nextValue: () -> TurnBorderState) {
        let next = nextValue()
        if next.isLocalTurn { value = next }
    }
}

private struct HoistsTurnBorderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when an ancestor (`PhoneCanvas` on iPad) draws the turn border
    /// itself, so the board must only report its state.
    var hoistsTurnBorder: Bool {
        get { self[HoistsTurnBorderKey.self] }
        set { self[HoistsTurnBorderKey.self] = newValue }
    }
}

struct TurnBorderLayer: View {
    let state: TurnBorderState

    /// Debug demo scenes (screenshots) never show the glow: it would be baked
    /// into every captured image.
    private var isSuppressed: Bool {
        #if DEBUG
        DemoScene.current != nil
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            if state.isLocalTurn, !isSuppressed {
                CurrentTurnBorder()
                if let deadline = state.graceDeadline {
                    GracePeriodBorder(deadline: deadline)
                }
            }
        }
    }
}

private struct TurnBorderModifier: ViewModifier {
    @Environment(\.hoistsTurnBorder) private var hoists
    let state: TurnBorderState

    func body(content: Content) -> some View {
        if hoists {
            content.preference(key: TurnBorderKey.self, value: state)
        } else {
            content.overlay { TurnBorderLayer(state: state) }
        }
    }
}

extension View {
    /// The animated "it is your turn" screen border, plus the red grace-period
    /// flash. On a phone it is an overlay on the board; on iPad the board is
    /// scaled, so the border is handed up to be drawn around the real screen.
    func turnBorder(isLocalTurn: Bool, graceDeadline: Date?) -> some View {
        modifier(TurnBorderModifier(state: TurnBorderState(
            isLocalTurn: isLocalTurn,
            graceDeadline: graceDeadline
        )))
    }
}
