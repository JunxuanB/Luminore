import LuminoreCore
import SwiftUI

struct MultiplayerMenuView: View {
    @ObservedObject var session: MatchSessionService
    @State private var showingCreate = false
    @State private var showingJoin = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            AppMark(size: 88)
            Text(session.mode.titleKey).font(.largeTitle.bold())
            Text(session.mode.subtitleKey)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingCreate = true
            } label: {
                Label("lan.create", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            Button {
                showingJoin = true
            } label: {
                Label("lan.join", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .navigationTitle(session.mode.titleKey)
        .sheet(isPresented: $showingCreate) {
            CreateRoomView(session: session)
        }
        .sheet(isPresented: $showingJoin) {
            JoinRoomView(session: session)
        }
    }
}

struct CreateRoomView: View {
    @ObservedObject var session: MatchSessionService
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var password = ""
    @State private var isPublic = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("lan.room.name", text: $roomName)
                    SecureField("lan.room.password.optional", text: $password)
                    if session.mode == .internet {
                        Toggle("internet.room.public", isOn: $isPublic)
                    }
                } header: {
                    Text("lan.room.details")
                } footer: {
                    Text("lan.room.password.hint")
                }
            }
            .navigationTitle("lan.create")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("lan.create") {
                        session.host(
                            roomName: roomName.trimmingCharacters(in: .whitespacesAndNewlines),
                            password: password,
                            isPublic: session.mode == .internet ? isPublic : true
                        )
                        dismiss()
                    }
                    .disabled(roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || roomName.count > 40)
                }
            }
        }
    }
}

struct JoinRoomView: View {
    @ObservedObject var session: MatchSessionService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRoom: DiscoveredMatchRoom?
    @State private var password = ""
    @State private var roomCode = ""
    @State private var isResolvingCode = false
    /// Shown inside the sheet: the session's error alert sits underneath this
    /// sheet and cannot present while it is up.
    @State private var codeError: String?

    var body: some View {
        NavigationStack {
            List {
                if session.mode == .internet {
                    Section {
                        HStack {
                            TextField("internet.room.code.placeholder", text: $roomCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .monospaced()
                            if isResolvingCode { ProgressView() }
                            Button("internet.room.code.join") { resolveCode() }
                                .disabled(normalizedCode.count != 6 || isResolvingCode)
                        }
                    } header: {
                        Text("internet.room.code.section")
                    } footer: {
                        if let codeError {
                            Text(codeError).foregroundStyle(.red)
                        }
                    }
                }
                Section(session.mode == .internet ? "internet.rooms.public" : "multiplayer.rooms.nearby") {
                    if session.discoveredRooms.isEmpty {
                    ContentUnavailableView(
                        session.mode == .internet ? "internet.rooms.empty" : "lan.rooms.empty",
                        systemImage: session.mode == .internet ? "globe" : "wifi",
                        description: Text(searchingHintKey)
                    )
                } else {
                    ForEach(session.discoveredRooms) { room in
                        Button {
                            selectedRoom = room
                            if !room.descriptor.isPasswordProtected { connect(room) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: room.descriptor.isPasswordProtected ? "lock.fill" : "wifi")
                                    .foregroundStyle(room.descriptor.stage == .lobby ? Color.accentColor : .secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(room.descriptor.name).font(.headline)
                                    Text("lan.room.host \(room.descriptor.hostNickname)")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(room.descriptor.playerCount)/\(room.descriptor.maximumPlayers)")
                                        .monospacedDigit()
                                    Text(stageKey(room.descriptor.stage))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(room.descriptor.stage != .lobby)
                    }
                }
                }
            }
            .navigationTitle("lan.join")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .alert("lan.password.title", isPresented: Binding(
                get: { selectedRoom?.descriptor.isPasswordProtected == true },
                set: { if !$0 { selectedRoom = nil; password = "" } }
            )) {
                SecureField("lan.room.password", text: $password)
                Button("lan.join") {
                    if let selectedRoom { connect(selectedRoom) }
                }
                Button("common.cancel", role: .cancel) { selectedRoom = nil }
            }
        }
        .onAppear { session.startBrowsing() }
        .onDisappear { session.stopBrowsing() }
    }

    private var normalizedCode: String {
        roomCode.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Nearby discovery depends on radios and a privacy prompt the player can miss,
    /// so its empty state spells out what to check instead of just spinning.
    private var searchingHintKey: LocalizedStringKey {
        switch session.mode {
        case .internet: "internet.rooms.searching"
        case .lan: "lan.rooms.searching"
        case .nearby: "nearby.rooms.searching"
        }
    }

    private func resolveCode() {
        // Same normalisation the Join button is enabled by, so "abc-def" works.
        let code = normalizedCode
        codeError = nil
        isResolvingCode = true
        Task {
            defer { isResolvingCode = false }
            do {
                let room = try await session.resolveRoom(code: code)
                selectedRoom = room
                if !room.descriptor.isPasswordProtected { connect(room) }
            } catch {
                codeError = error.localizedDescription
            }
        }
    }

    private func connect(_ room: DiscoveredMatchRoom) {
        session.join(room, password: password)
        selectedRoom = nil
        dismiss()
    }

    private func stageKey(_ stage: RoomStage) -> LocalizedStringKey {
        switch stage {
        case .lobby: "lan.stage.lobby"
        case .configuration: "lan.stage.configuration"
        case .playing: "lan.stage.playing"
        case .results: "lan.stage.results"
        }
    }
}
