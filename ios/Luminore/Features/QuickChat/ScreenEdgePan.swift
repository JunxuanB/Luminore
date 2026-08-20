import SwiftUI
import UIKit

/// Arms a `UIScreenEdgePanGestureRecognizer` on the nearest ancestor view
/// controller's view.
///
/// Two properties make this the right tool for the quick-chat drawer:
///
/// - It contributes **no hit area of its own** (zero-size, interaction disabled),
///   so unlike a SwiftUI edge strip it can never swallow a board tap. Recognizers
///   attached to an ancestor still see touches landing on any descendant.
/// - It is scoped to the presenting view controller rather than the window, so a
///   presented sheet — whose view is not a descendant — structurally disables the
///   gesture while it is up.
///
/// `shouldBeRequiredToFailBy` makes competing recognizers (notably the Duel
/// board's paging `TabView`) wait for this one, which fails within milliseconds
/// for any touch that did not start at the edge — so paging feels unchanged.
struct ScreenEdgePan: UIViewRepresentable {
    var isEnabled: Bool
    var edges: UIRectEdge = .right
    /// `(translationX, velocityX, locationY, state)`. Translation and velocity are
    /// in the recognizer's view; `locationY` is in **window** coordinates, because
    /// the recognizer's host view and the SwiftUI overlay do not share an origin —
    /// the caller converts it with `proxy.frame(in: .global)`.
    var onChange: (CGFloat, CGFloat, CGFloat, UIGestureRecognizer.State) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        view.edges = edges
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.onChange = onChange
        view.recognizer?.isEnabled = isEnabled
        view.pendingIsEnabled = isEnabled
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        guard let recognizer = view.recognizer else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat, CGFloat, CGFloat, UIGestureRecognizer.State) -> Void

        init(onChange: @escaping (CGFloat, CGFloat, CGFloat, UIGestureRecognizer.State) -> Void) {
            self.onChange = onChange
        }

        @objc func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            onChange(
                recognizer.translation(in: view).x,
                recognizer.velocity(in: view).x,
                recognizer.location(in: nil).y, // nil = window coordinates
                recognizer.state
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { false }
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?
        var edges: UIRectEdge = .right
        /// Latest value from `updateUIView`, applied once the recognizer exists —
        /// SwiftUI may update the representable before the view reaches a window.
        var pendingIsEnabled = true
        private(set) var recognizer: UIScreenEdgePanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil,
                  recognizer == nil,
                  let coordinator,
                  let host = nearestViewControllerView()
            else { return }
            let pan = UIScreenEdgePanGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.handle(_:))
            )
            pan.edges = edges
            pan.delegate = coordinator
            pan.isEnabled = pendingIsEnabled
            host.addGestureRecognizer(pan)
            recognizer = pan
        }

        private func nearestViewControllerView() -> UIView? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller.view }
                responder = current.next
            }
            return nil
        }
    }
}
