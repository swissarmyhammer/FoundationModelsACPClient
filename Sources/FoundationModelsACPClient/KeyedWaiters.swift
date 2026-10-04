/// Holds callers that wait by key, and resumes each caller exactly one time.
///
/// This is the shared core of each main-actor queue that suspends a caller
/// on a continuation: ``PendingRequestQueue`` keys its calls by the id of the
/// pending item, and ``KeyedTurnQueue`` keys its callers by the key of their
/// operation. The callers of one key wait in call order.
///
/// A caller resumes in one of two ways:
///
/// - ``resumeFirst(of:with:)`` resumes the first caller of a key with a value.
/// - Cancellation of the task of the caller takes the caller out of the
///   queue and resumes it with the cancelled value. A caller whose task was
///   cancelled before the call does not wait: it gets the cancelled value at
///   once.
@MainActor
final class KeyedWaiters<Key: Hashable & Sendable, Value: Sendable> {
    /// A caller that waits.
    private struct Waiter {
        /// The id that the cancel handler of the caller names the waiter by.
        let id: Int

        /// The continuation that the caller is suspended on.
        let continuation: CheckedContinuation<Value, Never>

        /// The step that the owner runs when a cancel takes the caller out of
        /// the queue.
        let onCancel: () -> Void
    }

    /// The callers that wait, in call order, keyed by the key they wait on.
    /// A key with no caller has no entry.
    private var waiters: [Key: [Waiter]] = [:]

    /// The id of the next caller that waits.
    private var nextWaiterId = 0

    /// The value for a caller whose task was cancelled.
    private let cancelledValue: Value

    /// Makes an empty queue.
    ///
    /// - Parameter cancelledValue: The value for a caller whose task was
    ///   cancelled.
    init(cancelledValue: Value) {
        self.cancelledValue = cancelledValue
    }

    /// Suspends the caller at the end of the callers of a key, until a
    /// resumption arrives.
    ///
    /// - Parameters:
    ///   - key: The key the caller waits on.
    ///   - onSuspend: The step that runs when the caller is in the queue. It
    ///     does not run for a caller whose task was cancelled before the call.
    ///   - onCancel: The step that runs when a cancel of the task takes the
    ///     caller out of the queue.
    /// - Returns: The value of the resumption, or the cancelled value.
    func wait(
        for key: Key,
        onSuspend: () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) async -> Value {
        let id = nextWaiterId
        nextWaiterId += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: cancelledValue)
                    return
                }
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation, onCancel: onCancel))
                onSuspend()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id, of: key)
            }
        }
    }

    /// Resumes the first caller of a key with a value.
    ///
    /// - Parameters:
    ///   - key: The key of the caller.
    ///   - value: The value to resume the caller with.
    /// - Returns: `true` when a caller resumed, `false` when no caller waits
    ///   on the key.
    @discardableResult
    func resumeFirst(of key: Key, with value: Value) -> Bool {
        guard var queue = waiters[key], !queue.isEmpty else { return false }
        let first = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        first.continuation.resume(returning: value)
        return true
    }

    /// Takes a cancelled caller out of the callers of a key, resumes it with
    /// the cancelled value, and runs its cancel step. A caller that already
    /// resumed is not in the queue, so the call then changes nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the waiter.
    ///   - key: The key the caller waits on.
    private func cancelWaiter(_ id: Int, of key: Key) {
        guard var queue = waiters[key], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[key] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: cancelledValue)
        waiter.onCancel()
    }
}
