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
/// runs.
@MainActor
final class KeyedTurnQueue<Key: Hashable & Sendable> {
    /// A caller that waits for its turn.
    private struct Waiter {
        /// The id that the cancel handler of the caller names the waiter by.
        let id: Int

        /// The continuation that gives the turn to the caller, or throws
        /// `CancellationError` when its task was cancelled.
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// The callers that wait for their turn, in call order, keyed by the key
    /// of their operation. A key is in the dictionary while an operation of
    /// that key runs.
    private var waiters: [Key: [Waiter]] = [:]

    /// The id of the next caller that waits.
    private var nextWaiterId = 0

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
        guard waiters[key] != nil else {
            waiters[key] = []
            return
        }
        let id = nextWaiterId
        nextWaiterId += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(Waiter(id: id, continuation: continuation), for: key)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id, of: key)
            }
        }
    }

    /// Puts a caller at the end of the waiters of a key. A caller whose task
    /// was already cancelled does not wait: the cancel handler ran before the
    /// caller was in the queue, so the caller throws at once.
    ///
    /// - Parameters:
    ///   - waiter: The caller that waits.
    ///   - key: The key of its operation.
    private func enqueue(_ waiter: Waiter, for key: Key) {
        guard !Task.isCancelled else {
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        waiters[key, default: []].append(waiter)
    }

    /// Takes a cancelled caller out of the waiters of a key, and makes it
    /// throw `CancellationError`. A caller that already has its turn is not in
    /// the queue, so the call then changes nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the waiter.
    ///   - key: The key of its operation.
    private func cancelWaiter(_ id: Int, of key: Key) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }),
            let waiter = waiters[key]?.remove(at: index)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Gives the turn of a key to its next waiter, or marks the key as idle
    /// when no caller waits.
    ///
    /// - Parameter key: The key of the operation that ended.
    private func passTurn(for key: Key) {
        guard var queue = waiters[key], !queue.isEmpty else {
            waiters[key] = nil
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue
        next.continuation.resume()
    }
}
