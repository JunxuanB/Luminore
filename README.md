# Luminore

A gem-trading board game for iPhone and iPad, written in SwiftUI. Take gems, buy development cards, turn them into permanent discounts and race to the target score.

Luminore is an independent, open-source project. It is not affiliated with any other board game or its publisher.

## Features

- **Two rulesets**: Standard for 2–4 players (with clearly marked table rules for 5–7) and Duel for two players
- **Three ways to play together**: local network (Bonjour + TCP), nearby (MultipeerConnectivity) and Internet (room codes through a relay)
- **AI players** in three difficulty levels, and guided tutorials for both rulesets
- Turn timer, custom rules, pause / save / resume, quick chat, an optional mining mini-game, and medals awarded by the losing players
- Native layouts for iPhone (portrait) and iPad (all orientations, with a two-column board in landscape)
- English and Simplified Chinese

## Repository layout

| Path | Contents |
| --- | --- |
| `ios/Luminore.xcodeproj` | The app |
| `ios/Luminore` | SwiftUI app: features, networking, persistence, resources |
| `ios/LuminoreCore` | Rules, AI and wire protocol, with no UI dependencies |
| `backend` | Cloudflare Workers relay for Internet play (TypeScript, Durable Objects) |
| `docs` | Design notes, the LAN protocol, the privacy policy and the support page |

The host device owns all lobby and game state. Clients send commands and receive snapshots, and the relay only forwards frames, so all three transports share one protocol. See [docs/03-lan-protocol-v1.md](docs/03-lan-protocol-v1.md).

## Building

Requires Xcode 26 or later. The minimum deployment target is iOS 17.

```bash
open ios/Luminore.xcodeproj
```

Run the tests from the command line (only the `Luminore` scheme is set up for testing):

```bash
xcodebuild -project ios/Luminore.xcodeproj -scheme Luminore -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Relay server

```bash
cd backend && npm install && npm test
```

```bash
cd backend && npm run deploy
```

The app's default relay is `https://luminore-api.junxuanb.com`. You can point the app at your own deployment from the Internet mode's server settings.

## Data and privacy

No account, ads, analytics or tracking. Profiles, medals and match history are stored on the device and in the player's own private iCloud. See [docs/PRIVACY.md](docs/PRIVACY.md) and [docs/SUPPORT.md](docs/SUPPORT.md).

## License

[MIT](LICENSE). Third-party data sources are credited in [ios/THIRD_PARTY_NOTICES.md](ios/THIRD_PARTY_NOTICES.md).
