import SwiftData
import SwiftUI

struct AccountView: View {
    @Query(sort: \AccountProfile.createdAt) private var profiles: [AccountProfile]
    @AppStorage("activeProfileID") private var activeProfileID = ""
    @AppStorage("languageOverride") private var languageOverride = "system"
    @State private var draftNickname = ""
    @State private var showingNotice = false

    private var activeProfile: AccountProfile? {
        profiles.first { $0.uuid.uuidString == activeProfileID } ?? profiles.first
    }

    var body: some View {
        Form {
            if let profile = activeProfile {
                Section("account.profile") {
                    TextField("account.nickname", text: $draftNickname)
                        .onSubmit { saveNickname(into: profile) }
                    LabeledContent("account.uuid") {
                        Text(profile.uuid.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("common.save") { saveNickname(into: profile) }
                        .disabled(normalizedNickname.isEmpty
                            || normalizedNickname.count > 20
                            || normalizedNickname == profile.nickname)
                }
            }

            Section {
                NavigationLink {
                    ProfilesView()
                } label: {
                    LabeledContent("account.profiles", value: "\(profiles.count)")
                }
            } footer: {
                Text("account.profiles.hint")
            }

            Section("settings.language") {
                Picker("settings.language", selection: $languageOverride) {
                    Text("settings.language.system").tag("system")
                    Text("settings.language.chinese").tag("zh-Hans")
                    Text("settings.language.english").tag("en")
                }
            }

            if let profile = activeProfile {
                ProfileRecordsSections(profile: profile)
            }

            Section("about.title") {
                Button("about.notice") { showingNotice = true }
                Link(destination: LaunchNotice.sourceURL) {
                    LabeledContent("about.sourceCode") {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                LabeledContent("about.version", value: appVersion)
            }
        }
        .navigationTitle("account.title")
        .sheet(isPresented: $showingNotice) {
            LaunchNoticeView { showingNotice = false }
        }
        .onAppear { draftNickname = activeProfile?.nickname ?? "" }
        .onChange(of: activeProfileID) { _, _ in draftNickname = activeProfile?.nickname ?? "" }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }

    private var normalizedNickname: String {
        draftNickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveNickname(into profile: AccountProfile) {
        guard !normalizedNickname.isEmpty, normalizedNickname.count <= 20 else { return }
        profile.nickname = normalizedNickname
        profile.updatedAt = Date()
    }
}
