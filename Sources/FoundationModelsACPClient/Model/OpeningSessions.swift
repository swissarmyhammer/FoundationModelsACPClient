import FoundationModelsACP
import Synchronization

// The sessions that are opening: the agent answered `session/new`, and the
// model of the session is not in `ConnectionModel.openSessions` yet.
//
// The agent can send a permission request or an elicitation for the new
// session in the frame that comes directly after the `session/new` answer.
// The handler of that request starts on another task, and it can reach the
// router before `newSession(_:)` registers the model. The `onResponse` hook
// of the wire runs on the reader, in frame order, before the next frame, so
// it marks the session as opening before the handler can start. A handler
// that does not find the model then waits until the open ends, and does not
// answer cancel too early.
//
// The hook does not run on the main actor, so the store is a `Mutex`, and
// not main-actor state.

/// The sessions that are opening, and the routed requests that wait for
/// them.
///
/// Each mark ends with exactly one ``finish(_:)``, from the call of
/// `newSession(_:)` that made the mark, after its register or after its
/// failure. The agent already answered, so that call always ends, and no
/// wait depends on the agent.
final class OpeningSessions: Sendable {
    /// The callers that wait for one session that is opening.
    private struct Opening {
        /// The routed requests that wait until the open ends.
        var waiters: [CheckedContinuation<Void, Never>] = []

        /// The callers of ``waitForAWaiter(on:)``.
        var waiterWatchers: [CheckedContinuation<Void, Never>] = []
    }

    /// Each session that is opening, keyed by session id.
    private let opening = Mutex<[SessionId: Opening]>([:])

    /// Marks a session as opening. A second mark of the same session keeps
    /// its waiters.
    ///
    /// - Parameter sessionId: The id that the `session/new` answer gave.
    func markOpening(_ sessionId: SessionId) {
        opening.withLock { opening in
            opening[sessionId] = opening[sessionId] ?? Opening()
        }
    }

    /// Ends the open of a session, and resumes each caller that waits for
    /// it. A session that is not opening changes nothing.
    ///
    /// - Parameter sessionId: The id of the session.
    func finish(_ sessionId: SessionId) {
        let ended = opening.withLock { opening in
            opening.removeValue(forKey: sessionId)
        }
        for continuation in (ended?.waiters ?? []) + (ended?.waiterWatchers ?? []) {
            continuation.resume()
        }
    }

    /// Waits while a session is opening. Returns at once when the session is
    /// not opening.
    ///
    /// - Parameter sessionId: The id of the session.
    func waitWhileOpening(_ sessionId: SessionId) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let watchers = opening.withLock { opening -> [CheckedContinuation<Void, Never>]? in
                guard var entry = opening[sessionId] else { return nil }
                entry.waiters.append(continuation)
                let watchers = entry.waiterWatchers
                entry.waiterWatchers = []
                opening[sessionId] = entry
                return watchers
            }
            guard let watchers else {
                continuation.resume()
                return
            }
            for watcher in watchers {
                watcher.resume()
            }
        }
    }

    /// Waits until a routed request waits for a session that is opening, or
    /// until the open of that session ends. Returns at once when the session
    /// is not opening, or when a request already waits.
    ///
    /// Only a test uses this event, to fix the order of a request and the
    /// register of its session.
    ///
    /// - Parameter sessionId: The id of the session.
    func waitForAWaiter(on sessionId: SessionId) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let watches = opening.withLock { opening -> Bool in
                guard var entry = opening[sessionId], entry.waiters.isEmpty else { return false }
                entry.waiterWatchers.append(continuation)
                opening[sessionId] = entry
                return true
            }
            if !watches {
                continuation.resume()
            }
        }
    }
}

/// The session id that one `session/new` call marked as opening, if the
/// agent answered it.
///
/// The `onResponse` hook writes it on the reader, and the call reads it when
/// it ends, so the call ends the open that it started.
final class OpeningTicket: Sendable {
    /// The marked id, or `nil` before the answer.
    private let sessionId = Mutex<SessionId?>(nil)

    /// Records the id that the answer gave.
    ///
    /// - Parameter id: The id of the new session.
    func record(_ id: SessionId) {
        sessionId.withLock { $0 = id }
    }

    /// The recorded id, or `nil` when no answer came.
    var recorded: SessionId? {
        sessionId.withLock { $0 }
    }
}
