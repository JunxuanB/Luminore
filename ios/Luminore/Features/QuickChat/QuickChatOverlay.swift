import LuminoreCore
import SwiftUI

extension View {
    /// Floats the quick-chat drawer and the latest-message pill over a game board
    /// without touching a line of the board's own layout.
    ///
    /// Apply it **after** the flight/coach/turn-border overlays and **before** the
    /// opening roulette and pause covers: `.overlay` stacks in application order,
    /// so that position makes the modal covers hide the chat for free.
    ///
    /// - Parameter bottomInset: how far above the root's bottom edge the message
    ///   pill sits. The player inventory bar does not ignore the safe area, so the
    ///   default clears its height.
    func quickChatOverlay(
        session: MatchSessionService,
        isEnabled: Bool,
        bottomInset: CGFloat = 96
    ) -> some View {
        modifier(QuickChatOverlayModifier(
            session: session,
            isEnabled: isEnabled,
            bottomInset: bottomInset
        ))
    }
}

private struct QuickChatOverlayModifier: ViewModifier {
    @ObservedObject var session: MatchSessionService
    let isEnabled: Bool
    let bottomInset: CGFloat

    @State private var isOpen = false
    /// 0 closed … 1 fully open, tracking the finger during a drag.
    @State private var dragProgress: CGFloat = 0
    /// Non-nil while the open panel is being dragged shut, overriding `progress`.
    @State private var closeDragProgress: CGFloat?
    @State private var showsPill = false
    /// Counters rather than values, so repeating the same phrase still retriggers
    /// the haptic.
    @State private var sentCount = 0
    @State private var blockedSendCount = 0
    /// Measured panel size — drives both the drag maths and the vertical clamp.
    @State private var drawerSize = QuickChatDrawer.estimatedSize
    /// Window-space Y where the current swipe started. The panel centres on it so
    /// a swipe from the bottom-right corner opens down there, not in the middle.
    /// `nil` falls back to the grabber's resting height.
    @State private var anchorY: CGFloat?
    /// One introductory nudge per match. Lives here rather than in the grabber so
    /// it survives the grabber being hidden and the drawer being opened.
    @State private var hasHintedGrabber = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelWidth: CGFloat { max(1, drawerSize.width) }

    /// Keeps the panel clear of the navigation bar / victory header above and the
    /// player inventory bar below.
    private static let panelTopInset: CGFloat = 88
    private static let panelBottomInset: CGFloat = 96
    /// Resting height of the grabber, as a fraction of the board — a little below
    /// centre so it falls under the thumb.
    private static let grabberPosition: CGFloat = 0.6

    /// The feature is live only during real play, with a human audience, and never
    /// underneath a modal cover.
    private var isActive: Bool {
        isEnabled
            && session.phase == .game
            && !session.isPaused
            && !session.isOpeningTurnSelection
            && session.hasQuickChatAudience
    }

    private var progress: CGFloat {
        if let closeDragProgress { return closeDragProgress }
        return isOpen ? 1 : dragProgress
    }

    private var isRevealing: Bool { isOpen || dragProgress > 0 }

    // Split into three chained helpers: as one expression this exceeds the type
    // checker's budget.
    func body(content: Content) -> some View {
        layers(content).modifier(QuickChatFeedback(
            sentCount: sentCount,
            blockedSendCount: blockedSendCount,
            event: session.quickChatEvent
        ))
    }

