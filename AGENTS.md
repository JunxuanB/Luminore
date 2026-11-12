This project is Luminore, a gem-trading board game for iOS written in Swift.
It supports several rulesets, currently Standard and the two-player Duel.

Tech stack:
- Front end: Swift
- Back end: TypeScript, entirely on Cloudflare services

Key decisions:
- iPhone is portrait only; iPad supports every orientation and is mostly used in landscape
- Only recent iOS versions need to be supported
- Adapt to screen sizes from iPhone 14 onwards; extreme cases such as iPhone SE can be ignored
- Simple, clean UI in the native iOS style
- Anti-cheat is not a priority; local binary or save tampering does not need to be handled
- Multilingual; currently Chinese and English
- Small code modules; no very long source files

Play modes (all multiplayer, including more than 4 players):
- Internet
- Local network (LAN)
- MultipeerConnectivity

Because the modes differ so much, the back-end server only relays data.
The account layer has just four things:
- UUID
- Nickname
- Medals: after each match the losing side awards the winner a medal carrying the loser's UUID, and the winner can see every medal in their medal list
- Final match records
These are stored locally and backed up automatically to the user's iCloud. Since anti-cheat is out of scope, they are stored in plain text without encryption.

Possible future plans (ignore the low-probability ones; leave room for the high-probability ones):
- High: playing against AI
- High: AI players joining a match
- Low: desktop (macOS)
- Low: web

Ask about details and confirm before starting.

Swift code is compiled, not run. To check or test something yourself, use the iPhone 17 Pro simulator.

The main project lives in /ios. Every feature must work in, and stay in sync across, all three play modes.

Deploy the back end after changing it.

Localization rules: all user-facing text follows the in-app language setting (`languageOverride`, whose default `system` follows the device language). Never read the device/system language directly.
- Strings live in `ios/Luminore/Resources/Localizable.xcstrings` (the default table), with both Chinese and English filled in. Do not create separate xcstrings tables.
- In SwiftUI use `Text("key")` style LocalizedStringKey values; the `\.locale` injected by `LuminoreApp` makes them take effect.
- Anything that builds a string at runtime (error messages, AI nicknames, accessibility labels, notifications) must go through `AppLanguage.string(_:)`. Never use `String(localized:)` or `NSLocalizedString` directly: they only honour the system language and bypass the in-app setting.
