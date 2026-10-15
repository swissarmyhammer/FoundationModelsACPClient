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
