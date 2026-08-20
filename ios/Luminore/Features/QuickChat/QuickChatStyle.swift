import LuminoreCore
import SwiftUI

/// Presentation for the fixed quick-chat phrases. Mirrors the `DuelTokenColor`
/// idiom in `DuelGameStyles.swift`: a `LocalizedStringKey` for views, and a
/// resolved `String` for interpolating into other localized strings.
extension QuickChatPhrase {
    var iconName: String {
        switch self {
        case .hurryUp: "hare.fill"
        case .whereAreMyCards: "rectangle.on.rectangle.angled"
        case .cry: "drop.fill"
        case .cheer: "hands.clap.fill"
        case .unrecognized: "bubble.left.fill"
        }
    }

    var tint: Color {
        switch self {
        case .hurryUp: .orange
        case .whereAreMyCards: .accentColor
        case .cry: .cyan
        case .cheer: .yellow
        case .unrecognized: .secondary
        }
    }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .hurryUp: "quickChat.phrase.hurryUp"
        case .whereAreMyCards: "quickChat.phrase.whereAreMyCards"
        case .cry: "quickChat.phrase.cry"
        case .cheer: "quickChat.phrase.cheer"
        case .unrecognized: "quickChat.phrase.unrecognized"
        }
    }

    /// Resolved phrase text, for interpolating into the message pill and
    /// accessibility labels. Goes through `AppLanguage` so it obeys the in-app
    /// language setting rather than the system one.
    var localizedName: String {
        switch self {
        case .hurryUp: AppLanguage.string("quickChat.phrase.hurryUp")
        case .whereAreMyCards: AppLanguage.string("quickChat.phrase.whereAreMyCards")
        case .cry: AppLanguage.string("quickChat.phrase.cry")
        case .cheer: AppLanguage.string("quickChat.phrase.cheer")
        case .unrecognized: AppLanguage.string("quickChat.phrase.unrecognized")
        }
    }
}
