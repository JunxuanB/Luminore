import Foundation

/// A fixed quick-chat phrase.
///
/// Sent as a token rather than as text so every receiver renders it in *their
/// own* app language: a player on a Chinese UI tapping 「快一点」 shows up as
/// "Hurry up!" on an English-UI peer.
public enum QuickChatPhrase: String, Codable, CaseIterable, Sendable {
    case hurryUp
    case whereAreMyCards
    case cry
    case cheer
    /// A phrase minted by a newer build. This build never sends it; it decodes to
    /// this case so an older client silently drops the bubble instead of failing
    /// the whole frame.
    case unrecognized

    /// The phrases this build offers in the drawer, in display order.
    public static let selectable: [QuickChatPhrase] = [.hurryUp, .whereAreMyCards, .cry, .cheer]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // `.unrecognized` is deliberately not reachable by raw value: a peer that
        // literally sends "unrecognized" is treated the same as any unknown token.
        self = QuickChatPhrase(rawValue: raw).flatMap { $0 == .unrecognized ? nil : $0 } ?? .unrecognized
    }
}

/// A host-relayed, presentation-only chat bubble. It never touches authoritative
/// game state.
///
/// `authorID` rides in the payload because `MatchSessionService.send(_:to:)`
/// always stamps the envelope with the *local* participant: when the host relays
/// another player's phrase, `WireEnvelope.senderID` is the host's, not the
/// author's. Names are never sent — receivers resolve them from their own roster.
public struct QuickChatMessage: Identifiable, Codable, Equatable, Sendable {
    /// Stable across the relay hop so receivers can key a fade timer on it; two
    /// identical phrases in a row therefore still retrigger the animation.
    public let id: UUID
    public let authorID: UUID
    public let phrase: QuickChatPhrase
    public let sentAt: Date

    public init(
        id: UUID = UUID(),
        authorID: UUID,
        phrase: QuickChatPhrase,
        sentAt: Date = Date()
    ) {
        self.id = id
        self.authorID = authorID
        self.phrase = phrase
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case authorID
        case phrase
        case sentAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            authorID: try container.decode(UUID.self, forKey: .authorID),
            phrase: try container.decode(QuickChatPhrase.self, forKey: .phrase),
            sentAt: try container.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
        )
    }
}
