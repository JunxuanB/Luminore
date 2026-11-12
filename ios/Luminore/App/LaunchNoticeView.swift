import SwiftUI

/// The independent-project notice shown on the first launch after every install.
///
/// The acknowledgement lives in `UserDefaults`, which iOS wipes together with
/// the app, so a reinstall shows the notice again. It is deliberately *not*
/// stored in SwiftData: that store mirrors to iCloud and would survive.
enum LaunchNotice {
    static let acknowledgedKey = "launchNoticeAcknowledgedVersion"
    /// Bump when the wording changes materially so everyone sees it again.
    static let currentVersion = 1
    static let sourceURL = URL(string: "https://github.com/JunxuanB/Luminore")!
}

struct LaunchNoticeView: View {
    /// Called when the player taps the acknowledge button.
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 12) {
                        AppMark(size: 72)
                        Text("notice.title")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)

                    NoticeRow(
                        systemImage: "heart.fill",
                        tint: .pink,
                        title: "notice.unofficial.title",
                        message: "notice.unofficial.body"
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        NoticeRow(
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            tint: .indigo,
                            title: "notice.openSource.title",
                            message: "notice.openSource.body"
                        )
                        Link(destination: LaunchNotice.sourceURL) {
                            Text(verbatim: "github.com/JunxuanB/Luminore")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.leading, 48)
                    }
                    NoticeRow(
                        systemImage: "gift.fill",
                        tint: .green,
                        title: "notice.free.title",
                        message: "notice.free.body"
                    )
                    NoticeRow(
                        systemImage: "server.rack",
                        tint: .orange,
                        title: "notice.fees.title",
                        message: "notice.fees.body"
                    )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }

            Button(action: onDone) {
                Text("notice.acknowledge")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 560)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct NoticeRow: View {
    let systemImage: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
