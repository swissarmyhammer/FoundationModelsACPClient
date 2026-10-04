/// Runs the operations of one key one after the other, in call order.
///
/// An operation of a key starts only after the earlier operation of the same
/// key returned or threw. Operations of different keys do not wait for each
/// other. The connection model uses one queue for the `session/resume`
/// requests, keyed by session id, so two resumes of one session never share
/// one replay.
///
/// A caller that waits for its turn obeys the cancel of its task: it leaves
/// the queue at once and throws `CancellationError`, and its operation never
/// runs. The shared ``KeyedWaiters`` holds the callers that wait.
@MainActor
final class KeyedTurnQueue<Key: Hashable & Sendable> {
    /// How a caller that waited for its turn resumes.
    private enum Turn {
        /// The earlier operation of the key ended, so the caller runs now.
        case granted

        /// The task of the caller was cancelled while it waited.
        case cancelled
    }

    /// The keys that have a running operation.
    private var runningKeys: Set<Key> = []

    /// The callers that wait for their turn, keyed by the key of their
    /// operation.
    private let waiters = KeyedWaiters<Key, Turn>(cancelledValue: .cancelled)

    /// Makes a queue with no running operation.
    init() {}

    /// Runs an operation when the earlier operations of its key ended.
    ///
    /// - Parameters:
    ///   - key: The key of the operation.
    ///   - operation: The operation to run.
    /// - Returns: Whatever `operation` returned.
    /// - Throws: `CancellationError` when the task was cancelled while it
    ///   waited for its turn, so `operation` did not run; or whatever
    ///   `operation` threw.
    func run<Output>(for key: Key, _ operation: () async throws -> Output) async throws -> Output {
        try await takeTurn(for: key)
        defer { passTurn(for: key) }
        return try await operation()
    }

    /// Waits until no earlier operation of a key runs, and marks the key as
    /// running.
    ///
    /// - Parameter key: The key of the operation.
    /// - Throws: `CancellationError` when the task was cancelled before the
    ///   turn came. The key then does not run for this caller.
    private func takeTurn(for key: Key) async throws {
        guard runningKeys.contains(key) else {
            runningKeys.insert(key)
            return
        }
        guard await waiters.wait(for: key) == .granted else {
            throw CancellationError()
        }
    }

    /// Gives the turn of a key to its next waiter, or marks the key as idle
    /// when no caller waits.
    ///
    /// - Parameter key: The key of the operation that ended.
    private func passTurn(for key: Key) {
        if !waiters.resumeFirst(of: key, with: .granted) {
            runningKeys.remove(key)
        }
    }
}
