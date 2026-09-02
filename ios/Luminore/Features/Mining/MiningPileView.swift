import LuminoreCore
import SwiftUI

/// The rock pile with a token buried under it.
///
/// Rock positions are baked once into `RockPile.layout`, never derived from a
/// live random source, so the mound stays put frame to frame and only its height
/// responds to the count.
///
/// **This view is on the critical path of a tap race.** The pile re-renders
/// several times per tap, so it deliberately avoids per-rock shadows (each is an
/// offscreen blur pass) and keeps the rocks in an `Equatable` child that a press
/// cannot invalidate. Dropping frames here costs the player real taps, because
/// SwiftUI delivers gesture callbacks on the same main thread.
struct MiningPileView: View {
    let gem: GemColor
    let remaining: Int
    let total: Int
    /// Miners dig; everyone else piles rocks back on. Only changes the feedback.
    let isMiner: Bool
    let isInteractive: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tapCount = 0
    @State private var isPressed = false

    private static let gemDiameter: CGFloat = 104
    static let size = CGSize(width: 250, height: 230)

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(remaining) / Double(total), 0), 1)
    }

    /// Continuous on purpose — see `RockPile`.
    private var visibleRocks: Double {
        fraction * Double(RockPile.maximumRocks)
    }

    var body: some View {
        ZStack {
            buriedGem
            // Kept as an Equatable child so a press — which flips `isPressed`
            // twice per tap — cannot force the heap to redraw.
            RockPile(visibleRocks: visibleRocks, isMiner: isMiner)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(Rectangle())
        .gesture(tapGesture)
        .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
        .animation(.spring(response: 0.15, dampingFraction: 0.6), value: isPressed)
        .sensoryFeedback(.impact(weight: isMiner ? .medium : .light), trigger: tapCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppLanguage.string("mining.a11y.pile", gem.localizedName, remaining)))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Buried token

    /// Drawn the same way the flight ghosts are (`GameAnimationSupport`), so the
    /// prize looks like the token it will become.
    private var buriedGem: some View {
        ZStack {
            Circle().fill(gem.tint)
            Circle().strokeBorder(.black.opacity(0.10), lineWidth: 1)
            Image(systemName: gem.iconName)
                .font(.system(size: Self.gemDiameter * 0.4, weight: .semibold))
                .foregroundStyle(gem.foreground)
        }
        .frame(width: Self.gemDiameter, height: Self.gemDiameter)
        // The more of the pile is gone, the brighter the prize shines through.
        .saturation(0.35 + 0.65 * (1 - fraction))
        .opacity(0.55 + 0.45 * (1 - fraction))
        .scaleEffect(0.92 + 0.08 * (1 - fraction))
        .offset(y: 6)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }

    // MARK: Input

    /// Fires on touch-*down* rather than on a completed tap: this is a race, and
    /// waiting for touch-up costs the player taps they actually made.
    private var tapGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard isInteractive, !isPressed else { return }
                isPressed = true
                tapCount += 1
                onTap()
            }
            .onEnded { _ in isPressed = false }
    }
}

/// The heap, drawn as a single `Canvas`.
///
/// It used to be 22 SwiftUI views, each with its own gradient, border, shadow
/// and spring animation, rebuilt several times per tap. That is 22 layers of
/// animation bookkeeping at five-plus taps a second, and dropping frames here
/// costs the player real taps — SwiftUI delivers gesture callbacks on the same
/// main thread it draws on. One `Canvas` is one draw pass, no layers, no
/// per-rock animation state.
///
/// Rocks fade individually off a continuous `visibleRocks`, so the heap still
/// moves smoothly without the animation system being involved at all.
private struct RockPile: View, Equatable {
    /// Continuous, not an integer count: the fractional part fades the topmost
    /// rock, which is what makes a tap read as progress.
    let visibleRocks: Double
    let isMiner: Bool

    static let maximumRocks = 22

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for rock in Self.layout {
                let alpha = min(max(visibleRocks - Double(rock.id), 0), 1)
                guard alpha > 0.01 else { continue }
                context.opacity = alpha
                // Rocks leaving fly out the way they came: dug ones sideways,
                // thrown ones back up.
                let drift = (1 - alpha) * (isMiner ? -14 : -34)
                var path = rock.path
                if drift != 0 {
                    path = path.applying(CGAffineTransform(translationX: 0, y: drift))
                }
                context.fill(
                    path,
                    with: .linearGradient(
                        rock.gradient,
                        startPoint: rock.gradientStart,
                        endPoint: rock.gradientEnd
                    )
                )
                context.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 1)
            }
        }
    }

    struct Rock {
        let id: Int
        let path: Path
        let gradient: Gradient
        let gradientStart: CGPoint
        let gradientEnd: CGPoint
    }

    /// Baked once at first use, already rotated and positioned, so a frame is
    /// pure drawing — no hashing, no geometry, no allocation.
    static let layout: [Rock] = (0 ..< maximumRocks).map { index in
        // Rocks fill bottom-up in loose rows so the mound reads as a heap and the
        // token emerges from the top.
        let perRow = 5
        let row = index / perRow
        let column = index % perRow
        let scale = 0.78 + 0.42 * noise(index, 3)
        let rowWidth = MiningPileView.size.width * (0.86 - 0.11 * Double(row))
        let size = CGSize(width: 40 * scale, height: 32 * scale)
        let centre = CGPoint(
            x: MiningPileView.size.width / 2
                + (Double(column) / Double(perRow - 1) - 0.5) * rowWidth
                + (noise(index, 1) - 0.5) * 26,
            y: MiningPileView.size.height / 2
                + MiningPileView.size.height * 0.34 - Double(row) * 30
                + (noise(index, 2) - 0.5) * 12
        )
        let shade = 0.44 + 0.20 * noise(index, 5)
        let box = CGRect(
            x: -size.width / 2,
            y: -size.height / 2,
            width: size.width,
            height: size.height
        )
        let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: (noise(index, 4) - 0.5) * 60 * .pi / 180)
        return Rock(
            id: index,
            path: Path(roundedRect: box, cornerRadius: 9, style: .continuous).applying(transform),
            gradient: Gradient(colors: [Color(white: shade + 0.14), Color(white: shade)]),
            gradientStart: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2),
            gradientEnd: CGPoint(x: centre.x + size.width / 2, y: centre.y + size.height / 2)
        )
    }

    /// Deterministic per-index noise in `0..<1`. Deliberately not `Double.random`:
    /// the mound must not reshuffle between launches, let alone between frames.
    private static func noise(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(index &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9)
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 29
        return Double(x % 1_000) / 1_000
    }
}
