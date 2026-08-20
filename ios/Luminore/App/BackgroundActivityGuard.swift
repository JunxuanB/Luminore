import UIKit

/// Holds the short background grant iOS hands out on request, so a live match
/// link survives a quick trip out of the app.
///
/// The motivating case is the host: the natural thing to do right after creating
/// a room is to switch to a chat app and paste the invite code. Without a
/// background task the process is suspended almost immediately, the relay socket
/// dies, the room is marked host-disconnected — and the friend who types the code
/// seconds later is told it does not exist. Holding the task keeps the socket
/// (or the Bonjour listener / nearby session) up for that round trip.
///
/// The grant is short and best-effort. Anything longer falls back to the normal
/// reconnect paths, which is why this only ever buys time — it never replaces
/// recovery.
@MainActor
final class BackgroundActivityGuard {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Luminore.match") { [weak self] in
            // The grant is about to lapse; release it so the app is not killed
            // for overrunning, and let the reconnect paths take over.
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
