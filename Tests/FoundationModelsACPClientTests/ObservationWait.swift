import Observation
import Testing

// The waits of the tests (rule T1 of the elicitation plan, section 10). Each
// wait ends when its condition becomes true or when its failure event comes,
// for example the close of the connection, the close of the session or the
// end of the task that must make the change. A wait that ends on its failure
// event records an issue at the call site and throws, so the test stops and
// does not hang. No wait reads a clock or polls.

/// The error of a wait that ended on its failure event before its condition
/// became true.
struct WaitEndedOnFailure: Error, CustomStringConvertible {
    /// Where the wait is in the test.
    let sourceLocation: SourceLocation

    var description: String {
        "The wait ended on its failure event before its condition became true (\(sourceLocation))."
    }
}

/// The failure condition of a wait that has no failure event.
///
/// Use it only when no event can tell that the change will never come, and
/// write the reason in a comment at the call site. Such a wait is a known
/// limit of rule T1: it hangs when the code under test is wrong.
let noFailureEvent: @MainActor () -> Bool = { false }

/// Waits until `condition` is true, or until `failure` is true, with no clock
/// and no poll.
///
/// The wait reads both closures on the main actor. When both are false, the
/// wait tracks each observable value that they read, and suspends until one
/// of them changes. Then it reads them again. The read and the start of the
/// tracking run in one main-actor step, and the models change their values
/// only on the main actor, so no change can come between them.
///
/// - Parameters:
///   - condition: The condition to wait for. It must read only observable
///     state, or a change of it does not end the wait.
///   - failure: The failure event of the wait, for example the close of the
///     connection. It must read only observable state.
///   - sourceLocation: The call site, for the issue of a failed wait.
/// - Throws: ``WaitEndedOnFailure`` when `failure` became true first. The
///   wait then also records an issue.
@MainActor
func waitForObservation(
    until condition: @escaping @MainActor () -> Bool,
    orFailWhen failure: @escaping @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let ended: @MainActor () -> Bool = { condition() || failure() }
    while !ended() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = ended()
            } onChange: {
                changed.resume()
            }
        }
    }
    guard condition() else {
        let error = WaitEndedOnFailure(sourceLocation: sourceLocation)
        Issue.record(error, sourceLocation: sourceLocation)
        throw error
    }
}

/// Tells when a task ended, as observable state, so a wait can end on it.
///
/// A test that waits for a change that a task must make uses the end of that
/// task as the failure event: when the task ended and the change did not
/// come, the change never comes.
@MainActor @Observable
final class TaskEnd {
    /// Whether the task ended, with a value, an error or a cancel.
    private(set) var hasEnded = false

    /// Starts to watch a task.
    ///
    /// - Parameter task: The task to watch.
    init<Success: Sendable, Failure: Error>(of task: Task<Success, Failure>) {
        Task { [weak self] in
            _ = await task.result
            self?.hasEnded = true
        }
    }
}

/// The change signal of the test stores that are not observable.
///
/// A test store that a task or a thread changes, for example
/// ``ThreadSafeBuffer``, calls ``post()`` after each change. ``waitUntil(_:orFailWhen:sourceLocation:)``
/// tracks ``generation``, so each change of such a store makes the wait read
/// its condition again. The signal carries no value: a wait that wakes for the
/// change of another store reads its condition, finds it false, and waits
/// again.
@MainActor @Observable
final class TestChangeSignal {
    /// The one signal of the test process.
    static let shared = TestChangeSignal()

    /// The count of the changes that ``post()`` gave. Only its change has a
    /// meaning.
    private(set) var generation = 0

    /// Makes the signal.
    private init() {}

    /// Tells each wait that a test store changed.
    ///
    /// The call can come from any task or thread. The count changes on the
    /// main actor after the change of the store, so a wait that wakes reads
    /// the changed store.
    nonisolated static func post() {
        Task { @MainActor in
            shared.generation += 1
        }
    }
}
