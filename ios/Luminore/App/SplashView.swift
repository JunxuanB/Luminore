import LuminoreCore
import SwiftUI

/// 开屏动画：五颗宝石从四周向心聚拢，拼合成 App 标志。
///
/// 首帧的构图（`LaunchBackground` 纯色 + 尚未出现的宝石）与 `Info.plist` 里
/// `UILaunchScreen` 指定的静态启动图完全一致，所以系统把画面交给 SwiftUI 的
/// 那一刻看不出接缝 —— 用户看到的是纯色底而不是白屏。
struct SplashView: View {
    /// 入场动画播完时回调。调用方结合数据就绪状态决定何时退场，
    /// 因此这里只负责"演完"，不负责"消失"。
    let onIntroFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 = 宝石在外圈，1 = 汇聚到圆心。位置、大小、旋转都由它派生。
    @State private var convergence: Double = 0
    @State private var dotOpacity: Double = 0
    /// 汇聚瞬间扩散出去的光环，0 → 1 一次性播完。
    @State private var flashProgress: Double = 0
    @State private var markScale: Double = 0.55
    @State private var markOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: Double = 10
    /// 数据还没就绪时标志的轻微呼吸，避免画面看起来卡死。
    @State private var breathing = false

    private static let gems = GemColor.purchasableColors
    private static let markSize: CGFloat = 116
    /// 整组构图相对屏幕正中上移的量。视觉重心略高于几何中心才不显得下坠，
    /// 宝石、光环、标志、标题必须同步位移，否则聚拢的落点会对不上标志。
    private static let verticalLift: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(
                x: proxy.size.width / 2,
                y: proxy.size.height / 2 - Self.verticalLift
            )
            let outerRadius = min(proxy.size.width, proxy.size.height) * 0.34

            ZStack {
                Color.launchBackground.ignoresSafeArea()

                ForEach(Array(Self.gems.enumerated()), id: \.element) { index, gem in
                    GemDot(gem: gem, diameter: 26 - 12 * convergence)
                        .position(dotPosition(index: index, center: center, outerRadius: outerRadius))
                        .opacity(dotOpacity)
                }

                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: Self.markSize, height: Self.markSize)
                    .scaleEffect(0.5 + 1.5 * flashProgress)
                    // 正弦包络：两端都是 0，所以光环在动画触发前后都完全隐形，
                    // 不会静静挂在屏幕中央等着播放。
                    .opacity(0.5 * sin(.pi * flashProgress))
                    .offset(y: -Self.verticalLift)

                AppMark(size: Self.markSize)
                    .scaleEffect(markScale)
                    .scaleEffect(breathing ? 1.04 : 1)
                    .opacity(markOpacity)
                    .offset(y: -Self.verticalLift)

                Text("app.name")
                    .font(.title.weight(.semibold))
                    // `primary` 而不是字面白色：深色模式下是纯白，浅色模式下自动
                    // 翻成纯黑。开屏底跟随深浅模式，写死白色会在浅色下看不见。
                    .foregroundStyle(.primary)
                    .offset(y: Self.markSize / 2 + 36 + titleOffset - Self.verticalLift)
                    .opacity(titleOpacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .task { await runIntro() }
    }

    /// 宝石在向心的同时带一点角速度，走出螺旋而不是直线，观感更"聚拢"。
    private func dotPosition(index: Int, center: CGPoint, outerRadius: CGFloat) -> CGPoint {
        let base = -Double.pi / 2 + 2 * .pi * Double(index) / Double(Self.gems.count)
        let angle = base + 0.8 * convergence
        let radius = outerRadius + (Self.markSize * 0.14 - outerRadius) * convergence
        return CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    private func runIntro() async {
        guard !reduceMotion else {
            // 关闭动态效果时只做淡入：没有位移、没有回弹、没有呼吸。
            withAnimation(.easeOut(duration: 0.5)) {
                markScale = 1
                markOpacity = 1
                titleOpacity = 1
                titleOffset = 0
            }
            try? await Task.sleep(for: .milliseconds(800))
            onIntroFinished()
            return
        }

        // 让系统启动图静静地多待一瞬，宝石再入场，衔接会更稳。
        try? await Task.sleep(for: .milliseconds(120))

        withAnimation(.easeOut(duration: 0.26)) { dotOpacity = 1 }
        withAnimation(.timingCurve(0.42, 0, 0.16, 1, duration: 0.90)) { convergence = 1 }
        try? await Task.sleep(for: .milliseconds(880))

        withAnimation(.easeOut(duration: 0.16)) { dotOpacity = 0 }
        withAnimation(.easeOut(duration: 0.65)) { flashProgress = 1 }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.52)) {
            markScale = 1
            markOpacity = 1
        }
        try? await Task.sleep(for: .milliseconds(320))

        withAnimation(.easeOut(duration: 0.38)) {
            titleOpacity = 1
            titleOffset = 0
        }
        // 先等标题淡完，再留一段定格 —— 这两段必须分开算，否则"标志 + 标题"
        // 的完整构图只存在一瞬就开始退场了。
        try? await Task.sleep(for: .milliseconds(380))
        try? await Task.sleep(for: .milliseconds(700))

        onIntroFinished()
        // 只有在数据尚未就绪、开屏被留在原地时才看得到这段呼吸。
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

/// 单颗宝石。描边用 `primary` 是为了让钻石（近白）和玛瑙（近黑）在各自
/// 对应的浅色 / 深色背景上都还看得清轮廓。
private struct GemDot: View {
    let gem: GemColor
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(gem.tint.gradient)
            .overlay(
                Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: max(1, diameter * 0.06))
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: gem.tint.opacity(0.45), radius: diameter * 0.35)
    }
}

extension Color {
    /// 与 `Info.plist` 的 `UILaunchScreen` 共用，两侧必须指向同一个色板。
    static let launchBackground = Color("LaunchBackground")
}
