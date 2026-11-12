#if DEBUG
import LuminoreCore
import SwiftData
import SwiftUI

/// Debug-only scenes for taking screenshots.
///
/// Launch with `-demoScene standard|duel|lobby` (and `-languageOverride en|zh-Hans`)
/// to boot straight into a hosted room with AI opponents. In the two game scenes
/// the local seat is played by the AI for a few moves, so the capture shows a
/// match in progress, then it stops on the local player's turn. Compiled out of
/// Release builds entirely.
enum DemoScene: String {
    case standard, duel, lobby

    static let current: DemoScene? = UserDefaults.standard.string(forKey: "demoScene").flatMap(DemoScene.init)

    /// Moves the AI still plays on the local player's behalf.
    @MainActor static var autoplayMovesLeft: Int = {
        // Launch arguments arrive as strings; `integer(forKey:)` parses them.
        let requested = UserDefaults.standard.integer(forKey: "demoMoves")
        return requested > 0 ? requested : 9
    }()

    private var botDifficulties: [BotDifficulty] {
        switch self {
        case .standard, .lobby: [.normal, .hard, .easy]
        case .duel: [.hard]
        }
    }

    private static var roomName: String {
        AppLanguage.locale.language.languageCode?.identifier == "zh" ? "周末桌游夜" : "Game Night"
    }

    /// Host a room, seat the bots and (for the game scenes) start the match.
    @MainActor
    func bootstrap(_ session: MatchSessionService) {
        guard session.phase == .menu else { return }
        session.host(roomName: Self.roomName, password: "")
        Task { @MainActor in
            for _ in 0 ..< 50 where session.phase != .lobby {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard session.phase == .lobby else { return }
            botDifficulties.forEach(session.addBot)
            guard self != .lobby else { return }
            session.enterConfiguration()
            guard var configuration = session.room?.configuration else { return }
            configuration.mode = self == .duel ? .duel : .standard
            configuration.turnDurationSeconds = nil
            session.updateConfiguration(configuration)
            session.startGame()
        }
    }
}

/// Root replacement while a demo scene is active: skips onboarding and Home.
struct DemoSceneHost: View {
    let scene: DemoScene
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountProfile.createdAt) private var profiles: [AccountProfile]

    var body: some View {
        NavigationStack {
            if let profile = profiles.first {
                MultiplayerFlowView(profile: profile, mode: .lan)
            } else {
                ProgressView().onAppear {
                    modelContext.insert(AccountProfile(nickname: "Avery"))
                    try? modelContext.save()
                }
            }
        }
    }
}
#endif
