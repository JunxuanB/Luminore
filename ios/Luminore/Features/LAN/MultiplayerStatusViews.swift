import LuminoreCore
import SwiftUI

struct ResultView: View {
    @ObservedObject var session: MatchSessionService
    @State private var isShowingAwardAnimation = true

    var body: some View {
        ZStack {
            resultContent
                .blur(radius: isPresentingAwards ? 4 : 0)
                .allowsHitTesting(!isPresentingAwards)

            if isPresentingAwards, let presentation {
                MedalAwardOverlay(presentation: presentation) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isShowingAwardAnimation = false
                    }
                }
                .transition(.opacity)
            }
        }
        .navigationTitle("result.title")
    }

    private var resultContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 58)).foregroundStyle(.yellow)
            Text("result.title").font(.largeTitle.bold())
            if let standings = session.game?.result?.standings {
                List(standings) { standing in
                    HStack {
                        Text("#\(standing.rank)").font(.title3.bold()).frame(width: 38)
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text(standing.nickname).font(.headline)
                                if let player = session.game?.players.first(where: { $0.id == standing.playerID }),
                                   player.kind == .human {
                                    MedalCountLabel(count: player.medalCount, compact: true)
                                }
                            }
                            Text("result.cards \(standing.developmentCards)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(standing.prestige)").font(.title2.bold())
                        if standing.isWinner { Image(systemName: "crown.fill").foregroundStyle(.yellow) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            if session.isHost {
                Button("result.rematch") { session.returnToConfiguration() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                ProgressView("result.waitingHost")
            }
        }
        .padding(.vertical)
    }

    private var presentation: MedalAwardPresentation? {
        session.game.map(MedalAwardPresentation.init)
    }

    private var isPresentingAwards: Bool {
        isShowingAwardAnimation && presentation?.hasAwards == true
    }
}

struct ReconnectingView: View {
    @ObservedObject var session: MatchSessionService

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(titleKey).font(.title2.bold())
            Text(detailKey)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    /// Joining by code while the host is still in the app they shared it from is
    /// a wait, not a recovery — saying "reconnecting" for a link that was never
    /// up reads as an error the player caused.
    private var titleKey: LocalizedStringKey {
        session.isWaitingForHost ? "lan.waitingHost" : "lan.reconnecting"
    }

    private var detailKey: LocalizedStringKey {
        session.isWaitingForHost ? "lan.waitingHost.detail" : "lan.reconnecting.detail"
    }
}

extension MultiplayerMode {
    var titleKey: LocalizedStringKey {
        switch self {
        case .lan: "mode.lan.title"
        case .internet: "mode.internet.title"
        case .nearby: "mode.multipeer.title"
        }
    }

    var subtitleKey: LocalizedStringKey {
        switch self {
        case .lan: "mode.lan.subtitle"
        case .internet: "mode.internet.subtitle"
        case .nearby: "mode.multipeer.subtitle"
        }
    }

    var presenceContext: String {
        switch self {
        case .lan: AppLanguage.string("presence.context.lan")
        case .internet: AppLanguage.string("presence.context.internet")
        case .nearby: AppLanguage.string("presence.context.nearby")
        }
    }
}
