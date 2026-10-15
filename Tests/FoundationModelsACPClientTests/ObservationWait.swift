import Observation

/// Waits until `condition` is true, with no clock and no poll.
///
/// The wait reads `condition` on the main actor. When it is false, the wait
/// tracks each observable value that `condition` read, and suspends until one
/// of them changes. Then it reads `condition` again. The read and the start of
/// the tracking run in one main-actor step, and the models change their
/// values only on the main actor, so no change can come between them.
///
/// The wait has no time limit. A condition that never becomes true is a
/// defect, and the test then hangs: take a `sample` of the test process to
/// find where.
///
/// - Parameter condition: The condition to wait for. It must read only
///   observable state, or a change of it does not end the wait.
@MainActor
func waitForObservation(until condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                changed.resume()
            }
        }
    }
}

/// The change signal of the test stores that are not observable.
///
/// A test store that a task or a thread changes, for example
/// ``ThreadSafeBuffer``, calls ``post()`` after each change. ``waitUntil(_:)``
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
