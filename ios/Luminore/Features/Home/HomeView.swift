import SwiftData
import SwiftUI

struct HomeView: View {
    let profile: AccountProfile
    @Query private var medals: [MedalRecord]

    init(profile: AccountProfile) {
        self.profile = profile
        let key = profile.uuid.uuidString
        _medals = Query(
            filter: #Predicate<MedalRecord> { $0.ownerKey == key },
            sort: \.awardedAt,
            order: .reverse
        )
    }

    private var medalCount: Int { medals.uniqueScopedMedals.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack(spacing: 14) {
                        AppMark(size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("app.name")
                                .font(.title.bold())
                            Text("home.greeting \(profile.nickname)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NavigationLink {
                            AccountView()
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.title2)
                                .padding(8)
                        }
                        .accessibilityLabel(Text("account.title"))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("home.chooseMode").font(.headline)
                        NavigationLink {
                            TutorialSelectionView(profile: profile)
                        } label: {
                            ModeCard(
                                title: "tutorial.entry.title",
                                subtitle: "tutorial.entry.subtitle",
                                systemImage: "graduationcap.fill",
                                enabled: true
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            MultiplayerFlowView(profile: profile, mode: .lan, medalCount: medalCount)
                        } label: {
                            ModeCard(
                                title: "mode.lan.title",
                                subtitle: "mode.lan.subtitle",
                                systemImage: "wifi",
                                enabled: true
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            MultiplayerFlowView(
                                profile: profile,
                                mode: .internet,
                                serverURL: InternetServerSettings.savedURL,
                                medalCount: medalCount
                            )
                        } label: {
                            ModeCard(
                                title: "mode.internet.title",
                                subtitle: "mode.internet.subtitle",
                                systemImage: "globe",
                                enabled: true
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            MultiplayerFlowView(profile: profile, mode: .nearby, medalCount: medalCount)
                        } label: {
                            ModeCard(
                                title: "mode.multipeer.title",
                                subtitle: "mode.multipeer.subtitle",
                                systemImage: "antenna.radiowaves.left.and.right",
                                enabled: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
        }
    }
}

private struct ModeCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2.bold())
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 48, height: 48)
                .background((enabled ? Color.accentColor : .gray).opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: enabled ? "chevron.right" : "lock.fill")
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(enabled ? 1 : 0.68)
    }
}
