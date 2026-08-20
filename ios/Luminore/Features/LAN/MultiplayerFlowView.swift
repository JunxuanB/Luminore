import LuminoreCore
import SwiftData
import SwiftUI

struct MultiplayerFlowView: View {
    let profile: AccountProfile
    let medalCount: Int
    @StateObject private var session: MatchSessionService
    @StateObject private var presence = PresenceCoordinator()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var presenceConflict: PresenceCoordinator.Conflict?
    @State private var showingServerSettings = false

    private var isLocalTurn: Bool {
        session.phase == .game
            && !session.isOpeningTurnSelection
            && session.game?.currentPlayerID == session.localID
    }

    init(
        profile: AccountProfile,
        mode: MultiplayerMode,
        serverURL: URL? = nil,
        medalCount: Int = 0
    ) {
        self.profile = profile
        self.medalCount = medalCount
        _session = StateObject(wrappedValue: MatchSessionService(
            localID: profile.uuid,
            nickname: profile.nickname,
            medalCount: medalCount,
            mode: mode,
            serverURL: serverURL
        ))
    }

    @ViewBuilder private var phaseContent: some View {
        switch session.phase {
        case .menu:
            MultiplayerMenuView(session: session)
        case .connecting:
            ProgressView("multiplayer.connecting")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lobby:
            LobbyView(session: session)
        case .configuration:
            ConfigurationView(session: session, profile: profile)
        case .game:
            if session.game?.configuration.mode == .duel {
                DuelGameBoardView(
                    session: session,
                    onExit: exitMatch,
                    onSaveAndSuspend: { session.saveAndEndMatch(context: modelContext) }
                )
            } else {
                GameBoardView(
                    session: session,
                    onExit: exitMatch,
                    onSaveAndSuspend: { session.saveAndEndMatch(context: modelContext) }
                )
            }
        case .results:
            ResultView(session: session)
        case .reconnecting:
            ReconnectingView(session: session)
        case .ended:
            ContentUnavailableView(
                "lan.sessionEnded",
                systemImage: "wifi.exclamationmark",
                description: Text("lan.sessionEnded.detail")
            )
        }
    }

    private func exitMatch() {
        session.leave()
        dismiss()
    }

    var body: some View {
        withLifecycle(withAlerts(withChrome(phaseContent)))
            .localTurnNotification(isLocalTurn: isLocalTurn)
    }

    private func withChrome<V: View>(_ content: V) -> some View {
        content
            .navigationBarBackButtonHidden(session.phase != .menu)
            .toolbar {
                if session.phase != .menu {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("common.leave", role: .destructive) {
                            session.leave()
                            dismiss()
                        }
                    }
                }
                if session.phase == .menu, session.mode == .internet {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingServerSettings = true
                        } label: {
                            Label("internet.server.title", systemImage: "server.rack")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingServerSettings) {
                InternetServerSettingsView { url in
                    session.updateInternetServer(url)
                }
            }
    }

    private func withAlerts<V: View>(_ content: V) -> some View {
        content
            .alert("common.error", isPresented: Binding(
                get: { session.presentedError != nil },
                set: { if !$0 { session.presentedError = nil } }
            )) {
                Button("common.ok") { session.presentedError = nil }
            } message: {
                Text(session.presentedError ?? "")
            }
            .alert("presence.takeover.title", isPresented: Binding(
                get: { presenceConflict != nil },
                set: { if !$0 { presenceConflict = nil } }
            ), presenting: presenceConflict) { _ in
                Button("presence.takeover.confirm") { presenceConflict = nil }
                Button("common.leave", role: .cancel) {
                    presenceConflict = nil
                    session.leave()
                    presence.release()
                    dismiss()
                }
            } message: { conflict in
                Text("presence.takeover.message \(conflict.deviceName)")
            }
            .alert("presence.takenOver.title", isPresented: $presence.wasTakenOver) {
                Button("common.ok") {
                    session.leave()
                    dismiss()
                }
            } message: {
                Text("presence.takenOver.message")
            }
    }

    private func withLifecycle<V: View>(_ content: V) -> some View {
        content
            .onAppear {
                presence.configure(modelContext)
                session.updateNickname(profile.nickname)
                session.updateMedalCount(medalCount)
            }
            .onChange(of: session.phase) { old, new in handlePhaseChange(from: old, to: new) }
            .onChange(of: session.game?.status) { _, _ in recordOutcomeIfFinished() }
            .onChange(of: scenePhase) { _, new in
                // `.inactive` already means the app is on its way out (app
                // switcher, share sheet hand-off), and the background grant has to
                // be claimed before the process is suspended — so anything that is
                // not `.active` arms it.
                if new == .active {
                    session.applicationDidBecomeActive()
                } else {
                    session.applicationWillResignActive()
                }
            }
            .onChange(of: session.wasSuspended) { _, suspended in
                // The host saved the match and ended it: everyone goes home.
                if suspended { dismiss() }
            }
            .onDisappear {
                if session.phase == .menu { session.leave() }
                presence.release()
            }
    }

    /// Persist medals and history the moment the match reaches its terminal state.
    /// `MatchOutcomeRecorder` is idempotent, so repeated snapshots are harmless.
    private func recordOutcomeIfFinished() {
        guard let game = session.game, game.status == .finished, let room = session.room else { return }
        do {
            _ = try MatchOutcomeRecorder.record(
                snapshot: game,
                ownerKey: profile.uuid.uuidString,
                localParticipantID: session.localID,
                transport: session.mode,
                roomName: room.descriptor.name,
                context: modelContext
            )
        } catch {
            session.presentedError = error.localizedDescription
        }
    }

    /// Claim the presence lease when a match becomes active and release it when the
    /// session returns to the menu or ends. `presenceConflict` surfaces the soft
    /// "already playing on another device" prompt.
    private func handlePhaseChange(from old: MatchSessionService.Phase, to new: MatchSessionService.Phase) {
        let wasActive = old != .menu && old != .ended
        let isActive = new != .menu && new != .ended
        if !wasActive, isActive {
            presenceConflict = presence.claim(
                profileUUID: profile.uuid,
                context: session.mode.presenceContext
            )
        } else if wasActive, !isActive {
            presence.release()
        }
    }
}
