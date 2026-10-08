// How an ``AgentProcess`` ended, and the one place that holds it.
//
// Every teardown path of an agent reaps it in
// `AgentProcessState.terminateCurrent()`, and the `waitpid` of that reap is
// the only source of the status. The teardown records the status here one
// time, and each host call that awaits the end resumes then.

import Synchronization

/// How an agent process ended.
///
/// An ``AgentProcess`` gives this value after its teardown reaped the agent:
/// the agent ended by itself (its stdout closed), or the host called
/// ``AgentProcess/shutdown()``, or the transport ended.
public enum AgentExitStatus: Sendable, Equatable {
    /// The agent called `exit` with this code. `0` is a success.
    case exited(code: Int32)

    /// A signal ended the agent. ``AgentProcess/shutdown()`` ends a live
    /// agent with `SIGKILL`.
    case signaled(signal: Int32)

    /// The teardown did not collect the agent, so its status is not known.
    /// The reap waits for a time limit only, and an agent that the group kill
    /// did not reach can live after that limit.
    case notCollected

    /// The bits of a `waitpid` status that hold the number of the signal
    /// that ended the child. They are `0` when the child called `exit`.
    private static let terminationSignalMask: Int32 = 0x7f

    /// The number of bits that the exit code is above in a `waitpid` status.
    private static let exitCodeShift: Int32 = 8

    /// The bits of the exit code, after the shift of ``exitCodeShift``.
    private static let exitCodeMask: Int32 = 0xff

    /// Decodes a `waitpid` status, as `WIFEXITED`, `WEXITSTATUS` and
    /// `WTERMSIG` do. Swift does not import those C macros.
    ///
    /// The reap does not give `WUNTRACED`, so the status of a stopped child
    /// does not occur here.
    ///
    /// - Parameter waitStatus: The status that `waitpid` wrote for a child it
    ///   collected.
    init(waitStatus: Int32) {
        let signal = waitStatus & Self.terminationSignalMask
        guard signal != 0 else {
            self = .exited(code: (waitStatus >> Self.exitCodeShift) & Self.exitCodeMask)
            return
        }
        self = .signaled(signal: signal)
    }
}

/// Holds the exit status of one agent, and the host calls that wait for it.
///
/// A plain `final class` with a `Mutex` rather than an actor, for the reason
/// of ``AgentProcessState``: the teardown that records the status runs
/// synchronously, also from `deinit`.
final class AgentExitLatch: Sendable {
    /// The status, or `nil` while the agent is not reaped, and the callers
    /// that wait for it, by waiter id.
    private struct Record {
        /// The recorded status, or `nil` before the record.
        var status: AgentExitStatus?

        /// The callers that wait for the status, by waiter id.
        var waiters: [Int: CheckedContinuation<AgentExitStatus, any Error>] = [:]

        /// The id of the next caller that waits.
        var nextWaiterId = 0
    }

    /// The status and the waiting callers.
    private let state = Mutex(Record())

    /// The recorded status, or `nil` before the record.
    var status: AgentExitStatus? {
        state.withLock { $0.status }
    }

    /// Records the status and resumes each waiting caller with it. Only the
    /// first record has an effect, because an agent ends one time.
    ///
    /// - Parameter status: How the agent ended.
    func record(_ status: AgentExitStatus) {
        let released = state.withLock { current -> [CheckedContinuation<AgentExitStatus, any Error>] in
            guard current.status == nil else { return [] }
            current.status = status
            let waiters = Array(current.waiters.values)
            current.waiters = [:]
            return waiters
        }
        for waiter in released {
            waiter.resume(returning: status)
        }
    }

    /// Waits until the status is recorded.
    ///
    /// - Returns: The recorded status. A caller that calls after the record
    ///   gets it at once.
    /// - Throws: `CancellationError` when the task of the caller is cancelled
    ///   before the record.
    func wait() async throws -> AgentExitStatus {
        let id = state.withLock { current -> Int in
            defer { current.nextWaiterId += 1 }
            return current.nextWaiterId
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enroll(continuation, id: id)
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Resumes `continuation` at once when the status is recorded or the task
    /// is cancelled, and otherwise keeps it until the record or the cancel.
    ///
    /// The cancel test runs inside the lock. A cancel handler that ran before
    /// this call found no waiter to remove, and the test here then sees the
    /// cancel, so no caller waits after its cancel.
    ///
    /// - Parameters:
    ///   - continuation: The continuation the caller is suspended on.
    ///   - id: The waiter id of the caller.
    private func enroll(_ continuation: CheckedContinuation<AgentExitStatus, any Error>, id: Int) {
        let ready = state.withLock { current -> Result<AgentExitStatus, any Error>? in
            if let status = current.status {
                return .success(status)
            }
            guard !Task.isCancelled else {
                return .failure(CancellationError())
            }
            current.waiters[id] = continuation
            return nil
        }
        if let ready {
            continuation.resume(with: ready)
        }
    }
}
