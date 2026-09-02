import SwiftUI

/// A rounded-rectangle path that starts at the top edge's midpoint and runs
/// **counter-clockwise** (left first), so `.trim(from: 0, to: f)` yields an arc
/// anchored at 12 o'clock that recedes as `f` shrinks.
///
/// Nothing existing does this: `ContainerRelativeShape` cannot be trimmed
/// usefully, and every other border in the app strokes a full outline.
///
/// SwiftUI angles run clockwise on screen (y grows downward), so drawing
/// counter-clockwise means *decreasing* angle — i.e. `clockwise: true`.
struct MiningRingShape: Shape {
    var cornerRadius: CGFloat = 56

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(270),
            endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(-90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

/// The thick rainbow countdown that wraps the whole screen during a dig.
///
/// Progress comes from the host's absolute `startedAt`/`endsAt`, the same trick
/// `OpeningTurnRouletteView` uses, so every device's ring empties together
/// without a single extra message.
struct MiningCountdownRing: View {
    let startedAt: Date
    let endsAt: Date
    /// Set once the window closes so the ring fades out instead of snapping away.
    var isFadingOut: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lineWidth: CGFloat = 20
    private static let palette: [Color] = [
        Color(red: 0.40, green: 0.80, blue: 1.00),
        Color(red: 0.60, green: 0.55, blue: 1.00),
        Color(red: 0.90, green: 0.50, blue: 0.95),
        Color(red: 1.00, green: 0.55, blue: 0.75),
        Color(red: 1.00, green: 0.82, blue: 0.45),
        Color(red: 0.50, green: 1.00, blue: 0.75),
        Color(red: 0.40, green: 0.80, blue: 1.00),
    ]

    var body: some View {
        // 30 fps, matching `CurrentTurnBorder`. The ring is a full-screen stroked
        // path; redrawing it 60 times a second competes with the tap race running
        // inside it, and the extra frames buy nothing on a 5-plus-second sweep.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isFadingOut)) { context in
            let remaining = fraction(at: context.date)
            let shimmer = reduceMotion
                ? Angle.zero
                : .degrees((context.date.timeIntervalSinceReferenceDate * 90).truncatingRemainder(dividingBy: 360))
            ring(remaining: remaining, shimmer: shimmer)
        }
        .padding(Self.lineWidth / 2)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(isFadingOut ? 0 : 1)
        .animation(.easeOut(duration: 0.45), value: isFadingOut)
    }

    private func ring(remaining: Double, shimmer: Angle) -> some View {
        MiningRingShape()
            .trim(from: 0, to: remaining)
            .stroke(
                AngularGradient(gradient: Gradient(colors: Self.palette), center: .center, angle: shimmer),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
            )
            // The bloom is a second, wider, fainter stroke — no `.shadow` and no
            // `.blur`, both of which force a full-screen offscreen pass on every
            // frame. That is far too expensive to run underneath a tap race, and
            // the soft edge of a rounded cap reads much the same.
            .background(
                MiningRingShape()
                    .trim(from: 0, to: remaining)
                    .stroke(
                        AngularGradient(gradient: Gradient(colors: Self.palette), center: .center, angle: shimmer),
                        style: StrokeStyle(lineWidth: Self.lineWidth * 1.9, lineCap: .round)
                    )
                    .opacity(0.22)
            )
            // The last moments dim on their own, so "time's up" reads before the
            // arc has fully disappeared.
            .opacity(0.35 + 0.65 * min(1, remaining * 4))
    }

    private func fraction(at date: Date) -> Double {
        let total = endsAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 0 }
        let remaining = endsAt.timeIntervalSince(date)
        return min(max(remaining / total, 0), 1)
    }
}
