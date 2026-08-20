import Foundation

/// Runtime string lookups that honour the in-app language override.
///
/// SwiftUI resolves `Text("key")` through `\.locale`, which `LuminoreApp` sets
/// from the `languageOverride` preference. `String(localized:)` and
/// `NSLocalizedString` bypass that entirely and resolve against the *system*
/// language, so anything that builds a String at runtime — bot nicknames, error
/// messages pushed into `presentedError`, accessibility labels — has to look the
/// key up in the override's bundle instead.
enum AppLanguage {
    static let storageKey = "languageOverride"

    /// The chosen language code, or `nil` when following the system.
    static var override: String? {
        let value = UserDefaults.standard.string(forKey: storageKey) ?? "system"
        return value == "system" ? nil : value
    }

    static var locale: Locale {
        guard let override else { return .autoupdatingCurrent }
        return Locale(identifier: override)
    }

    /// The override's compiled `.lproj`, falling back to the main bundle when the
    /// player follows the system or the language ships no strings.
    static var bundle: Bundle {
        guard let override,
              let path = Bundle.main.path(forResource: override, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    /// Localized value for `key`, or the key itself when it is missing (matching
    /// `NSLocalizedString`'s behaviour).
    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Localized format string filled in with `arguments`.
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
