import SwiftData
import SwiftUI

/// 开屏门：先出画面，再建数据栈。
///
/// `ModelContainer` 的主 store 走 CloudKit 私有库镜像，构建耗时明显。以前它是
/// `LuminoreApp` 的存储属性，必须在第一帧之前同步跑完，这段时间用户看到的就是
/// 系统启动图的白屏。现在改成首帧渲染之后在后台线程构建，`SplashView` 正好盖住
/// 这段等待 —— 顺带也盖住了 `RootView` 里 `@Query` 尚未出结果时的 `ProgressView`。
struct LaunchGateView: View {
    @State private var container: ModelContainer?
    @State private var isIntroFinished = false
    @State private var isSplashDismissed = false

    var body: some View {
        ZStack {
            if let container {
                // 提前挂载：开屏还在播的时候主界面就已经在底下完成布局了。
                RootView()
                    .modelContainer(container)
            }

            if !isSplashDismissed {
                SplashView(onIntroFinished: markIntroFinished)
                    .transition(.opacity)
            }
        }
        .task {
            guard container == nil else { return }
            container = await Self.makeContainerOffMainThread()
            dismissSplashIfReady()
        }
    }

    private func markIntroFinished() {
        isIntroFinished = true
        dismissSplashIfReady()
    }

    /// 动画播完 **且** 数据就绪才退场，两个条件谁后到都由这里收口。
    private func dismissSplashIfReady() {
        guard container != nil, isIntroFinished, !isSplashDismissed else { return }
        withAnimation(.easeOut(duration: 0.4)) { isSplashDismissed = true }
    }

    /// 放到后台线程，避免 CloudKit 镜像的建栈开销卡住开屏动画。
    private static func makeContainerOffMainThread() async -> ModelContainer {
        await Task.detached(priority: .userInitiated) {
            PersistenceController.makeContainer()
        }.value
    }
}
