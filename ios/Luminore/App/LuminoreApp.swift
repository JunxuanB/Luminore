import SwiftUI

@main
struct LuminoreApp: App {
    @AppStorage("languageOverride") private var languageOverride = "system"

    var body: some Scene {
        WindowGroup {
            // `ModelContainer` 由 `LaunchGateView` 在首帧之后异步构建并注入，
            // 这样启动时不必等 CloudKit 建栈完成才出画面。
            LaunchGateView()
                .environment(\.locale, selectedLocale)
        }
    }

    private var selectedLocale: Locale {
        switch languageOverride {
        case "zh-Hans": Locale(identifier: "zh-Hans")
        case "en": Locale(identifier: "en")
        default: .autoupdatingCurrent
        }
    }
}
