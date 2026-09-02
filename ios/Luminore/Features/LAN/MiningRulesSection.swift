import LuminoreCore
import SwiftUI

/// Host settings for the 挖矿 house rule, 普通模式 only.
///
/// Mirrors `CustomStandardRulesSection`: guests can read the section but only the
/// host can change it, and every edit routes through `onUpdate` — i.e.
/// `MatchSessionService.updateConfiguration` — so it reaches LAN, internet and
/// nearby peers in the next `RoomSnapshot` and rides into the match inside
/// `ClientGameSnapshot.configuration`.
struct MiningRulesSection: View {
    let configuration: GameConfiguration
    let isHost: Bool
    let onUpdate: (GameConfiguration) -> Void

    private var rules: MiningRules { configuration.mining }

    /// Bound to an explicit `LocalizedStringKey`: an inline ternary of string
    /// literals can silently resolve to `String` and render the raw key.
    private var footerKey: LocalizedStringKey {
        rules.isEnabled ? "config.mining.footer.on" : "config.mining.footer.off"
    }

    var body: some View {
        Section {
            Toggle("config.mining.enabled", isOn: enabledBinding)
                .disabled(!isHost)

            if rules.isEnabled {
                chanceSlider("config.mining.lastPlaceChance", \.lastPlaceChance)
                chanceSlider("config.mining.sameColorChance", \.sameColorChance)
            }
        } header: {
            Text("config.mining.title")
        } footer: {
            Text(footerKey)
        }
    }

    private func chanceSlider(
        _ title: LocalizedStringKey,
        _ keyPath: WritableKeyPath<MiningRules, Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(verbatim: "\(rules[keyPath: keyPath])%")
                    .monospacedDigit()
            }
            Slider(
                value: doubleBinding(keyPath),
                in: Double(MiningRules.chanceRange.lowerBound) ... Double(MiningRules.chanceRange.upperBound),
                step: 5
            )
            .disabled(!isHost)
        }
    }

    /// `Slider` needs a `Double`; the rule itself stays an `Int` percentage so it
    /// round-trips over the wire without float drift.
    private func doubleBinding(_ keyPath: WritableKeyPath<MiningRules, Int>) -> Binding<Double> {
        Binding(
            get: { Double(rules[keyPath: keyPath]) },
            set: { newValue in
                var updated = rules
                updated[keyPath: keyPath] = Int(newValue.rounded())
                apply(updated)
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rules.isEnabled },
            set: { enabled in
                var updated = rules
                updated.isEnabled = enabled
                apply(updated)
            }
        )
    }

    private func apply(_ mining: MiningRules) {
        var configuration = self.configuration
        // Re-run the memberwise init so the percentages are clamped on the way in.
        configuration.mining = MiningRules(
            isEnabled: mining.isEnabled,
            lastPlaceChance: mining.lastPlaceChance,
            sameColorChance: mining.sameColorChance
        )
        onUpdate(configuration)
    }
}