    private func layers(_ content: Content) -> some View {
        content
            .background {
                ScreenEdgePan(isEnabled: isActive && !isOpen, edges: .right, onChange: handleEdgePan)
            }
            .overlay(alignment: .bottomLeading) { pillLayer }
            .overlay { scrimLayer }
            .overlay { anchoredLayers }
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: session.quickChatEvent)
            .modifier(QuickChatLifecycle(
                eventID: session.quickChatEvent?.id,
                hasEvent: session.quickChatEvent != nil,
                isOpen: isOpen,
                isActive: isActive,
                onShowPill: { withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { showsPill = true } },
                onHidePill: { withAnimation(.easeOut(duration: 0.45)) { showsPill = false } },
                onAutoClose: close,
                onDeactivate: reset
            ))
    }

    private func reset() {
        isOpen = false
        dragProgress = 0
        closeDragProgress = nil
        anchorY = nil
        showsPill = false
    }

    // MARK: Layers

    @ViewBuilder
    private var pillLayer: some View {
        if let event = session.quickChatEvent, showsPill, isActive {
            QuickChatMessagePill(event: event)
                .padding(.leading, 12)
                .padding(.bottom, bottomInset)
                .transition(pillTransition)
                .allowsHitTesting(false)
                .id(event.id)
        }
    }

    private var pillTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .leading)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.94, anchor: .bottomLeading)),
            removal: .opacity.combined(with: .offset(y: -6))
        )
    }

    @ViewBuilder
    private var scrimLayer: some View {
        if isRevealing {
            // Built only while revealing, so when closed there is nothing to hit-test
            // and board taps are completely unaffected.
            Color.black.opacity(0.12 * Double(progress))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityLabel(Text("quickChat.close.accessibility"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { close() }
                .transition(.opacity)
        }
    }

    /// The drawer and the grabber both need the container's geometry, so they share
    /// one GeometryReader. It is kept out of the modifier chain in `layers` — that
    /// chain already sits near the type checker's budget.
    private var anchoredLayers: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .topTrailing) {
                drawerLayer(containerHeight: height, containerOriginY: proxy.frame(in: .global).minY)
                grabberLayer(containerHeight: height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    @ViewBuilder
    private func drawerLayer(containerHeight: CGFloat, containerOriginY: CGFloat) -> some View {
        if isRevealing {
            QuickChatDrawer(
                progress: progress,
                cooldownEndsAt: session.quickChatCooldownEndsAt,
                onSelect: send
            )
            .background {
                // Measured rather than assumed: the panel hugs its content, so its
                // width differs per language and its height per Dynamic Type size.
                // `onChange` (not `onPreferenceChange`) because the latter's action
                // is `@Sendable` and cannot write to `@State` under Swift 6.
                GeometryReader { drawerProxy in
                    Color.clear.onChange(of: drawerProxy.size, initial: true) { _, size in
                        if size != .zero { drawerSize = size }
                    }
                }
            }
            .offset(x: panelWidth * (1 - progress))
            .offset(y: panelTop(containerHeight: containerHeight, containerOriginY: containerOriginY))
            .allowsHitTesting(isOpen)
            .gesture(closeDrag)
            // The panel leaves the hierarchy as soon as `isRevealing` flips, so the
            // slide-out has to come from the transition, not the offset.
            .transition(.move(edge: .trailing))
        }
    }

    /// Top edge of the panel: centred on wherever the swipe started, then clamped
    /// into the board area so it never rides over the navigation bar or the
    /// inventory bar. Falls back to centring when the panel cannot fit.
    private func panelTop(containerHeight: CGFloat, containerOriginY: CGFloat) -> CGFloat {
        let lowest = containerHeight - Self.panelBottomInset - drawerSize.height
        guard lowest > Self.panelTopInset else {
            return max(0, (containerHeight - drawerSize.height) / 2)
        }
        let localAnchor = anchorY.map { $0 - containerOriginY }
            ?? containerHeight * Self.grabberPosition
        return min(max(localAnchor - drawerSize.height / 2, Self.panelTopInset), lowest)
    }

    @ViewBuilder
    private func grabberLayer(containerHeight: CGFloat) -> some View {
        if isActive {
            QuickChatGrabber(
                shouldHint: !hasHintedGrabber,
                onHintShown: { hasHintedGrabber = true },
                onOpen: {
                    // Tapping opens beside the grabber rather than jumping to centre.
                    anchorY = nil
                    open()
                }
            )
            .offset(y: max(0, containerHeight * Self.grabberPosition - 28))
            // Hidden rather than unmounted while the drawer is out, so its hint
            // task is not restarted every time the drawer closes.
            .opacity(isRevealing ? 0 : 1)
            .allowsHitTesting(!isRevealing)
        }
    }

    // MARK: Interaction

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isOpen else { return }
                let pulled = max(0, value.translation.width)
                closeDragProgress = max(0, 1 - pulled / panelWidth)
            }
            .onEnded { value in
                closeDragProgress = nil
                let pulled = max(0, value.translation.width)
                if pulled > 60 || value.predictedEndTranslation.width > 160 {
                    close()
                } else {
                    open()
                }
            }
    }

    private func handleEdgePan(
        translation: CGFloat,
        velocity: CGFloat,
        locationY: CGFloat,
        state: UIGestureRecognizer.State
    ) {
        guard isActive else { return }
        switch state {
        case .began:
            // Pin the panel to where the finger landed, before any tracking, so it
            // does not slide up or down as the swipe progresses.
            anchorY = locationY
            dragProgress = 0
        case .changed:
            let raw = -translation / panelWidth
            // Rubber-band past fully open so an over-pull still feels alive.
            dragProgress = raw > 1 ? 1 + (raw - 1) * 0.18 : max(0, raw)
        case .ended:
            if dragProgress > 0.45 || velocity < -450 { open() } else { close() }
        case .cancelled, .failed:
            close()
        default:
            break
        }
    }

    private func open() {
        withAnimation(openAnimation) {
            isOpen = true
            dragProgress = 1
        }
    }

    private func close() {
        withAnimation(openAnimation) {
            isOpen = false
            dragProgress = 0
        }
    }

    private var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86)
    }

    private func send(_ phrase: QuickChatPhrase) {
        guard session.canSendQuickChat else {
            blockedSendCount += 1
            return
        }
        session.sendQuickChat(phrase)
        sentCount += 1
        close()
    }
}

/// Pill fade timer, drawer auto-close, and the teardown when the feature goes
/// inactive (pause, roulette, match end).
private struct QuickChatLifecycle: ViewModifier {
    let eventID: UUID?
    let hasEvent: Bool
    let isOpen: Bool
    let isActive: Bool
    let onShowPill: () -> Void
    let onHidePill: () -> Void
    let onAutoClose: () -> Void
    let onDeactivate: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: eventID) {
                guard hasEvent, isActive else { return }
                onShowPill()
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled else { return }
                onHidePill()
            }
            .task(id: isOpen) {
                // A stray edge swipe should never leave the panel parked over the board.
                guard isOpen else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                onAutoClose()
            }
            .onChange(of: isActive) { _, active in
                if !active { onDeactivate() }
            }
    }
}

private struct QuickChatFeedback: ViewModifier {
    let sentCount: Int
    let blockedSendCount: Int
    let event: QuickChatEvent?

    /// Only remote lines get the arrival tap — your own send already had one.
    private var announcesArrival: Bool { event.map { !$0.isLocalAuthor } ?? false }

    func body(content: Content) -> some View {
        // The counters only ever increment, so a plain trigger is enough. The
        // arrival tap needs a condition, and the closure params are annotated
        // because inference across these overloads blows the type checker's budget.
        content
            .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
            .sensoryFeedback(.warning, trigger: blockedSendCount)
            .sensoryFeedback(trigger: event?.id) { (_: UUID?, _: UUID?) -> SensoryFeedback? in
                announcesArrival ? .selection : nil
            }
    }
}
