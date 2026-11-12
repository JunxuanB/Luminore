import SwiftData
import SwiftUI

/// Manages the profiles stored under one iCloud account. Multiple profiles let
/// people who share an Apple ID (a common family setup) each play as themselves,
/// which is also why the active profile — not the account UUID alone — drives
/// match identity and the presence lock.
struct ProfilesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountProfile.createdAt) private var profiles: [AccountProfile]
    @Query private var medals: [MedalRecord]
    @Query private var completedGames: [CompletedGameRecord]
    @Query private var saves: [GameSaveRecord]
    @AppStorage("activeProfileID") private var activeProfileID = ""
    @State private var isAddingProfile = false
    @State private var pendingDeletion: AccountProfile?

    var body: some View {
        List {
            Section {
                ForEach(profiles) { profile in
                    Button {
                        activeProfileID = profile.uuid.uuidString
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.nickname).foregroundStyle(.primary)
                                Text(profile.uuid.uuidString.prefix(8))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.uuid.uuidString == activeProfileID {
                                Text("account.profiles.active")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    // Deleting wipes medals and history from iCloud too, so ask first.
                    guard profiles.count > 1, let index = offsets.first else { return }
                    pendingDeletion = profiles[index]
                }
                .deleteDisabled(profiles.count <= 1)
            } footer: {
                Text("account.profiles.hint")
            }

            Section {
                Button {
                    isAddingProfile = true
                } label: {
                    Label("account.profiles.add", systemImage: "person.badge.plus")
                }
            }
        }
        .navigationTitle("account.profiles")
        .toolbar { EditButton() }
        .confirmationDialog(
            "profiles.delete.title",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { profile in
            Button("profiles.delete.confirm", role: .destructive) { delete(profile) }
            Button("common.cancel", role: .cancel) {}
        } message: { profile in
            Text("profiles.delete.message \(profile.nickname)")
        }
        .sheet(isPresented: $isAddingProfile) {
            NewProfileSheet { nickname in
                let profile = AccountProfile(nickname: nickname)
                modelContext.insert(profile)
                try? modelContext.save()
                activeProfileID = profile.uuid.uuidString
            }
        }
    }

    private func delete(_ profile: AccountProfile) {
        // Keep at least one profile so the app never drops back to onboarding by
        // surprise.
        guard profiles.count > 1 else { return }
        let key = profile.uuid.uuidString
        medals.filter { $0.ownerKey == key }.forEach(modelContext.delete)
        completedGames.filter { $0.ownerKey == key }.forEach(modelContext.delete)
        saves.filter { $0.ownerKey == key }.forEach(modelContext.delete)
        modelContext.delete(profile)
        try? modelContext.save()
        if activeProfileID == key {
            activeProfileID = profiles.first { $0.uuid.uuidString != key }?.uuid.uuidString ?? ""
        }
    }
}

private struct NewProfileSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @FocusState private var isFocused: Bool

    private var normalized: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("account.profiles.newTitle") {
                    TextField("onboarding.nickname.placeholder", text: $nickname)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                }
            }
            .navigationTitle("account.profiles.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: create)
                        .disabled(normalized.isEmpty || normalized.count > 20)
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private func create() {
        guard !normalized.isEmpty, normalized.count <= 20 else { return }
        onCreate(normalized)
        dismiss()
    }
}
