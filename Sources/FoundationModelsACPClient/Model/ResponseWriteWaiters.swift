import Foundation

/// Holds the callers that wait until the connection wrote the response of a
/// request that they resolved, or until the connection discarded that
/// response.
///
/// A caller that resolved a request marks its id with ``expect(_:)``, and then
/// waits with ``waitUntilWritten(_:)``. The "written" signal of the id comes
/// from ``signal(_:)``. The signal can arrive before the caller waits: the
/// waiters keep it, and the wait then returns at once.
///
/// A signal for an id that no caller expects changes nothing. Thus a request
/// that a cancel of the turn or a close resolved leaves no state here.
@MainActor
final class ResponseWriteWaiters {
    /// The progress of one expected id.
    private enum Progress {
        /// A caller resolved the request, and the signal did not arrive yet.
        case expected

        /// The signal arrived before the caller waited.
        case written
    }

    /// The progress of each expected id. An id that no caller expects has no
    /// entry.
    private var progress: [UUID: Progress] = [:]

    /// The callers that wait for a signal, keyed by the id of the request.
    private let waiters = KeyedWaiters<UUID, Void>(cancelledValue: ())

    /// Marks an id as expected: a caller resolved its request and waits for
    /// its signal.
    ///
    /// - Parameter id: The id of the resolved request.
    func expect(_ id: UUID) {
        progress[id] = .expected
    }

    /// Suspends until the signal of an expected id arrives.
    ///
    /// The call returns at once when the signal arrived first, when the id is
    /// not expected, and when ``resumeAll()`` ran first. Cancellation of the
    /// task of the caller also ends the wait.
    ///
    /// - Parameter id: The id of the resolved request.
    func waitUntilWritten(_ id: UUID) async {
        guard progress[id] == .expected else {
            progress[id] = nil
            return
        }
        await waiters.wait(for: id)
        // A cancel of the caller ends the wait before the signal, so the id
        // must not stay expected.
        progress[id] = nil
    }

    /// Gives the signal of one id: the connection wrote the response, or it
    /// will never write it.
    ///
    /// - Parameter id: The id of the resolved request.
    func signal(_ id: UUID) {
        guard progress[id] != nil else { return }
        if waiters.resumeFirst(of: id, with: ()) {
            progress[id] = nil
        } else {
            progress[id] = .written
        }
    }

    /// Resumes each caller that waits, and forgets each expected id, so no
    /// caller stays suspended.
    func resumeAll() {
        let ids = Array(progress.keys)
        progress.removeAll()
        for id in ids {
            waiters.resumeFirst(of: id, with: ())
        }
    }
}
