import LuminoreCore
import SwiftUI

/// Host-authored setup overrides for 普通模式, collapsed by default.
///
/// The disclosure itself stays tappable for guests so they can inspect what the
/// host picked; only the controls inside are host-gated. Every edit routes
/// through `onUpdate` — i.e. `MatchSessionService.updateConfiguration` — which is
/// the same path the built-in rules already take, so the change reaches LAN,
/// internet and nearby peers alike in the next `RoomSnapshot`, and rides into the
/// match inside `ClientGameSnapshot.configuration`.
struct CustomStandardRulesSection: View {
    let configuration: GameConfiguration
    /// Seats currently at the table; decides what "自动" resolves to.
    let playerCount: Int
    let isHost: Bool
    let onUpdate: (GameConfiguration) -> Void

    @State private var isExpanded = false

    private var isCustom: Bool { configuration.customStandardRules != nil }

    /// What the match will actually use — the host's overrides, or the printed
    /// rules scaled to `playerCount`.
    private var rules: StandardCustomRules {
        configuration.resolvedStandardRules(playerCount: playerCount)
    }

    /// Bound to an explicit `LocalizedStringKey` rather than an inline ternary,
    /// which can silently resolve to a plain `String` and render the raw key.
    private var stateLabel: LocalizedStringKey {
        isCustom ? "config.custom.state.on" : "config.custom.state.off"
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                Toggle("config.custom.enabled", isOn: enabledBinding)
                    .disabled(!isHost)

                if isCustom {
                    stepper("config.custom.gemCount", \.gemCount, in: StandardCustomRules.gemRange)
                    stepper("config.custom.goldCount", \.goldCount, in: StandardCustomRules.goldRange)
                    stepper("config.custom.deck.tier3", \.tier3DeckCount, in: StandardCustomRules.deckRange(tier: 3))
                    stepper("config.custom.deck.tier2", \.tier2DeckCount, in: StandardCustomRules.deckRange(tier: 2))
                    stepper("config.custom.deck.tier1", \.tier1DeckCount, in: StandardCustomRules.deckRange(tier: 1))
                    stepper("config.custom.nobleCount", \.nobleCount, in: StandardCustomRules.nobleRange)
                    stepper("config.custom.tokenLimit", \.tokenLimit, in: StandardCustomRules.tokenLimitRange)
                    stepper("config.custom.reserveLimit", \.reserveLimit, in: StandardCustomRules.reserveLimitRange)

                    Button("config.custom.reset") {
                        apply(.standard(playerCount: playerCount))
                    }
                    .disabled(!isHost || rules.matchesDefaults(playerCount: playerCount))
                } else {
                    Text("config.custom.auto.description")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } label: {
                LabeledContent("config.custom.title") { Text(stateLabel) }
            }
        } footer: {
            Text("config.custom.footer")
        }
    }

    private func stepper(
        _ title: LocalizedStringKey,
        _ keyPath: WritableKeyPath<StandardCustomRules, Int>,
        in range: ClosedRange<Int>
    ) -> some View {
        Stepper(value: binding(keyPath), in: range) {
            LabeledContent(title, value: "\(rules[keyPath: keyPath])")
        }
        .disabled(!isHost)
    }

    private func binding(_ keyPath: WritableKeyPath<StandardCustomRules, Int>) -> Binding<Int> {
        Binding(
            get: { rules[keyPath: keyPath] },
            set: { newValue in
                var updated = rules
                updated[keyPath: keyPath] = newValue
                apply(updated)
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isCustom },
            // Turning it on seeds the printed rules for the current table, so the
            // very act of opening the panel never changes the setup.
            set: { enabled in
                if enabled {
                    apply(.standard(playerCount: playerCount))
                } else {
                    var configuration = self.configuration
                    configuration.customStandardRules = nil
                    onUpdate(configuration)
                }
            }
        )
    }

    private func apply(_ custom: StandardCustomRules) {
        var configuration = self.configuration
        configuration.customStandardRules = custom.clamped
        onUpdate(configuration)
    }
}
