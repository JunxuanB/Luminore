import Foundation

/// Builds playful, randomised nicknames for AI seats.
///
/// The word pools and the joining format live in `Localizable.xcstrings` as
/// comma-separated lists, looked up through `AppLanguage` so the name follows the
/// host's in-app language setting rather than the system language (bots are
/// created host-side and the nickname is broadcast verbatim to every client).
/// Chinese renders as `修饰的主体` (e.g. 奔跑的蟑螂); English renders as
/// `Modifier Subject`.
enum BotNameGenerator {
    /// A random `modifier + subject` combination that collides with none of
    /// `taken`. Falls back to a numeric suffix if the pools are exhausted.
    static func randomName(excluding taken: Set<String>) -> String {
        let modifiers = pool("bot.random.modifiers")
        let subjects = pool("bot.random.subjects")
        guard !modifiers.isEmpty, !subjects.isEmpty else {
            return uniqueFallback(excluding: taken)
        }

        // Sampling with retries keeps the common case cheap; the full cross
        // product (30 × 30) is far larger than any 7-seat room needs.
        for _ in 0 ..< 40 {
            guard let modifier = modifiers.randomElement(), let subject = subjects.randomElement() else { break }
            let name = AppLanguage.string("bot.random.format", modifier, subject)
            if !taken.contains(name) { return name }
        }
        return uniqueFallback(excluding: taken)
    }

    /// Splits a localized comma-separated word list, tolerating both ASCII and
    /// full-width commas plus stray whitespace from translators.
    private static func pool(_ key: String) -> [String] {
        AppLanguage.string(key)
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func uniqueFallback(excluding taken: Set<String>) -> String {
        let base = AppLanguage.string("bot.random.fallback")
        var index = 1
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
