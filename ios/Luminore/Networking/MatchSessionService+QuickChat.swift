import Foundation
import LuminoreCore

/// A quick-chat bubble ready to render.
///
/// The author's display name is resolved once, at arrival, from the local roster
/// — so a player who leaves mid-fade still shows correctly, and a client can
/// never inject a fake nickname.
struct QuickChatEvent: Identifiable, Equatable {
    let id: UUID
    let authorID: UUID
    let authorName: String
    let phrase: QuickChatPhrase
    let isLocalAuthor: Bool
}

/// Quick chat rides the same "purely presentational broadcast" path as
/// `.gameAnimation`: it is relayed by the host but never touches authoritative
/// state, so it is safe to send at any point during a match.
///
/// Anti-spam is **deliberately local only** — a spammer throttles nobody but
/// themselves. This is a politeness nudge, not enforcement; please don't "fix" it
/// by adding host-side rate limiting.
extension MatchSessionService {
    /// Minimum gap between two sends.
    static let quickChatMinimumInterval: TimeInterval = 2
    /// Sends within `quickChatBurstWindow` that trip the longer lockout.
    static let quickChatBurstLimit = 4
    static let quickChatBurstWindow: TimeInterval = 12
    static let quickChatBurstLockout: TimeInterval = 8

    var canSendQuickChat: Bool {
        guard phase == .game else { return false }
        guard let until = quickChatCooldownEndsAt else { return true }
        return Date() >= until
    }

    /// True when at least one *other* human occupies a seat. Solo-vs-bots and the
    /// tutorial have nobody to talk to, so the whole feature stays hidden there.
    ///
    /// Deliberately not gated on `isConnected`: someone who dropped may come back,
    /// and an entry point that flickers away on every blip is worse than one that
    /// stays put.
    var hasQuickChatAudience: Bool {
        game?.players.contains { $0.id != localID && $0.kind == .human } == true
    }

    func sendQuickChat(_ phrase: QuickChatPhrase) {
        guard phase == .game, phrase != .unrecognized, canSendQuickChat else { return }

        let now = Date()
        quickChatSendTimes.append(now)
        quickChatSendTimes.removeAll { now.timeIntervalSince($0) > Self.quickChatBurstWindow }
        let overBurst = quickChatSendTimes.count >= Self.quickChatBurstLimit
        quickChatCooldownEndsAt = now.addingTimeInterval(
            overBurst ? Self.quickChatBurstLockout : Self.quickChatMinimumInterval
        )

        let message = QuickChatMessage(authorID: localID, phrase: phrase)
        // Echo locally first: the bubble must appear the instant the player taps,
        // with no round trip — even on the loopback transport, or while the relay
        // is briefly unavailable.
        presentQuickChat(message)
        if isHost {
            // The host has no peer entry for itself, so a plain broadcast reaches
            // every client and nobody twice.
            broadcast(.quickChat(message))
        } else {
            sendToHost(.quickChat(message))
        }
    }

    /// Host: authenticate the author, show it locally, then fan out to everyone
    /// except the author — who already echoed it.
    func receiveQuickChatAsHost(
        _ message: QuickChatMessage,
        from peer: TransportPeerID,
        senderID: UUID
    ) {
        // Same anti-impersonation guard as `.action`, plus a payload-vs-envelope
        // identity check so a client cannot attribute a phrase to another seat.
        guard peerParticipants[peer] == senderID, message.authorID == senderID else { return }
        guard phase == .game else { return }
        presentQuickChat(message)
        for (participantID, target) in participantPeers where participantID != message.authorID {
            send(.quickChat(message), to: target)
        }
    }

    func presentQuickChat(_ message: QuickChatMessage) {
        // A phrase from a newer build has nothing to render.
        guard message.phrase != .unrecognized else { return }
        quickChatEvent = QuickChatEvent(
            id: message.id,
            authorID: message.authorID,
            authorName: quickChatDisplayName(for: message.authorID),
            phrase: message.phrase,
            isLocalAuthor: message.authorID == localID
        )
    }

    private func quickChatDisplayName(for id: UUID) -> String {
        if id == localID { return AppLanguage.string("quickChat.sender.you") }
        if let name = game?.players.first(where: { $0.id == id })?.nickname, !name.isEmpty {
            return name
        }
        if let name = room?.participants.first(where: { $0.id == id })?.nickname, !name.isEmpty {
            return name
        }
        return AppLanguage.string("quickChat.sender.unknown")
    }
}
